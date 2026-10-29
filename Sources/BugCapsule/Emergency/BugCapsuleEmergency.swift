import Foundation

/// Settings of `BugCapsule.emergency.initialize(_:)`.
public struct EmergencyConfiguration: Sendable {
    /// `bcek.v1.…` from the dashboard: the application id and the public keys
    /// allowed to sign its policies. Compile it into the app; it is never
    /// fetched from the network. An invalid anchor turns emergency policies
    /// off (every feature uses its failure mode).
    public var trustAnchor: String
    /// Policies of this environment are fetched and accepted.
    public var environment: String
    /// Seconds between fetches while the app is in the foreground; at least 15.
    public var refreshInterval: TimeInterval
    /// What a feature does when there is no usable policy document, by exact
    /// key or `prefix.*` (exact wins, then the longest prefix). Every other
    /// key fails open.
    public var failureModes: [String: EmergencyFailureMode]
    /// SDK token (`bcsdk.v1.…`). Nil: `backend`, else the connection of
    /// `BugCapsule.start`.
    public var token: String?
    /// Explicit backend URL and ingest key; wins over `token`.
    public var backend: BugCapsuleBackendConfig?
    /// Version policies are targeted against. Nil: the version given to
    /// `BugCapsule.start`, else `CFBundleShortVersionString`.
    public var appVersion: String?
    /// The update adapter behind `BugCapsule.emergency.updates`
    /// (`AppStoreUpdateProvider()` for the App Store). Nil: no update
    /// adapter and no runtime reports.
    public var updateProvider: (any EmergencyUpdateProvider)?

    var testHooks: EmergencyTestHooks?

    public init(
        trustAnchor: String, environment: String = "production", refreshInterval: TimeInterval = 60,
        failureModes: [String: EmergencyFailureMode] = [:], token: String? = nil, backend: BugCapsuleBackendConfig? = nil,
        appVersion: String? = nil, updateProvider: (any EmergencyUpdateProvider)? = nil
    ) {
        self.trustAnchor = trustAnchor
        self.environment = environment
        self.refreshInterval = refreshInterval
        self.failureModes = failureModes
        self.token = token
        self.backend = backend
        self.appVersion = appVersion
        self.updateProvider = updateProvider
    }
}

/// State of the emergency client (§7.5).
public struct EmergencyStatus: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        /// No verified document.
        case none
        /// A verified document within `expiresAt` + 5 minutes.
        case usable
        /// The verified document has expired; failure modes apply.
        case expired
    }

    /// The last thing that went wrong.
    public struct Failure: Error, Sendable, Equatable, CustomStringConvertible {
        /// A rejection reason (`bad_signature`, `stale_revision`, …),
        /// `credential_rejected`, `network_error`, `http_error`,
        /// `body_too_large`, `emergency_not_configured`, `no_backend`,
        /// `invalid_token`, `invalid_anchor` or `invalid_environment`.
        public var code: String
        public var message: String
        public var httpStatus: Int?

        public init(code: String, message: String, httpStatus: Int? = nil) {
            self.code = code
            self.message = message
            self.httpStatus = httpStatus
        }

        public var description: String { "\(code): \(message)" }
    }

    public var isInitialized: Bool
    public var state: State
    /// Revision of the current document.
    public var revision: Int?
    public var issuedAt: Date?
    public var expiresAt: Date?
    /// When the backend last answered a fetch with a document, 304 or a
    /// credential refusal (failed fetches leave it unchanged).
    public var lastFetchAt: Date?
    /// Nil after a successful fetch.
    public var lastError: Failure?
    /// The backend refused the credential: scheduled fetches stopped for this run.
    public var credentialRejected: Bool

    static let notInitialized = EmergencyStatus(
        isInitialized: false, state: .none, revision: nil, issuedAt: nil, expiresAt: nil, lastFetchAt: nil,
        lastError: nil, credentialRejected: false)
}

/// The verified document the client evaluates, as published to observers.
public struct EmergencySnapshot: Sendable, Equatable {
    /// State when the snapshot was taken.
    public var state: EmergencyStatus.State
    public var revision: Int?
    public var issuedAt: Date?
    public var expiresAt: Date?
    public var receivedAt: Date?
    public var policies: [EmergencyPolicy]

