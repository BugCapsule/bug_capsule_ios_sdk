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

    static func setContext(_ context: JSONObject) {
        let bytes = JSON.encodeData(.object(context))
        bytes.withUnsafeBytes { raw in
            bc_crash_set_context(raw.baseAddress?.assumingMemoryBound(to: CChar.self), raw.count)
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
}
