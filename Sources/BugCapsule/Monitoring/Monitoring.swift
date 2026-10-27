import Foundation

#if canImport(UIKit)
    import UIKit
#endif

/// A partially built error event (exception or message).
struct EventDraft: @unchecked Sendable {
    var level: MonitoringLevel
    var exceptionValues: [JSONValue]?
    var message: String?
    var threads: [JSONValue]?
    var images: [DebugImage] = []
    var options: CaptureOptions?
    var hint = EventHint()
    var timestamp = Date()
    /// Release, user, tags, contexts and breadcrumbs from an earlier launch
    /// (native crash report) instead of the current scope.
    var template: JSONObject?
}

/// Monitoring (monitoring-v1): error events, sessions, transactions and
/// feedback, batched into envelopes, redacted, persisted in their own
/// outbox and sent to `POST /v1/envelope`. One per capture session; off in
/// replay.
final class Monitoring: @unchecked Sendable {
    let options: BugCapsuleMonitoringOptions
    let release: String
    let environment: String
    let scope: Scope
    let stack: StackBuilder
    let directory: URL?
    let installId: String
    private(set) var tracer: Tracer!
    private(set) var health: ReleaseHealth?
    let frames = FramesTracker()
    private(set) var hangs: AppHangTracker?
    private(set) var metricKit: MetricKitSubscriber?
    /// This instance installed the process-wide crash handlers.
    private var ownsCrashHandlers = false
    let ledger: CrashLedger
    private weak var session: BugCapsuleSession?
    private let appInfo: (id: String?, name: String?, version: String, build: String)
    private let random: @Sendable () -> Double

    private let lock = NSRecursiveLock()
    private(set) var outbox: UploadOutbox?
    private var pending: [JSONValue] = []
    private var pendingBytes = 0
    private var batchScheduled = false
    private var remote: RemoteCaptureConfig?
    private var _lastEventId: String?
    private var stopped = false
    private var previousRoute: String?
    private var contextSyncScheduled = false
    private var foreground = true
    private var appStartPending = true
    private var screen: ScreenLoad?
    private var interaction: BugCapsuleTransaction?
    private var spanScopes: [ObjectIdentifier: BugCapsuleSpan?] = [:]
    let startDate = Date()
    /// How long screen / interaction transactions wait for child spans.
    var idleTimeout: TimeInterval = 3
    private let queue = DispatchQueue(label: "com.bugcapsule.monitoring", qos: .utility)

    static let batchDelay: TimeInterval = 1
    static let maxItemBytes = 1024 * 1024
    static let maxEnvelopeItems = 100
    static let maxEnvelopeBytes = 900 * 1024

    init(
        session: BugCapsuleSession, options: BugCapsuleMonitoringOptions, root: URL?, remote: RemoteCaptureConfig?,
        random: @escaping @Sendable () -> Double
    ) {
        self.session = session
        self.options = options
        self.remote = remote
        self.random = random
        let config = session.config
        appInfo = (config.appId, config.appName, config.appVersion, config.appBuild)
        release = (options.release ?? Self.defaultRelease(config)).dartPrefix(200)
        environment = (options.environment ?? Self.defaultEnvironment(session.mode)).dartPrefix(64)
        scope = Scope(maxBreadcrumbs: Self.clampBreadcrumbs(remote?.maxBreadcrumbs ?? options.maxBreadcrumbs))
        stack = StackBuilder(options: options)
        let dir = root?.appendingPathComponent("monitoring", isDirectory: true)
        if let dir { try? FileIO.ensureDirectory(dir) }
        directory = dir
        ledger = CrashLedger(file: dir?.appendingPathComponent("crash_times.json"))
        installId = Self.loadInstallId(dir)
        tracer = Tracer(monitoring: self, random: random)
    }

    static func defaultRelease(_ c: BugCapsuleConfig) -> String {
        let version = "\(c.appVersion)+\(c.appBuild)"
        if let id = c.appId, !id.isEmpty { return "\(id)@\(version)" }
        return version
    }

    static func defaultEnvironment(_ mode: CaptureMode) -> String {
        switch mode {
        case .production: return "production"
        case .qa: return "qa"
        case .debug: return "development"
        }
    }

    static func clampBreadcrumbs(_ n: Int) -> Int { min(max(n, 0), 100) }