    init(current: EmergencyRuntime.Current?, nowMs: Int64) {
        guard let c = current else {
            state = .none
            policies = []
            return
        }
        let doc = c.document
        state = nowMs <= doc.expiresAtMs + EmergencyContract.clockSkewMs ? .usable : .expired
        revision = doc.revision
        issuedAt = doc.issuedAt
        expiresAt = doc.expiresAt
        receivedAt = c.receivedAtMs > 0 ? Date(timeIntervalSince1970: TimeInterval(c.receivedAtMs) / 1000) : nil
        policies = doc.policies
    }
}

/// Keeps an `observe` handler registered. Cancelled by `cancel()` or when
/// released.
@objc(BCEmergencyObservation)
public final class EmergencyObservation: NSObject, @unchecked Sendable {
    private let onCancel: @Sendable () -> Void
    private let lock = NSLock()
    private var cancelled = false

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    @objc public func cancel() {
        let first = lock.locked { () -> Bool in
            defer { cancelled = true }
            return !cancelled
        }
        if first { onCancel() }
    }

    deinit { cancel() }
}

extension BugCapsule {
    /// Remote, signed feature guards (emergency recovery). Usable before and
    /// without `start`.
    public static var emergency: BugCapsuleEmergency { BugCapsuleEmergency.shared }
}

/// Remote feature guards: signed policies fetched from BugCapsule, verified
/// against the trust anchor compiled into the app, cached on the device and
/// evaluated locally.
///
/// ```swift
/// BugCapsule.emergency.initialize(EmergencyConfiguration(
///     trustAnchor: "bcek.v1.…", failureModes: ["checkout.*": .failClosed]))
/// let d = BugCapsule.emergency.evaluate(featureKey: "checkout.confirm_order")
/// if !d.allowed { showUnavailable(d.publicUserMessage) }
/// ```
///
/// A guard in the app only improves what users see. The app's server must
/// enforce the same restriction for anything that moves money or data.
/// Policies never carry code.
@objc(BCEmergency)
public final class BugCapsuleEmergency: NSObject, @unchecked Sendable {
    @objc(sharedInstance) public static let shared = BugCapsuleEmergency()

    private let lock = NSLock()
    private var runtime: EmergencyRuntime?
    private var handlers: [UUID: @MainActor @Sendable (EmergencySnapshot) -> Void] = [:]
    private var continuations: [UUID: AsyncStream<EmergencySnapshot>.Continuation] = [:]
    private var warnedUninitialized = false

    /// The update adapter configured with `updateProvider`: availability
    /// checks, the store page, and their runtime reports (§7.6, §7.7).
    @objc public let updates = EmergencyUpdates()

    override init() {
        super.init()
        updates.emergency = self
    }

    private var current: EmergencyRuntime? { lock.locked { runtime } }

    /// The update adapter of the initialized client.
    var updateCoordinator: EmergencyUpdateCoordinator? { current?.updates }

    // MARK: setup

    /// Starts the emergency client: parses the anchor, loads and re-verifies
    /// the cached document, and starts the first fetch in the background.
    /// Never blocks on the network and never throws. A second call is
    /// ignored.
    public func initialize(_ configuration: EmergencyConfiguration) {
        let created: EmergencyRuntime? = lock.locked {
            if runtime != nil { return nil }
            let r = EmergencyRuntime(configuration: configuration) { [weak self] snapshot in self?.publish(snapshot) }
            runtime = r
            return r
        }
        guard let created else {
            BugCapsuleLog.warn("emergency: initialize called twice; ignored")
            return
        }
        created.start()
    }

    public var isInitialized: Bool { current != nil }

    // MARK: evaluation

    /// The decision for [featureKey], computed in memory from the current
    /// snapshot. Thread-safe; never blocks on I/O. [subject] is the rollout
    /// subject: a stable pseudonymous id (never an email or other personal
    /// data); nil uses the installation id. Before `initialize` every
    /// feature is allowed (`source: .failureMode`).
    public func evaluate(featureKey: String, subject: String? = nil) -> EmergencyDecision {
        evaluateWithPolicy(featureKey: featureKey, subject: subject).0
    }

    /// True only when the decision's action is ALLOW.
    @objc(isFeatureAllowed:subject:)
    public func isFeatureAllowed(_ featureKey: String, subject: String? = nil) -> Bool {
        evaluate(featureKey: featureKey, subject: subject).allowed
    }

