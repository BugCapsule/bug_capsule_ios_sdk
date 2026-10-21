import Foundation

/// Where capsules are uploaded and the remote capture config comes from.
public struct BugCapsuleBackendConfig: Sendable, Equatable {
    /// e.g. `http://127.0.0.1:8787` locally, `https://bugcapsule.example.com` hosted.
    public var url: String
    /// Project ingest key (`bci_...`). Upload-only; safe to ship in the app.
    /// Never put the secret key (`bcs_...`) in an app.
    public var ingestKey: String

    public init(url: String, ingestKey: String) {
        self.url = url
        self.ingestKey = ingestKey
    }
}

/// Bounds on the upload outbox: 10 capsules, 10 MiB, 7 days by default;
/// whichever is hit first evicts the oldest capsules.
public struct OutboxLimits: Sendable, Equatable {
    public var maxCount: Int
    public var maxBytes: Int
    public var maxAge: TimeInterval

    public init(maxCount: Int = 10, maxBytes: Int = 10 * 1024 * 1024, maxAge: TimeInterval = 7 * 24 * 3600) {
        self.maxCount = maxCount
        self.maxBytes = maxBytes
        self.maxAge = maxAge
    }
}

/// SDK configuration. Only `appVersion`/`appBuild` are required; they
/// default to the bundle's `CFBundleShortVersionString` / `CFBundleVersion`.
public struct BugCapsuleConfig: @unchecked Sendable {
    public var appVersion: String
    public var appBuild: String
    public var appId: String?
    public var appName: String?
    public var flavor: String?
    /// `nil`: `BUGCAPSULE_MODE` Info.plist key / environment, else `.debug`
    /// in DEBUG builds and `.production` otherwise.
    public var mode: CaptureMode?
    /// Local master switch. The backend kill switch can also disable capture.
    public var enabled: Bool
    public var backend: BugCapsuleBackendConfig?
    /// `nil`: the `BugCapsuleGitSHA` Info.plist key (set from the
    /// `BUGCAPSULE_GIT_SHA` build setting).
    public var gitSha: String?
    public var gitDirty: Bool?
    /// Bump when serialized state (registered state objects) changes incompatibly.
    public var stateSchemaVersion: Int
    public var checkpointInterval: TimeInterval
    /// Events older than this are evicted.
    public var window: TimeInterval
    public var maxEvents: Int
    /// Maximum fraction of production sessions that record (QA/debug always
    /// record). The backend `sampleRate` can lower it, never raise it.
    public var productionSampleRate: Double
    public var autoCaptureOnFailure: Bool
    public var maxCapsulesPerSession: Int
    public var captureNetworkBodies: Bool
    public var maxBodyBytes: Int
    public var redactKeys: [String]
    public var redactHeaders: [String]
    /// Extra free-text patterns replaced with `[REDACTED]`.
    public var redactPatterns: [NSRegularExpression]
    /// Last look at every event after built-in redaction: return the data
    /// to keep, or nil to drop the event. If it throws, the event is dropped.
    public var beforeRecord: (@Sendable (_ type: String, _ data: JSONObject) throws -> JSONObject?)?
    /// Last look at each integration's checkpoint snapshot after redaction.
    public var beforeCheckpoint: (@Sendable (_ integration: String, _ data: JSONValue) throws -> JSONValue?)?
    public var outboxLimits: OutboxLimits
    /// How old the last fetched remote config may be for uploads to proceed.
    public var maxStaleConfig: TimeInterval
    /// Return true for errors that should not count as failures.
    public var ignoreError: (@Sendable (Error) -> Bool)?
    public var labels: [String: String]
    /// Replay source for tests (DEBUG builds only). Apps get it from the UI test.
    public var replayURL: String?
    /// Error events, release health, tracing and feedback (monitoring-v1).
    /// `.disabled` turns all of it off; capsules are unaffected.
    public var monitoring: BugCapsuleMonitoringOptions

