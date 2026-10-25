import Foundation

/// Capture config the backend can change at runtime (kill switch,
/// sampling, bodies, redaction) and the monitoring fields of
/// monitoring-v1 §10 (nil: the backend did not send the field, the app's
/// option applies).
public struct RemoteCaptureConfig: Sendable, Equatable {
    public var enabled: Bool
    public var sampleRate: Double
    public var maxCapsuleBytes: Int
    public var captureNetworkBodies: Bool
    public var redactKeys: [String]
    public var configTtlSeconds: Int
    /// Wall clock (epoch ms) of the successful fetch this config came from.
    public var fetchedAtMs: Int
    /// false: no envelopes are sent (capsules are unaffected).
    public var monitoringEnabled: Bool
    public var errorSampleRate: Double?
    public var tracesSampleRate: Double?
    public var sessionTracking: Bool
    public var maxBreadcrumbs: Int?
    /// When set, replaces the app's list.
    public var tracePropagationTargets: [String]?

    public init(
        enabled: Bool = true, sampleRate: Double = 1, maxCapsuleBytes: Int = 5 * 1024 * 1024,
        captureNetworkBodies: Bool = true, redactKeys: [String] = [], configTtlSeconds: Int = 300, fetchedAtMs: Int = 0,
        monitoringEnabled: Bool = true, errorSampleRate: Double? = nil, tracesSampleRate: Double? = nil,
        sessionTracking: Bool = true, maxBreadcrumbs: Int? = nil, tracePropagationTargets: [String]? = nil
    ) {
        self.enabled = enabled
        self.sampleRate = sampleRate
        self.maxCapsuleBytes = maxCapsuleBytes
        self.captureNetworkBodies = captureNetworkBodies
        self.redactKeys = redactKeys
        self.configTtlSeconds = configTtlSeconds
        self.fetchedAtMs = fetchedAtMs
        self.monitoringEnabled = monitoringEnabled
        self.errorSampleRate = errorSampleRate
        self.tracesSampleRate = tracesSampleRate
        self.sessionTracking = sessionTracking
        self.maxBreadcrumbs = maxBreadcrumbs
        self.tracePropagationTargets = tracePropagationTargets
    }

    public struct FormatError: Error, Sendable { public let message: String }

    /// Parses the `/v1/sdk/config` body (or the cache). Throws on wrong
    /// types; values are clamped to sane ranges.
    public init(json j: JSONObject, fetchedAtMs: Int? = nil) throws {
        func check(_ key: String, _ ok: (JSONValue) -> Bool) throws {
            if let v = j[key], !v.isNull, !ok(v) { throw FormatError(message: "remote config \"\(key)\" has the wrong type") }
        }
        try check("sampleRate") { $0.isNumber }
        try check("configTtlSeconds") { $0.intValue != nil }
        try check("maxCapsuleBytes") { $0.intValue != nil }
        try check("enabled") { $0.boolValue != nil }
        try check("captureNetworkBodies") { $0.boolValue != nil }
        try check("redactKeys") { $0.arrayValue != nil }
        try check("fetchedAtMs") { $0.intValue != nil }
        try check("monitoringEnabled") { $0.boolValue != nil }
        try check("errorSampleRate") { $0.isNumber }
        try check("tracesSampleRate") { $0.isNumber }
        try check("sessionTracking") { $0.boolValue != nil }
        try check("maxBreadcrumbs") { $0.intValue != nil }
        try check("tracePropagationTargets") { $0.arrayValue != nil }
        func unit(_ key: String) -> Double? {
            guard let d = j[key]?.doubleValue else { return nil }
            return d.isNaN ? 0 : min(max(d, 0), 1)
        }
        let rate = j["sampleRate"]?.doubleValue ?? 1
        enabled = j["enabled"]?.boolValue ?? true
        sampleRate = rate.isNaN ? 0 : min(max(rate, 0), 1)
        maxCapsuleBytes = max(j["maxCapsuleBytes"]?.intValue ?? 5 * 1024 * 1024, 1)
        captureNetworkBodies = j["captureNetworkBodies"]?.boolValue ?? true
        redactKeys = (j["redactKeys"]?.arrayValue ?? []).map { $0.stringValue ?? JSON.encode($0) }
        configTtlSeconds = min(max(j["configTtlSeconds"]?.intValue ?? 300, 0), 86400)
        self.fetchedAtMs = fetchedAtMs ?? j["fetchedAtMs"]?.intValue ?? 0
        monitoringEnabled = j["monitoringEnabled"]?.boolValue ?? true
        errorSampleRate = unit("errorSampleRate")
        tracesSampleRate = unit("tracesSampleRate")
        sessionTracking = j["sessionTracking"]?.boolValue ?? true
        maxBreadcrumbs = j["maxBreadcrumbs"]?.intValue.map { min(max($0, 0), 1000) }
        tracePropagationTargets = j["tracePropagationTargets"]?.arrayValue?.compactMap(\.stringValue)
    }

