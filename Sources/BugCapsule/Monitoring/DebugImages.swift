import Darwin
import Foundation
import MachO

/// A loaded Mach-O image (monitoring-v1 §3 `macho` debug image).
struct DebugImage: Sendable, Equatable {
    let path: String
    /// LC_UUID, lower case with dashes (the dSYM's UUID).
    let debugId: String
    let loadAddress: UInt64
    /// `__TEXT` vmaddr (file address of the image start).
    let vmAddress: UInt64
    /// `__TEXT` size.
    let size: UInt64
    let arch: String

    func contains(_ address: UInt64) -> Bool { address >= loadAddress && address < loadAddress + size }

    var json: JSONValue {
        [
            "type": "macho", "debugId": .string(debugId), "codeFile": .string(path),
            "imageAddr": .string(hex(loadAddress)), "imageSize": .int(Int(size)), "imageVmAddr": .string(hex(vmAddress)),
            "arch": .string(arch),
        ]
    }

    init(path: String, debugId: String, loadAddress: UInt64, vmAddress: UInt64, size: UInt64, arch: String) {
        self.path = path
        self.debugId = debugId
        self.loadAddress = loadAddress
        self.vmAddress = vmAddress
        self.size = size
        self.arch = arch
    }

    /// From a debug image JSON written by an earlier launch (crash report).
    init?(json: JSONValue) {
        guard let id = json["debugId"]?.stringValue, let load = parseHex(json["imageAddr"]?.stringValue),
            let size = json["imageSize"]?.intValue
        else { return nil }
        debugId = id
        path = json["codeFile"]?.stringValue ?? ""
        loadAddress = load
        vmAddress = parseHex(json["imageVmAddr"]?.stringValue) ?? 0
        self.size = UInt64(max(size, 0))
        arch = json["arch"]?.stringValue ?? ""
    }

    /// Reads LC_UUID and the `__TEXT` segment of a 64-bit image header.
    static func parse(header: UnsafePointer<mach_header>, path: String) -> DebugImage? {
        let raw = UnsafeRawPointer(header)
        let h = raw.loadUnaligned(as: mach_header_64.self)
        guard h.magic == MH_MAGIC_64 else { return nil }
        var cursor = raw.advanced(by: MemoryLayout<mach_header_64>.size)
        var uuid: String?
        var vmaddr: UInt64 = 0
        var vmsize: UInt64 = 0
        for _ in 0..<h.ncmds {
            let cmd = cursor.loadUnaligned(as: load_command.self)
            if cmd.cmd == LC_UUID {
                let u = cursor.loadUnaligned(as: uuid_command.self).uuid
                uuid = UUID(uuid: u).uuidString.lowercased()
            } else if cmd.cmd == LC_SEGMENT_64 {
                let seg = cursor.loadUnaligned(as: segment_command_64.self)
                let name = withUnsafeBytes(of: seg.segname) { bytes in
                    String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                }
                if name == "__TEXT" {
                    vmaddr = seg.vmaddr
                    vmsize = seg.vmsize
                }
            }
            if cmd.cmdsize == 0 { break }
            cursor = cursor.advanced(by: Int(cmd.cmdsize))
        }
        guard let uuid, vmsize > 0 else { return nil }
        return DebugImage(
            path: path, debugId: uuid, loadAddress: UInt64(UInt(bitPattern: raw)), vmAddress: vmaddr, size: vmsize,
            arch: archName(h.cputype, h.cpusubtype))
    }

    static func archName(_ type: cpu_type_t, _ subtype: cpu_subtype_t) -> String {
        switch type {
        case CPU_TYPE_ARM64: return (UInt32(bitPattern: subtype) & ~CPU_SUBTYPE_MASK) == UInt32(bitPattern: CPU_SUBTYPE_ARM64E) ? "arm64e" : "arm64"
        case CPU_TYPE_X86_64: return "x86_64"
        default: return "unknown"
        }
    }
}

func hex(_ v: UInt64) -> String { "0x" + String(v, radix: 16) }

func parseHex(_ s: String?) -> UInt64? {
    guard var s else { return nil }
    if s.hasPrefix("0x") || s.hasPrefix("0X") { s.removeFirst(2) }
    return UInt64(s, radix: 16)
}

/// The images of this process, kept current through dyld callbacks; the
/// list is mirrored into the crash writer's buffer for native crashes.
final class DebugImageCache: @unchecked Sendable {
    static let shared = DebugImageCache()

