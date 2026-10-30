import Foundation

#if canImport(UIKit)
    import UIKit
#endif

/// Test seams of the emergency module (clock, randomness, storage, timers).
struct EmergencyTestHooks: @unchecked Sendable {
    var storageDirectory: URL?
    var now: (@Sendable () -> Date)?
    var random: (@Sendable () -> Double)?
    /// false: refreshes are never scheduled (tests call `refresh` themselves).
    var autoSchedule = true
    var isReplaying: (@Sendable () -> Bool)?
    /// false: no UIKit lifecycle observers.
    var observeLifecycle = true
    /// Seconds between runtime reports (§7.6); nil: 60.
    var runtimeReportInterval: TimeInterval?
}

/// One initialized emergency client (§7): the verified document, the
/// refresh loop, receipts and status. Evaluation is synchronous and reads an
/// immutable snapshot under a lock; everything else runs off the caller's
/// thread.
final class EmergencyRuntime: @unchecked Sendable {
    /// The accepted document with what came with it.
    struct Current: Sendable {
        var document: EmergencyDocument
        var envelope: JSONValue
        var etag: String?
        var receivedAtMs: Int64
    }

    enum Trigger: Sendable, Equatable { case startup, scheduled, foreground, manual, sessionStarted }

    static let minRefreshInterval: TimeInterval = 15
    static let maxBackoff: TimeInterval = 15 * 60
    /// A foreground fetch is skipped when one started this recently.
    static let foregroundThrottle: TimeInterval = 2

    let environment: String
    let refreshInterval: TimeInterval
    let anchor: EmergencyTrustAnchor?
    /// Why the client cannot work at all (invalid anchor or environment).
    let configurationError: EmergencyStatus.Failure?
    let installationId: String
    let appVersion: String?
    private let exactModes: [String: EmergencyFailureMode]
    /// `prefix.` (with the dot) to mode, longest first.
    private let prefixModes: [(prefix: String, mode: EmergencyFailureMode)]
    private let explicitBackend: BugCapsuleBackendConfig?
    private let tokenError: BugCapsuleTokenError?
    private let store: EmergencyStore?
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double
    private let autoSchedule: Bool
    private let observeLifecycle: Bool
    private let replaying: @Sendable () -> Bool
    private let notify: @Sendable (EmergencySnapshot) -> Void

    private let lock = NSLock()
    private var current: Current?
    private var highestRevision: Int?
    private var lastFetchAt: Date?
    private var lastAttemptAt: Date?
    private var lastError: EmergencyStatus.Failure?
    private var credentialRejected = false
    private var failures = 0
    private var inFlight: (id: Int, task: Task<Void, Never>)?
    private var taskCounter = 0
    private var timer: Task<Void, Never>?
    private var paused = false
    private var disposed = false
    private var sentReceipts = Set<String>()
    private var transport: EmergencyHTTPTransport?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var warnedKeys = Set<String>()
    /// The update adapter; set once in `init`.
    private(set) var updates: EmergencyUpdateCoordinator?
    // Runtime reports (§7.6).
    private let runtimeReportInterval: TimeInterval
    /// The latest `runtime` object, sent or not.
    private var runtimeObject: JSONObject?
    /// The encoded object of the last report: never sent twice in a row.
    private var lastReportedRuntime: String?
    /// `systemUptime` of the last report.
    private var lastRuntimeReportAt: TimeInterval?
    /// Sends the latest object when the interval ends.
    private var runtimeTimer: Task<Void, Never>?
    private var warnedInvalidRuntime = false
    /// Delay of the last scheduled refresh (tests).
    var scheduledDelay: TimeInterval? { lock.locked { _scheduledDelay } }
    /// A refresh timer is waiting (tests).
    var hasPendingTimer: Bool { lock.locked { timer != nil } }
    private var _scheduledDelay: TimeInterval?

