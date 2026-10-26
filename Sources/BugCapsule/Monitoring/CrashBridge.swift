import Foundation

#if canImport(UIKit)
    import UIKit
#endif

/// Crash capture for SDKs that embed BugCapsule for iOS and send events
/// themselves: the BugCapsule Flutter SDK's iOS plugin. **Not for apps**: an
/// app uses `BugCapsule.start`, which does all of this and more.
///
/// It runs the crash handlers without this SDK's own sessions, outbox or
/// transport, so the embedding SDK stays the only sender:
///
/// - signal and Mach exception handlers (every thread, the embedding SDK's
///   scope written into each report) and uncaught `NSException`s;
/// - the main-thread hang watchdog;
/// - MetricKit crash and hang diagnostics (iOS 14+), skipped when the
///   handlers or the watchdog already reported the same failure.
///
/// Events are monitoring-v1 `event` JSON (docs/monitoring-v1.md §2) with
/// `runtime: "ios"`; the embedding SDK adds its device contexts, may change
/// `runtime`, redacts and sends them. They are kept on disk until
/// `takePendingEvents(timeoutMs:)` returns them. Android's
/// `dev.bugcapsule.android.embedding.CrashBridge` has the same shape.
///
///     BugCapsuleCrashBridge.install(release: "com.shop.app@1.4.0+52", environment: "production")
///     BugCapsuleCrashBridge.updateScope(json: #"{"tags":{"screen":"cart"}}"#)
///     for event in BugCapsuleCrashBridge.takePendingEvents() { /* send it */ }
public enum BugCapsuleCrashBridge {
    /// What `install` turns on. `inAppIncludes` default to the main executable.
    public struct Options: Sendable, Equatable {
        /// Signals, Mach exceptions (not under a debugger) and uncaught
        /// `NSException`s, reported by the next launch.
        public var nativeCrashes: Bool
        /// Main-thread hang threshold in seconds (nil: no watchdog). A hang
        /// is reported once, with every thread's stack.
        public var appHangs: TimeInterval?
        /// MetricKit crash and hang diagnostics (iOS 14+).
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

    /// Installs the handlers and reads what earlier runs left behind (in
    /// the background). Returns false (and does nothing) when this SDK's own
    /// monitoring is running in the process. Idempotent: a second call
    /// returns true and keeps the first settings.
    @discardableResult
    public static func install(release: String, environment: String, options: Options = Options()) -> Bool {
        guard let root = try? CapsuleStore.defaultRoot() else { return false }
        return CrashBridgeRuntime.shared.install(
            directory: root.appendingPathComponent("crash-bridge", isDirectory: true), release: release,
            environment: environment, options: options)
    }

    /// The previous run ended in a crash the handlers recorded.
    public static var lastRunCrashed: Bool { CrashBridgeRuntime.shared.lastRunCrashed }

    /// The signal and Mach exception handlers are installed.
    public static var nativeCrashHandlerInstalled: Bool { CrashBridgeRuntime.shared.nativeInstalled }

    /// Sets the scope crash events get: one JSON object with any of
    /// `fingerprint`, `tags`, `user`, `extra`, `contexts`, `breadcrumbs`
    /// (oldest first) in event form, already redacted. Each call replaces
    /// the whole scope. Copied into the crash handler at once (at most
    /// 128 KiB; the oldest breadcrumbs go first) and to disk at most every
    /// second (for MetricKit diagnostics of this process reported later).
    /// Invalid JSON is ignored.
    public static func updateScope(json: String) {
        CrashBridgeRuntime.shared.updateScope(json: json)
    }

    /// Events not taken yet, oldest first, each removed once returned:
    /// earlier runs' crashes and, as they happen, uncaught exceptions, app
    /// hangs and MetricKit diagnostics. Crashes and hangs carry `threads`
    /// and `debugImages`. Waits up to [timeoutMs] for the previous run's
    /// reports to be built (that happens in the background after `install`).
    /// MetricKit delivers some time after launch; call it again later (e.g.
    /// on resume).
    public static func takePendingEvents(timeoutMs: Int = 5_000) -> [String] {
        CrashBridgeRuntime.shared.takePendingEvents(timeoutMs: timeoutMs)
    }

    /// Told about events captured while the app runs (app hangs), after
    /// they are stored; earlier runs' crashes are only in
    /// `takePendingEvents`. Called on a background queue.
    public static func setListener(_ listener: (@Sendable (String) -> Void)?) {
        CrashBridgeRuntime.shared.setListener(listener)
    }

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

/// State behind `BugCapsuleCrashBridge`. Files under its directory:
/// `crash.report` (the writer's), `reports/` (earlier runs' reports until
/// their events are stored), `events/` (pending events), `scope.json`,
/// `crash_times.json`.
final class CrashBridgeRuntime: @unchecked Sendable {
    static let shared = CrashBridgeRuntime()

