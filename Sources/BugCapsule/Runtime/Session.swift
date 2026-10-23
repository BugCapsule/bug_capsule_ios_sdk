import Foundation

#if canImport(UIKit)
    import UIKit
#endif

/// Result of writing a capsule.
public struct CaptureResult: Sendable {
    public let capsuleId: String
    public let file: URL
    public let eligibility: Eligibility
    public let failureSignature: String?
    /// Nil when no backend is configured.
    public let upload: UploadResult?
}

let sdkName = "bugcapsule-ios"
let sdkVersion = "0.4.1-beta.1"

/// The running SDK: recording, capsule writing, uploads, remote config and
/// replay setup. Integrations receive it in `setUp`. Thread-safe; UI work
/// (snapshots, restores, replay dispatch) runs on the main thread.
///
/// Every SDK error is caught: a failure in capture setup leaves the app
/// running without capture.
public final class BugCapsuleSession: @unchecked Sendable {
    private static let currentLock = NSLock()
    nonisolated(unsafe) private static var _current: BugCapsuleSession?
    static var current: BugCapsuleSession? {
        get { currentLock.locked { _current } }
        set { currentLock.locked { _current = newValue } }
    }

    public let config: BugCapsuleConfig
    let integrations: [BugCapsuleIntegration]
    let overrides: BugCapsuleTestOverrides?
    public let mode: CaptureMode
    let gitSha: String?
    let gitDirty: Bool?

    private let lock = NSRecursiveLock()
    let queue = DispatchQueue(label: "com.bugcapsule.session", qos: .utility)
    private let startUptime = uptime()
    let sessionId = uuidV4()
    let startedAt = Date()
    let seed = BugCapsuleRandom.newSeed()
    private var _random: BugCapsuleRandom
    private let samplingRandom: @Sendable () -> Double

    private var recorder: FlightRecorder?
    private var _engine: ReplayEngine?
    private var _redactor = Redactor()
    private var recording = false
    private var captureBodies = true
    private var maxCapsuleBytes = 5 * 1024 * 1024
    private var sessionRate = 1.0
    private var captureEpoch = 0
    private var killed = false
    private var anchorMs: Int?
    private var wallAtAnchorMs: Int?
    private(set) var lastFailure: FailureRecord?
    private var capturedSignatures = Set<String>()
    private var seenSignatures = Set<String>()
    private var capsulesWritten = 0
    private(set) var store: CapsuleStore?
    private var transport: BugCapsuleTransport?
    private(set) var outbox: UploadOutbox?
    private(set) var remote: RemoteConfigController?
    private var frameworks: [String] = []
    private var platform = PlatformInfo(os: "ios", osVersion: "", locale: Locale.current.identifier, screenWidth: 0, screenHeight: 0, pixelRatio: 1)
    private var checkpointTimer: DispatchSourceTimer?
    private var disposed = false
    private var warned = Set<String>()
    private var observers: [NSObjectProtocol] = []
    private var anchorWaiters: [@MainActor () -> Void] = []
    private var _monitoring: Monitoring?
    private var lastFailureEventId: String?

    init(config: BugCapsuleConfig, integrations: [BugCapsuleIntegration], overrides: BugCapsuleTestOverrides?) {
        self.config = config
        self.integrations = integrations
        self.overrides = overrides
        mode = config.resolvedMode
        gitSha = config.resolvedGitSha
        gitDirty = config.resolvedGitDirty
        _random = BugCapsuleRandom(seed: seed)
        if let r = overrides?.random { samplingRandom = r } else { samplingRandom = { Double.random(in: 0..<1) } }
    }

    // MARK: public surface for integrations

    public var isRecording: Bool { lock.locked { recording } }
    public var isReplaying: Bool { lock.locked { _engine != nil } }
    public var replay: ReplayContext? { lock.locked { _engine } }
    var engine: ReplayEngine? { lock.locked { _engine } }
    public var redactor: Redactor { lock.locked { _redactor } }
    public var captureNetworkBodies: Bool { lock.locked { captureBodies } }
    public var maxBodyBytes: Int { config.maxBodyBytes }
    public var random: BugCapsuleRandom { lock.locked { _random } }
    var monitoring: Monitoring? { lock.locked { _monitoring } }

    /// True while events are wanted: recording a capsule window, or feeding
    /// monitoring breadcrumbs (never in replay). Integrations check this
    /// before building event data.
    public var isObserving: Bool {
        lock.locked { _engine == nil && (recording || (_monitoring?.wantsBreadcrumbs ?? false)) }
    }

    /// Milliseconds on the session clock (same clock as recorder event `t`).
    public func now() -> Int { Int(((uptime() - startUptime) * 1000).rounded(.down)) }

    /// Wall clock: real time when capturing, the virtual replay clock in replay.
    public func wallClock() -> Date { engine?.virtualNow() ?? Date() }