    /// The policy behind the current decision for [featureKey]; nil when no
    /// policy applies (ALLOW, a failure mode or replay).
    public func getPolicy(_ featureKey: String, subject: String? = nil) -> EmergencyPolicy? {
        evaluateWithPolicy(featureKey: featureKey, subject: subject).1
    }

    private func evaluateWithPolicy(featureKey: String, subject: String?) -> (EmergencyDecision, EmergencyPolicy?) {
        if let r = current { return r.evaluate(featureKey: featureKey, subject: subject) }
        if ReplayGate.replayURL() != nil || BugCapsuleSession.current?.isReplaying == true {
            return (EmergencyDecision(featureKey: featureKey, allowed: true, action: .allow, source: .replay), nil)
        }
        let warn = lock.locked { () -> Bool in
            defer { warnedUninitialized = true }
            return !warnedUninitialized
        }
        if warn {
            BugCapsuleLog.warn("emergency: evaluate called before BugCapsule.emergency.initialize; every feature is allowed")
        }
        return (EmergencyRuntime.unavailable(featureKey, allowed: true), nil)
    }

    // MARK: refresh and state

    /// Fetches policies now (joining a fetch in flight). Runs even after the
    /// credential was refused. Does nothing before `initialize` or in replay.
    public func refreshPolicies() async {
        await current?.refresh(.manual)
    }

    /// §7.5: document state, revision, last fetch and error.
    public var status: EmergencyStatus { current?.status() ?? .notInitialized }

    /// The current verified document.
    public var snapshot: EmergencySnapshot {
        current?.snapshot() ?? EmergencySnapshot(current: nil, nowMs: 0)
    }

    /// Snapshots published after `initialize` and after every accepted
    /// document, from now on.
    public var changes: AsyncStream<EmergencySnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            lock.locked { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = self.lock.locked { self.continuations.removeValue(forKey: id) }
            }
        }
    }

    /// Calls [handler] on the main thread with each published snapshot,
    /// until the returned observation is cancelled or released.
    public func observe(_ handler: @escaping @MainActor @Sendable (EmergencySnapshot) -> Void) -> EmergencyObservation {
        let id = UUID()
        lock.locked { handlers[id] = handler }
        return EmergencyObservation { [weak self] in
            guard let self else { return }
            _ = self.lock.locked { self.handlers.removeValue(forKey: id) }
        }
    }

    /// After the swap, off every lock; each handler is its own main-queue
    /// block, so one observer cannot hold up another or the client.
    private func publish(_ snapshot: EmergencySnapshot) {
        let (hs, cs) = lock.locked { (Array(handlers.values), Array(continuations.values)) }
        for c in cs { c.yield(snapshot) }
        for h in hs {
            DispatchQueue.main.async { MainActor.assumeIsolated { h(snapshot) } }
        }
    }

    /// `BugCapsule.start` resolved its connection: the first fetch can use it.
    func sessionDidStart() {
        guard let r = current else { return }
        Task { await r.onSessionStarted() }
    }

    /// Forgets the client, observers and streams (tests). Files stay.
    public func resetForTesting() async {
        let (r, cs) = lock.locked { () -> (EmergencyRuntime?, [AsyncStream<EmergencySnapshot>.Continuation]) in
            let r = runtime
            let cs = Array(continuations.values)
            runtime = nil
            handlers = [:]
            continuations = [:]
            warnedUninitialized = false
            return (r, cs)
        }
        r?.dispose()
        for c in cs { c.finish() }
    }

    var runtimeForTesting: EmergencyRuntime? { current }

    // MARK: Objective-C

    /// Objective-C: `[BCEmergency.sharedInstance initializeWithConfiguration:config]`.
    @objc(initializeWithConfiguration:)
    public func initialize(_ configuration: EmergencyConfigurationObject) {
        initialize(configuration.swiftValue)
    }

    /// Objective-C: the decision as an object.
    @objc(evaluateFeatureKey:subject:)
    public func decisionObject(featureKey: String, subject: String?) -> EmergencyDecisionObject {
        EmergencyDecisionObject(evaluate(featureKey: featureKey, subject: subject))
    }

    /// Objective-C: `refreshPolicies()` with a completion on the main thread.
    @objc(refreshPoliciesWithCompletion:)
    public func refreshPolicies(completion: (@Sendable () -> Void)?) {
        Task {
            await refreshPolicies()
            if let completion { DispatchQueue.main.async { completion() } }
        }
    }

    /// Objective-C: calls [block] on the main thread after each published
    /// snapshot. Keep the returned observation: releasing it cancels.
    @objc(observeChanges:)
    public func observeChanges(_ block: @escaping @Sendable () -> Void) -> EmergencyObservation {
        observe { _ in block() }
    }

    /// Objective-C: `none`, `usable` or `expired`.
    @objc public var stateName: String { status.state.rawValue }
}