    public var json: JSONValue {
        var o: JSONObject = [
            "enabled": .bool(enabled), "sampleRate": .double(sampleRate), "maxCapsuleBytes": .int(maxCapsuleBytes),
            "captureNetworkBodies": .bool(captureNetworkBodies), "redactKeys": .array(redactKeys.map { .string($0) }),
            "configTtlSeconds": .int(configTtlSeconds), "fetchedAtMs": .int(fetchedAtMs),
            "monitoringEnabled": .bool(monitoringEnabled), "sessionTracking": .bool(sessionTracking),
        ]
        if let errorSampleRate { o["errorSampleRate"] = .double(errorSampleRate) }
        if let tracesSampleRate { o["tracesSampleRate"] = .double(tracesSampleRate) }
        if let maxBreadcrumbs { o["maxBreadcrumbs"] = .int(maxBreadcrumbs) }
        if let tracePropagationTargets { o["tracePropagationTargets"] = .array(tracePropagationTargets.map { .string($0) }) }
        return .object(o)
    }
}

/// Where the last good config is persisted between launches.
public protocol RemoteConfigCache: Sendable {
    /// The cached config for `scope`, or nil (missing, corrupt, other scope).
    func read(scope: String) -> RemoteCaptureConfig?
    func write(scope: String, config: RemoteCaptureConfig) throws
}

/// A failed `GET /v1/sdk/config` (the last one is kept for status and support).
public struct ConfigFetchFailure: Sendable, Equatable {
    public var message: String
    /// HTTP status; nil for a network error or timeout.
    public var status: Int?
    public var retryAfter: TimeInterval?
    /// The backend's refusal reason (`token_revoked`, `token_expired`, `token_unknown`, ...).
    public var reason: String?
    /// What to do about it, from the backend.
    public var detail: String?

    public init(message: String, status: Int? = nil, retryAfter: TimeInterval? = nil, reason: String? = nil, detail: String? = nil) {
        self.message = message
        self.status = status
        self.retryAfter = retryAfter
        self.reason = reason
        self.detail = detail
    }

    /// The backend refused the credential.
    public var isRefusal: Bool { status == 401 || status == 403 }

    /// Not reachable or not answering usefully: retried with backoff, never fatal.
    public var isOffline: Bool {
        guard let status else { return true }
        return status >= 500 || status == 429 || status == 408
    }
}