    /// A random id persisted per install (never a hardware id).
    static func loadInstallId(_ dir: URL?) -> String {
        guard let file = dir?.appendingPathComponent("install_id") else { return uuidV4() }
        if let s = try? String(contentsOf: file, encoding: .utf8), UUID(uuidString: s.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
            return s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let id = uuidV4()
        try? FileIO.writeAtomically(Data(id.utf8), to: file)
        return id
    }

    // MARK: effective settings

    var isActive: Bool {
        lock.locked { !stopped && (remote?.enabled ?? true) && (remote?.monitoringEnabled ?? true) }
    }

    var wantsBreadcrumbs: Bool { isActive }

    var errorSampleRate: Double { min(max(lock.locked { remote?.errorSampleRate } ?? options.errorSampleRate, 0), 1) }

    /// The remote rate when fetched, else the app's (`tracesSampler` wins over both).
    var tracesSampleRate: Double { min(max(lock.locked { remote?.tracesSampleRate } ?? options.tracesSampleRate ?? 0, 0), 1) }

    var tracePropagationTargets: [String] { lock.locked { remote?.tracePropagationTargets } ?? options.tracePropagationTargets }

    var sessionTrackingEnabled: Bool { options.enableAutoSessionTracking && lock.locked { remote?.sessionTracking ?? true } }

    var currentScope: Scope { Scope.pushed ?? scope }

    var lastEventId: String? { lock.locked { _lastEventId } }

    /// MetricKit diagnostics will be received: journals of processes that
    /// died without a crash report are kept for them.
    var metricKitActive: Bool {
        #if canImport(MetricKit) && os(iOS)
            return lock.locked { metricKit != nil }
        #else
            return false
        #endif
    }

    // MARK: start / stop

    /// Starts monitoring: reports what the previous launch left (native
    /// crash, unfinished session), installs crash and hang handlers and
    /// starts the session. [outboxDirectory] nil: nothing is sent.
    @MainActor
    func start(outboxDirectory: URL?) {
        if let outboxDirectory {
            let box = UploadOutbox(directory: outboxDirectory, limits: options.outboxLimits, fileExtension: "envelope")
            lock.locked { outbox = box }
            Task { await box.open() }
        }
        let report = directory.flatMap { NativeCrashHandler.pendingReport(in: $0) }
        let health = ReleaseHealth(
            file: directory?.appendingPathComponent("session.json"), release: release, environment: environment,
            timeout: options.sessionTimeout,
            did: { [weak self] in self?.currentScope.user?.id ?? self?.installId ?? uuidV4() },
            emit: { [weak self] payload in self?.enqueue("session", payload) })
        lock.locked { self.health = health }
        // What the previous run left is persisted in the outbox before its
        // files go, so a crash right after launch cannot lose it.
        if let previous = health.recoverPrevious(crashedAt: report?.time, discard: false) {
            enqueue("session", previous, synchronous: true)
        }
        health.discardPrevious()
        if let report, let directory {
            ledger.record(.crash, at: report.time, pid: report.pid)
            if !report.suppressed, let session, let pid = report.pid, let journal = session.crashJournals?.find(pid: pid) {
                // That process kept a crash journal: its capsule is built off
                // the main thread (crash-capsules §2). The report stays until
                // the event is stored.
                session.queue.async { [self] in
                    session.captureCrash(
                        eventFromReport(report), journal: journal, crashTime: report.preciseTime, monitoring: self)
                    NativeCrashHandler.discardPendingReport(in: directory)
                }
            } else {
                if !report.suppressed { _ = capture(eventFromReport(report), synchronous: true) }
                NativeCrashHandler.discardPendingReport(in: directory)
            }
        }
        scope.onChange = { [weak self] in self?.scheduleContextSync() }
        // Uncaught NSExceptions become fatal events (chained handler).
        CrashHandler.install()
        // The process-wide handlers belong to one owner (BugCapsuleCrashBridge
        // when an embedding SDK installed it first).
        let owns = CrashOwnership.claim(.sdk)
        if !owns { BugCapsuleLog.warn("crash handlers already installed by BugCapsuleCrashBridge; monitoring skips them") }
        lock.locked { ownsCrashHandlers = owns }
        if owns, options.enableNativeCrashHandling, let directory {
            if !NativeCrashHandler.install(directory: directory, mach: options.enableMachExceptionHandling) {
                BugCapsuleLog.warn("native crash handler not fully installed")
            }
            NativeCrashHandler.setRelease(release, environment: environment)
            syncCrashContext()
        }
        #if canImport(UIKit)
            let inForeground = UIApplication.shared.applicationState != .background
        #else
            let inForeground = true
        #endif
        lock.locked { foreground = inForeground }
        if sessionTrackingEnabled && inForeground { health.start() }
        if owns && options.enableAppHangTracking && !NativeCrashHandler.debuggerAttached {
            startHangTracking(threshold: options.appHangTimeout)
        }
        if owns && options.enableMetricKit {
            let subscriber = MetricKitSubscriber { [weak self] json, begin, end in
                self?.receiveMetricKit(json, begin: begin, end: end)
            }
            lock.locked { metricKit = subscriber }
            subscriber.start()
        }
        if options.enableFramesTracking || options.enableScreenTracing || options.enableAppStartTracking {
            frames.start(counting: options.enableFramesTracking)
        }
    }

    @MainActor
    func startHangTracking(threshold: TimeInterval) {
        let tracker = AppHangTracker(
            threshold: threshold, mainThread: NativeCrashHandler.currentThreadPort,
            isForeground: { [weak self] in self?.lock.locked { self?.foreground ?? false } ?? false },
            onHang: { [weak self] samples in self?.captureAppHang(samples, threshold: threshold) })
        lock.locked { hangs = tracker }
        tracker.start()
    }

    func stop() {
        let (hangs, box, metricKit, owns): (AppHangTracker?, UploadOutbox?, MetricKitSubscriber?, Bool) = lock.locked {
            stopped = true
            defer { ownsCrashHandlers = false }
            return (self.hangs, outbox, self.metricKit, ownsCrashHandlers)
        }
        hangs?.stop()
        metricKit?.stop()
        frames.stop()
        scope.onChange = nil
        if owns {
            if options.enableNativeCrashHandling { NativeCrashHandler.uninstallForTesting() }
            CrashOwnership.release(.sdk)
        }
        if let box { Task { await box.close() } }
    }

    // MARK: lifecycle

    @MainActor
    func onLifecycle(_ state: String) {
        guard isActive else { return }
        switch state {
        case "resumed":
            lock.locked { foreground = true }
            if sessionTrackingEnabled { health?.willEnterForeground() }
            let appStart = lock.locked { () -> Bool in
                defer { appStartPending = false }
                return appStartPending
            }
            if appStart && options.enableAppStartTracking {
                frames.onNextFrame { [weak self] in self?.appStartEnded(at: Date()) }
            }
        case "paused":
            lock.locked { foreground = false }
            if sessionTrackingEnabled { health?.didEnterBackground() }
            Task { await self.flushPending() }
        case "detached":
            if sessionTrackingEnabled { health?.end() }
            writePendingSynchronously()
        default:
            break
        }
    }

    // MARK: remote config

    func applyRemote(_ next: RemoteCaptureConfig) {
        let (wasActive, box) = lock.locked { () -> (Bool, UploadOutbox?) in
            let was = !stopped && (remote?.enabled ?? true) && (remote?.monitoringEnabled ?? true)
            remote = next
            return (was, outbox)
        }
        scope.maxBreadcrumbs = Self.clampBreadcrumbs(next.maxBreadcrumbs ?? options.maxBreadcrumbs)
        if !next.enabled || !next.monitoringEnabled {
            // Nothing captured before the switch may leave the device.
            lock.locked {
                pending = []
                pendingBytes = 0
            }
            if let box { Task { await box.purge() } }
            if wasActive { BugCapsuleLog.info("monitoring disabled by remote config") }
        }
    }

    // MARK: breadcrumbs

    /// Breadcrumbs from the flight recorder's event stream (already redacted).
    func recorded(_ type: String, _ data: JSONObject) {
        guard isActive else { return }
        let previous = lock.locked { () -> String? in
            let p = previousRoute
            if type == EventTypes.route { previousRoute = data["location"]?.stringValue }
            return p
        }
        guard let crumb = BreadcrumbMapper.breadcrumb(type: type, data: data, previousRoute: previous) else { return }
        addBreadcrumb(crumb)
        if type == EventTypes.action, options.enableUserInteractionTracing, let id = data["id"]?.stringValue {
            startInteraction(id)
        }
    }

    func addBreadcrumb(_ crumb: Breadcrumb, to target: Scope? = nil) {
        var c = crumb
        if let before = options.beforeBreadcrumb {
            guard let kept = before(c) else { return }
            c = kept
        }
        (target ?? currentScope).addBreadcrumb(c)
    }

    // MARK: events

    private lazy var staticContexts: JSONObject = Self.deviceContexts(
        appId: appInfo.id, appName: appInfo.name, version: appInfo.version, build: appInfo.build)

    /// `device`, `os`, `app` and `culture` contexts (constant for the process).
    static func deviceContexts(appId: String?, appName: String?, version: String, build: String) -> JSONObject {
        var device: JSONObject = [
            "model": .string(DeviceInfo.model), "manufacturer": "Apple", "arch": .string(DeviceInfo.arch),
            "simulator": .bool(DeviceInfo.isSimulator),
        ]
        device["family"] = .string(DeviceInfo.model.prefix { $0.isLetter }.description)
        var os: JSONObject = [:]
        #if os(iOS)
            os["name"] = "iOS"
        #elseif os(macOS)
            os["name"] = "macOS"
        #else
            os["name"] = "Apple"
        #endif
        let v = ProcessInfo.processInfo.operatingSystemVersion
        os["version"] = .string("\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
        if let build = DeviceInfo.osBuild { os["build"] = .string(build) }
        var app: JSONObject = ["appVersion": .string(version), "appBuild": .string(build)]
        if let appId { app["appId"] = .string(appId) }
        if let appName { app["appName"] = .string(appName) }
        let culture: JSONObject = [
            "locale": .string(Locale.current.identifier), "timezone": .string(TimeZone.current.identifier),
        ]
        return ["device": .object(device), "os": .object(os), "app": .object(app), "culture": .object(culture)]
    }

    func contexts(_ extra: JSONObject = JSONObject(), span: BugCapsuleSpan?) -> JSONObject {
        var c = lock.locked { staticContexts }
        if var app = c["app"]?.objectValue {
            app["inForeground"] = .bool(lock.locked { foreground })
            c["app"] = .object(app)
        }
        for (k, v) in extra { c[k] = v }
        if let span {
            c["trace"] = ["traceId": .string(span.traceId), "spanId": .string(span.spanId), "op": .string(span.op)]
        } else {
            let parent = tracer.traceparent().split(separator: "-")
            if parent.count >= 3 { c["trace"] = ["traceId": .string(String(parent[1])), "spanId": .string(String(parent[2]))] }
        }
        return c
    }

    private func userJSON(_ user: BugCapsuleUser?) -> JSONValue {
        var u = user ?? BugCapsuleUser()
        if options.sendDefaultPii && u.ipAddress == nil { u.ipAddress = "{{auto}}" }
        return u.json
    }

    /// The event payload for [draft] with the current scope.
    func payload(for draft: EventDraft, capsuleId: String?) -> JSONObject {
        let opts = draft.options ?? CaptureOptions()
        var p = JSONObject()
        p["eventId"] = .string(uuidV4())
        p["timestamp"] = .string(ISODate.format(draft.timestamp))
        let snap = currentScope.snapshot()
        let level = opts.level ?? (draft.template == nil ? snap.level : nil) ?? draft.level
        p["level"] = .string(level.rawValue)
        p["runtime"] = "ios"
        p["release"] = .string(release)
        p["environment"] = .string(environment)
        if let dist = options.dist { p["dist"] = .string(dist) }
        if let values = draft.exceptionValues, !values.isEmpty {
            p["exception"] = ["values": .array(Array(values.suffix(10)))]
        }
        p["message"] = draft.message.map { ["formatted": .string($0.dartPrefix(8192))] } ?? .null
        if let template = draft.template {
            for key in ["release", "environment", "dist", "user", "tags", "extra", "contexts", "breadcrumbs", "fingerprint"] {
                if let v = template[key] { p[key] = v }
            }
            if let fp = opts.fingerprint { p["fingerprint"] = .array(fp.map { .string($0) }) }
        } else {
            let fingerprint = opts.fingerprint ?? snap.fingerprint
            p["fingerprint"] = fingerprint.map { .array($0.prefix(10).map { .string($0.dartPrefix(200)) }) } ?? .null
            var tags = snap.tags
            for k in opts.tags.keys.sorted() where Scope.validTagKey(k) { tags[k] = .string(opts.tags[k]!.dartPrefix(200)) }
            p["tags"] = .object(tags)
            p["user"] = userJSON(snap.user)
            var ctx = snap.contexts
            for (k, v) in opts.contexts { ctx[k] = v }
            p["contexts"] = .object(contexts(ctx, span: tracer.activeSpan))
            let max = scope.maxBreadcrumbs
            p["breadcrumbs"] = .array(snap.breadcrumbs.suffix(max).map(\.json))
            var extra = snap.extra
            for (k, v) in opts.extra { extra[k] = v }
            p["extra"] = .object(extra)
        }
        if !draft.images.isEmpty { p["debugImages"] = .array(draft.images.prefix(500).map(\.json)) }
        p["request"] = .null
        if let capsuleId { p["capsuleId"] = .string(capsuleId) }
        if let threads = draft.threads { p["threads"] = .array(threads) }
        return p
    }

    /// Builds, samples, runs `beforeSend` and queues an event. Returns its
    /// id, or nil when it was dropped. [synchronous]: written to the outbox
    /// before returning (crash paths).
    @discardableResult
    func capture(_ draft: EventDraft, capsuleId: String? = nil, synchronous: Bool = false) -> String? {
        guard let payload = prepare(draft, capsuleId: capsuleId) else { return nil }
        return send(payload, draft: draft, synchronous: synchronous)
    }

    /// The payload `capture` would queue (sampled, through `beforeSend`), or
    /// nil when it is dropped. A crash capsule is built between this and `send`.
    func prepare(_ draft: EventDraft, capsuleId: String?) -> JSONObject? {
        guard isActive else { return nil }
        var payload = payload(for: draft, capsuleId: capsuleId)
        let level = MonitoringLevel(rawValue: payload["level"]?.stringValue ?? "") ?? .error
        if level != .fatal && capsuleId == nil && random() >= errorSampleRate { return nil }
        if let before = options.beforeSend {
            guard let kept = before(MonitoringEvent(payload: payload), draft.hint) else { return nil }
            payload = kept.payload
        }
        return payload["eventId"]?.stringValue == nil ? nil : payload
    }

    /// Queues a payload from `prepare`. Returns its id.
    @discardableResult
    func send(_ payload: JSONObject, draft: EventDraft, synchronous: Bool) -> String? {
        guard let id = payload["eventId"]?.stringValue else { return nil }
        let level = MonitoringLevel(rawValue: payload["level"]?.stringValue ?? "") ?? .error
        lock.locked { _lastEventId = id }
        if draft.exceptionValues != nil && (level == .error || level == .fatal) && draft.template == nil && !synchronous {
            if sessionTrackingEnabled { health?.errorCaptured() }
        }
        enqueue("event", payload, synchronous: synchronous)
        return id
    }

    func errorDraft(_ error: Error, mechanism: String, handled: Bool, options opts: CaptureOptions?) -> EventDraft {
        let (frames, images) = stack.liveFrames(Thread.callStackReturnAddresses.map { $0.uint64Value })
        let scrub = session?.redactor.scrubText ?? { $0 }
        let values = StackBuilder.errorValues(error, mechanism: mechanism, handled: handled, frames: frames, scrub: scrub)
        var d = EventDraft(level: .error, exceptionValues: values, images: images, options: opts)
        d.hint = EventHint(error: error)
        return d
    }

    func exceptionDraft(_ exception: NSException, handled: Bool, level: MonitoringLevel, options opts: CaptureOptions? = nil)
        -> EventDraft
    {
        let addresses = exception.callStackReturnAddresses.map { $0.uint64Value }
        let (frames, images) =
            addresses.isEmpty
            ? stack.liveFrames(Thread.callStackReturnAddresses.map { $0.uint64Value })
            : stack.liveFrames(addresses, dropSDKFrames: false)
        let scrub = session?.redactor.scrubText ?? { $0 }
        let value = StackBuilder.exceptionValue(
            type: exception.name.rawValue, value: scrub(exception.reason ?? ""), module: nil, mechanism: "nsexception",
            handled: handled, frames: frames)
        var d = EventDraft(level: level, exceptionValues: [value], images: images, options: opts)
        d.hint = EventHint(exception: exception)
        return d
    }

    /// A failure of the capsule pipeline (`fail`, reported errors) as an event.
    func failureDraft(_ failure: FailureRecord, error: Error?, options opts: CaptureOptions?) -> EventDraft {
        if let error { return errorDraft(error, mechanism: "manual", handled: true, options: opts) }
        let (frames, images) = stack.liveFrames(Thread.callStackReturnAddresses.map { $0.uint64Value })
        let mechanism = failure.kind == .assertion ? "assertion" : "manual"
        let value = StackBuilder.exceptionValue(
            type: failure.type, value: failure.message, module: nil, mechanism: mechanism, handled: true, frames: frames)
        return EventDraft(level: .error, exceptionValues: [value], images: images, options: opts)
    }

    func messageDraft(_ message: String, level: MonitoringLevel) -> EventDraft {
        var d = EventDraft(level: level, message: session?.redactor.scrubText(message) ?? message)
        if options.attachStacktrace {
            let (frames, images) = stack.liveFrames(Thread.callStackReturnAddresses.map { $0.uint64Value })
            d.threads = [["id": 0, "current": true, "crashed": false, "stacktrace": StackBuilder.stacktrace(frames)]]
            d.images = images
        }
        return d
    }

    /// Uncaught NSException: queued synchronously (the process is about to
    /// end); the native report that follows only marks the session crashed.
    func captureUncaughtException(_ exception: NSException, capsuleId: String?) -> String? {
        guard isActive else { return nil }
        let id = capture(exceptionDraft(exception, handled: false, level: .fatal), capsuleId: capsuleId, synchronous: true)
        if sessionTrackingEnabled, let update = health?.crashedSynchronously() {
            enqueue("session", update, synchronous: true)
        }
        if id != nil { NativeCrashHandler.suppressNextEvent() }
        writePendingSynchronously()
        return id
    }

    func eventFromReport(_ r: NativeCrashReport) -> EventDraft { CrashEvents.draft(from: r, stack: stack) }

    func captureAppHang(_ samples: [ThreadSample], threshold: TimeInterval) {
        // A later MetricKit hang diagnostic of this process is the same hang.
        ledger.record(.hang, at: Date(), pid: Int(getpid()))
        capture(CrashEvents.hangDraft(samples, threshold: threshold, stack: stack))
    }

    /// One MetricKit diagnostic payload. Failures BugCapsule reported
    /// itself (a crash report or a watchdog hang of the same process, or
    /// within 60 s) are dropped; the rest are written to the outbox before
    /// returning (MetricKit delivers each payload once).
    func receiveMetricKit(_ json: JSONValue, begin: Date? = nil, end: Date?) {
        guard isActive else { return }
        for d in MetricKitConverter.diagnostics(fromPayload: json, stack: stack, timestamp: end, begin: begin) {
            if d.isDuplicate(in: ledger) { continue }
            var draft = d.draft
            let r = MetricKitConverter.release(
                of: d, current: release, appId: appInfo.id, appVersion: appInfo.version, appBuild: appInfo.build,
                customRelease: options.release != nil)
            // That run's scope is unknown: device contexts only (not this launch's `app`).
            var contexts = lock.locked { staticContexts }
            contexts["app"] = nil
            draft.template = ["release": .string(r), "environment": .string(environment), "contexts": .object(contexts)]
            // A crash of a process that kept a journal gets its capsule now
            // (the journal was claimed for it on the launch after it died).
            if d.isCrash, let pid = d.pid, let session, let journal = session.crashJournals?.find(pid: pid) {
                session.captureCrash(draft, journal: journal, crashTime: nil, monitoring: self)
            } else {
                capture(draft, synchronous: true)
            }
        }
    }

    // MARK: feedback

    func captureFeedback(
        message: String, name: String?, email: String?, eventId: String?, url: String?, tags: [String: String],
        capsuleId: String?
    ) -> String? {
        guard isActive else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let id = uuidV4()
        let snap = currentScope.snapshot()
        var t = snap.tags
        for k in tags.keys.sorted() where Scope.validTagKey(k) { t[k] = .string(tags[k]!.dartPrefix(200)) }
        var p: JSONObject = [
            "feedbackId": .string(id), "timestamp": .string(ISODate.format(Date())),
            "eventId": eventId.map { .string($0) } ?? .null, "name": name.map { .string($0.dartPrefix(200)) } ?? .null,
            "email": email.map { .string($0.dartPrefix(200)) } ?? .null, "message": .string(trimmed.dartPrefix(5000)),
            "url": url.map { .string($0) } ?? .null, "release": .string(release), "environment": .string(environment),
            "runtime": "ios",
        ]
        p["user"] = userJSON(snap.user)
        p["contexts"] = .object(contexts(span: tracer.activeSpan))
        p["tags"] = .object(t)
        p["capsuleId"] = capsuleId.map { .string($0) } ?? .null
        enqueue("feedback", p)
        return id
    }

    // MARK: transactions

    func startTransaction(name: String, op: String, bindToScope: Bool, start: Date = Date()) -> BugCapsuleTransaction {
        let t = tracer.startTransaction(name: name.dartPrefix(200), op: op, bindToScope: bindToScope, start: start)
        if frames.isCounting {
            let before = frames.counts
            t.onFinish.append { [weak self] t in
                guard let self else { return }
                let d = self.frames.counts.minus(before)
                t.setMeasurement("frames_total", value: Double(d.total))
                t.setMeasurement("frames_slow", value: Double(d.slow))
                t.setMeasurement("frames_frozen", value: Double(d.frozen))
                t.setMeasurement("frames_delay", value: d.delay, unit: "second")
            }
        }
        return t
    }

    /// `startSpan`: a child of the active span (or a new transaction), made
    /// the scope's span until `endSpanScope`.
    func beginSpan(name: String, op: String) -> BugCapsuleSpan {
        let previous = scope.span
        let span: BugCapsuleSpan =
            tracer.activeSpan?.startChild(op: op, description: name)
            ?? startTransaction(name: name, op: op, bindToScope: false)
        lock.locked { spanScopes[ObjectIdentifier(span)] = previous }
        scope.span = span
        return span
    }

    func endSpanScope(_ span: BugCapsuleSpan) {
        let previous = lock.locked { spanScopes.removeValue(forKey: ObjectIdentifier(span)) } ?? nil
        if scope.span === span { scope.span = previous.flatMap { $0.isFinished ? nil : $0 } }
    }

    func send(_ transaction: BugCapsuleTransaction) {
        guard transaction.sampled, !transaction.discarded, isActive else { return }
        var p = transaction.payload()
        p["release"] = .string(release)
        p["environment"] = .string(environment)
        p["runtime"] = "ios"
        let snap = scope.snapshot()
        var tags = snap.tags
        for (k, v) in p["tags"]?.objectValue ?? JSONObject() { tags[k] = v }
        p["tags"] = .object(tags)
        p["user"] = userJSON(snap.user)
        var ctx = contexts(snap.contexts, span: nil)
        ctx["trace"] = [
            "traceId": .string(transaction.traceId), "spanId": .string(transaction.spanId), "op": .string(transaction.op),
            "status": .string((transaction.status ?? .ok).rawValue),
        ]
        p["contexts"] = .object(ctx)
        if let before = options.beforeSendTransaction {
            guard let kept = before(p) else { return }
            p = kept
        }
        enqueue("transaction", p)
    }

    // MARK: envelopes

    private func envelopeBody(_ items: [JSONValue]) -> Data {
        let doc: JSONValue = ["sdk": ["name": .string(sdkName), "version": .string(sdkVersion)], "items": .array(items)]
        return JSON.encodeData(doc)
    }

    /// Redacts [payload] and queues it for the next envelope.
    func enqueue(_ type: String, _ payload: JSONObject, synchronous: Bool = false) {
        guard isActive else { return }
        if type == "session" && !sessionTrackingEnabled { return }
        let redactor = session?.redactor ?? Redactor()
        var clean = ItemRedaction.redact(payload, redactor: redactor)
        var size = JSON.encodeData(.object(clean)).count
        if size > Self.maxItemBytes && type != "session" {
            clean["breadcrumbs"] = .array([])
            clean["extra"] = .object(["_truncated": true])
            size = JSON.encodeData(.object(clean)).count
            if size > Self.maxItemBytes {
                BugCapsuleLog.warn("dropping a \(type) item of \(size) bytes (limit 1 MiB)")
                return
            }
        }
        let item: JSONValue = ["type": .string(type), "payload": .object(clean)]
        if synchronous {
            writeSynchronously([item])
            return
        }
        let flushNow: Bool = lock.locked {
            pending.append(item)
            pendingBytes += size
            return pending.count >= Self.maxEnvelopeItems || pendingBytes >= Self.maxEnvelopeBytes
        }
        if flushNow {
            Task { await self.flushPending() }
        } else {
            scheduleBatch()
        }
    }

    private func scheduleBatch() {
        let schedule = lock.locked { () -> Bool in
            if batchScheduled { return false }
            batchScheduled = true
            return true
        }
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + Self.batchDelay) { [weak self] in
            Task { await self?.flushPending() }
        }
    }

    private func takePending() -> [JSONValue] {
        lock.locked {
            let items = pending
            pending = []
            pendingBytes = 0
            batchScheduled = false
            return items
        }
    }

    /// Moves pending items into the outbox and sends.
    func flushPending(send: Bool = true) async {
        let items = takePending()
        let box = lock.locked { outbox }
        if !items.isEmpty, let box {
            if let bytes = try? Gzip.compress(envelopeBody(items)) {
                if !(await box.enqueue(capsuleId: uuidV4(), bytes: bytes)) {
                    BugCapsuleLog.warn("envelope not queued (outbox limit or disk error)")
                }
            }
        }
        if send { await session?.flushEnvelopes() }
    }

    private func writeSynchronously(_ items: [JSONValue]) {
        guard let box = lock.locked({ outbox }), let bytes = try? Gzip.compress(envelopeBody(items)) else { return }
        UploadOutbox.writeSynchronously(directory: box.directory, capsuleId: uuidV4(), bytes: bytes, fileExtension: "envelope")
    }

    func writePendingSynchronously() {
        let items = takePending()
        if !items.isEmpty { writeSynchronously(items) }
    }

    /// The wire body for a queued envelope: `sentAt` added, gzip over 1 KiB.
    static func prepareForSending(_ stored: Data) -> (Data, Bool)? {
        guard let raw = try? Gzip.decompress(stored, maxBytes: 10 * 1024 * 1024),
            case .object(let doc)? = try? JSON.parse(raw)
        else { return nil }
        var out: JSONObject = ["sentAt": .string(ISODate.format(Date()))]
        for (k, v) in doc where k != "sentAt" { out[k] = v }
        let body = JSON.encodeData(.object(out))
        if body.count > 1024, let gz = try? Gzip.compress(body) { return (gz, true) }
        return (body, false)
    }

    // MARK: crash context

    private func scheduleContextSync() {
        guard options.enableNativeCrashHandling else { return }
        let schedule = lock.locked { () -> Bool in
            if contextSyncScheduled { return false }
            contextSyncScheduled = true
            return true
        }
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.lock.locked { self.contextSyncScheduled = false }
            self.syncCrashContext()
        }
    }

