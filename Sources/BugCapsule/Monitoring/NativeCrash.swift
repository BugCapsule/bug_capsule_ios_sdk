import BugCapsuleCrash
import Foundation

/// A report written by the native crash handler (BugCapsuleCrash) in an
/// earlier launch.
struct NativeCrashReport: Equatable {
    var kind: String
    var signal: Int32
    var code: Int
    var address: UInt64
    var exception: Int
    var exceptionCode: UInt64
    var exceptionSubcode: UInt64
    var time: Date
    /// The uncaught-exception handler already queued the event.
    var suppressed: Bool
    /// Innermost first.
    var frames: [UInt64]
    /// Every thread the writer could walk (empty in reports of older SDKs).
    var threads: [ThreadSample] = []
    /// Of the process that crashed (nil in reports of older SDKs).
    var release: String?
    var environment: String?
    var context: JSONObject?
    var images: [DebugImage]

    static func parse(_ data: Data) -> NativeCrashReport? {
        let bytes = [UInt8](data)
        var i = 0
        func line() -> String? {
            guard i < bytes.count else { return nil }
            let start = i
            while i < bytes.count && bytes[i] != 0x0A { i += 1 }
            let s = String(decoding: bytes[start..<i], as: UTF8.self)
            i += 1
            return s
        }
        func blob(_ length: Int) -> Data? {
            guard length >= 0, i + length <= bytes.count else { return nil }
            let d = Data(bytes[i..<i + length])
            i += length + 1
            return d
        }
        guard line() == "BCCRASH 1" else { return nil }
        var r = NativeCrashReport(
            kind: "signal", signal: 0, code: 0, address: 0, exception: 0, exceptionCode: 0, exceptionSubcode: 0,
            time: Date(), suppressed: false, frames: [], context: nil, images: [])
        var ended = false
        while let l = line() {
            let parts = l.split(separator: " ", maxSplits: 1).map(String.init)
            guard let key = parts.first else { continue }
            let value = parts.count > 1 ? parts[1] : ""
            switch key {
            case "kind": r.kind = value
            case "signal": r.signal = Int32(value) ?? 0
            case "code": r.code = Int(value) ?? 0
            case "addr": r.address = parseHex(value) ?? 0
            case "exception": r.exception = Int(value) ?? 0
            case "exceptionCode": r.exceptionCode = parseHex(value) ?? 0
            case "exceptionSubcode": r.exceptionSubcode = parseHex(value) ?? 0
            case "time": r.time = Date(timeIntervalSince1970: TimeInterval(Int(value) ?? 0))
            case "suppressed": r.suppressed = value == "1"
            case "frame": if let a = parseHex(value) { r.frames.append(a) }
            case "thread":
                let f = value.split(separator: " ").map { Int($0) ?? 0 }
                guard f.count >= 4 else { break }
                r.threads.append(
                    ThreadSample(index: f[0], name: nil, crashed: f[1] == 1, current: f[2] == 1, isMain: f[3] == 1, frames: []))
            case "threadname": if !r.threads.isEmpty, !value.isEmpty { r.threads[r.threads.count - 1].name = value }
            case "tframe": if !r.threads.isEmpty, let a = parseHex(value) { r.threads[r.threads.count - 1].frames.append(a) }
            case "release":
                if let d = blob(Int(value) ?? -1) { r.release = String(decoding: d, as: UTF8.self) }
            case "environment":
                if let d = blob(Int(value) ?? -1) { r.environment = String(decoding: d, as: UTF8.self) }
            case "context":
                if let d = blob(Int(value) ?? -1) { r.context = (try? JSON.parse(d))?.objectValue }
            case "images":
                if let d = blob(Int(value) ?? -1) {
                    r.images = ((try? JSON.parse(d))?.arrayValue ?? []).compactMap(DebugImage.init(json:))
                        .sorted { $0.loadAddress < $1.loadAddress }
                }
            case "end": ended = true
            default: break
            }
            if ended { break }
        }
        // A report cut short (the process died mid-write) still counts.
        return r
    }

