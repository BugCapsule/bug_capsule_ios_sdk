import Foundation

#if canImport(MetricKit)
    import MetricKit
#endif

/// When BugCapsule itself reported a crash (native report times), persisted
/// so a MetricKit crash diagnostic for the same crash is not sent twice.
final class CrashLedger: @unchecked Sendable {
    /// A diagnostic this close to a recorded crash is the same crash.
    static let window: TimeInterval = 60
    static let maxEntries = 50
    static let maxAge: TimeInterval = 30 * 24 * 3600

    private let file: URL?
    private let lock = NSLock()
    private var times: [Date]

    init(file: URL?) {
        self.file = file
        let raw = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSON.parse($0) }
        times = (raw?.arrayValue ?? []).compactMap { $0.doubleValue }.map { Date(timeIntervalSince1970: $0) }
    }

    func record(_ time: Date) {
        lock.locked {
            let cutoff = Date().addingTimeInterval(-Self.maxAge)
            times = Array((times.filter { $0 > cutoff } + [time]).suffix(Self.maxEntries))
            guard let file else { return }
            try? FileIO.writeAtomically(JSON.encodeData(.array(times.map { .double($0.timeIntervalSince1970) })), to: file)
        }
    }

    func contains(near time: Date) -> Bool {
        lock.locked { times.contains { abs($0.timeIntervalSince(time)) <= Self.window } }
    }
}

/// MetricKit diagnostics (`MXDiagnosticPayload.jsonRepresentation()`) as
/// monitoring events: `MXCrashDiagnostic` → `fatal` with mechanism
/// `metrickit`, `MXHangDiagnostic` → `error` with mechanism `app_hang`.
/// Call stack trees become frames (the root frame is the top of the stack)
/// and their binaries `macho` debug images.
enum MetricKitConverter {
    struct Diagnostic {
        var isCrash: Bool
        var draft: EventDraft
        /// From `diagnosticMetaData`: the build that produced it.
        var appVersion: String?
        var appBuild: String?
        var bundleId: String?
    }

    static func diagnostics(fromPayload payload: JSONValue, stack: StackBuilder, timestamp: Date? = nil) -> [Diagnostic] {
        let time =
            timestamp ?? parseTime(payload["timeStampEnd"]?.stringValue) ?? parseTime(payload["timeStampBegin"]?.stringValue)
            ?? Date()
        var out: [Diagnostic] = []
        for d in payload["crashDiagnostics"]?.arrayValue ?? [] {
            if let c = convert(d, isCrash: true, time: time, stack: stack) { out.append(c) }
        }
        for d in payload["hangDiagnostics"]?.arrayValue ?? [] {
            if let c = convert(d, isCrash: false, time: time, stack: stack) { out.append(c) }
        }
        return out
    }

    private static func convert(_ d: JSONValue, isCrash: Bool, time: Date, stack: StackBuilder) -> Diagnostic? {
        let meta = d["diagnosticMetaData"] ?? .object([:])
        let stacks = (d["callStackTree"]?["callStacks"]?.arrayValue ?? []).prefix(CrashEvents.maxThreads)
        var images: [String: DebugImage] = [:]
        var threads: [(attributed: Bool, frames: [UInt64])] = []
        for callStack in stacks {
            let chain = flatten(callStack["callStackRootFrames"]?.arrayValue ?? [])
            for f in chain { addImage(f, into: &images) }
            threads.append((callStack["threadAttributed"]?.boolValue ?? false, chain.compactMap(address)))
        }
        let list = images.values.sorted { $0.loadAddress < $1.loadAddress }
        let resolve: (UInt64) -> DebugImage? = { a in list.last { $0.loadAddress <= a && $0.contains(a) } }
        let symbol: (UInt64, DebugImage) -> String? = { a, image in
            guard let live = DebugImageCache.shared.image(debugId: image.debugId) else { return nil }
            return Symbolicator.function(at: a &- image.loadAddress &+ live.loadAddress)
        }
        let crashedIndex = threads.firstIndex { $0.attributed } ?? (threads.isEmpty ? nil : 0)
        let crashedFrames = crashedIndex.map { threads[$0].frames } ?? []
        let (frames, used) = stack.frames(crashedFrames, firstIsPC: true, resolve: resolve, symbol: symbol)
        let samples = threads.enumerated().map { i, t in
            ThreadSample(index: i, name: nil, crashed: i == crashedIndex, current: i == crashedIndex, isMain: false, frames: t.frames)
        }
        let (threadValues, threadImages) = CrashEvents.threads(samples, stack: stack, resolve: resolve, symbol: symbol)

        let value: JSONValue
        if isCrash {
            let (type, message, data) = describeCrash(meta)
            value = StackBuilder.exceptionValue(
                type: type, value: message, module: nil, mechanism: "metrickit", handled: false, frames: frames, data: data)
        } else {
            let duration = meta["hangDuration"].map { $0.stringValue ?? $0.doubleValue.map { "\($0) sec" } ?? "" } ?? ""
            value = StackBuilder.exceptionValue(
                type: "App Hanging", value: duration.isEmpty ? "App hanging (MetricKit)." : "App hanging for \(duration).",
                module: nil, mechanism: "app_hang", handled: false, frames: frames, data: ["source": "metrickit"])
        }
        var draft = EventDraft(level: isCrash ? .fatal : .error, exceptionValues: [value], timestamp: time)
        draft.threads = threads.isEmpty ? nil : threadValues
        draft.images = CrashEvents.merge(used, threadImages)
        draft.hint = EventHint(fromPreviousLaunch: isCrash)
        return Diagnostic(
            isCrash: isCrash, draft: draft, appVersion: meta["appVersion"]?.stringValue,
            appBuild: meta["appBuildVersion"]?.stringValue, bundleId: meta["bundleIdentifier"]?.stringValue)
    }