    /// The event template the native crash handler writes with its report.
    func crashContext() -> JSONObject {
        let snap = scope.snapshot()
        var c: JSONObject = ["release": .string(release), "environment": .string(environment)]
        if let dist = options.dist { c["dist"] = .string(dist) }
        c["user"] = userJSON(snap.user)
        c["tags"] = .object(snap.tags)
        c["extra"] = .object(snap.extra)
        c["contexts"] = .object(contexts(snap.contexts, span: snap.span))
        c["breadcrumbs"] = .array(snap.breadcrumbs.suffix(scope.maxBreadcrumbs).map(\.json))
        if let fp = snap.fingerprint { c["fingerprint"] = .array(fp.map { .string($0) }) }
        let redactor = session?.redactor ?? Redactor()
        return ItemRedaction.redact(c, redactor: redactor)
    }

    func syncCrashContext() {
        guard options.enableNativeCrashHandling, isActive else { return }
        NativeCrashHandler.setContext(crashContext())
    }

    // MARK: screens, app start, interactions

    final class ScreenLoad: @unchecked Sendable {
        let name: String
        let transaction: BugCapsuleTransaction
        let ttid: BugCapsuleSpan
        let ttfd: BugCapsuleSpan?
        init(name: String, transaction: BugCapsuleTransaction, ttid: BugCapsuleSpan, ttfd: BugCapsuleSpan?) {
            self.name = name
            self.transaction = transaction
            self.ttid = ttid
            self.ttfd = ttfd
        }
    }