    init(configuration c: EmergencyConfiguration, notify: @escaping @Sendable (EmergencySnapshot) -> Void) {
        let hooks = c.testHooks
        self.notify = notify
        let defaultNow: @Sendable () -> Date = { Date() }
        let defaultRandom: @Sendable () -> Double = { Double.random(in: 0..<1) }
        let gateURL = ReplayGate.replayURL()
        let defaultReplaying: @Sendable () -> Bool = { gateURL != nil || BugCapsuleSession.current?.isReplaying == true }
        now = hooks?.now ?? defaultNow
        random = hooks?.random ?? defaultRandom
        autoSchedule = hooks?.autoSchedule ?? true
        observeLifecycle = hooks?.observeLifecycle ?? true
        replaying = hooks?.isReplaying ?? defaultReplaying
        runtimeReportInterval = hooks?.runtimeReportInterval ?? EmergencyRuntimeReport.interval
        environment = c.environment
        refreshInterval = min(max(c.refreshInterval.isFinite ? c.refreshInterval : 60, Self.minRefreshInterval), 86400)
        appVersion = c.appVersion ?? BugCapsuleSession.current?.config.appVersion ?? Self.bundleVersion()

        // Failure modes: exact keys and `prefix.*` patterns.
        var exact: [String: EmergencyFailureMode] = [:]
        var prefixes: [(String, EmergencyFailureMode)] = []
        for (key, mode) in c.failureModes {
            guard EmergencyContract.isFeatureKey(key, allowWildcard: true) else {
                BugCapsuleLog.warn("emergency: failure mode for \"\(key)\" ignored: not a feature key or prefix.* pattern")
                continue
            }
            if key.hasSuffix(".*") { prefixes.append((String(key.dropLast()), mode)) } else { exact[key] = mode }
        }
        exactModes = exact
        prefixModes = prefixes.sorted { $0.0.utf8.count > $1.0.utf8.count }

        // Connection: explicit backend, else the token, else BugCapsule.start's.
        var tokenError: BugCapsuleTokenError?
        if let backend = c.backend {
            explicitBackend = backend
        } else if let token = c.token {
            switch BugCapsuleConnectionToken.parse(token) {
            case .success(let backend): explicitBackend = backend
            case .failure(let error):
                explicitBackend = nil
                tokenError = error
                BugCapsuleLog.warn("emergency: the SDK token can't be used (\(error.code.rawValue)): \(error.message)")
            }
        } else {
            explicitBackend = nil
        }
        self.tokenError = tokenError

        // Anchor and environment.
        var anchor: EmergencyTrustAnchor?
        var configurationError: EmergencyStatus.Failure?
        do {
            anchor = try EmergencyTrustAnchor.parse(c.trustAnchor)
        } catch {
            configurationError = .init(code: "invalid_anchor", message: "the trust anchor is invalid: \(error)")
        }
        if configurationError == nil, !EmergencyContract.isEnvironment(c.environment) {
            configurationError = .init(
                code: "invalid_environment", message: "environment \"\(c.environment)\" does not match ^[a-z0-9][a-z0-9_-]{0,39}$")
        }
        if let configurationError {
            BugCapsuleLog.warn(
                "emergency: \(configurationError.message). Emergency policies are off; every feature uses its failure mode.")
            anchor = nil
        }
        self.anchor = anchor
        self.configurationError = configurationError

        // Storage.
        var store: EmergencyStore?
        if let dir = hooks?.storageDirectory {
            store = EmergencyStore(directory: dir)
        } else {
            do {
                store = EmergencyStore(directory: try EmergencyStore.defaultDirectory())
            } catch {
                BugCapsuleLog.warn("emergency: no storage (\(error.localizedDescription)); policies are kept in memory only")
            }
        }
        self.store = store
        installationId = store?.installationId() ?? EmergencyStore.newInstallationId()
        lastError = configurationError
        loadCache()
        if let provider = c.updateProvider {
            updates = EmergencyUpdateCoordinator(provider: provider, installedVersion: appVersion, replaying: replaying) {
                [weak self] status in self?.setUpdateStatus(status)
            }
        }
    }

    static func bundleVersion() -> String? {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return v?.isEmpty == false ? v : nil
    }

    // MARK: startup (§7.1)

    /// Loads the persisted envelope and verifies it again against the current
    /// anchor and environment; discards it when that fails.
    private func loadCache() {
        guard let anchor, let store, let cached = store.readPolicies(environment: environment) else { return }
        let sameBinding = cached.applicationId == anchor.applicationId && cached.environment == environment
        var highest = sameBinding ? cached.highestRevision : nil
        var accepted: Current?
        if let envelope = cached.envelope {
            switch EmergencyVerifier.verify(envelope: envelope, anchor: anchor, environment: environment) {
            case .verified(let doc):
                accepted = Current(
                    document: doc, envelope: envelope, etag: cached.etag, receivedAtMs: cached.receivedAtMs ?? 0)
                highest = max(highest ?? doc.revision, doc.revision)
            case .rejected(let reason, _):
                BugCapsuleLog.warn("emergency: the cached policy document no longer verifies (\(reason.rawValue)); discarding it")
            }
        }
        lock.locked {
            current = accepted
            highestRevision = highest
        }
        if accepted == nil, cached.envelope != nil || !sameBinding {
            persist(nil, highest: highest)
        }
    }

