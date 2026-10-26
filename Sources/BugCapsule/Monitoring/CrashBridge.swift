import Foundation

#if canImport(UIKit)
    import UIKit
#endif

/// Crash capture for SDKs that embed BugCapsule for iOS (the Flutter SDK's
/// iOS plugin). **For embedding only**: apps use `BugCapsule.start`.
///
/// It runs the native crash handlers (signals, Mach exceptions, uncaught
/// `NSException`s), the app hang watchdog and the MetricKit subscriber
/// without the SDK's sessions, outbox or uploads, so the embedding SDK stays
/// the single sender: it mirrors its scope with `updateScope(json:)` and,
/// on each launch, sends what `takePendingEvents()` returns.
///
/// Same shape as Android's `dev.bugcapsule.android.embedding.CrashBridge`.
///
///     BugCapsuleCrashBridge.install(release: "com.shop.app@1.4.0+52", environment: "production")
///     BugCapsuleCrashBridge.updateScope(json: #"{"tags":{"screen":"cart"}}"#)
///     for event in BugCapsuleCrashBridge.takePendingEvents() { /* send it */ }
///
/// The handlers belong to one owner per process: when `BugCapsule.start`
/// installed them first, `install` does nothing and returns false (and the
/// SDK's monitoring skips them when the bridge was first).
public enum BugCapsuleCrashBridge {
    public struct Options: Sendable, Equatable {
        /// Signals, Mach exceptions (not under a debugger) and uncaught
        /// `NSException`s, reported by the next launch.
        public var nativeCrashes: Bool
        /// Main-thread hang threshold in seconds (nil: no watchdog). A hang
        /// is reported once, with every thread's stack.
        public var appHangs: TimeInterval?
        /// MetricKit crash and hang diagnostics (iOS 14+); a crash the
        /// handlers already reported (within 60 s) is skipped.
        public var metricKit: Bool
        /// Image name prefixes (e.g. `Runner`, `App`, a plugin framework)
        /// whose frames are in-app.
        public var inAppIncludes: [String]

        public init(
            nativeCrashes: Bool = true, appHangs: TimeInterval? = 2, metricKit: Bool = true, inAppIncludes: [String] = []
        ) {
            self.nativeCrashes = nativeCrashes
            self.appHangs = appHangs
            self.metricKit = metricKit
            self.inAppIncludes = inAppIncludes
        }
    }

    /// Installs the handlers and turns the previous process's crash into a
    /// pending event. Call it once, early (the plugin's registration).
    /// Returns false when the SDK's own monitoring already installed them;
    /// calling it again only updates the release and environment.
    @discardableResult
    public static func install(release: String, environment: String, options: Options = Options()) -> Bool {
        guard let root = try? CapsuleStore.defaultRoot() else { return false }
        return CrashBridgeRuntime.shared.install(
            directory: root.appendingPathComponent("crash-bridge", isDirectory: true), release: release,
            environment: environment, options: options)
    }

    /// Mirrors the embedding SDK's scope into the crash context, as a JSON
    /// object with any of `user`, `tags`, `contexts`, `breadcrumbs`
    /// (oldest first, monitoring-v1 breadcrumbs), `extra`, `fingerprint`
    /// and `dist`. Each call replaces the whole scope. Invalid JSON is
    /// ignored.
    public static func updateScope(json: String) {
        CrashBridgeRuntime.shared.updateScope(json: json)
    }

    /// monitoring-v1 event payloads (JSON objects, the `payload` of an
    /// `event` envelope item) not yet taken: the crash of the previous
    /// process and, as they arrive, uncaught exceptions, app hangs and
    /// MetricKit diagnostics. Crashes carry `threads` and `debugImages`.
    /// Returned records are deleted, so each is returned once: the caller
    /// persists or sends them. MetricKit delivers some time after launch;
    /// call this again later (e.g. on resume).
    public static func takePendingEvents() -> [String] {
        CrashBridgeRuntime.shared.takePendingEvents()
    }

    /// The previous process ended in a crash the handlers recorded.
    public static var lastRunCrashed: Bool { CrashBridgeRuntime.shared.lastRunCrashed }

    // MARK: testing

    @discardableResult
    static func installForTesting(
        directory: URL, release: String, environment: String, options: Options, mach: Bool = false
    ) -> Bool {
        CrashBridgeRuntime.shared.install(
            directory: directory, release: release, environment: environment, options: options, mach: mach)
    }

    static func resetForTesting() { CrashBridgeRuntime.shared.reset() }
}

/// State behind `BugCapsuleCrashBridge`.
final class CrashBridgeRuntime: @unchecked Sendable {
    static let shared = CrashBridgeRuntime()

    static let scopeKeys = ["user", "tags", "contexts", "breadcrumbs", "extra", "fingerprint", "dist"]

    private let lock = NSLock()
    private var directory: URL?
    private var release = ""
    private var environment = ""
    private var options = BugCapsuleCrashBridge.Options()
    private var stack = StackBuilder(options: BugCapsuleMonitoringOptions())
    private var scope: JSONObject = [:]
    private var ledger: CrashLedger?
    private var hangs: AppHangTracker?
    private var metricKit: MetricKitSubscriber?
    private var observers: [NSObjectProtocol] = []
    private var foreground = true
    private var _lastRunCrashed = false

