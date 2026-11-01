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
let sdkVersion = "0.4.1-beta.5"

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

    /// The configuration in effect: a usable `token` is resolved into `backend`.
    public let config: BugCapsuleConfig
    /// How the backend was configured (nil: neither token nor backend).
    public let connectionSource: BugCapsuleConnectionSource?
    /// Why `config.token` could not be used.
    public let tokenError: BugCapsuleTokenError?
    let integrations: [BugCapsuleIntegration]
    let overrides: BugCapsuleTestOverrides?
    public let mode: CaptureMode
    let gitSha: String?
    let gitDirty: Bool?

    let lock = NSRecursiveLock()
    let queue = DispatchQueue(label: "com.bugcapsule.session", qos: .utility)
    private let startUptime = uptime()
    let sessionId = uuidV4()
    let startedAt = Date()
    let seed = BugCapsuleRandom.newSeed()
    private var _random: BugCapsuleRandom
    private let samplingRandom: @Sendable () -> Double

    private var recorder: FlightRecorder?
    private var _engine: ReplayEngine?
    private let patchLock = NSLock()
    private var _patch: PatchIdentity?
    private var _patchRead = false
    private var _redactor = Redactor()
    private var recording = false
    private var captureBodies = true
    private(set) var maxCapsuleBytes = 5 * 1024 * 1024
    private var sessionRate = 1.0
    private var captureEpoch = 0
    private(set) var killed = false
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
    /// This process's crash journal (crash-capsules §1), while recording.
    private var journal: CrashJournal?
    private var journalEvicted = false
    /// Every process's journal under `journal/`.
    private(set) var crashJournals: CrashJournals?
    // Connection status (`BugCapsule.status`), mirrored from the remote config
    // controller and the transport so it can be read synchronously.
    private var configFetchedAt: Date?
    private var lastConfigFailure: ConfigFetchFailure?
    private var credentialRejected = false
    private(set) var remoteDisabled = false
    private var firstEventAcceptedAt: Date?
    private var firstCapsuleAcceptedAt: Date?
    /// Interaction dependencies (capsule-v2): installed adapters, capture
    /// bookkeeping and, in replay, the scheduler.
    let interactions: InteractionRuntime

    init(config input: BugCapsuleConfig, integrations: [BugCapsuleIntegration], overrides: BugCapsuleTestOverrides?) {
        let (config, source, tokenError) = Self.resolveConnection(input)
        self.config = config
        connectionSource = source
        self.tokenError = tokenError
        self.integrations = integrations
        self.overrides = overrides
        mode = config.resolvedMode
        gitSha = config.resolvedGitSha
        gitDirty = config.resolvedGitDirty
        _random = BugCapsuleRandom(seed: seed)
        if let r = overrides?.random { samplingRandom = r } else { samplingRandom = { Double.random(in: 0..<1) } }
        let box = WeakSession()
        interactions = InteractionRuntime(
            limits: InteractionLimits(windowMs: Int(config.window * 1000)),
            record: { type, data in box.value?.record(type, data) }, now: { box.value?.now() ?? 0 },
            redactor: { box.value?.redactor ?? Redactor() }, recording: { box.value?.isRecording ?? false })
        box.value = self
    }

    private final class WeakSession: @unchecked Sendable {
        weak var value: BugCapsuleSession?
    }

    /// Turns `token` into `backend` (connection token v1). An explicit
    /// `backend` wins; a token that cannot be used leaves no backend, so the
    /// app runs without one instead of failing. Never throws.
    static func resolveConnection(
        _ input: BugCapsuleConfig
    ) -> (BugCapsuleConfig, BugCapsuleConnectionSource?, BugCapsuleTokenError?) {
        if input.backend != nil {
            if input.token != nil {
                BugCapsuleLog.warn("both token and backend are set; using backend and ignoring token")
            }
            return (input, .backend, nil)
        }
        guard let token = input.token else { return (input, nil, nil) }
        switch BugCapsuleConnectionToken.parse(token) {
        case .success(let backend):
            var config = input
            config.backend = backend
            return (config, .token, nil)
        case .failure(let error):
            BugCapsuleLog.warn(
                "the SDK token can't be used (\(error.code.rawValue)): \(error.message). The app runs without a BugCapsule backend.")
            return (input, .token, error)
        }
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
    public func record(_ type: String, _ data: JSONObject = JSONObject()) { recordEvent(type, data) }

    /// A guard decision (§7.8). False when the capture rules dropped it from a
    /// recording or changed what replay needs: the capsule then misses a
    /// decision.
    func recordDecision(_ data: JSONObject) -> Bool {
        recordEvent(EventTypes.emergencyDecision, data) { EmergencyDecisionTracker.isIntact($0, original: data) }
    }

    /// False when the event was wanted for a capsule but dropped. [accept]
    /// decides on the event as the capture rules left it.
    @discardableResult
    private func recordEvent(_ type: String, _ data: JSONObject, accept: ((JSONObject) -> Bool)? = nil) -> Bool {
        let t = now()
        let (active, redactor, bodies, monitoring) = lock.locked {
            (recording && recorder != nil, _redactor, captureBodies, _engine == nil ? _monitoring : nil)
        }
        let observe = type != EventTypes.pointer && (monitoring?.wantsBreadcrumbs ?? false)
        guard active || observe else { return true }
        guard let clean = sanitize(type, data, redactor: redactor, captureBodies: bodies && active), accept?(clean) ?? true else {
            return !active
        }
        if active {
            lock.locked {
                guard recording, let recorder else { return }
                let event = recorder.add(t: t, type: type, data: clean)
                journal?.append(event)
                if !journalEvicted && recorder.droppedEvents > 0 {
                    journalEvicted = true
                    journal?.recorderEvicted()
                }
            }
        }
        if observe { monitoring?.recorded(type, clean) }
        return true
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
            if type == "screenshot" { out["base64"] = data["base64"] } // Binary pixels are masked by the provider.
            if type == EventTypes.failure, case .string? = data["signature"] { out["signature"] = data["signature"] }
            if InteractionTypes.isInteraction(type) {
                // Match keys and payload objects were built from redacted
                // values by the adapter; mode and replayable must stay true.
                for k in ["key"] + InteractionTypes.payloadFields { if let v = data[k] { out[k] = v } }
                // Body capture off (local or remote) omits interaction
                // payloads too (capsule-v2 §7); sizes are kept.
                if !captureBodies {
                    for k in InteractionTypes.payloadFields {
                        guard case .object(var payload)? = out[k] else { continue }
                        payload["mode"] = .string("omitted")
                        payload["replayable"] = .bool(false)
                        payload["value"] = nil
                        out[k] = .object(payload)
                    }
                }
            }
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
        // Emergency policies initialized before start can now use this connection.
        BugCapsuleEmergency.shared.sessionDidStart()
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
        let base: BugCapsuleTransport? = overrides?.transport ?? config.backend.map { BugCapsuleBackendClient(config: $0) }
        let transport = base.map { base in
            ObservedTransport(
                base,
                onCapsule: { [weak self] in self?.noteAccepted(capsule: true) },
                onEvent: { [weak self] in self?.noteAccepted(capsule: false) })
        }
        let store = try CapsuleStore(root: overrides?.storageDirectory ?? CapsuleStore.defaultRoot())
        // Before monitoring reports what earlier processes left (crash-capsules §2).
        let journals = CrashJournals(root: store.root.appendingPathComponent("journal", isDirectory: true))
        journals.setAsideCurrent()
        lock.locked { crashJournals = journals }
        var cached: RemoteCaptureConfig?
        var outbox: UploadOutbox?
        var remote: RemoteConfigController?
        if let transport {
            let scope = RemoteConfigController.scope(for: config.backend)
            cached = store.configCache.read(scope: scope)
            let box = UploadOutbox(directory: store.outboxDirectory, limits: config.outboxLimits)
            outbox = box
            Task { await box.open() }
            let source = connectionSource
            remote = RemoteConfigController(
                fetch: { [weak self] in
                    let result = await transport.fetchConfig()
                    self?.noteConfigFetch(result)
                    return result
                }, cache: store.configCache, scope: scope,
                onChange: { [weak self] previous, next in self?.applyRemote(previous, next) },
                maxStale: config.maxStaleConfig, initial: cached,
                onRejected: { failure in
                    let what = source == .token ? "SDK token" : "ingest key"
                    BugCapsuleLog.warn(
                        "the backend refused this app's \(what) (\(failure.reason ?? "HTTP \(failure.status ?? 0)"))"
                            + (failure.detail.map { ": \($0)" } ?? "") + ". Capture and uploads are off for this run.")
                })
        }
        lock.locked {
            self.store = store
            self.transport = transport
            self.outbox = outbox
            self.remote = remote
            _redactor = baseRedactor(remote: cached?.redactKeys ?? [])
            remoteDisabled = cached?.enabled == false
            captureBodies = config.captureNetworkBodies && (cached?.captureNetworkBodies ?? true)
            interactions.setDisabledAdapters(Set(cached?.disabledAdapters ?? []))
            interactions.setMaxPayloadBytes(cached?.maxInteractionPayloadBytes)
            maxCapsuleBytes = cached?.maxCapsuleBytes ?? maxCapsuleBytes
            recording = decideRecording(cached)
        }
        if config.monitoring.enabled {
            let m = Monitoring(
                session: self, options: config.monitoring, root: store.root, remote: cached, random: samplingRandom)
            lock.locked { _monitoring = m }
            m.start(outboxDirectory: transport == nil ? nil : store.root.appendingPathComponent("envelopes", isDirectory: true))
        }
        // After the crash capsules monitoring scheduled on the same queue.
        let claimForMetricKit = monitoring?.metricKitActive ?? false
        queue.async { journals.cleanup(claimForMetricKit: claimForMetricKit) }
        for integration in integrations { integration.setUp(self) }
        if isRecording {
            let launch = Checkpoint(kind: .launch, t: now(), wallClockMs: epochMs(), afterSeq: 0, data: snapshot(.launch))
            let header = journalHeader()
            lock.locked {
                recorder = FlightRecorder(
                    launch: launch, maxEvents: config.maxEvents, windowMs: Int(config.window * 1000))
                journal = CrashJournal(
                    directory: journals.currentDirectory, maxBytes: 2 * maxCapsuleBytes, header: header, launch: launch)
            }
            installCapture()
            // Decisions made before recording started.
            BugCapsuleEmergency.shared.writeDecisions(to: self)
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
        if kind == .periodic, let open = interactions.checkpointData() { data["interactions"] = open }
        return data
    }

    @MainActor
    func periodicCheckpoint() {
        let state: (FlightRecorder, Int, Int, Int)? = lock.locked {
            guard recording, let recorder else { return nil }
            journal?.boundary(afterSeq: recorder.lastSeq)
            return (recorder, captureEpoch, now(), recorder.lastSeq)
        }
        guard let (recorder, epoch, t, afterSeq) = state else { return }
        let data = snapshot(.periodic)
        lock.locked {
            guard epoch == captureEpoch, recorder === self.recorder else { return }
            let checkpoint = Checkpoint(kind: .periodic, t: t, wallClockMs: epochMs(), afterSeq: afterSeq, data: data)
            recorder.addCheckpoint(checkpoint)
            journal?.checkpoint(checkpoint)
        }
        BugCapsuleEmergency.shared.writeDecisions(to: self)
        refreshJournalHeader()
    }

    /// `header.json` of the crash journal: the manifest fields known now,
    /// plus where the anchor is on the session clock.
    func journalHeader() -> JSONObject {
        let m = monitoring
        let release = m?.release ?? Monitoring.defaultRelease(config)
        let environment = m?.environment ?? Monitoring.defaultEnvironment(mode)
        let dependencies = interactions.allDependencies()
        return lock.locked {
            let startMs = Int((startedAt.timeIntervalSince1970 * 1000).rounded(.down))
            var labels = JSONObject()
            for (k, v) in sanitizedLabels(config.labels, redactor: _redactor) { labels[k] = .string(v) }
            var capabilities = JSONObject()
            for (k, v) in capabilityList { capabilities[k] = .string(v) }
            var h: JSONObject = [
                "mode": .string(mode.rawValue),
                "app": appInfo.json,
                "source": ["gitSha": gitSha.map { .string($0) } ?? .null, "dirty": gitDirty.map { .bool($0) } ?? .null],
                "sdk": ["name": .string(sdkName), "version": .string(sdkVersion)],
                "stateSchemaVersion": .int(config.stateSchemaVersion),
                "platform": platform.json,
                "session": [
                    "id": .string(sessionId), "startedAt": .string(ISODate.format(startedAt)),
                    "wallClockAtAnchorMs": .int(wallAtAnchorMs ?? startMs), "seed": .int(seed),
                ],
                "integrations": .array(integrations.map { .string($0.name) }),
                "labels": .object(labels),
                "dependencies": .array((dependencies + (patchIdentity?.patchSetDigest == nil ? [] : [patchIdentity!.dependency])).map(\.json)),
                "patch": patchIdentity?.json ?? .null,
                "runtime": RuntimeInfo(name: "ios", version: platform.osVersion, language: "swift", frameworks: frameworks).json,
                "capabilities": .object(capabilities),
            ]
            if !_redactor.extraKeys.isEmpty || !_redactor.extraHeaders.isEmpty {
                h["redaction"] = [
                    "extraKeys": .array(_redactor.extraKeys.map { .string($0) }),
                    "extraHeaders": .array(_redactor.extraHeaders.map { .string($0) }),
                ]
            }
            h["pid"] = .int(Int(getpid()))
            h["release"] = .string(release)
            h["environment"] = .string(environment)
            h["anchorT"] = anchorMs.map { .int($0) } ?? .null
            h["wallClockAtStartMs"] = .int(startMs)
            return h
        }
    }

    func refreshJournalHeader() {
        guard let journal = lock.locked({ journal }) else { return }
        journal.updateHeader(journalHeader())
    }

    var appInfo: AppInfo {
        AppInfo(
            id: config.appId?.dartPrefix(200), name: config.appName?.dartPrefix(200),
            version: config.appVersion.dartPrefix(200), build: config.appBuild.dartPrefix(200),
            flavor: config.flavor?.dartPrefix(200))
    }

    /// `manifest.capabilities` of this runtime and its integrations.
    var capabilityList: [(String, String)] {
        var capabilities: [(String, String)] = [
            ("input.pointer.capture", "explicit"),
            ("input.pointer.replay", "unsupported"),
            ("input.semantic.replay", "supported"),
            ("text.replay", "supported"),
            ("lifecycle.replay", "partial"),
            ("clock.virtual", "explicit"),
            ("random.seeded", "explicit"),
            ("crash.uncaught", "partial"),
            ("crash.native", "partial"),
            (emergencyDecisionsCapability, BugCapsuleEmergency.shared.decisionsCapability),
        ]
        for i in integrations { capabilities.append(contentsOf: i.capabilities) }
        return capabilities
    }

    /// At most 100 labels, keys cut to 100 characters, values scrubbed (or
    /// a placeholder under a sensitive key) and cut to 2,000.
    func sanitizedLabels(_ merged: [String: String], redactor: Redactor) -> [(String, String)] {
        merged.keys.sorted().prefix(100).map { k in
            let v = merged[k]!
            return (k.dartPrefix(100), redactor.isSensitiveKey(k) ? Redactor.placeholder : redactor.scrubText(v).dartPrefix(2000))
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
        refreshJournalHeader()
    }

    @MainActor
    private func onLifecycle(_ state: String) {
        // Synthetic lifecycle posted by the replay engine must not be recorded or re-dispatched.
        if isReplaying { return }
        record(EventTypes.lifecycle, ["state": .string(state)])
        // Going to the background: the journal is written now (the process
        // may be suspended or killed without another chance).
        if state == "paused" { lock.locked({ journal })?.flush() }
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
        lock.locked({ journal })?.flush()
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
        let patch = patchIdentity
        let dependencies = interactions.manifestDependencies(
            events: windowEvents, checkpoint: window.checkpoint, eligibility: eligibility)
            + (patch?.patchSetDigest == nil ? [] : [patch!.dependency])
        let capabilities = capabilityList
        let events = windowEvents.map { $0.shifted(anchor) }
        var merged = config.labels
        for (k, v) in labels { merged[k] = v }
        let labelPairs = sanitizedLabels(merged, redactor: redactor)
        let capsule = Capsule(
            manifest: CapsuleManifest(
                capsuleId: capsuleId ?? uuidV4(), createdAt: Date(), mode: mode,
                app: appInfo,
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
                capabilities: capabilities, monitoring: link, dependencies: dependencies, patch: patch),
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
            engine.uncaught(failure, reason: "uncaught exception \(exception.name.rawValue)")
            return
        }
        var data = failure.json.objectValue!
        data["stack"] = nil
        record(EventTypes.failure, data)
        // The capsule below replaces what the journal would give next launch.
        defer {
            let j: CrashJournal? = lock.locked {
                defer { journal = nil }
                return journal
            }
            j?.delete()
        }
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
        let (outbox, maxBytes) = lock.locked { (self.outbox, self.maxCapsuleBytes) }
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
        remoteDisabled = !next.enabled
        maxCapsuleBytes = next.maxCapsuleBytes
        journal?.maxBytes = 2 * next.maxCapsuleBytes
        var rewrote = false
        // Whatever the recorder rewrote, the journal is written again from it.
        defer { if rewrote { resetJournalLocked() } }
        let switchedOff = interactions.setDisabledAdapters(Set(next.disabledAdapters))
        interactions.setMaxPayloadBytes(next.maxInteractionPayloadBytes)
        if !switchedOff.isEmpty {
            rewrote = true
            // Kill switch of single adapters: their buffered events go too.
            recorder?.rewrite(event: { e in
                guard InteractionTypes.isInteraction(e.type), let dep = e.data["dep"]?.stringValue else { return e }
                return switchedOff.contains(dep) ? nil : e
            })
        }
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
            rewrote = true
            recorder?.rewrite(event: { e in
                e.type == EventTypes.http ? BugCapsuleEvent(seq: e.seq, t: e.t, type: e.type, data: Self.withoutBodies(e.data)) : e
            })
        }
        captureBodies = bodies
        let wanted = Redactor(extraKeys: config.redactKeys + next.redactKeys).extraKeys
        if _redactor.extraKeys != wanted {
            rewrote = true
            _redactor = baseRedactor(remote: next.redactKeys)
            let redactor = _redactor
            // Request keys were computed with the old rules: buffered
            // exchanges are dropped (the capsule reports it), the rest is
            // redacted again.
            recorder?.rewrite(
                event: { e in
                    if e.type == EventTypes.http { return nil }
                    if InteractionTypes.isInteraction(e.type) {
                        // Match keys were computed with the old rules too.
                        if let dep = e.data["dep"]?.stringValue {
                            self.interactions.recorder(forDependency: dep)?.gap(
                                DependencyGaps.eventsDropped, "dropped when redaction rules changed")
                        }
                        return nil
                    }
                    guard let d = self.sanitize(e.type, e.data, redactor: redactor, captureBodies: bodies, hook: false) else {
                        return nil
                    }
                    if e.type == EventTypes.emergencyDecision, !EmergencyDecisionTracker.isIntact(d, original: e.data) {
                        BugCapsuleEmergency.shared.decisionLost()
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

    private func resetJournalLocked() {
        guard let journal, let recorder else { return }
        let state = recorder.journalState()
        journal.reset(
            header: journalHeader(), launch: state.launch, launchCovers: state.launchCovers, periodic: state.periodic,
            events: state.events)
    }

    /// A session that does not record keeps no journal.
    private func stopRecordingLocked() {
        captureEpoch += 1
        recording = false
        recorder = nil
        checkpointTimer?.cancel()
        checkpointTimer = nil
        journal?.delete()
        journal = nil
    }

    /// Kill switch: stop recording, drop the buffer, delete queued and saved captures.
    private func disableCaptureLocked() {
        let was = recording
        killed = true
        stopRecordingLocked()
        if was { BugCapsuleLog.info("capture disabled by remote config") }
        if let outbox { Task { await outbox.purge() } }
        if let store { queue.async { store.clearSavedCaptures() } }
        if let crashJournals { queue.async { FileIO.deleteQuietly(crashJournals.root) } }
    }

    // MARK: connection status

    private func noteConfigFetch(_ result: ConfigFetchResult) {
        lock.locked {
            switch result {
            case .fetched:
                configFetchedAt = Date()
                lastConfigFailure = nil
                credentialRejected = false
            case .failed(let message, let status, let retryAfter, let reason, let detail):
                let failure = ConfigFetchFailure(message: message, status: status, retryAfter: retryAfter, reason: reason, detail: detail)
                lastConfigFailure = failure
                if failure.isRefusal { credentialRejected = true }
            }
        }
    }

    private func noteAccepted(capsule: Bool) {
        lock.locked {
            if capsule {
                if firstCapsuleAcceptedAt == nil { firstCapsuleAcceptedAt = Date() }
            } else if firstEventAcceptedAt == nil {
                firstEventAcceptedAt = Date()
            }
        }
    }

    /// Connection and instrumentation (`BugCapsule.status`).
    public var status: BugCapsuleStatus {
        // Explicit self and distinct local names: older compilers report a circular reference otherwise.
        let s = lock.locked {
            (
                self.configFetchedAt, self.lastConfigFailure, self.credentialRejected, self.remoteDisabled, self.firstEventAcceptedAt,
                self.firstCapsuleAcceptedAt, self.recording, self.frameworks
            )
        }
        let (fetchedAt, failure, rejected, disabledRemotely, firstEvent, firstCapsule, isRecording, frameworkNames) = s
        let hasBackend = config.backend != nil || overrides?.transport != nil
        let state: BugCapsuleConnectionState
        if let tokenError {
            state = tokenError.code == .invalidToken ? .invalidToken : .unsupportedTokenVersion
        } else if !hasBackend {
            state = .notConfigured
        } else if !config.enabled {
            state = .disabled
        } else if rejected {
            state = .rejected
        } else if disabledRemotely {
            state = .disabled
        } else if fetchedAt != nil {
            state = .connected
        } else if let failure, failure.isOffline {
            state = .offline
        } else {
            state = .connecting
        }
        var reason: String?
        var message: String?
        if let tokenError {
            reason = tokenError.code.rawValue
            message = tokenError.message
        } else if state == .rejected {
            reason = failure?.reason ?? failure?.message
            message = failure?.detail ?? "the backend refused the credential"
        } else if state == .offline {
            reason = failure?.reason ?? failure?.message
            message = "the backend could not be reached; data is kept and retried"
        } else if state == .disabled {
            message = config.enabled ? "capture is disabled by the project's remote configuration" : "capture is disabled (enabled: false)"
        } else if state == .notConfigured {
            message = "no token or backend configured; capsules are only saved on the device"
        }
        let network = BugCapsuleURLSession.protocolInstalled && integrations.contains { $0 is BugCapsuleURLSession }
        let navigation = integrations.contains { ($0 as? BugCapsuleNavigation)?.hasSeenNavigation ?? false }
        let appState = integrations.contains {
            $0 is BugCapsuleUserDefaults || (($0 as? BugCapsuleStateIntegration)?.hasRegisteredState ?? false)
        }
        var missing: [String] = []
        if !network { missing.append("network") }
        if !navigation { missing.append("navigation") }
        if !appState { missing.append("app_state") }
        return BugCapsuleStatus(
            connection: BugCapsuleStatus.Connection(
                state: state, source: connectionSource, apiURL: config.backend?.url, reason: reason, message: message,
                configFetchedAt: fetchedAt, firstEventAcceptedAt: firstEvent, firstCapsuleAcceptedAt: firstCapsule),
            instrumentation: BugCapsuleStatus.Instrumentation(
                recording: isRecording, network: network, navigation: navigation, appState: appState, frameworks: frameworkNames,
                missing: missing))
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
    func startReplayForTesting(
        capsule: Capsule, settings: ReplaySettings, onReport: (@Sendable (ReplayReport) -> Void)? = nil
    ) -> ReplayEngine? {
        BugCapsuleSession.current = self
        return setUpReplay(capsule: capsule, settings: settings, channel: nil, onReport: onReport)
    }

    /// What this process runs. Read once: a process pins one generation.
    var patchIdentity: PatchIdentity? {
        // Its own lock: callers may already hold the session lock.
        patchLock.withLock {
            if !_patchRead {
                _patchRead = true
                _patch = config.patchBinding?.identity
            }
            return _patch
        }
    }

    /// Loads the exact patch of a replay attempt. Returns why it can't run, or nil.
    private func pinPatch(capsule: Capsule, settings: ReplaySettings, channel: ReplayChannel?) -> String? {
        let binding = config.patchBinding
        var running: PatchIdentity?
        if let binding {
            do {
                let bundle = settings.patchArtifact ? try channel?.fetchPatchFileSync(ReplayProtocol.patchPath) : nil
                let keyring = settings.patchKeyring ? try channel?.fetchPatchFileSync(ReplayProtocol.keyringPath) : nil
                let signature = settings.patchKeyring ? try channel?.fetchPatchFileSync(ReplayProtocol.keyringSignaturePath) : nil
                running = try binding.pinForReplay(bundle: bundle, keyring: keyring, keyringSignature: signature)
            } catch {
                patchLock.withLock { _patchRead = true }
                return "patch.unavailable: \(error)"
            }
        }
        patchLock.withLock {
            _patchRead = true
            _patch = running
        }
        channel?.patch = running
        return patchPreflight(manifest: capsule.manifest, settings: settings, hasBinding: binding != nil, running: running)
    }

    @MainActor
    private func setUpReplay(
        capsule: Capsule, settings: ReplaySettings, channel: ReplayChannel?,
        onReport: (@Sendable (ReplayReport) -> Void)? = nil
    ) -> ReplayEngine? {
        let replay = ReplayEngine(capsule: capsule, settings: settings, buildGitSha: gitSha, channel: channel, session: self)
        replay.onReport = onReport
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
        interactions.replay = replay.interactions
        for integration in integrations { integration.setUp(self) }
        // capsule-v2 §2 preflight: every required dependency's adapter is
        // installed, supports its schema and can restore what was open.
        if let problem = pinPatch(capsule: capsule, settings: settings, channel: channel) ?? interactions.preflight(capsule) {
            replay.finishIncompatible(problem)
            lock.locked { _engine = nil }
            interactions.replay = nil
            return nil
        }
        for name in capsule.checkpoint.data.keys where !names.contains(name) && name != "interactions" {
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
        let (remote, outbox, monitoring, journal) = lock.locked {
            () -> (RemoteConfigController?, UploadOutbox?, Monitoring?, CrashJournal?) in
            disposed = true
            // Like the end of the process: the journal stays for the next launch.
            let j = self.journal
            self.journal = nil
            stopRecordingLocked()
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers = []
            return (self.remote, self.outbox, _monitoring, j)
        }
        journal?.close()
        monitoring?.stop()
        await remote?.dispose()
        await outbox?.close()
        await monitoring?.outbox?.close()
        if BugCapsuleSession.current === self { BugCapsuleSession.current = nil }
    }

    // Test helpers
    var recorderForTesting: FlightRecorder? { lock.locked { recorder } }
    var journalForTesting: CrashJournal? { lock.locked { journal } }
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