    static let signalNames: [Int32: String] = [
        SIGABRT: "SIGABRT", SIGBUS: "SIGBUS", SIGFPE: "SIGFPE", SIGILL: "SIGILL", SIGSEGV: "SIGSEGV", SIGTRAP: "SIGTRAP",
        SIGSYS: "SIGSYS",
    ]
    static let exceptionNames: [Int: String] = [
        1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 6: "EXC_BREAKPOINT",
    ]

    var isMach: Bool { kind == "mach" }

    /// `type` / `value` / mechanism of the exception value.
    var description: (type: String, value: String, mechanism: String, data: JSONObject) {
        if isMach {
            let name = Self.exceptionNames[exception] ?? "EXC_\(exception)"
            var value: String
            switch exception {
            case 1: value = "Bad access at \(hex(exceptionSubcode)) (code \(hex(exceptionCode)))"
            case 6: value = "Trap: a Swift runtime check failed or the process hit a breakpoint instruction"
            default: value = "\(name) code \(hex(exceptionCode)) subcode \(hex(exceptionSubcode))"
            }
            if exception == 2 { value = "Illegal instruction at \(hex(exceptionSubcode))" }
            return (
                name, value, "mach_exception",
                ["exception": .int(exception), "code": .string(hex(exceptionCode)), "subcode": .string(hex(exceptionSubcode))]
            )
        }
        let name = Self.signalNames[signal] ?? "SIG\(signal)"
        let value: String
        switch signal {
        case SIGABRT: value = "Abort: the process called abort()"
        case SIGTRAP: value = "Trap: a Swift runtime check failed or the process hit a breakpoint instruction"
        case SIGSEGV, SIGBUS: value = "Bad access at \(hex(address)) (si_code \(code))"
        default: value = "\(name) at \(hex(address)) (si_code \(code))"
        }
        return (name, value, "signal", ["signal": .int(Int(signal)), "code": .int(code), "address": .string(hex(address))])
    }
}

/// Swift side of the native crash handler: installs it, keeps its context
/// buffer current and reads the report left by the previous launch.
enum NativeCrashHandler {
    static func reportFile(in directory: URL) -> URL { directory.appendingPathComponent("crash.report") }

    /// The previous launch's report (removed from disk).
    static func takePendingReport(in directory: URL) -> NativeCrashReport? {
        let file = reportFile(in: directory)
        guard let data = try? Data(contentsOf: file) else { return nil }
        FileIO.deleteQuietly(file)
        return NativeCrashReport.parse(data)
    }

    static func install(directory: URL, mach: Bool) -> Bool {
        let path = reportFile(in: directory).path
        let ok = path.withCString { bc_crash_install($0, mach) } == 0
        DebugImageCache.shared.mirror { images in
            let bytes = JSON.encodeData(.array(images.map(\.json)))
            bytes.withUnsafeBytes { raw in
                bc_crash_set_images(raw.baseAddress?.assumingMemoryBound(to: CChar.self), raw.count)
            }
        }
        return ok
    }

    static let contextLimit = Int(BC_CRASH_CONTEXT_MAX)

    /// Mirrors [context] into the crash writer's buffer. Too large for it:
    /// the oldest breadcrumbs go first, then the extras.
    static func setContext(_ context: JSONObject) {
        var c = context
        var bytes = JSON.encodeData(.object(c))
        while bytes.count > contextLimit, var crumbs = c["breadcrumbs"]?.arrayValue, !crumbs.isEmpty {
            crumbs.removeFirst(max(crumbs.count / 4, 1))
            c["breadcrumbs"] = .array(crumbs)
            bytes = JSON.encodeData(.object(c))
        }
        if bytes.count > contextLimit {
            c["extra"] = ["_truncated": true]
            bytes = JSON.encodeData(.object(c))
        }
        bytes.withUnsafeBytes { raw in
            bc_crash_set_context(raw.baseAddress?.assumingMemoryBound(to: CChar.self), raw.count)
        }
    }