    /// Ids in screen names become `:id` (`/product/42` → `/product/:id`).
    static func screenName(_ raw: String) -> String {
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false).map { part -> String in
            let s = String(part)
            if !s.isEmpty && (s.allSatisfy(\.isNumber) || UUID(uuidString: s) != nil) { return ":id" }
            return s
        }
        return parts.joined(separator: "/")
    }

    /// A screen starts loading: `ui.load` transaction with TTID (next frame)
    /// and, when enabled, TTFD (`reportFullyDisplayed`).
    @MainActor
    func screenWillAppear(_ rawName: String) {
        guard isActive, options.enableScreenTracing else { return }
        let name = Self.screenName(session?.redactor.redactURL(rawName) ?? rawName)
        let (previous, previousInteraction) = lock.locked { () -> (ScreenLoad?, BugCapsuleTransaction?) in
            let p = (screen, interaction)
            screen = nil
            interaction = nil
            return p
        }
        if let previous, !previous.transaction.isFinished {
            previous.ttid.finish(status: .deadlineExceeded)
            previous.ttfd?.finish(status: .deadlineExceeded)
            previous.transaction.finish(status: .cancelled)
        }
        previousInteraction?.finish()
        let t = startTransaction(name: name, op: "ui.load", bindToScope: true)
        let ttid = t.startChild(op: "ui.load.initial_display", description: "\(name) initial display")
        let ttfd = options.enableTimeToFullDisplayTracing
            ? t.startChild(op: "ui.load.full_display", description: "\(name) full display") : nil
        let load = ScreenLoad(name: name, transaction: t, ttid: ttid, ttfd: ttfd)
        lock.locked { screen = load }
        frames.onNextFrame { [weak self] in
            let now = Date()
            ttid.finish(at: now)
            t.setMeasurement(
                "time_to_initial_display", value: now.timeIntervalSince(t.startTimestamp) * 1000, unit: "millisecond")
            if let ttfd {
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    if !ttfd.isFinished {
                        ttfd.finish(status: .deadlineExceeded)
                        self?.finishWhenIdle(t)
                    }
                }
            } else {
                self?.finishWhenIdle(t)
            }
        }
    }

    @MainActor
    func reportFullyDisplayed() {
        guard let load = lock.locked({ screen }), let ttfd = load.ttfd, !ttfd.isFinished else { return }
        let finish: @Sendable () -> Void = { [weak self] in
            let now = Date()
            ttfd.finish(at: now)
            load.transaction.setMeasurement(
                "time_to_full_display", value: now.timeIntervalSince(load.transaction.startTimestamp) * 1000,
                unit: "millisecond")
            self?.finishWhenIdle(load.transaction)
        }
        // Full display is never before initial display.
        if load.ttid.isFinished { finish() } else { frames.onNextFrame(finish) }
    }

    /// Finishes [t] once it has no open children for `idle` seconds (at most
    /// `limit`), trimmed to its last child.
    func finishWhenIdle(_ t: BugCapsuleTransaction, idle: TimeInterval? = nil, limit: TimeInterval = 30) {
        let idle = idle ?? idleTimeout
        final class Watch: @unchecked Sendable {
            let started = Date()
            var idleSince: Date?
        }
        let watch = Watch()
        @Sendable func check() {
            if t.isFinished { return }
            let now = Date()
            if t.openChildren.isEmpty {
                watch.idleSince = watch.idleSince ?? now
            } else {
                watch.idleSince = nil
            }
            let timedOut = now.timeIntervalSince(watch.started) >= limit
            if timedOut || (watch.idleSince.map { now.timeIntervalSince($0) >= idle } ?? false) {
                for c in t.openChildren { c.finish(status: .deadlineExceeded, at: now) }
                // An interaction that started nothing is not worth a transaction.
                if t.op == "ui.action.click" && t.allChildren.isEmpty { t.discarded = true }
                let end = t.allChildren.compactMap(\.timestamp).max() ?? now
                t.finish(status: timedOut ? .deadlineExceeded : nil, at: timedOut ? now : end)
                lock.locked {
                    if screen?.transaction === t { screen = nil }
                    if interaction === t { interaction = nil }
                }
                return
            }
            queue.asyncAfter(deadline: .now() + 0.1) { check() }
        }
        // Checks run on the serial monitoring queue.
        queue.async { check() }
    }

    func startInteraction(_ id: String) {
        let busy = lock.locked { (screen != nil && !(screen!.transaction.isFinished)) || interaction != nil }
        if busy || scope.span != nil { return }
        let t = startTransaction(name: id, op: "ui.action.click", bindToScope: true)
        lock.locked { interaction = t }
        finishWhenIdle(t)
    }

    /// Cold (or prewarmed: warm) start, measured from process start to the
    /// first frame after the app became active.
    func appStartEnded(at end: Date) {
        guard isActive, options.enableAppStartTracking else { return }
        let prewarmed = ProcessInfo.processInfo.environment["ActivePrewarm"] == "1"
        let processStart = DeviceInfo.processStart ?? startDate
        let start = prewarmed ? startDate : processStart
        let duration = end.timeIntervalSince(start)
        // Launched in the background, or a debugger paused it: not a user-visible start.
        guard duration > 0, duration < 60 else { return }
        let kind = prewarmed ? "warm" : "cold"
        let t = startTransaction(name: "App Start", op: "app.start.\(kind)", bindToScope: false, start: start)
        let root = t.startChild(op: "app.start.\(kind)", description: "\(kind.capitalized) Start")
        if !prewarmed {
            let pre = BugCapsuleSpan(
                traceId: t.traceId, parentSpanId: root.spanId, op: "app.start.\(kind)", description: "Pre Runtime Init",
                sampled: t.sampled, start: processStart)
            pre.root = t
            t.adopt(pre)
            pre.finish(at: startDate)
        }
        let initSpan = BugCapsuleSpan(
            traceId: t.traceId, parentSpanId: root.spanId, op: "app.start.\(kind)", description: "UIKit Init",
            sampled: t.sampled, start: startDate)
        initSpan.root = t
        t.adopt(initSpan)
        initSpan.finish(at: end)
        root.finish(at: end)
        t.setMeasurement("app_start_\(kind)", value: duration * 1000, unit: "millisecond")
        t.finish(at: end)
    }

    // MARK: flush

    /// Sends what is queued; false when [timeout] passed first.
    func flush(timeout: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.flushPending()
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