    func warnOnce(_ message: String) {
        let first = lock.locked { warned.insert(message).inserted }
        if first { BugCapsuleLog.warn(message) }
    }

    func noteFramework(_ name: String) {
        lock.locked { if !frameworks.contains(name) { frameworks.append(name) } }
    }

    /// Records an event (no-op when not observing). Data passes through the
    /// redactor and the app's `beforeRecord` hook first; it goes to the
    /// flight recorder and becomes a monitoring breadcrumb.
    public func record(_ type: String, _ data: JSONObject = JSONObject()) {
        let t = now()
        let (active, redactor, bodies, monitoring) = lock.locked {
            (recording && recorder != nil, _redactor, captureBodies, _engine == nil ? _monitoring : nil)
        }
        let observe = type != EventTypes.pointer && (monitoring?.wantsBreadcrumbs ?? false)
        guard active || observe else { return }
        guard let clean = sanitize(type, data, redactor: redactor, captureBodies: bodies && active) else { return }
        if active { lock.locked { if recording { recorder?.add(t: t, type: type, data: clean) } } }
        if observe { monitoring?.recorded(type, clean) }
    }

    /// Defense in depth: whatever an integration records goes through the
    /// redactor again (idempotent), then `beforeRecord`.
    func sanitize(_ type: String, _ data: JSONObject, redactor: Redactor, captureBodies: Bool, hook: Bool = true) -> JSONObject? {
        var out = data
        if type == EventTypes.http && !captureBodies { out = Self.withoutBodies(out) }
        if type != EventTypes.pointer && type != EventTypes.lifecycle {
            guard let redacted = redactor.redactJSON(.object(out)).objectValue else { return nil }
            out = redacted
            if type == EventTypes.http {
                // Derived from already-redacted input: must stay identical.
                if let key = data["key"] { out["key"] = key }
                if out["bodyEncoding"] == .string("base64") { out["responseBody"] = data["responseBody"] }
                if out["requestEncoding"] == .string("base64") { out["requestBody"] = data["requestBody"] }
            }
            if type == EventTypes.failure, case .string? = data["signature"] { out["signature"] = data["signature"] }
        }
        guard hook, let before = config.beforeRecord else { return out }
        do {
            return try before(type, out)
        } catch {
            warnOnce("dropping a \(type) event: beforeRecord threw (\(error))")
            return nil
        }
    }

    static func withoutBodies(_ data: JSONObject) -> JSONObject {
        var d = data
        d["requestBody"] = .null
        d["responseBody"] = .null
        d["bodyEncoding"] = "omitted"
        if let enc = d["requestEncoding"], !enc.isNull, enc != .string("json") { d["requestEncoding"] = "omitted" }
        return d
    }

    @discardableResult
    public func reportError(_ error: Error) -> String? { reportError(error, options: nil) }

    @discardableResult
    func reportError(_ error: Error, options: CaptureOptions?) -> String? {
        if config.ignoreError?(error) == true { return nil }
        let f = FailureRecord.exception(
            type: String(describing: type(of: error)), message: String(describing: error),
            stack: Thread.callStackSymbols.joined(separator: "\n"), t: now(), scrub: redactor.scrubText)
        return handleFailure(f, error: error, options: options)
    }

    @discardableResult
    func reportException(_ exception: NSException, options: CaptureOptions? = nil) -> String? {
        let f = Self.failure(for: exception, t: now(), redactor: redactor)
        return handleFailure(f, exception: exception, options: options)
    }

    static func failure(for exception: NSException, t: Int, redactor: Redactor) -> FailureRecord {
        FailureRecord.exception(
            type: exception.name.rawValue, message: exception.reason ?? "",
            stack: exception.callStackSymbols.joined(separator: "\n"), t: t, scrub: redactor.scrubText)
    }

    // MARK: startup

    @MainActor
    func start() {
        BugCapsuleSession.current = self
        captureEnvironment()
        if let url = ReplayGate.replayURL(configURL: config.replayURL) {
            BugCapsuleLog.info("replay mode: \(url)")
            startReplay(url)
            return
        }
        do {
            try prepareCapture()
        } catch {
            BugCapsuleLog.warn("capture setup failed; the app runs without capture: \(error)")
            lock.locked { stopRecordingLocked() }
        }
        installObservers()
        afterAppStarted()
    }

    @MainActor
    private func captureEnvironment() {
        #if canImport(UIKit)
            noteFramework("uikit")
            let version = UIDevice.current.systemVersion
            lock.locked {
                platform.osVersion = version
            }
            updateScreen()
        #else
            let v = ProcessInfo.processInfo.operatingSystemVersion
            lock.locked { platform.osVersion = "\(v.majorVersion).\(v.minorVersion)" }
        #endif
    }