    static let scopeKeys = ["fingerprint", "tags", "user", "extra", "contexts", "breadcrumbs"]
    static let scopeFileInterval: TimeInterval = 1

    private let lock = NSLock()
    private var queue = DispatchQueue(label: "com.bugcapsule.crash-bridge", qos: .utility)
    private var directory: URL?
    private var release = ""
    private var environment = ""
    private var stack = StackBuilder(options: BugCapsuleMonitoringOptions())
    /// This process's scope (with pid, release, environment).
    private var scope: JSONObject = [:]
    /// The previous process's, from `scope.json`.
    private var previousScope: JSONObject?
    private var scopeFileScheduled = false
    /// Bumped by `reset`: a scope write scheduled before it is dropped.
    private var generation = 0
    private var nativeEnabled = false
    private var ledger: CrashLedger?
    private var hangs: AppHangTracker?
    private var metricKit: MetricKitSubscriber?
    private var observers: [NSObjectProtocol] = []
    private var foreground = true
    private var listener: (@Sendable (String) -> Void)?
    private var _lastRunCrashed = false
    private var _nativeInstalled = false

    var lastRunCrashed: Bool { lock.locked { _lastRunCrashed } }
    var nativeInstalled: Bool { lock.locked { _nativeInstalled } }

    private var eventsDirectory: URL? { lock.locked { directory?.appendingPathComponent("events", isDirectory: true) } }