    private let lock = NSLock()
    private var images: [DebugImage] = []
    private var started = false
    private var mirrorScheduled = false
    private var mirror: (@Sendable ([DebugImage]) -> Void)?

    var all: [DebugImage] {
        startIfNeeded()
        return lock.locked { images }
    }

    func startIfNeeded() {
        let first = lock.locked { () -> Bool in
            if started { return false }
            started = true
            return true
        }
        guard first else { return }
        // Called once per image already loaded, then for every dlopen.
        _dyld_register_func_for_add_image { header, _ in
            guard let header else { return }
            DebugImageCache.shared.added(header)
        }
    }

    private func added(_ header: UnsafePointer<mach_header>) {
        var info = Dl_info()
        let path = dladdr(UnsafeRawPointer(header), &info) != 0 && info.dli_fname != nil ? String(cString: info.dli_fname) : ""
        guard let image = DebugImage.parse(header: header, path: path) else { return }
        let schedule = lock.locked { () -> Bool in
            let i = images.firstIndex { $0.loadAddress > image.loadAddress } ?? images.count
            images.insert(image, at: i)
            if mirror == nil || mirrorScheduled { return false }
            mirrorScheduled = true
            return true
        }
        if schedule { scheduleMirror() }
    }

    /// [body] receives the full list now and after images are added.
    func mirror(into body: @escaping @Sendable ([DebugImage]) -> Void) {
        startIfNeeded()
        let list = lock.locked { () -> [DebugImage] in
            mirror = body
            return images
        }
        body(list)
    }

    private func scheduleMirror() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { [self] in
            let (list, body) = lock.locked { () -> ([DebugImage], (@Sendable ([DebugImage]) -> Void)?) in
                mirrorScheduled = false
                return (images, mirror)
            }
            body?(list)
        }
    }

    func image(containing address: UInt64) -> DebugImage? {
        startIfNeeded()
        return lock.locked {
            // Sorted by load address: binary search for the last start ≤ address.
            var lo = 0
            var hi = images.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if images[mid].loadAddress <= address { lo = mid + 1 } else { hi = mid }
            }
            guard lo > 0 else { return nil }
            let candidate = images[lo - 1]
            return candidate.contains(address) ? candidate : nil
        }
    }

    func image(debugId: String) -> DebugImage? {
        startIfNeeded()
        return lock.locked { images.first { $0.debugId == debugId } }
    }

    static var mainExecutablePath: String? {
        Bundle.main.executablePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }
}

/// On-device symbol names (`dladdr`), demangled when they are Swift symbols.
enum Symbolicator {
    private typealias Demangle = @convention(c) (
        UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
    ) -> UnsafeMutablePointer<CChar>?

    private static let demangler: Demangle? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }
        return unsafeBitCast(sym, to: Demangle.self)
    }()

    static func demangle(_ name: String) -> String {
        guard name.hasPrefix("$s") || name.hasPrefix("_$s") || name.hasPrefix("$S") || name.hasPrefix("_T"),
            let demangler
        else { return name }
        return name.withCString { ptr -> String in
            guard let out = demangler(ptr, strlen(ptr), nil, nil, 0) else { return name }
            defer { free(out) }
            return String(cString: out)
        }
    }

    /// The symbol containing [address], or nil (stripped or not exported).
    static func function(at address: UInt64) -> String? {
        guard let ptr = UnsafeRawPointer(bitPattern: UInt(address)) else { return nil }
        var info = Dl_info()
        guard dladdr(ptr, &info) != 0, let name = info.dli_sname else { return nil }
        let s = String(cString: name)
        if s == "<redacted>" { return nil }
        return demangle(s)
    }
}

/// Device facts for `contexts` (sysctl).
enum DeviceInfo {
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
            return true
        #else
            return false
        #endif
    }

    static var model: String {
        if isSimulator, let m = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return m }
        #if os(macOS)
            return sysctlString("hw.model") ?? "Mac"
        #else
            return sysctlString("hw.machine") ?? "unknown"
        #endif
    }

    static var arch: String {
        #if arch(arm64)
            return "arm64"
        #elseif arch(x86_64)
            return "x86_64"
        #else
            return "unknown"
        #endif
    }

    static var osBuild: String? { sysctlString("kern.osversion") }

    /// When this process started (kinfo_proc), for cold app start.
    static var processStart: Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }
}