    @MainActor
    func updateScreen() {
        #if canImport(UIKit)
            let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first { $0.isKeyWindow }
                ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first
            let size = window?.bounds.size ?? UIScreen.main.bounds.size
            let scale = window?.screen.scale ?? UIScreen.main.scale
            lock.locked {
                platform.screenWidth = Double(size.width)
                platform.screenHeight = Double(size.height)
                platform.pixelRatio = Double(scale)
            }
        #endif
    }

    var screenSize: (Double, Double) { lock.locked { (platform.screenWidth, platform.screenHeight) } }

    private func baseRedactor(remote: [String] = []) -> Redactor {
        Redactor(extraKeys: config.redactKeys + remote, extraHeaders: config.redactHeaders, patterns: config.redactPatterns)
    }

    @MainActor
    private func prepareCapture() throws {
        lock.locked { _redactor = baseRedactor() }
        guard config.enabled else { return }
        let transport = overrides?.transport ?? config.backend.map { BugCapsuleBackendClient(config: $0) }
        let store = try CapsuleStore(root: overrides?.storageDirectory ?? CapsuleStore.defaultRoot())
        var cached: RemoteCaptureConfig?
        var outbox: UploadOutbox?
        var remote: RemoteConfigController?
        if let transport {
            let scope = RemoteConfigController.scope(for: config.backend)
            cached = store.configCache.read(scope: scope)
            let box = UploadOutbox(directory: store.outboxDirectory, limits: config.outboxLimits)
            outbox = box
            Task { await box.open() }
            remote = RemoteConfigController(
                fetch: { await transport.fetchConfig() }, cache: store.configCache, scope: scope,
                onChange: { [weak self] previous, next in self?.applyRemote(previous, next) },
                maxStale: config.maxStaleConfig, initial: cached)
        }
        lock.locked {
            self.store = store
            self.transport = transport
            self.outbox = outbox
            self.remote = remote
            _redactor = baseRedactor(remote: cached?.redactKeys ?? [])
            captureBodies = config.captureNetworkBodies && (cached?.captureNetworkBodies ?? true)
            maxCapsuleBytes = cached?.maxCapsuleBytes ?? maxCapsuleBytes
            recording = decideRecording(cached)
        }
        if config.monitoring.enabled {
            let m = Monitoring(
                session: self, options: config.monitoring, root: store.root, remote: cached, random: samplingRandom)
            lock.locked { _monitoring = m }
            m.start(outboxDirectory: transport == nil ? nil : store.root.appendingPathComponent("envelopes", isDirectory: true))
        }
        for integration in integrations { integration.setUp(self) }
        if isRecording {
            let launch = Checkpoint(kind: .launch, t: now(), wallClockMs: epochMs(), afterSeq: 0, data: snapshot(.launch))
            lock.locked {
                recorder = FlightRecorder(
                    launch: launch, maxEvents: config.maxEvents, windowMs: Int(config.window * 1000))
            }
            installCapture()
        }
    }

    private func afterAppStarted() {
        guard let remote = lock.locked({ remote }) else { return }
        Task { [weak self] in
            await remote.refresh()
            _ = await self?.flushOutbox()
            await self?.monitoring?.flushPending()
        }
    }

    private func effectiveRate(_ remote: RemoteCaptureConfig?) -> Double {
        let cap = min(max(config.productionSampleRate, 0), 1)
        return min(remote?.sampleRate ?? 1, cap)
    }

    /// Startup decision: a cached kill switch applies however old it is;
    /// production sessions are sampled at min(app cap, remote rate).
    private func decideRecording(_ remote: RemoteCaptureConfig?) -> Bool {
        if !config.enabled { return false }
        if let remote, !remote.enabled { return false }
        if mode != .production { return true }
        sessionRate = effectiveRate(remote)
        return samplingRandom() < sessionRate
    }