    func install(
        directory: URL, release: String, environment: String, options: BugCapsuleCrashBridge.Options, mach: Bool = true
    ) -> Bool {
        let outcome: Bool? = lock.locked {
            if self.directory != nil { return false }
            if BugCapsuleSession.current != nil || !CrashOwnership.claim(.bridge) { return nil }
            self.directory = directory
            self.release = release.dartPrefix(200)
            self.environment = environment.dartPrefix(64)
            nativeEnabled = options.nativeCrashes
            stack = StackBuilder(options: BugCapsuleMonitoringOptions(inAppIncludes: options.inAppIncludes))
            ledger = CrashLedger(file: directory.appendingPathComponent("crash_times.json"))
            return true
        }
        guard let outcome else {
            BugCapsuleLog.warn("crash bridge not installed: BugCapsule.start() already reports crashes in this process")
            return false
        }
        guard outcome else { return true }

        let reports = directory.appendingPathComponent("reports", isDirectory: true)
        try? FileIO.ensureDirectory(directory.appendingPathComponent("events", isDirectory: true))
        try? FileIO.ensureDirectory(reports)
        // The last run's report moves aside before the handler can write a new one.
        let report = NativeCrashHandler.reportFile(in: directory)
        if FileIO.fm.fileExists(atPath: report.path) {
            try? FileIO.fm.moveItem(
                at: report, to: reports.appendingPathComponent("\(UInt64(Date().timeIntervalSince1970 * 1000)).report"))
        }
        let waiting = ((try? FileIO.fm.contentsOfDirectory(at: reports, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "report" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let scopeFile = directory.appendingPathComponent("scope.json")
        let previous = (try? Data(contentsOf: scopeFile)).flatMap { try? JSON.parse($0) }?.objectValue
        lock.locked {
            _lastRunCrashed = !waiting.isEmpty
            previousScope = previous
        }
        if !waiting.isEmpty { queue.async { [self] in buildReports(waiting) } }

        if options.nativeCrashes {
            let installed = NativeCrashHandler.install(directory: directory, mach: mach)
            if !installed { BugCapsuleLog.warn("native crash handler not fully installed") }
            NativeCrashHandler.setRelease(release, environment: environment)
            lock.locked { _nativeInstalled = installed }
            CrashHandler.bridge = { [weak self] exception in self?.recordUncaught(exception) }
            CrashHandler.install()
            updateScope(object: [:])
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
            let subscriber = MetricKitSubscriber { [weak self] json, begin, end in
                self?.receiveMetricKit(json, begin: begin, end: end)
            }
            lock.locked { metricKit = subscriber }
            subscriber.start()
        }
        return true
    }

    func reset() {
        let (hangs, metricKit, observers, installed, queue): (
            AppHangTracker?, MetricKitSubscriber?, [NSObjectProtocol], Bool, DispatchQueue
        ) = lock.locked {
            defer {
                self.hangs = nil
                self.metricKit = nil
                self.observers = []
                directory = nil
                scope = [:]
                previousScope = nil
                scopeFileScheduled = false
                generation += 1
                listener = nil
                _lastRunCrashed = false
                _nativeInstalled = false
                foreground = true
                self.queue = DispatchQueue(label: "com.bugcapsule.crash-bridge", qos: .utility)
            }
            return (self.hangs, self.metricKit, self.observers, directory != nil, self.queue)
        }
        hangs?.stop()
        metricKit?.stop()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        queue.sync {}
        guard installed else { return }
        CrashHandler.bridge = nil
        NativeCrashHandler.uninstallForTesting()
        CrashOwnership.release(.bridge)
    }

    func setListener(_ l: (@Sendable (String) -> Void)?) { lock.locked { listener = l } }

    // MARK: scope

    func updateScope(json: String) {
        guard lock.locked({ directory != nil }), let object = (try? JSON.parse(Data(json.utf8)))?.objectValue else { return }
        updateScope(object: object)
    }

    private func updateScope(object: JSONObject) {
        let (next, native, schedule, queue, gen): (JSONObject, Bool, Bool, DispatchQueue, Int) = lock.locked {
            var next: JSONObject = [
                "pid": .int(Int(getpid())), "release": .string(release), "environment": .string(environment),
            ]
            for key in Self.scopeKeys { if let v = object[key], v != .null { next[key] = v } }
            if let crumbs = next["breadcrumbs"]?.arrayValue { next["breadcrumbs"] = .array(Array(crumbs.suffix(100))) }
            scope = next
            let schedule = !scopeFileScheduled
            scopeFileScheduled = true
            return (next, nativeEnabled, schedule, self.queue, generation)
        }
        if native { NativeCrashHandler.setContext(next) }
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + Self.scopeFileInterval) { [weak self] in
            guard let self else { return }
            let pending = self.lock.locked { () -> (JSONObject, URL)? in
                guard gen == self.generation, let dir = self.directory else { return nil }
                self.scopeFileScheduled = false
                return (self.scope, dir.appendingPathComponent("scope.json"))
            }
            guard let (current, file) = pending else { return }
            try? FileIO.writeAtomically(JSON.encodeData(.object(current)), to: file)
        }
    }

    private var currentScope: JSONObject { lock.locked { scope } }

    // MARK: events

    /// The event JSON for [d]: [scope] is the scope of the process it
    /// describes, or nil when unknown (never this process's for another run).
    func event(_ d: EventDraft, release: String, environment: String, scope: JSONObject?) -> JSONObject {
        var p: JSONObject = [
            "eventId": .string(uuidV4()), "timestamp": .string(ISODate.format(d.timestamp)),
            "level": .string(d.level.rawValue), "runtime": "ios", "release": .string(release),
            "environment": .string(environment),
        ]
        if let values = d.exceptionValues, !values.isEmpty { p["exception"] = ["values": .array(Array(values.suffix(10)))] }
        if let message = d.message { p["message"] = ["formatted": .string(message.dartPrefix(8192))] }
        if let threads = d.threads { p["threads"] = .array(CrashEvents.fit(threads)) }
        if !d.images.isEmpty { p["debugImages"] = .array(d.images.prefix(500).map(\.json)) }
        if let scope {
            for key in Self.scopeKeys { if let v = scope[key] { p[key] = v } }
        }
        return p
    }

    /// Stores [payload] in the pending events (synchronously: crash paths
    /// call it before the process ends; names sort by time). Returns its JSON.
    @discardableResult
    func store(_ payload: JSONObject) -> String? {
        guard let dir = eventsDirectory else { return nil }
        let data = JSON.encodeData(.object(payload))
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        let id = payload["eventId"]?.stringValue ?? uuidV4()
        do {
            try FileIO.writeAtomically(data, to: dir.appendingPathComponent("\(ms)-\(id).json"))
            return String(decoding: data, as: UTF8.self)
        } catch {
            BugCapsuleLog.warn("crash bridge could not store an event: \(error)")
            return nil
        }
    }

    /// Earlier runs' reports: each removed only once its event is stored.
    private func buildReports(_ files: [URL]) {
        let (stack, release, environment, ledger) = lock.locked { (self.stack, self.release, self.environment, self.ledger) }
        for file in files {
            guard let data = try? Data(contentsOf: file), let r = NativeCrashReport.parse(data) else {
                FileIO.deleteQuietly(file)
                continue
            }
            // Suppressed: the uncaught-exception handler already stored its event.
            if !r.suppressed {
                let draft = CrashEvents.draft(from: r, stack: stack)
                let context = r.context
                let contextPid = context?["pid"]?.intValue
                let sameProcess = context != nil && (contextPid == nil || r.pid == nil || contextPid == r.pid)
                let ev = event(
                    draft, release: r.release ?? context?["release"]?.stringValue ?? release,
                    environment: r.environment ?? context?["environment"]?.stringValue ?? environment,
                    scope: sameProcess ? context : nil)
                guard store(ev) != nil else { continue }
            }
            ledger?.record(.crash, at: r.time, pid: r.pid)
            FileIO.deleteQuietly(file)
        }
    }

    func takePendingEvents(timeoutMs: Int) -> [String] {
        guard let dir = eventsDirectory else { return [] }
        final class Job: @unchecked Sendable {
            let lock = NSLock()
            var started = false
            var cancelled = false
            var result: [String] = []
            let done = DispatchSemaphore(value: 0)
        }
        let job = Job()
        let queue = lock.locked { self.queue }
        queue.async {
            let go = job.lock.locked { () -> Bool in
                if job.cancelled { return false }
                job.started = true
                return true
            }
            guard go else { return }
            let files = ((try? FileIO.fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            var out: [String] = []
            for file in files {
                if let data = try? Data(contentsOf: file), (try? JSON.parse(data))?.objectValue != nil {
                    out.append(String(decoding: data, as: UTF8.self))
                }
                FileIO.deleteQuietly(file)
            }
            job.result = out
            job.done.signal()
        }
        if job.done.wait(timeout: .now() + .milliseconds(max(timeoutMs, 0))) == .timedOut {
            // Not started yet: it never runs, and nothing is deleted. Started: it is only reading files.
            let started = job.lock.locked { () -> Bool in
                if !job.started { job.cancelled = true }
                return job.started
            }
            guard started else {
                BugCapsuleLog.warn("crash bridge: pending events not ready within \(timeoutMs) ms")
                return []
            }
            job.done.wait()
        }
        return job.result
    }

    /// Uncaught NSException: stored now; the SIGABRT report that follows
    /// only marks the run crashed.
    func recordUncaught(_ exception: NSException) {
        let (stack, release, environment) = lock.locked { (self.stack, self.release, self.environment) }
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
        let (threads, threadImages) = CrashEvents.threads(
            samples, stack: stack, resolve: { DebugImageCache.shared.image(containing: $0) })
        draft.threads = threads
        draft.images = CrashEvents.merge(images, threadImages)
        if store(event(draft, release: release, environment: environment, scope: currentScope)) != nil {
            NativeCrashHandler.suppressNextEvent()
        }
    }

    func recordHang(_ samples: [ThreadSample], threshold: TimeInterval) {
        let (stack, release, environment, ledger, queue) = lock.locked {
            (self.stack, self.release, self.environment, self.ledger, self.queue)
        }
        // A later MetricKit hang diagnostic of this process is the same hang.
        ledger?.record(.hang, at: Date(), pid: Int(getpid()))
        let ev = event(
            CrashEvents.hangDraft(samples, threshold: threshold, stack: stack), release: release,
            environment: environment, scope: currentScope)
        queue.async { [weak self] in
            guard let self, let json = self.store(ev) else { return }
            self.lock.locked { self.listener }?(json)
        }
    }

    /// MetricKit payload: duplicates of what the handlers or the watchdog
    /// reported are dropped; the rest are stored before returning.
    func receiveMetricKit(_ json: JSONValue, begin: Date? = nil, end: Date?) {
        let (installed, stack, current, environment, ledger, previous) = lock.locked {
            (directory != nil, self.stack, release, self.environment, self.ledger, previousScope)
        }
        guard installed else { return }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        for d in MetricKitConverter.diagnostics(fromPayload: json, stack: stack, timestamp: end, begin: begin) {
            if d.isDuplicate(in: ledger) { continue }
            // The scope of the process it describes, when known by pid.
            var scope: JSONObject?
            if let pid = d.pid {
                if pid == Int(getpid()) {
                    scope = currentScope
                } else if let previous, previous["pid"]?.intValue == pid {
                    scope = previous
                }
            }
            let release =
                scope?["release"]?.stringValue
                ?? MetricKitConverter.release(
                    of: d, current: current, appId: Bundle.main.bundleIdentifier, appVersion: version, appBuild: build,
                    customRelease: false)
            store(event(d.draft, release: release, environment: scope?["environment"]?.stringValue ?? environment, scope: scope))
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