    /// Publishes the startup snapshot, installs lifecycle observers and
    /// starts the first fetch in the background. Never waits for the network.
    func start() {
        notify(snapshot())
        installLifecycleObservers()
        Task { [weak self] in await self?.refresh(.startup) }
    }

    func dispose() {
        let (observers, timers, inFlight): ([NSObjectProtocol], [Task<Void, Never>], Task<Void, Never>?) = lock.locked {
            disposed = true
            let o = lifecycleObservers
            lifecycleObservers = []
            let t = [self.timer, runtimeTimer].compactMap { $0 }
            self.timer = nil
            runtimeTimer = nil
            return (o, t, self.inFlight?.task)
        }
        for t in timers { t.cancel() }
        inFlight?.cancel()
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: evaluation (§6, §7.4)

    func evaluate(featureKey: String, subject: String?) -> (EmergencyDecision, EmergencyPolicy?) {
        if replaying() {
            return (BugCapsuleEmergency.shared.replayDecision(featureKey: featureKey, subject: subject), nil)
        }
        if !EmergencyContract.isFeatureKey(featureKey) {
            let first = lock.locked { () -> Bool in
                guard warnedKeys.count < 100 else { return false }
                return warnedKeys.insert(featureKey).inserted
            }
            if first { BugCapsuleLog.warn("emergency: \"\(featureKey)\" is not a valid feature key; no policy can match it") }
        }
        let cur = lock.locked { current }
        let nowMs = EmergencyContract.milliseconds(now())
        let ctx = EmergencyEvaluationContext(
            platform: EmergencyContract.platform, appVersion: appVersion, subject: subject ?? installationId, nowMs: nowMs)
        if let cur, nowMs <= cur.document.expiresAtMs + EmergencyContract.clockSkewMs {
            return EmergencyContract.evaluate(
                policies: cur.document.policies, revision: cur.document.revision, featureKey: featureKey, context: ctx,
                source: .policy)
        }
        switch failureMode(for: featureKey) {
        case .failOpen:
            return (Self.unavailable(featureKey, allowed: true), nil)
        case .failClosed:
            return (Self.unavailable(featureKey, allowed: false), nil)
        case .useLastValidPolicy:
            guard let cur else { return (Self.unavailable(featureKey, allowed: true), nil) }
            return EmergencyContract.evaluate(
                policies: cur.document.policies, revision: cur.document.revision, featureKey: featureKey, context: ctx,
                source: .stalePolicy)
        }
    }

    static func unavailable(_ featureKey: String, allowed: Bool) -> EmergencyDecision {
        EmergencyDecision(
            featureKey: featureKey, allowed: allowed, action: allowed ? .allow : .block,
            reasonCode: EmergencyDecision.policyUnavailable, source: .failureMode)
    }

    /// The configured failure mode: exact key first, then the longest
    /// matching `prefix.*`, else FAIL_OPEN.
    func failureMode(for featureKey: String) -> EmergencyFailureMode {
        if let m = exactModes[featureKey] { return m }
        for (prefix, mode) in prefixModes where featureKey.utf8.starts(with: prefix.utf8) { return mode }
        return .failOpen
    }

    // MARK: status (§7.5)

    func snapshot() -> EmergencySnapshot {
        let cur = lock.locked { current }
        return EmergencySnapshot(current: cur, nowMs: EmergencyContract.milliseconds(now()))
    }

    func status() -> EmergencyStatus {
        let nowMs = EmergencyContract.milliseconds(now())
        return lock.locked {
            let doc = current?.document
            let state: EmergencyStatus.State =
                doc == nil ? .none : (nowMs <= doc!.expiresAtMs + EmergencyContract.clockSkewMs ? .usable : .expired)
            return EmergencyStatus(
                isInitialized: true, state: state, revision: doc?.revision, issuedAt: doc?.issuedAt,
                expiresAt: doc?.expiresAt, lastFetchAt: lastFetchAt, lastError: lastError,
                credentialRejected: credentialRejected)
        }
    }

    // MARK: refresh (§7.2)

    /// Fetches now. Concurrent calls join the fetch in flight. Scheduled and
    /// foreground fetches stop after the credential was refused; a manual
    /// one still runs.
    func refresh(_ trigger: Trigger) async {
        let replay = replaying()
        let task: Task<Void, Never>? = lock.locked {
            if disposed || anchor == nil || replay { return nil }
            if credentialRejected && trigger != .manual { return nil }
            if paused && trigger == .scheduled { return nil }
            if let inFlight { return inFlight.task }
            if trigger == .foreground, let last = lastAttemptAt,
                now().timeIntervalSince(last) < Self.foregroundThrottle
            {
                return nil
            }
            taskCounter += 1
            let id = taskCounter
            let t = Task { [self] in
                await self.performFetch()
                self.lock.locked { if self.inFlight?.id == id { self.inFlight = nil } }
            }
            inFlight = (id, t)
            return t
        }
        await task?.value
    }

    private func resolveBackend() -> BugCapsuleBackendConfig? {
        explicitBackend ?? (tokenError == nil ? BugCapsuleSession.current?.config.backend : nil)
    }

    private func transport(for backend: BugCapsuleBackendConfig) -> EmergencyHTTPTransport {
        lock.locked {
            if let transport, transport.backend == backend { return transport }
            let t = EmergencyHTTPTransport(backend: backend)
            transport = t
            return t
        }
    }

    private func performFetch() async {
        guard let anchor else { return }
        guard let backend = resolveBackend() else {
            let failure: EmergencyStatus.Failure =
                tokenError.map { .init(code: "invalid_token", message: "the SDK token can't be used: \($0.message)") }
                ?? .init(
                    code: "no_backend",
                    message: "no backend: pass token or backend to EmergencyConfiguration, or call BugCapsule.start")
            lock.locked { lastError = failure }
            return
        }
        let etag: String? = lock.locked {
            lastAttemptAt = now()
            return current?.etag
        }
        let result = await transport(for: backend).fetchPolicies(
            applicationId: anchor.applicationId, environment: environment, appVersion: appVersion, etag: etag)
        if lock.locked({ disposed }) { return }
        switch result {
        case .notModified:
            succeeded()
        case .envelope(let json, let etag):
            handle(envelope: json, etag: etag, anchor: anchor, backend: backend)
        case .unparseable:
            rejected(.malformed, revision: nil, anchor: anchor, backend: backend)
        case .refused(let status, let reason):
            let first = lock.locked { () -> Bool in
                let first = !credentialRejected
                credentialRejected = true
                lastFetchAt = now()
                lastError = .init(
                    code: "credential_rejected",
                    message: "the backend refused the credential (\(reason ?? "HTTP \(status)"))", httpStatus: status)
                timer?.cancel()
                timer = nil
                return first
            }
            if first {
                BugCapsuleLog.warn(
                    "emergency: the backend refused the credential (HTTP \(status)); scheduled policy fetches stop for this run. The cached document stays in use until it expires.")
            }
        case .failed(let code, let message, let status, let retryAfter):
            failed(.init(code: code, message: message, httpStatus: status), retryAfter: retryAfter)
        }
    }

    /// §5: accept, ignore or reject a verified-or-not envelope.
    private func handle(envelope json: JSONValue, etag: String?, anchor: EmergencyTrustAnchor, backend: BugCapsuleBackendConfig) {
        let doc: EmergencyDocument
        switch EmergencyVerifier.verify(envelope: json, anchor: anchor, environment: environment) {
        case .rejected(let reason, let revision):
            rejected(reason, revision: revision, anchor: anchor, backend: backend)
            return
        case .verified(let d):
            doc = d
        }
        enum Outcome { case accepted(Current, Int), ignored, rejected(EmergencyRejection) }
        let nowMs = EmergencyContract.milliseconds(now())
        let outcome: Outcome = lock.locked {
            if let h = highestRevision, doc.revision < h { return .rejected(.staleRevision) }
            if let cur = current, doc.revision == cur.document.revision, doc.issuedAtMs <= cur.document.issuedAtMs {
                return .ignored
            }
            if doc.expiresAtMs + EmergencyContract.clockSkewMs < nowMs { return .rejected(.expiredOnArrival) }
            let accepted = Current(document: doc, envelope: json, etag: etag, receivedAtMs: nowMs)
            let highest = max(highestRevision ?? doc.revision, doc.revision)
            // Atomic swap: evaluations see the old document or this one, never a mix.
            current = accepted
            highestRevision = highest
            return .accepted(accepted, highest)
        }
        switch outcome {
        case .ignored:
            succeeded()
        case .rejected(let reason):
            rejected(reason, revision: doc.revision, anchor: anchor, backend: backend)
        case .accepted(let accepted, let highest):
            persist(accepted, highest: highest)
            BugCapsuleLog.info("emergency: applied policy revision \(doc.revision) (\(doc.policies.count) policies)")
            sendReceipt(revision: doc.revision, status: "APPLIED", errorCode: nil, anchor: anchor, backend: backend)
            succeeded()
            notify(snapshot())
        }
    }

    private func persist(_ accepted: Current?, highest: Int?) {
        guard let store, let anchor else { return }
        do {
            try store.writePolicies(
                .init(
                    applicationId: anchor.applicationId, environment: environment, envelope: accepted?.envelope,
                    etag: accepted?.etag, receivedAtMs: accepted?.receivedAtMs, highestRevision: highest))
        } catch {
            BugCapsuleLog.warn("emergency: could not store the policy document (\(error.localizedDescription)); it is kept in memory")
        }
    }

    private func succeeded() {
        lock.locked {
            failures = 0
            lastFetchAt = now()
            lastError = nil
            credentialRejected = false
        }
        schedule(refreshInterval)
    }

    private func rejected(
        _ reason: EmergencyRejection, revision: Int?, anchor: EmergencyTrustAnchor, backend: BugCapsuleBackendConfig
    ) {
        BugCapsuleLog.warn("emergency: rejected a policy document (\(reason.rawValue))")
        let receiptRevision = revision ?? lock.locked { highestRevision ?? 0 }
        sendReceipt(revision: receiptRevision, status: "FAILED", errorCode: reason.rawValue, anchor: anchor, backend: backend)
        lock.locked { lastFetchAt = now() }
        failed(.init(code: reason.rawValue, message: "policy document rejected: \(reason.rawValue)"), retryAfter: nil)
    }

    private func failed(_ failure: EmergencyStatus.Failure, retryAfter: TimeInterval?) {
        let attempts: Int = lock.locked {
            failures += 1
            lastError = failure
            return failures
        }
        var delay = min(refreshInterval * pow(2, Double(min(attempts - 1, 20))), Self.maxBackoff)
        delay *= 0.8 + random() * 0.4
        if let retryAfter { delay = max(delay, min(max(retryAfter, 0), 86400)) }
        schedule(delay)
    }

    private func schedule(_ delay: TimeInterval) {
        lock.locked {
            timer?.cancel()
            timer = nil
            _scheduledDelay = delay
            if disposed || paused || credentialRejected || !autoSchedule { return }
            timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.refresh(.scheduled)
            }
        }
    }