// MARK: - Objective-C types

/// Objective-C counterpart of `EmergencyAction`.
@objc(BCEmergencyAction)
public enum EmergencyObjCAction: Int, Sendable {
    case allow, block, readOnly, requireUpdate, showMaintenance, disableFeature, useSafeFallback

    init(_ a: EmergencyAction) {
        switch a {
        case .allow: self = .allow
        case .block: self = .block
        case .readOnly: self = .readOnly
        case .requireUpdate: self = .requireUpdate
        case .showMaintenance: self = .showMaintenance
        case .disableFeature: self = .disableFeature
        case .useSafeFallback: self = .useSafeFallback
        }
    }
}

/// Objective-C counterpart of `EmergencyFailureMode`.
@objc(BCEmergencyFailureMode)
public enum EmergencyObjCFailureMode: Int, Sendable {
    case failOpen, failClosed, useLastValidPolicy

    var swiftValue: EmergencyFailureMode {
        switch self {
        case .failOpen: return .failOpen
        case .failClosed: return .failClosed
        case .useLastValidPolicy: return .useLastValidPolicy
        }
    }
}

/// Objective-C counterpart of `EmergencyConfiguration`.
@objc(BCEmergencyConfiguration)
public final class EmergencyConfigurationObject: NSObject, @unchecked Sendable {
    @objc public var trustAnchor: String
    @objc public var environment: String = "production"
    @objc public var refreshInterval: TimeInterval = 60
    /// SDK token; nil uses `backendURL` + `ingestKey`, else `BugCapsule.start`'s connection.
    @objc public var token: String?
    @objc public var backendURL: String?
    @objc public var ingestKey: String?
    @objc public var appVersion: String?
    /// The App Store update adapter; nil: none.
    @objc public var updateProvider: AppStoreUpdateProvider?
    private var modes: [String: EmergencyFailureMode] = [:]

    @objc(initWithTrustAnchor:)
    public init(trustAnchor: String) {
        self.trustAnchor = trustAnchor
    }

    /// [key]: an exact feature key or `prefix.*`.
    @objc(setFailureMode:forKey:)
    public func setFailureMode(_ mode: EmergencyObjCFailureMode, forKey key: String) {
        modes[key] = mode.swiftValue
    }

    var swiftValue: EmergencyConfiguration {
        var backend: BugCapsuleBackendConfig?
        if let backendURL, let ingestKey { backend = BugCapsuleBackendConfig(url: backendURL, ingestKey: ingestKey) }
        return EmergencyConfiguration(
            trustAnchor: trustAnchor, environment: environment, refreshInterval: refreshInterval, failureModes: modes,
            token: token, backend: backend, appVersion: appVersion, updateProvider: updateProvider)
    }
}

/// Objective-C counterpart of `EmergencyDecision`.
@objc(BCEmergencyDecision)
public final class EmergencyDecisionObject: NSObject, @unchecked Sendable {
    public let decision: EmergencyDecision

    init(_ decision: EmergencyDecision) {
        self.decision = decision
    }

    @objc public var featureKey: String { decision.featureKey }
    @objc public var allowed: Bool { decision.allowed }
    @objc public var action: EmergencyObjCAction { EmergencyObjCAction(decision.action) }
    /// The action as on the wire (`BLOCK`, …).
    @objc public var actionName: String { decision.action.rawValue }
    @objc public var reasonCode: String? { decision.reasonCode }
    @objc public var policyId: String? { decision.policyId }
    @objc public var policyRevision: NSNumber? { decision.policyRevision.map { NSNumber(value: $0) } }
    @objc public var documentRevision: NSNumber? { decision.documentRevision.map { NSNumber(value: $0) } }
    @objc public var publicUserMessage: String? { decision.publicUserMessage }
    @objc public var requiredVersion: String? { decision.requiredVersion }
    @objc public var fallback: String? { decision.fallback }
    @objc public var fallbackAvailable: Bool { decision.fallbackAvailable }
    /// `policy`, `stale_policy`, `failure_mode` or `replay`.
    @objc public var source: String { decision.source.rawValue }
}