    @MainActor
    private func installCapture() {
        CrashHandler.install()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = max(config.checkpointInterval, 1)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.periodicCheckpoint() }
        }
        timer.resume()
        lock.locked { checkpointTimer = timer }
    }

    @MainActor
    func snapshot(_ kind: CheckpointKind) -> JSONObject {
        var data = JSONObject()
        let redactor = self.redactor
        for integration in integrations {
            guard let value = integration.snapshot(kind) else { continue }
            var clean: JSONValue? = redactor.redactJSON(value)
            if let hook = config.beforeCheckpoint, let c = clean {
                do { clean = try hook(integration.name, c) } catch {
                    warnOnce("\(integration.name) snapshot dropped: beforeCheckpoint threw (\(error))")
                    clean = nil
                }
            }
            if let clean { data[integration.name] = clean }
        }
        return data
    }

    @MainActor
    func periodicCheckpoint() {
        let state: (FlightRecorder, Int, Int, Int)? = lock.locked {
            guard recording, let recorder else { return nil }
            return (recorder, captureEpoch, now(), recorder.lastSeq)
        }
        guard let (recorder, epoch, t, afterSeq) = state else { return }
        let data = snapshot(.periodic)
        lock.locked {
            guard epoch == captureEpoch, recorder === self.recorder else { return }
            recorder.addCheckpoint(Checkpoint(kind: .periodic, t: t, wallClockMs: epochMs(), afterSeq: afterSeq, data: data))
        }
    }

    // MARK: lifecycle and anchor

    @MainActor
    private func installObservers() {
        #if canImport(UIKit)
            let nc = NotificationCenter.default
            func observe(_ name: Notification.Name, _ body: @escaping @MainActor (BugCapsuleSession) -> Void) {
                let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    guard let self else { return }
                    MainActor.assumeIsolated { body(self) }
                }
                lock.locked { observers.append(token) }
            }
            observe(UIWindow.didBecomeVisibleNotification) { s in s.markAnchor() }
            observe(UIApplication.didBecomeActiveNotification) { s in
                s.markAnchor()
                s.onLifecycle("resumed")
            }
            observe(UIApplication.willResignActiveNotification) { s in s.onLifecycle("inactive") }
            observe(UIApplication.didEnterBackgroundNotification) { s in s.onLifecycle("paused") }
            observe(UIApplication.willTerminateNotification) { s in s.onLifecycle("detached") }
        #endif
    }

    @MainActor
    func markAnchor() {
        updateScreen()
        let waiters: [@MainActor () -> Void] = lock.locked {
            guard anchorMs == nil else { return [] }
            anchorMs = now()
            wallAtAnchorMs = epochMs()
            let w = anchorWaiters
            anchorWaiters = []
            return w
        }
        for w in waiters { w() }
    }

    @MainActor
    private func onLifecycle(_ state: String) {
        // Synthetic lifecycle posted by the replay engine must not be recorded or re-dispatched.
        if isReplaying { return }
        record(EventTypes.lifecycle, ["state": .string(state)])
        monitoring?.onLifecycle(state)
        guard let remote = lock.locked({ remote }) else { return }
        if state == "resumed" {
            Task { [weak self] in
                await remote.onResumed()
                _ = await self?.flushOutbox()
                await self?.monitoring?.flushPending()
            }
        } else if state == "paused" {
            Task { await remote.onPaused() }
        }
    }

    // MARK: failures and capsules

    /// A failure: recorded, sent as an error event (monitoring) and, when
    /// recording, captured as a capsule linked to that event. Returns the
    /// event id.
    @discardableResult
    func handleFailure(
        _ failure: FailureRecord, error: Error? = nil, exception: NSException? = nil, options: CaptureOptions? = nil
    ) -> String? {
        if let engine {
            engine.onFailure(failure)
            return nil
        }
        var dropStack = failure.json.objectValue!
        dropStack["stack"] = nil
        record(EventTypes.failure, dropStack)
        let shouldCapture: Bool = lock.locked {
            guard recording else { return false }
            lastFailure = failure
            guard seenSignatures.insert(failure.signature).inserted else { return false }
            // Counted when scheduled, so a burst of failures cannot exceed the limit.
            guard config.autoCaptureOnFailure, capsulesWritten < config.maxCapsulesPerSession,
                capturedSignatures.count < config.maxCapsulesPerSession
            else { return false }
            return capturedSignatures.insert(failure.signature).inserted
        }
        // The capsule id is fixed now so the event can point at it.
        let capsuleId = shouldCapture ? uuidV4() : nil
        var link: CapsuleMonitoringLink?
        var eventId: String?
        if let m = monitoring {
            let draft =
                exception.map { m.exceptionDraft($0, handled: true, level: .error, options: options) }
                ?? m.failureDraft(failure, error: error, options: options)
            eventId = m.capture(draft, capsuleId: capsuleId)
            if let eventId {
                link = CapsuleMonitoringLink(
                    eventId: eventId, traceId: m.tracer.activeSpan?.traceId, release: m.release,
                    environment: m.environment)
                lock.locked { if lastFailure == failure { lastFailureEventId = eventId } }
            }
        }
        guard shouldCapture else { return eventId }
        let monitoringLink = link
        // Let the failure settle (follow-up events) before writing.
        let delay = overrides?.captureSettleDelay ?? 0.3
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            Task {
                if let r = await self.writeCapsule(failure: failure, capsuleId: capsuleId, monitoring: monitoringLink) {
                    BugCapsuleLog.info(
                        "captured \(r.capsuleId) (\(r.eligibility.status.rawValue)) → \(r.file.path) upload: \(r.upload?.status.rawValue ?? "none")")
                }
            }
        }
        return eventId
    }

    /// `manifest.monitoring` for a manual capture: the last failure's event.
    var lastFailureLink: CapsuleMonitoringLink? {
        guard let m = monitoring, let id = lock.locked({ lastFailureEventId }) else { return nil }
        return CapsuleMonitoringLink(eventId: id, traceId: m.tracer.activeSpan?.traceId, release: m.release, environment: m.environment)
    }

    struct BuiltCapsule {
        let capsule: Capsule
        let bytes: Data
        let file: URL
        let problem: String?
    }

    /// Builds, validates, encodes and saves a capsule synchronously. Used by
    /// `writeCapsule` and by the uncaught-exception handler.
    func buildCapsule(
        failure: FailureRecord?, labels: [String: String], crash: Bool = false, capsuleId: String? = nil,
        monitoring link: CapsuleMonitoringLink? = nil
    ) -> BuiltCapsule? {
        let snapshot: (RecordedWindow, Int, Int, Redactor, PlatformInfo, [String], Int, CapsuleStore)? = lock.locked {
            guard recording, let recorder, let store else { return nil }
            capsulesWritten += 1
            let window = recorder.window()
            let anchor = anchorMs ?? now()
            let wallAtAnchor = wallAtAnchorMs ?? (window.checkpoint.wallClockMs + anchor - window.checkpoint.t)
            return (window, anchor, wallAtAnchor, _redactor, platform, frameworks, recorder.rewriteDropped, store)
        }
        guard let (window, anchor, wallAtAnchor, redactor, platform, frameworks, rewriteDropped, store) = snapshot else {
            return nil
        }
        var windowEvents = window.events
        var nextSeq = max(windowEvents.last?.seq ?? 0, window.checkpoint.afterSeq)
        let pendingT = now()
        for data in BugCapsuleURLSession.active?.pendingExchanges() ?? [] {
            guard let clean = sanitize(EventTypes.http, data, redactor: redactor, captureBodies: false, hook: false) else { continue }
            nextSeq += 1
            windowEvents.append(BugCapsuleEvent(seq: nextSeq, t: pendingT, type: EventTypes.http, data: clean))
        }
        let eligibility = EligibilityBuilder()
        if gitSha == nil {
            eligibility.missing("build.gitSha", "BUGCAPSULE_GIT_SHA was not set at build time")
        } else if gitDirty == true {
            eligibility.missing("build.gitSha", "built from a tree with uncommitted changes")
        }
        if failure == nil {
            eligibility.missing("failure.assertion", "manual capture without a failure assertion", blocking: true)
        }
        if rewriteDropped > 0 {
            eligibility.missing(
                "events.redaction", "\(rewriteDropped) buffered events were dropped when redaction rules changed")
        }
        if window.hasGap {
            eligibility.missing(
                "events.window", "events between the checkpoint and the window were evicted; raise window or maxEvents")
        }
        if crash {
            eligibility.missing(
                "crash.persisted", "written by the uncaught-exception handler: events after the crash point are absent")
        }
        let pointers = windowEvents.filter { $0.type == EventTypes.pointer }.count
        let actions = windowEvents.filter { $0.type == EventTypes.action }.count
        if pointers > 0 && actions == 0 {
            eligibility.missing(
                "capability.input.pointer.replay",
                "only pointer input was recorded (\(pointers) events); iOS replays semantic actions, not touches")
        }
        for integration in integrations {
            integration.describeEligibility(eligibility, window: window)
        }
        var capabilities: [(String, String)] = [
            ("input.pointer.capture", "explicit"),
            ("input.pointer.replay", "unsupported"),
            ("input.semantic.replay", "supported"),
            ("text.replay", "supported"),
            ("lifecycle.replay", "partial"),
            ("clock.virtual", "explicit"),
            ("random.seeded", "explicit"),
            ("crash.uncaught", "partial"),
        ]
        for i in integrations { capabilities.append(contentsOf: i.capabilities) }
        let events = windowEvents.map { $0.shifted(anchor) }
        var labelPairs: [(String, String)] = []
        var merged = config.labels
        for (k, v) in labels { merged[k] = v }
        for k in merged.keys.sorted().prefix(100) {
            let v = merged[k]!
            labelPairs.append((k.dartPrefix(100), redactor.isSensitiveKey(k) ? Redactor.placeholder : redactor.scrubText(v).dartPrefix(2000)))
        }
        let capsule = Capsule(
            manifest: CapsuleManifest(
                capsuleId: capsuleId ?? uuidV4(), createdAt: Date(), mode: mode,
                app: AppInfo(
                    id: config.appId?.dartPrefix(200), name: config.appName?.dartPrefix(200),
                    version: config.appVersion.dartPrefix(200), build: config.appBuild.dartPrefix(200),
                    flavor: config.flavor?.dartPrefix(200)),
                gitSha: gitSha, dirty: gitDirty, sdkName: sdkName, sdkVersion: sdkVersion,
                stateSchemaVersion: config.stateSchemaVersion, platform: platform,
                session: SessionInfo(
                    id: sessionId, startedAt: startedAt, wallClockAtAnchorMs: wallAtAnchor, seed: seed,
                    durationMs: now() - anchor),
                failure: failure?.shifted(anchor), eligibility: eligibility.build(),
                integrations: integrations.map(\.name), eventCount: events.count,
                droppedEvents: window.droppedEvents, checkpointKind: window.checkpoint.kind, labels: labelPairs,
                redactionKeys: redactor.extraKeys, redactionHeaders: redactor.extraHeaders,
                runtime: RuntimeInfo(name: "ios", version: platform.osVersion, language: "swift", frameworks: frameworks),
                capabilities: capabilities, monitoring: link),
            checkpoint: window.checkpoint.shifted(anchor),
            events: events)
        let problem = validateCapsuleDocument(CapsuleCodec.toJSON(capsule))
        do {
            let bytes = try CapsuleCodec.encode(capsule)
            if lock.locked({ killed }) { return nil }
            let file = try store.save(capsuleId: capsule.manifest.capsuleId, bytes: bytes)
            if lock.locked({ killed }) {
                store.clearSavedCaptures()
                return nil
            }
            return BuiltCapsule(capsule: capsule, bytes: bytes, file: file, problem: problem)
        } catch {
            // Disk full or another I/O error: the capsule is dropped.
            BugCapsuleLog.warn("could not save capsule: \(error)")
            return nil
        }
    }

    /// Writes a capsule now and queues it for upload.
    func writeCapsule(
        failure: FailureRecord?, labels: [String: String] = [:], capsuleId: String? = nil,
        monitoring link: CapsuleMonitoringLink? = nil
    ) async -> CaptureResult? {
        let built: BuiltCapsule? = await withCheckedContinuation { cont in
            queue.async {
                cont.resume(
                    returning: self.buildCapsule(failure: failure, labels: labels, capsuleId: capsuleId, monitoring: link))
            }
        }
        guard let built else { return nil }
        let id = built.capsule.manifest.capsuleId
        var upload: UploadResult?
        let (outbox, maxBytes) = lock.locked { (self.outbox, maxCapsuleBytes) }
        if let problem = built.problem {
            BugCapsuleLog.warn("capsule \(id) failed validation, not uploaded: \(problem)")
            if outbox != nil { upload = UploadResult(.rejected, message: "invalid capsule: \(problem)") }
        } else if let outbox {
            if built.bytes.count > maxBytes {
                upload = UploadResult(.rejected, message: "capsule is \(built.bytes.count) bytes, limit \(maxBytes)")
            } else if !(await outbox.enqueue(capsuleId: id, bytes: built.bytes)) {
                upload = UploadResult(.rejected, message: "not queued (outbox limit or disk error)")
            } else if lock.locked({ killed }) {
                await outbox.purge()
                return nil
            } else {
                upload = await flushOutbox(onlyId: id)
            }
        }
        return CaptureResult(
            capsuleId: id, file: built.file, eligibility: built.capsule.manifest.eligibility,
            failureSignature: failure?.signature, upload: upload)
    }

    /// Uncaught NSException: written synchronously to the outbox (uploaded
    /// on the next launch). Best effort: the process is about to terminate.
    func handleUncaughtException(_ exception: NSException) {
        let failure = Self.failure(for: exception, t: now(), redactor: redactor)
        if let engine {
            engine.onFailure(failure)
            engine.finishSynchronously(reason: "uncaught exception \(exception.name.rawValue)")
            return
        }
        var data = failure.json.objectValue!
        data["stack"] = nil
        record(EventTypes.failure, data)
        let ok: Bool = lock.locked {
            guard recording, capsulesWritten < config.maxCapsulesPerSession,
                capturedSignatures.count < config.maxCapsulesPerSession,
                !capturedSignatures.contains(failure.signature)
            else { return false }
            capturedSignatures.insert(failure.signature)
            return true
        }
        let capsuleId = ok ? uuidV4() : nil
        var link: CapsuleMonitoringLink?
        if let m = monitoring, let eventId = m.captureUncaughtException(exception, capsuleId: capsuleId) {
            link = CapsuleMonitoringLink(
                eventId: eventId, traceId: m.tracer.activeSpan?.traceId, release: m.release, environment: m.environment)
        }
        guard ok,
            let built = buildCapsule(failure: failure, labels: [:], crash: true, capsuleId: capsuleId, monitoring: link),
            built.problem == nil
        else { return }
        let (outbox, maxBytes) = lock.locked { (outbox, maxCapsuleBytes) }
        if let outbox, built.bytes.count <= maxBytes, built.bytes.count <= config.outboxLimits.maxBytes {
            UploadOutbox.writeSynchronously(directory: outbox.directory, capsuleId: built.capsule.manifest.capsuleId, bytes: built.bytes)
        }
        BugCapsuleLog.info("captured \(built.capsule.manifest.capsuleId) from an uncaught exception (uploads next launch)")
    }

    var uploadsAllowed: Bool {
        get async {
            guard !lock.locked({ disposed }), let remote = lock.locked({ remote }) else { return false }
            return await remote.uploadsAllowed
        }
    }

    /// Uploads pending capsules; refreshes the remote config first when it
    /// is older than its TTL, so a new kill switch is seen before sending.
    @discardableResult
    func flushOutbox(onlyId: String? = nil) async -> UploadResult? {
        let (outbox, transport, remote, disposed) = lock.locked { (self.outbox, self.transport, self.remote, self.disposed) }
        guard let outbox, let transport, let remote, !disposed else { return nil }
        await remote.ensureFresh()
        if !(await uploadsAllowed) {
            return onlyId == nil ? nil : UploadResult(.retryLater, message: "waiting for remote config")
        }
        return await outbox.flush(
            upload: { bytes in
                let result = await transport.upload(bytes)
                if result.message == "capture_disabled" { Task { await remote.refresh() } }
                return result
            },
            allowed: { [weak self] in await self?.uploadsAllowed ?? false },
            onlyId: onlyId)
    }

    /// Sends queued monitoring envelopes (same rules as capsule uploads:
    /// a fresh, enabled remote config; `monitoringEnabled` must be true).
    func flushEnvelopes() async {
        let (m, transport, remote, disposed) = lock.locked { (_monitoring, self.transport, self.remote, self.disposed) }
        guard let m, let outbox = m.outbox, let transport, let remote, !disposed else { return }
        await remote.ensureFresh()
        guard await envelopesAllowed else { return }
        _ = await outbox.flush(
            upload: { stored in
                guard let (body, gzipped) = Monitoring.prepareForSending(stored) else {
                    return UploadResult(.rejected, message: "unreadable envelope")
                }
                let result = await transport.sendEnvelope(body, gzipped: gzipped)
                if result.message == "capture_disabled" { Task { await remote.refresh() } }
                return result
            },
            allowed: { [weak self] in await self?.envelopesAllowed ?? false })
    }

    var envelopesAllowed: Bool {
        get async {
            guard let m = monitoring, m.isActive else { return false }
            return await uploadsAllowed
        }
    }

    // MARK: remote config

    /// Applies a freshly fetched config (kill switch, sampling, bodies,
    /// redaction, capsule size, monitoring fields) to the running session.
    func applyRemote(_ previous: RemoteCaptureConfig?, _ next: RemoteCaptureConfig) {
        monitoring?.applyRemote(next)
        lock.lock()
        defer { lock.unlock() }
        maxCapsuleBytes = next.maxCapsuleBytes
        if !next.enabled {
            disableCaptureLocked()
            return
        }
        if mode == .production && recording {
            let rate = effectiveRate(next)
            if rate < sessionRate {
                let keep = sessionRate <= 0 ? 0 : rate / sessionRate
                sessionRate = rate
                if samplingRandom() >= keep {
                    BugCapsuleLog.info("sample rate lowered to \(rate); this session stops recording")
                    stopRecordingLocked()
                }
            }
        }
        let bodies = config.captureNetworkBodies && next.captureNetworkBodies
        if captureBodies && !bodies {
            recorder?.rewrite(event: { e in
                e.type == EventTypes.http ? BugCapsuleEvent(seq: e.seq, t: e.t, type: e.type, data: Self.withoutBodies(e.data)) : e
            })
        }
        captureBodies = bodies
        let wanted = Redactor(extraKeys: config.redactKeys + next.redactKeys).extraKeys
        if _redactor.extraKeys != wanted {
            _redactor = baseRedactor(remote: next.redactKeys)
            let redactor = _redactor
            // Request keys were computed with the old rules: buffered
            // exchanges are dropped (the capsule reports it), the rest is
            // redacted again.
            recorder?.rewrite(
                event: { e in
                    if e.type == EventTypes.http { return nil }
                    guard let d = self.sanitize(e.type, e.data, redactor: redactor, captureBodies: bodies, hook: false) else {
                        return nil
                    }
                    return BugCapsuleEvent(seq: e.seq, t: e.t, type: e.type, data: d)
                },
                checkpoint: { c in
                    Checkpoint(
                        kind: c.kind, t: c.t, wallClockMs: c.wallClockMs, afterSeq: c.afterSeq,
                        data: redactor.redactJSON(.object(c.data)).objectValue ?? JSONObject())
                })
        }
    }

    private func stopRecordingLocked() {
        captureEpoch += 1
        recording = false
        recorder = nil
        checkpointTimer?.cancel()
        checkpointTimer = nil
    }

    /// Kill switch: stop recording, drop the buffer, delete queued and saved captures.
    private func disableCaptureLocked() {
        let was = recording
        killed = true
        stopRecordingLocked()
        if was { BugCapsuleLog.info("capture disabled by remote config") }
        if let outbox { Task { await outbox.purge() } }
        if let store { queue.async { store.clearSavedCaptures() } }
    }

    // MARK: replay

    @MainActor
    private func startReplay(_ url: String) {
        let channel = ReplayChannel(baseURL: url)
        let capsule: Capsule
        let settings: ReplaySettings
        do {
            (capsule, settings) = try channel.fetchSync()
        } catch {
            let report = ReplayReport(
                outcome: error is CapsuleFormatError ? .incompatible : .error, attempt: 1, durationMs: 0, strategy: .auto,
                message: "could not load capsule: \(error)", runtime: "ios")
            channel.deliver(report, attemptId: nil)
            return
        }
        guard let replay = setUpReplay(capsule: capsule, settings: settings, channel: channel) else { return }
        // Inputs start at the anchor (first visible window / first activation).
        installReplayAnchor { replay.start() }
    }

    /// Replay without the CLI channel (tests): restores and returns the engine; call `run()`.
    @MainActor
    func startReplayForTesting(capsule: Capsule, settings: ReplaySettings) -> ReplayEngine? {
        BugCapsuleSession.current = self
        return setUpReplay(capsule: capsule, settings: settings, channel: nil)
    }

    @MainActor
    private func setUpReplay(capsule: Capsule, settings: ReplaySettings, channel: ReplayChannel?) -> ReplayEngine? {
        let replay = ReplayEngine(capsule: capsule, settings: settings, buildGitSha: gitSha, channel: channel, session: self)
        lock.locked {
            _engine = replay
            _random = BugCapsuleRandom(seed: capsule.manifest.session.seed)
            // The capture's redaction rules, so request keys of redacted bodies match.
            _redactor = Redactor(
                extraKeys: config.redactKeys + capsule.manifest.redactionKeys,
                extraHeaders: config.redactHeaders + capsule.manifest.redactionHeaders, patterns: config.redactPatterns)
        }
        if capsule.manifest.stateSchemaVersion != config.stateSchemaVersion && capsule.checkpoint.kind == .periodic {
            replay.finishIncompatible(
                "state schema v\(capsule.manifest.stateSchemaVersion) captured, app is v\(config.stateSchemaVersion); "
                    + "register a migration or mark the capsule stale")
            lock.locked { _engine = nil }
            return nil
        }
        replay.precheck()
        CrashHandler.install()
        let names = Set(integrations.map(\.name))
        for name in capsule.manifest.integrations where !names.contains(name) {
            replay.diverge("integration.missing", "\(name) was used when capturing but is not set up")
        }
        for integration in integrations { integration.setUp(self) }
        for name in capsule.checkpoint.data.keys where !names.contains(name) {
            replay.diverge("restore.missingIntegration", name)
        }
        for integration in integrations {
            do {
                try integration.restore(capsule.checkpoint.data[integration.name], session: self)
            } catch {
                replay.diverge("restore.\(integration.name)", "\(error)")
            }
        }
        return replay
    }

    @MainActor
    private func installReplayAnchor(_ begin: @escaping @MainActor () -> Void) {
        var started = false
        let once: @MainActor () -> Void = {
            if started { return }
            started = true
            begin()
        }
        lock.locked { anchorWaiters.append(once) }
        #if canImport(UIKit)
            let nc = NotificationCenter.default
            for name in [UIWindow.didBecomeVisibleNotification, UIApplication.didBecomeActiveNotification] {
                let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.markAnchor() }
                }
                lock.locked { observers.append(token) }
            }
            // Started after the first window appeared: begin on the next turn.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                MainActor.assumeIsolated { self?.markAnchor() }
            }
        #else
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.markAnchor() } }
        #endif
    }

    // MARK: teardown (tests)

    func dispose() async {
        let (remote, outbox, monitoring) = lock.locked { () -> (RemoteConfigController?, UploadOutbox?, Monitoring?) in
            disposed = true
            stopRecordingLocked()
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers = []
            return (self.remote, self.outbox, _monitoring)
        }
        monitoring?.stop()
        await remote?.dispose()
        await outbox?.close()
        await monitoring?.outbox?.close()
        if BugCapsuleSession.current === self { BugCapsuleSession.current = nil }
    }

    // Test helpers
    var recorderForTesting: FlightRecorder? { lock.locked { recorder } }
    func setAnchorForTesting(_ ms: Int) { lock.locked { anchorMs = ms; wallAtAnchorMs = epochMs() } }
}

extension NSLocking {
    @inline(__always)
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