    // MARK: lifecycle

    /// The app went to the background: no timers run.
    func onBackground() {
        lock.locked {
            paused = true
            timer?.cancel()
            timer = nil
        }
    }

    /// The app came back: fetch (joining one in flight).
    func onForeground() async {
        lock.locked { paused = false }
        await refresh(.foreground)
    }

    /// `didBecomeActive`: only a resume from the background fetches (a
    /// `willEnterForeground` normally did it already).
    func onActive() async {
        let wasPaused = lock.locked { () -> Bool in
            let p = paused
            paused = false
            return p
        }
        if wasPaused { await refresh(.foreground) }
    }

    /// `BugCapsule.start` resolved a backend after `initialize`.
    func onSessionStarted() async {
        let needed = lock.locked { explicitBackend == nil && lastFetchAt == nil && !credentialRejected }
        reportRuntime()
        if needed { await refresh(.sessionStarted) }
    }

    private func installLifecycleObservers() {
        #if canImport(UIKit)
            guard observeLifecycle else { return }
            let nc = NotificationCenter.default
            var tokens: [NSObjectProtocol] = []
            tokens.append(
                nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) {
                    [weak self] _ in self?.onBackground()
                })
            tokens.append(
                nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) {
                    [weak self] _ in
                    guard let self else { return }
                    Task { await self.onForeground() }
                })
            tokens.append(
                nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) {
                    [weak self] _ in
                    guard let self else { return }
                    Task { await self.onActive() }
                })
            let keep = lock.locked { () -> Bool in
                if disposed { return false }
                lifecycleObservers = tokens
                return true
            }
            if !keep { for t in tokens { nc.removeObserver(t) } }
        #endif
    }

    // MARK: receipts (§7.3)

    /// Fire-and-forget; each (revision, status, errorCode) at most once per
    /// process. Never in replay.
    private func sendReceipt(
        revision: Int, status: String, errorCode: String?, anchor: EmergencyTrustAnchor, backend: BugCapsuleBackendConfig
    ) {
        if replaying() { return }
        let key = "\(revision)|\(status)|\(errorCode ?? "")"
        let (fresh, runtime) = lock.locked { (sentReceipts.insert(key).inserted, runtimeObject) }
        if !fresh { return }
        // APPLIED and FAILED may carry the latest runtime object (§7.6).
        let body = receiptBody(
            revision: revision, status: status, errorCode: errorCode,
            runtime: runtime.flatMap { EmergencyRuntimeReport.validate($0) == nil ? $0 : nil })
        post(body, status: status, revision: revision, anchor: anchor, backend: backend)
    }

    private func receiptBody(revision: Int, status: String, errorCode: String?, runtime: JSONObject?) -> JSONObject {
        var body: JSONObject = [
            "environment": .string(environment), "platform": .string(EmergencyContract.platform),
            "installationId": .string(installationId), "revision": .int(revision), "status": .string(status),
            "sdkVersion": .string(sdkVersion),
        ]
        body["appVersion"] = EmergencyHTTPTransport.diagnosticVersion(appVersion).map { .string($0) } ?? .null
        body["errorCode"] = errorCode.map { .string($0) } ?? .null
        if let runtime { body["runtime"] = .object(runtime) }
        return body
    }

    private func post(
        _ body: JSONObject, status: String, revision: Int, anchor: EmergencyTrustAnchor, backend: BugCapsuleBackendConfig
    ) {
        let transport = transport(for: backend)
        let app = anchor.applicationId
        Task {
            if case .failure(let failure) = await transport.sendReceipt(applicationId: app, body: body) {
                BugCapsuleLog.warn("emergency: receipt \(status) for revision \(revision) not delivered (\(failure.message))")
            }
        }
    }

    // MARK: runtime reports (§7.6)

    /// The update adapter learned something: report it when it differs from
    /// the last object.
    func setUpdateStatus(_ status: EmergencyUpdateStatus) {
        let object = EmergencyRuntimeReport.object(update: status)
        let changed = lock.locked { () -> Bool in
            if runtimeObject == object { return false }
            runtimeObject = object
            return true
        }
        if changed { reportRuntime() }
    }

    /// The latest runtime object (tests).
    var latestRuntimeObject: JSONObject? { lock.locked { runtimeObject } }

    /// Sends the latest runtime object as a `RUNTIME` receipt: never the
    /// object of the last report again, at most one report per interval.
    /// Within the interval, the latest object waits for its end. Exempt from
    /// the once-per-(revision, status, errorCode) rule of receipts. Never in
    /// replay.
    private func reportRuntime() {
        if replaying() { return }
        guard let anchor else { return }
        let backend = resolveBackend()
        enum Step { case none, invalid(String), send(JSONObject, revision: Int) }
        let step: Step = lock.locked {
            guard !disposed, runtimeTimer == nil, let object = runtimeObject else { return .none }
            let key = JSON.encode(.object(object))
            if key == lastReportedRuntime { return .none }
            if let problem = EmergencyRuntimeReport.validate(object) {
                if warnedInvalidRuntime { return .none }
                warnedInvalidRuntime = true
                return .invalid(problem)
            }
            // Without a connection the object stays unsent; `BugCapsule.start`
            // reports it once a backend is known.
            guard backend != nil else { return .none }
            let t = ProcessInfo.processInfo.systemUptime
            if let last = lastRuntimeReportAt, t - last < runtimeReportInterval {
                let delay = runtimeReportInterval - (t - last)
                runtimeTimer = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
                    if Task.isCancelled { return }
                    self?.runtimeIntervalEnded()
                }
                return .none
            }
            lastReportedRuntime = key
            lastRuntimeReportAt = t
            return .send(object, revision: highestRevision ?? 0)
        }
        switch step {
        case .none:
            return
        case .invalid(let problem):
            BugCapsuleLog.warn("emergency: runtime report not sent: \(problem)")
        case .send(let object, let revision):
            guard let backend else { return }
            let body = receiptBody(revision: revision, status: EmergencyRuntimeReport.status, errorCode: nil, runtime: object)
            post(body, status: EmergencyRuntimeReport.status, revision: revision, anchor: anchor, backend: backend)
        }
    }

    private func runtimeIntervalEnded() {
        lock.locked { runtimeTimer = nil }
        reportRuntime()
    }
}
