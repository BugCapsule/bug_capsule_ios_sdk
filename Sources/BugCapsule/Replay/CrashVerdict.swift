import Foundation

/// What a crash report (`.ips`, written by the host's ReportCrash for a
/// simulator app) says about how the app under test died. Read by
/// `BugCapsuleXCTest` when the app stops during a crash capsule's replay.
public struct ObservedCrash: Sendable, Equatable {
    public struct Frame: Sendable, Equatable {
        public var symbol: String?
        /// In the app's main executable (or its Xcode `.debug.dylib`).
        public var inApp: Bool

        public init(symbol: String?, inApp: Bool) {
            self.symbol = symbol
            self.inApp = inApp
        }
    }

    public var pid: Int?
    public var process: String?
    /// The executable's path (on a simulator it contains the device's UDID).
    public var processPath: String?
    public var bundleId: String?
    /// `EXC_BAD_ACCESS`, `EXC_BREAKPOINT`, `EXC_CRASH` (a signal sent or raised).
    public var exceptionType: String?
    /// `SIGSEGV`, `SIGABRT`, …
    public var signal: String?
    /// `termination.namespace` / `code` (`FRONTBOARD` / `0x8badf00d` for a watchdog kill).
    public var terminationNamespace: String?
    public var terminationCode: UInt64?
    /// An uncaught NSException's name, from the report's application specific information.
    public var exceptionName: String?
    public var summary: String
    /// The crashed thread, innermost first.
    public var frames: [Frame]

    public init(
        pid: Int? = nil, process: String? = nil, processPath: String? = nil, bundleId: String? = nil,
        exceptionType: String? = nil, signal: String? = nil, terminationNamespace: String? = nil,
        terminationCode: UInt64? = nil, exceptionName: String? = nil, summary: String = "", frames: [Frame] = []
    ) {
        self.pid = pid
        self.process = process
        self.processPath = processPath
        self.bundleId = bundleId
        self.exceptionType = exceptionType
        self.signal = signal
        self.terminationNamespace = terminationNamespace
        self.terminationCode = terminationCode
        self.exceptionName = exceptionName
        self.summary = summary
        self.frames = frames
    }

    /// Parses an `.ips` crash report (a JSON header line, then the JSON
    /// body). Nil for other reports (hangs, resource reports).
    public static func parseIPS(_ data: Data) -> ObservedCrash? {
        guard let newline = data.firstIndex(of: 0x0A),
            let header = (try? JSON.parse(Data(data[..<newline])))?.objectValue,
            let body = (try? JSON.parse(Data(data[data.index(after: newline)...])))?.objectValue
        else { return nil }
        guard header["bug_type"]?.stringValue == "309" || body["exception"] != nil else { return nil }
        var c = ObservedCrash()
        c.pid = body["pid"]?.intValue
        c.process = body["procName"]?.stringValue ?? header["name"]?.stringValue
        c.processPath = body["procPath"]?.stringValue
        c.bundleId = header["bundleID"]?.stringValue ?? body["bundleInfo"]?["CFBundleIdentifier"]?.stringValue
        let exception = body["exception"]?.objectValue ?? JSONObject()
        c.exceptionType = exception["type"]?.stringValue
        c.signal = exception["signal"]?.stringValue
        let termination = body["termination"]?.objectValue ?? JSONObject()
        c.terminationNamespace = termination["namespace"]?.stringValue
        if let code = termination["code"] {
            c.terminationCode = code.intValue.map { UInt64(bitPattern: Int64($0)) } ?? code.stringValue.flatMap(parseHex)
        }
        let specific = (body["asi"]?.objectValue ?? JSONObject()).flatMap { _, v in (v.arrayValue ?? []).compactMap(\.stringValue) }
        for line in specific {
            guard let r = line.range(of: "uncaught exception '") else { continue }
            let rest = line[r.upperBound...]
            if let end = rest.firstIndex(of: "'") { c.exceptionName = String(rest[..<end]) }
            break
        }
        c.summary = [
            c.exceptionType.map { t in c.signal.map { "\(t) (\($0))" } ?? t }, exception["subtype"]?.stringValue,
            termination["indicator"]?.stringValue,
        ].compactMap { $0 }.joined(separator: ": ")
        let images = (body["usedImages"]?.arrayValue ?? []).map { $0["path"]?.stringValue }
        let threads = body["threads"]?.arrayValue ?? []
        let crashed = body["faultingThread"]?.intValue.flatMap { threads.indices.contains($0) ? threads[$0] : nil }
            ?? threads.first { $0["triggered"]?.boolValue == true }
        c.frames = (crashed?["frames"]?.arrayValue ?? []).map { f in
            let path = f["imageIndex"]?.intValue.flatMap { images.indices.contains($0) ? images[$0] : nil }
            let inApp = path != nil && c.processPath.map { path == $0 || path == $0 + ".debug.dylib" } == true
            return Frame(symbol: f["symbol"]?.stringValue, inApp: inApp)
        }
        return c
    }