    /// Written with every report: the release that crashed.
    static func setRelease(_ release: String, environment: String) {
        let r = Data(release.replacingOccurrences(of: "\n", with: " ").utf8)
        let e = Data(environment.replacingOccurrences(of: "\n", with: " ").utf8)
        r.withUnsafeBytes { rr in
            e.withUnsafeBytes { er in
                bc_crash_set_release(
                    rr.baseAddress?.assumingMemoryBound(to: CChar.self), rr.count,
                    er.baseAddress?.assumingMemoryBound(to: CChar.self), er.count)
            }
        }
    }

    static var isInstalled: Bool { bc_crash_is_installed() != 0 }
    static var machInstalled: Bool { bc_crash_mach_installed() != 0 }
    static var debuggerAttached: Bool { bc_debugger_attached() }

    static func suppressNextEvent() { bc_crash_suppress_next_event() }

    static func uninstallForTesting() { bc_crash_uninstall() }

    /// Writes a report from the current stack without crashing (tests).
    @discardableResult
    static func writeTestReport(signal: Int32) -> Bool { bc_crash_write_test_report(signal) == 0 }

    /// Return addresses of another thread (suspended while sampled).
    static func backtrace(ofThread port: UInt32, max: Int = 128) -> [UInt64] {
        var frames = [UInt](repeating: 0, count: max)
        let n = frames.withUnsafeMutableBufferPointer { bc_thread_backtrace(port, $0.baseAddress, Int32(max)) }
        return frames.prefix(Int(n)).map { UInt64($0) }
    }

    static var currentThreadPort: UInt32 { bc_current_thread_port() }

    static var mainThreadPort: UInt32 { bc_main_thread_port() }

    /// The arm64 leaf-frame rule of the walker (`bc_insert_link_register`).
    static func insertLinkRegister(pc: UInt64, lr: UInt64, frames: [UInt64], max: Int = 128) -> [UInt64] {
        var buffer = frames.map { UInt($0) } + [UInt](repeating: 0, count: Swift.max(max - frames.count, 0))
        let n = buffer.withUnsafeMutableBufferPointer {
            bc_insert_link_register(UInt(pc), UInt(lr), $0.baseAddress, Int32(frames.count), Int32(max))
        }
        return buffer.prefix(Int(n)).map { UInt64($0) }
    }

    /// Every thread but the caller's, each suspended while it is walked.
    static func sampleThreads(max: Int = Int(BC_CRASH_MAX_THREADS)) -> [ThreadSample] {
        let buffer = UnsafeMutablePointer<bc_thread_sample>.allocate(capacity: max)
        defer { buffer.deallocate() }
        let n = Int(bc_sample_threads(buffer, Int32(max)))
        return (0..<n).map { ThreadSample(buffer[$0]) }
    }
}

/// One thread's stack from the crash writer or the hang sampler.
struct ThreadSample: Equatable, Sendable {
    var index: Int
    var name: String?
    var crashed: Bool
    var current: Bool
    var isMain: Bool
    /// Innermost first; frames[0] is the pc.
    var frames: [UInt64]

    init(index: Int, name: String?, crashed: Bool, current: Bool, isMain: Bool, frames: [UInt64]) {
        self.index = index
        self.name = name
        self.crashed = crashed
        self.current = current
        self.isMain = isMain
        self.frames = frames
    }

    init(_ s: bc_thread_sample) {
        var copy = s
        let name = withUnsafeBytes(of: &copy.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let frames = withUnsafeBytes(of: &copy.frames) { raw in
            Array(raw.bindMemory(to: UInt.self).prefix(Int(s.count))).map { UInt64($0) }
        }
        self.init(
            index: Int(s.index), name: name.isEmpty ? nil : name, crashed: s.crashed != 0, current: s.current != 0,
            isMain: s.main != 0, frames: frames)
    }
}