    /// The release of the build that produced [d]: [current] for this
    /// build, else the default `<bundle id>@<version>+<build>` (a custom
    /// release of another build is unknown: [current]).
    static func release(
        of d: Diagnostic, current: String, appId: String?, appVersion: String, appBuild: String, customRelease: Bool
    ) -> String {
        guard let v = d.appVersion, let b = d.appBuild, v != appVersion || b != appBuild, !customRelease else { return current }
        let id = d.bundleId ?? appId ?? ""
        return (id.isEmpty ? "\(v)+\(b)" : "\(id)@\(v)+\(b)").dartPrefix(200)
    }

    private static func describeCrash(_ meta: JSONValue) -> (String, String, JSONObject) {
        var data: JSONObject = [:]
        let exceptionType = meta["exceptionType"]?.intValue
        let signal = meta["signal"]?.intValue
        if let exceptionType { data["exception"] = .int(exceptionType) }
        if let code = meta["exceptionCode"]?.intValue { data["code"] = .int(code) }
        if let signal { data["signal"] = .int(signal) }
        let termination = meta["terminationReason"]?.stringValue
        if let termination { data["terminationReason"] = .string(termination) }
        let reason = meta["exceptionReason"]
        let type =
            reason?["exceptionName"]?.stringValue
            ?? exceptionType.flatMap { NativeCrashReport.exceptionNames[$0] }
            ?? signal.flatMap { NativeCrashReport.signalNames[Int32($0)] } ?? "MXCrashDiagnostic"
        let message =
            reason?["composedMessage"]?.stringValue ?? termination
            ?? signal.flatMap { NativeCrashReport.signalNames[Int32($0)] }.map { "\($0) (MetricKit)" }
            ?? "Crash reported by MetricKit"
        return (type, message, data)
    }

    /// Top of the stack first: each frame, then its most sampled sub-frame.
    private static func flatten(_ roots: [JSONValue]) -> [JSONValue] {
        var out: [JSONValue] = []
        var next = roots.max { ($0["sampleCount"]?.intValue ?? 0) < ($1["sampleCount"]?.intValue ?? 0) }
        while let frame = next, out.count < 512 {
            out.append(frame)
            let subs = frame["subFrames"]?.arrayValue ?? []
            next = subs.max { ($0["sampleCount"]?.intValue ?? 0) < ($1["sampleCount"]?.intValue ?? 0) }
        }
        return out
    }

    private static func address(_ f: JSONValue) -> UInt64? {
        if let i = f["address"]?.intValue, i >= 0 { return UInt64(i) }
        return f["address"]?.doubleValue.map { UInt64($0) }
    }

    private static func addImage(_ f: JSONValue, into images: inout [String: DebugImage]) {
        guard let uuid = f["binaryUUID"]?.stringValue, let addr = address(f) else { return }
        let offset = UInt64(max(f["offsetIntoBinaryTextSegment"]?.intValue ?? 0, 0))
        guard addr >= offset else { return }
        let id = uuid.lowercased()
        let load = addr - offset
        let name = f["binaryName"]?.stringValue ?? ""
        let existing = images[id]
        let size = max(existing?.size ?? 0, offset + 4)
        if let live = DebugImageCache.shared.image(debugId: id) {
            images[id] = DebugImage(
                path: live.path, debugId: id, loadAddress: load, vmAddress: live.vmAddress, size: max(live.size, size),
                arch: live.arch)
            return
        }
        // Not loaded now: a main executable's __TEXT starts at 0x100000000.
        let mainName = DebugImageCache.mainExecutablePath.map { ($0 as NSString).lastPathComponent }
        let vmaddr: UInt64 = name == mainName ? 0x1_0000_0000 : 0
        images[id] = DebugImage(path: name, debugId: id, loadAddress: load, vmAddress: vmaddr, size: size, arch: DeviceInfo.arch)
    }

    static func parseTime(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = ISODate.parse(s) { return d }
        for format in ["yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}

/// Receives MetricKit diagnostic payloads (iOS 14+) and hands each one's
/// JSON and end time to [handler] on MetricKit's background thread.
/// Registering happens off the main thread, so launch never waits for it.
final class MetricKitSubscriber: NSObject, @unchecked Sendable {
    private let handler: @Sendable (JSONValue, Date?) -> Void
    private let lock = NSLock()
    private var registered = false

    init(handler: @escaping @Sendable (JSONValue, Date?) -> Void) {
        self.handler = handler
    }

    func start() {
        #if canImport(MetricKit) && os(iOS)
            if #available(iOS 14, *) {
                DispatchQueue.global(qos: .utility).async { [self] in
                    lock.locked { registered = true }
                    MXMetricManager.shared.add(self)
                }
            }
        #endif
    }

    func stop() {
        #if canImport(MetricKit) && os(iOS)
            if #available(iOS 14, *), lock.locked({ registered }) {
                MXMetricManager.shared.remove(self)
                lock.locked { registered = false }
            }
        #endif
    }

    func receive(_ json: Data, end: Date?) {
        guard let value = try? JSON.parse(json) else { return }
        handler(value, end)
    }
}

#if canImport(MetricKit) && os(iOS)
    @available(iOS 14, *)
    extension MetricKitSubscriber: MXMetricManagerSubscriber {
        func didReceive(_ payloads: [MXDiagnosticPayload]) {
            for p in payloads { receive(p.jsonRepresentation(), end: p.timeStampEnd) }
        }
    }
#endif