    var lastRunCrashed: Bool { lock.locked { _lastRunCrashed } }

    var pendingDirectory: URL? { lock.locked { directory?.appendingPathComponent("pending", isDirectory: true) } }

    func install(
        directory: URL, release: String, environment: String, options: BugCapsuleCrashBridge.Options, mach: Bool = true
    ) -> Bool {
        let first: Bool? = lock.locked {
            if self.directory != nil {
                self.release = release.dartPrefix(200)
                self.environment = environment.dartPrefix(64)
                return false
            }
            guard CrashOwnership.claim(.bridge) else { return nil }
            self.directory = directory
            self.release = release.dartPrefix(200)
            self.environment = environment.dartPrefix(64)
            self.options = options
            stack = StackBuilder(options: BugCapsuleMonitoringOptions(inAppIncludes: options.inAppIncludes))
            ledger = CrashLedger(file: directory.appendingPathComponent("crash_times.json"))
            return true
        }
        guard let first else {
            BugCapsuleLog.warn("crash handlers already installed by BugCapsule.start; the crash bridge is not installed")
            return false
        }
        guard first else {
            if options.nativeCrashes { NativeCrashHandler.setRelease(release, environment: environment) }
            syncContext()
            return true
        }
        try? FileIO.ensureDirectory(directory.appendingPathComponent("pending", isDirectory: true))

        // The previous process's crash.
        if let report = NativeCrashHandler.takePendingReport(in: directory) {
            lock.locked { _lastRunCrashed = true }
            ledger?.record(report.time)
            // Suppressed: the uncaught-exception handler already wrote its event.
            if !report.suppressed { writePending(payload(CrashEvents.draft(from: report, stack: stack))) }
        }

        if options.nativeCrashes {
            if !NativeCrashHandler.install(directory: directory, mach: mach) {
                BugCapsuleLog.warn("native crash handler not fully installed")
            }
            NativeCrashHandler.setRelease(release, environment: environment)
            CrashHandler.bridge = { [weak self] exception in self?.recordUncaught(exception) }
            CrashHandler.install()
            syncContext()
        }
        observeForeground()
        if let threshold = options.appHangs, threshold > 0, !NativeCrashHandler.debuggerAttached {
            let tracker = AppHangTracker(
                threshold: threshold, mainThread: NativeCrashHandler.mainThreadPort,
                isForeground: { [weak self] in self?.lock.locked { self?.foreground ?? false } ?? false },
                onHang: { [weak self] samples in self?.recordHang(samples, threshold: threshold) })
            lock.locked { hangs = tracker }
            tracker.start()
        }
        if options.metricKit {
            let subscriber = MetricKitSubscriber { [weak self] json, end in self?.receiveMetricKit(json, end: end) }
            lock.locked { metricKit = subscriber }
            subscriber.start()
        }
        return true
    }

    func reset() {
        let (hangs, metricKit, observers, installed): (AppHangTracker?, MetricKitSubscriber?, [NSObjectProtocol], Bool) =
            lock.locked {
                defer {
                    self.hangs = nil
                    self.metricKit = nil
                    self.observers = []
                    directory = nil
                    scope = [:]
                    _lastRunCrashed = false
                    foreground = true
                }
                return (self.hangs, self.metricKit, self.observers, directory != nil)
            }
        hangs?.stop()
        metricKit?.stop()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        guard installed else { return }
        CrashHandler.bridge = nil
        NativeCrashHandler.uninstallForTesting()
        CrashOwnership.release(.bridge)
    }

    // MARK: scope

    func updateScope(json: String) {
        guard let value = try? JSON.parse(Data(json.utf8)), let object = value.objectValue else { return }
        var next: JSONObject = [:]
        for key in Self.scopeKeys { if let v = object[key], v != .null { next[key] = v } }
        if let crumbs = next["breadcrumbs"]?.arrayValue { next["breadcrumbs"] = .array(Array(crumbs.suffix(100))) }
        lock.locked { scope = next }
        syncContext()
    }

    /// The scope plus this process's release and environment (the crash
    /// context template).
    func template() -> JSONObject {
        lock.locked {
            var t = scope
            t["release"] = .string(release)
            t["environment"] = .string(environment)
            return t
        }
    }

    private func syncContext() {
        guard lock.locked({ directory != nil && options.nativeCrashes }) else { return }
        NativeCrashHandler.setContext(ItemRedaction.redact(template(), redactor: Redactor()))
    }

    // MARK: events