    public init(
        appVersion: String? = nil, appBuild: String? = nil, appId: String? = nil, appName: String? = nil,
        flavor: String? = nil, mode: CaptureMode? = nil, enabled: Bool = true, backend: BugCapsuleBackendConfig? = nil,
        gitSha: String? = nil, gitDirty: Bool? = nil, stateSchemaVersion: Int = 1, checkpointInterval: TimeInterval = 30,
        window: TimeInterval = 300, maxEvents: Int = 20000, productionSampleRate: Double = 0.1,
        autoCaptureOnFailure: Bool = true, maxCapsulesPerSession: Int = 3, captureNetworkBodies: Bool = true,
        maxBodyBytes: Int = 256 * 1024, redactKeys: [String] = [], redactHeaders: [String] = [],
        redactPatterns: [NSRegularExpression] = [],
        beforeRecord: (@Sendable (String, JSONObject) throws -> JSONObject?)? = nil,
        beforeCheckpoint: (@Sendable (String, JSONValue) throws -> JSONValue?)? = nil,
        outboxLimits: OutboxLimits = OutboxLimits(), maxStaleConfig: TimeInterval = 7 * 24 * 3600,
        ignoreError: (@Sendable (Error) -> Bool)? = nil, labels: [String: String] = [:], replayURL: String? = nil,
        monitoring: BugCapsuleMonitoringOptions = BugCapsuleMonitoringOptions()
    ) {
        let info = Bundle.main.infoDictionary ?? [:]
        self.appVersion = appVersion ?? (info["CFBundleShortVersionString"] as? String) ?? "0"
        self.appBuild = appBuild ?? (info["CFBundleVersion"] as? String) ?? "0"
        self.appId = appId ?? Bundle.main.bundleIdentifier
        self.appName = appName ?? (info["CFBundleName"] as? String)
        self.flavor = flavor
        self.mode = mode
        self.enabled = enabled
        self.backend = backend
        self.gitSha = gitSha
        self.gitDirty = gitDirty
        self.stateSchemaVersion = stateSchemaVersion
        self.checkpointInterval = checkpointInterval
        self.window = window
        self.maxEvents = maxEvents
        self.productionSampleRate = productionSampleRate
        self.autoCaptureOnFailure = autoCaptureOnFailure
        self.maxCapsulesPerSession = maxCapsulesPerSession
        self.captureNetworkBodies = captureNetworkBodies
        self.maxBodyBytes = maxBodyBytes
        self.redactKeys = redactKeys
        self.redactHeaders = redactHeaders
        self.redactPatterns = redactPatterns
        self.beforeRecord = beforeRecord
        self.beforeCheckpoint = beforeCheckpoint
        self.outboxLimits = outboxLimits
        self.maxStaleConfig = maxStaleConfig
        self.ignoreError = ignoreError
        self.labels = labels
        self.replayURL = replayURL
        self.monitoring = monitoring
    }

    /// The effective capture mode.
    public var resolvedMode: CaptureMode {
        if let mode { return mode }
        if let raw = (Bundle.main.object(forInfoDictionaryKey: "BugCapsuleMode") as? String)
            ?? ProcessInfo.processInfo.environment["BUGCAPSULE_MODE"],
            let m = CaptureMode(rawValue: raw.lowercased())
        {
            return m
        }
        #if DEBUG
            return .debug
        #else
            return .production
        #endif
    }

    /// `gitSha`, else the `BugCapsuleGitSHA` Info.plist key (empty or an
    /// unexpanded `$(...)` build setting means unset).
    public var resolvedGitSha: String? {
        if let gitSha, !gitSha.isEmpty { return gitSha }
        return Self.plistString("BugCapsuleGitSHA")
    }

    public var resolvedGitDirty: Bool? {
        if let gitDirty { return gitDirty }
        guard let raw = Self.plistString("BugCapsuleGitDirty") else { return nil }
        return raw.lowercased() == "true" || raw == "1" || raw.lowercased() == "yes"
    }

    static func plistString(_ key: String) -> String? {
        guard let v = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.hasPrefix("$(") { return nil }
        return t
    }
}

/// Replaces storage, transport, randomness and clocks in tests.
public struct BugCapsuleTestOverrides: @unchecked Sendable {
    public var storageDirectory: URL?
    public var transport: BugCapsuleTransport?
    public var random: (@Sendable () -> Double)?
    public var captureSettleDelay: TimeInterval?

    public init(
        storageDirectory: URL? = nil, transport: BugCapsuleTransport? = nil, random: (@Sendable () -> Double)? = nil,
        captureSettleDelay: TimeInterval? = nil
    ) {
        self.storageDirectory = storageDirectory
        self.transport = transport
        self.random = random
        self.captureSettleDelay = captureSettleDelay
    }
}