    /// The crash `type` of a capsule this report would have produced.
    public var type: String {
        if let exceptionName { return exceptionName }
        if isWatchdogKill { return CrashVerdict.anrType }
        if let exceptionType, exceptionType != "EXC_CRASH" { return exceptionType }
        return signal ?? exceptionType ?? "Crash"
    }

    var isWatchdogKill: Bool { terminationCode == 0x8bad_f00d }
}

/// How a crash capsule's replay attempt ends when the app died
/// (crash-capsules §4).
public enum CrashVerdict {
    public static let anrType = "ApplicationNotResponding"

    /// The same crash: the capsule's `type` is the report's signal, Mach
    /// exception, uncaught NSException or (ANR) a watchdog kill.
    public static func matches(_ type: String, _ crash: ObservedCrash) -> Bool {
        if type == anrType { return crash.isWatchdogKill }
        return [crash.signal, crash.exceptionType, crash.exceptionName].contains(type)
    }

    /// `reproduced` (reason code `failure.different_frame` when the in-app
    /// frame closest to the crash is another function) or `inconclusive`
    /// with `failure.different`.
    public static func judge(expected: FailureRecord, crash: ObservedCrash, t: Int = 0) -> (
        outcome: ReplayOutcome, observed: FailureRecord, reasonCodes: [String]
    ) {
        let same = matches(expected.type, crash)
        var info: JSONObject = ["mechanism": .string(crash.exceptionType == nil || crash.exceptionType == "EXC_CRASH" ? "signal" : "mach_exception")]
        if let name = crash.signal, let number = signalNumbers[name] { info["signal"] = .int(Int(number)) }
        if let exception = crash.exceptionType.flatMap({ machNumbers[$0] }) { info["exception"] = .int(exception) }
        let frame = crash.frames.first { $0.inApp }?.symbol
        if let frame { info["inAppFrame"] = .string(frame.dartPrefix(1000)) }
        let stack = crash.frames.prefix(50).enumerated().map { i, f in "#\(i) \(f.symbol ?? "?")" }.joined(separator: "\n")
        let observed = FailureRecord.crash(
            type: same ? expected.type : crash.type, message: crash.summary, stack: stack.isEmpty ? nil : stack, crash: info,
            t: t)
        guard same else { return (.inconclusive, observed, ["failure.different"]) }
        if let wanted = expected.crash?["inAppFrame"]?.stringValue, let frame, !sameFunction(wanted, frame) {
            return (.reproduced, observed, ["failure.different_frame"])
        }
        return (.reproduced, observed, [])
    }

    /// The attempt's report, as the CLI reads it.
    public static func report(
        expected: FailureRecord, crash: ObservedCrash, settings: ReplaySettings, durationMs: Int, source: String
    ) -> ReplayReport {
        let (outcome, observed, codes) = judge(expected: expected, crash: crash)
        return ReplayReport(
            outcome: outcome, attempt: settings.attempt, durationMs: durationMs, strategy: .semantic,
            expectedSignature: expected.signature, observed: observed,
            message: "the app died during replay: \(crash.summary) (\(source))", attemptId: settings.attemptId,
            runtime: "ios", reasonCodes: codes)
    }

    /// Two symbol names of one function: the module prefix, `static` /
    /// `@objc`, arguments and return type may differ between the SDK's and
    /// the report's demangling.
    static func sameFunction(_ a: String, _ b: String) -> Bool {
        func base(_ s: String) -> String {
            var s = s
            for prefix in ["static ", "@objc "] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
            if let r = s.range(of: " -> ") { s = String(s[..<r.lowerBound]) }
            if let r = s.firstIndex(of: "(") { s = String(s[..<r]) }
            return s.trimmingCharacters(in: .whitespaces)
        }
        let x = base(a)
        let y = base(b)
        if x.isEmpty || y.isEmpty { return true }
        return x == y || x.hasSuffix("." + y) || y.hasSuffix("." + x)
    }

    static let signalNumbers: [String: Int32] = [
        "SIGABRT": SIGABRT, "SIGBUS": SIGBUS, "SIGFPE": SIGFPE, "SIGILL": SIGILL, "SIGSEGV": SIGSEGV, "SIGTRAP": SIGTRAP,
        "SIGSYS": SIGSYS, "SIGKILL": SIGKILL,
    ]
    static let machNumbers: [String: Int] = [
        "EXC_BAD_ACCESS": 1, "EXC_BAD_INSTRUCTION": 2, "EXC_ARITHMETIC": 3, "EXC_BREAKPOINT": 6, "EXC_CRASH": 10,
    ]
}