    /// The event JSON for [draft]: its template (a crashed process's scope)
    /// or this process's, with device contexts the embedding SDK did not set.
    func payload(_ d: EventDraft) -> JSONObject {
        var p: JSONObject = [
            "eventId": .string(uuidV4()), "timestamp": .string(ISODate.format(d.timestamp)),
            "level": .string(d.level.rawValue), "runtime": "ios",
        ]
        if let values = d.exceptionValues, !values.isEmpty { p["exception"] = ["values": .array(Array(values.suffix(10)))] }
        if let message = d.message { p["message"] = ["formatted": .string(message.dartPrefix(8192))] }
        var source = template()
        if let crashed = d.template {
            // Another run's scope: only the release and environment fall back to this one's.
            source = ["release": source["release"] ?? .null, "environment": source["environment"] ?? .null]
            for (k, v) in crashed { source[k] = v }
        }
        for key in ["release", "environment"] + Self.scopeKeys { if let v = source[key] { p[key] = v } }
        var contexts = p["contexts"]?.objectValue ?? [:]
        let info = Bundle.main.infoDictionary
        let defaults = Monitoring.deviceContexts(
            appId: Bundle.main.bundleIdentifier, appName: info?["CFBundleName"] as? String,
            version: info?["CFBundleShortVersionString"] as? String ?? "0", build: info?["CFBundleVersion"] as? String ?? "0")
        for (k, v) in defaults where contexts[k] == nil { contexts[k] = v }
        p["contexts"] = .object(contexts)
        if let threads = d.threads { p["threads"] = .array(threads) }
        if !d.images.isEmpty { p["debugImages"] = .array(d.images.prefix(500).map(\.json)) }
        return ItemRedaction.redact(p, redactor: Redactor())
    }

    /// Written synchronously (crash paths call it before the process ends).
    func writePending(_ payload: JSONObject) {
        guard let dir = pendingDirectory else { return }
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        let id = payload["eventId"]?.stringValue ?? uuidV4()
        try? FileIO.writeAtomically(
            JSON.encodeData(.object(payload)), to: dir.appendingPathComponent("\(ms)-\(id).json"))
    }

    func takePendingEvents() -> [String] {
        guard let dir = pendingDirectory else { return [] }
        return lock.locked {
            let files = ((try? FileIO.fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            var out: [String] = []
            for file in files {
                if let data = try? Data(contentsOf: file), (try? JSON.parse(data))?.objectValue != nil {
                    out.append(String(decoding: data, as: UTF8.self))
                }
                FileIO.deleteQuietly(file)
            }
            return out
        }
    }

    /// Uncaught NSException: written now; the SIGABRT report that follows
    /// only marks the run crashed.
    func recordUncaught(_ exception: NSException) {
        let addresses = exception.callStackReturnAddresses.map { $0.uint64Value }
        let live = addresses.isEmpty ? Thread.callStackReturnAddresses.map { $0.uint64Value } : addresses
        let (frames, images) = stack.liveFrames(live, dropSDKFrames: addresses.isEmpty)
        let value = StackBuilder.exceptionValue(
            type: exception.name.rawValue, value: exception.reason ?? "", module: nil, mechanism: "nsexception",
            handled: false, frames: frames)
        var draft = EventDraft(level: .fatal, exceptionValues: [value], images: images)
        var samples = NativeCrashHandler.sampleThreads()
        let taken = Set(samples.map(\.index))
        let index = (0...samples.count).first { !taken.contains($0) } ?? samples.count
        samples.append(
            ThreadSample(
                index: index, name: Thread.current.name.flatMap { $0.isEmpty ? nil : $0 }, crashed: true, current: true,
                isMain: Thread.isMainThread, frames: live))
        samples.sort { $0.index < $1.index }
        let (threads, threadImages) = CrashEvents.threads(
            samples, stack: stack, resolve: { DebugImageCache.shared.image(containing: $0) })
        draft.threads = threads
        draft.images = CrashEvents.merge(images, threadImages)
        writePending(payload(draft))
        NativeCrashHandler.suppressNextEvent()
    }

    func recordHang(_ samples: [ThreadSample], threshold: TimeInterval) {
        writePending(payload(CrashEvents.hangDraft(samples, threshold: threshold, stack: stack)))
    }

    func receiveMetricKit(_ json: JSONValue, end: Date?) {
        guard lock.locked({ directory != nil }) else { return }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        for d in MetricKitConverter.diagnostics(fromPayload: json, stack: stack, timestamp: end) {
            if d.isCrash && (ledger?.contains(near: d.draft.timestamp) ?? false) { continue }
            var draft = d.draft
            let current = lock.locked { release }
            let r = MetricKitConverter.release(
                of: d, current: current, appId: Bundle.main.bundleIdentifier, appVersion: version, appBuild: build,
                customRelease: false)
            // The diagnostic's own run: its scope is unknown.
            draft.template = ["release": .string(r), "breadcrumbs": .array([])]
            writePending(payload(draft))
        }
    }

    private func observeForeground() {
        #if canImport(UIKit)
            let center = NotificationCenter.default
            let background = center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
            ) { [weak self] _ in self?.lock.locked { self?.foreground = false } }
            let foreground = center.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
            ) { [weak self] _ in self?.lock.locked { self?.foreground = true } }
            let inForeground =
                Thread.isMainThread ? MainActor.assumeIsolated { UIApplication.shared.applicationState != .background } : true
            lock.locked {
                observers = [background, foreground]
                self.foreground = inForeground
            }
        #endif
    }
}