/// Keeps the remote capture config current and decides what it allows
/// (port of `remote_config.dart`).
///
/// * Startup: `loadCached` restores the last config for this backend URL and
///   ingest key (`scope`). A cached kill switch applies however old it is.
/// * Refresh: next fetch after the config's TTL (at least `minInterval`,
///   30 s); after a failure, backoff 30 s → 30 min with ±20 % jitter,
///   honouring `Retry-After`. `onResumed` refreshes a stale config.
/// * Uploads are allowed only with an enabled config fetched within `maxStale`.
/// * 401/403 acts like a kill switch for the session (not persisted);
///   `onRejected` is called once per refusal with the backend's reason.
public actor RemoteConfigController {
    public typealias OnChange = @Sendable (RemoteCaptureConfig?, RemoteCaptureConfig) -> Void
    public typealias OnRejected = @Sendable (ConfigFetchFailure) -> Void

    private let fetch: @Sendable () async -> ConfigFetchResult
    private let cache: RemoteConfigCache
    public let scope: String
    private let onChange: OnChange
    public let maxStale: TimeInterval
    public let minInterval: TimeInterval
    public let maxBackoff: TimeInterval
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double
    private let autoSchedule: Bool
    private let onRejected: OnRejected?

    public private(set) var current: RemoteCaptureConfig?
    public private(set) var keyRejected = false
    /// The last failed fetch; nil after a successful one.
    public private(set) var lastFailure: ConfigFetchFailure?
    /// When a config was last fetched in this run (not from the cache).
    public private(set) var fetchedThisSession: Date?
    private var failures = 0
    private var timer: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?
    private var paused = false
    private var disposed = false
    /// Delay of the last scheduled refresh (tests).
    public private(set) var scheduledDelay: TimeInterval?

    public init(
        fetch: @escaping @Sendable () async -> ConfigFetchResult, cache: RemoteConfigCache, scope: String,
        onChange: @escaping OnChange, maxStale: TimeInterval = 7 * 24 * 3600, minInterval: TimeInterval = 30,
        maxBackoff: TimeInterval = 1800, now: @escaping @Sendable () -> Date = { Date() },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }, autoSchedule: Bool = true,
        initial: RemoteCaptureConfig? = nil, onRejected: OnRejected? = nil
    ) {
        current = initial
        self.onRejected = onRejected
        self.fetch = fetch
        self.cache = cache
        self.scope = scope
        self.onChange = onChange
        self.maxStale = maxStale
        self.minInterval = minInterval
        self.maxBackoff = maxBackoff
        self.now = now
        self.random = random
        self.autoSchedule = autoSchedule
    }

    /// Cache scope: one per backend URL and ingest key (FNV-1a 64).
    public static func scope(for backend: BugCapsuleBackendConfig?) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in "\(backend?.url ?? "")|\(backend?.ingestKey ?? "")".utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return String(h, radix: 16)
    }

    var ttl: TimeInterval { max(TimeInterval(current?.configTtlSeconds ?? 0), minInterval) }

    public var age: TimeInterval? {
        guard let current else { return nil }
        return now().timeIntervalSince1970 - TimeInterval(current.fetchedAtMs) / 1000
    }

    public var isFresh: Bool {
        guard let age else { return false }
        return age < ttl
    }

    public var captureAllowed: Bool { !keyRejected && (current?.enabled ?? true) }

    public var uploadsAllowed: Bool {
        guard !keyRejected, let current, current.enabled, let age else { return false }
        return age <= maxStale
    }

    public func loadCached() {
        current = cache.read(scope: scope)
    }

    /// Fetches now unless a fetch is already running (then waits for it).
    public func refresh() async {
        if disposed { return }
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { await self.doRefresh() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// Refreshes first when the config is missing or older than its TTL.
    public func ensureFresh() async {
        if !isFresh { await refresh() }
    }

    private func doRefresh() async {
        timer?.cancel()
        let result = await fetch()
        if disposed { return }
        switch result {
        case .fetched(let config):
            failures = 0
            lastFailure = nil
            fetchedThisSession = now()
            let previous = current
            current = config
            keyRejected = false
            do {
                try cache.write(scope: scope, config: config)
            } catch {
                BugCapsuleLog.warn("could not cache remote config: \(error)")
            }
            onChange(previous, config)
            schedule(ttl)
        case .failed(let message, let status, let retryAfter, let reason, let detail):
            failures += 1
            let failure = ConfigFetchFailure(message: message, status: status, retryAfter: retryAfter, reason: reason, detail: detail)
            lastFailure = failure
            if failure.isRefusal && !keyRejected {
                keyRejected = true
                if let onRejected {
                    onRejected(failure)
                } else {
                    BugCapsuleLog.warn(
                        "ingest key rejected (\(reason ?? "HTTP \(status!)")); capture stopped: \(detail ?? message)")
                }
                let previous = current
                onChange(previous, Self.disabledLike(previous))
            }
            var delay = min(minInterval * pow(2, Double(min(failures - 1, 16))), maxBackoff)
            if let retryAfter, retryAfter > delay { delay = retryAfter }
            schedule(delay * (0.8 + random() * 0.4))
        }
    }

    static func disabledLike(_ c: RemoteCaptureConfig?) -> RemoteCaptureConfig {
        RemoteCaptureConfig(
            enabled: false, sampleRate: c?.sampleRate ?? 0, maxCapsuleBytes: c?.maxCapsuleBytes ?? 0,
            captureNetworkBodies: false, redactKeys: c?.redactKeys ?? [], configTtlSeconds: c?.configTtlSeconds ?? 0,
            fetchedAtMs: c?.fetchedAtMs ?? 0, monitoringEnabled: false)
    }

    private func schedule(_ delay: TimeInterval) {
        timer?.cancel()
        timer = nil
        scheduledDelay = delay
        if disposed || paused || !autoSchedule { return }
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.refresh()
        }
    }

    public func onPaused() {
        paused = true
        timer?.cancel()
        timer = nil
    }

    public func onResumed() async {
        if !paused || disposed { return }
        paused = false
        if inFlight != nil { return }
        if isFresh, let age {
            schedule(ttl - age)
        } else {
            await refresh()
        }
    }

    public func dispose() {
        disposed = true
        timer?.cancel()
        timer = nil
    }
}
