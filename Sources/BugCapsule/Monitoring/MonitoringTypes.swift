import Foundation

/// Event severity (monitoring-v1 §2).
public enum MonitoringLevel: String, Sendable, CaseIterable {
    case fatal, error, warning, info, debug
}

/// The user an event, session or feedback belongs to.
public struct BugCapsuleUser: Sendable, Equatable {
    public var id: String?
    public var email: String?
    public var username: String?
    /// `"{{auto}}"` lets the server fill it from the connection (only kept
    /// when the project stores IP addresses).
    public var ipAddress: String?
    public var segment: String?
    public var data: JSONObject?

    public init(
        id: String? = nil, email: String? = nil, username: String? = nil, ipAddress: String? = nil,
        segment: String? = nil, data: JSONObject? = nil
    ) {
        self.id = id
        self.email = email
        self.username = username
        self.ipAddress = ipAddress
        self.segment = segment
        self.data = data
    }

    var json: JSONValue {
        var o = JSONObject()
        if let id { o["id"] = .string(id.dartPrefix(200)) }
        if let email { o["email"] = .string(email.dartPrefix(200)) }
        if let username { o["username"] = .string(username.dartPrefix(200)) }
        if let ipAddress { o["ipAddress"] = .string(ipAddress.dartPrefix(64)) }
        if let segment { o["segment"] = .string(segment.dartPrefix(200)) }
        if let data { o["data"] = .object(data) }
        return .object(o)
    }
}

/// A trail entry attached to events (newest last). The SDK derives them
/// from what the flight recorder sees (route, action, http, lifecycle, log,
/// state, failure); apps add their own with `BugCapsule.addBreadcrumb`.
public struct Breadcrumb: Sendable, Equatable {
    /// `default`, `http`, `navigation`, `user`, `ui`, `error`, `debug`,
    /// `info`, `query`, `state`.
    public var type: String
    public var category: String?
    public var message: String?
    public var level: MonitoringLevel
    public var data: JSONObject?
    public var timestamp: Date

    public init(
        type: String = "default", category: String? = nil, message: String? = nil, level: MonitoringLevel = .info,
        data: JSONObject? = nil, timestamp: Date = Date()
    ) {
        self.type = type
        self.category = category
        self.message = message
        self.level = level
        self.data = data
        self.timestamp = timestamp
    }

    var json: JSONValue {
        [
            "timestamp": .string(ISODate.format(timestamp)), "type": .string(type),
            "category": category.map { .string($0.dartPrefix(200)) } ?? .null,
            "message": message.map { .string($0.dartPrefix(8192)) } ?? .null, "level": .string(level.rawValue),
            "data": data.map { .object($0) } ?? .null,
        ]
    }
}

/// An error/message event as it will be sent (monitoring-v1 §2). The
/// payload is the wire JSON; the accessors cover the fields apps usually
/// change in `beforeSend`.
public struct MonitoringEvent: Sendable, Equatable {
    public var payload: JSONObject

    public init(payload: JSONObject) { self.payload = payload }

    public var eventId: String { payload["eventId"]?.stringValue ?? "" }

    public var level: MonitoringLevel {
        get { MonitoringLevel(rawValue: payload["level"]?.stringValue ?? "") ?? .error }
        set { payload["level"] = .string(newValue.rawValue) }
    }

    public var tags: [String: String] {
        get {
            var out: [String: String] = [:]
            for (k, v) in payload["tags"]?.objectValue ?? JSONObject() { out[k] = v.stringValue }
            return out
        }
        set {
            var o = JSONObject()
            for k in newValue.keys.sorted() { o[k] = .string(newValue[k]!) }
            payload["tags"] = .object(o)
        }
    }

    public var fingerprint: [String]? {
        get { payload["fingerprint"]?.arrayValue?.compactMap(\.stringValue) }
        set { payload["fingerprint"] = newValue.map { .array($0.map { .string($0) }) } ?? .null }
    }

    public var extra: JSONObject {
        get { payload["extra"]?.objectValue ?? JSONObject() }
        set { payload["extra"] = .object(newValue) }
    }

    /// `type` of the last (outermost) exception value.
    public var exceptionType: String? { payload["exception"]?["values"]?.arrayValue?.last?["type"]?.stringValue }
    public var exceptionValue: String? { payload["exception"]?["values"]?.arrayValue?.last?["value"]?.stringValue }
    public var message: String? { payload["message"]?["formatted"]?.stringValue }
    public var capsuleId: String? { payload["capsuleId"]?.stringValue }
}

/// What the event was built from (for `beforeSend`).
public struct EventHint: @unchecked Sendable {
    public var error: Error?
    public var exception: NSException?
    /// `true` for crashes from the previous launch (sent on this launch).
    public var fromPreviousLaunch: Bool

    public init(error: Error? = nil, exception: NSException? = nil, fromPreviousLaunch: Bool = false) {
        self.error = error
        self.exception = exception
        self.fromPreviousLaunch = fromPreviousLaunch
    }
}

/// Input of `tracesSampler`.
public struct SamplingContext: Sendable {
    public var name: String
    public var op: String
    /// The decision of the incoming trace (`continueTrace`), if any.
    public var parentSampled: Bool?
}

/// Options for `captureException`.
public struct CaptureOptions: Sendable {
    public var level: MonitoringLevel?
    public var tags: [String: String]
    public var extra: JSONObject
    public var fingerprint: [String]?
    public var contexts: JSONObject

    public init(
        level: MonitoringLevel? = nil, tags: [String: String] = [:], extra: JSONObject = JSONObject(),
        fingerprint: [String]? = nil, contexts: JSONObject = JSONObject()
    ) {
        self.level = level
        self.tags = tags
        self.extra = extra
        self.fingerprint = fingerprint
        self.contexts = contexts
    }
}

/// Monitoring options (monitoring-v1 §11). Every signal can be turned off;
/// `enabled: false` turns off everything in the monitoring contract
/// (capsules are unaffected).
public struct BugCapsuleMonitoringOptions: @unchecked Sendable {
    public var enabled: Bool
    /// Default `<app id>@<version>+<build>`.
    public var release: String?
    /// Default from the capture mode: `production`, `qa`, `development` (debug).
    public var environment: String?
    public var dist: String?
    /// Share of error events sent (fatal and capsule-linked events always are).
    /// The remote `errorSampleRate` replaces it once fetched.
    public var errorSampleRate: Double
    /// nil: the remote `tracesSampleRate` (default 0).
    public var tracesSampleRate: Double?
    /// Decides per root transaction; overrides both rates. Return nil to
    /// fall back to the rate.
    public var tracesSampler: (@Sendable (SamplingContext) -> Double?)?
    /// URLs that get `traceparent` / `baggage`: substrings, or `/regex/`.
    /// The remote list replaces it when set.
    public var tracePropagationTargets: [String]
    public var enableAutoSessionTracking: Bool
    /// A foreground run ends after this long in the background.
    public var sessionTimeout: TimeInterval
    public var maxBreadcrumbs: Int
    public var beforeSend: (@Sendable (MonitoringEvent, EventHint) -> MonitoringEvent?)?
    public var beforeSendTransaction: (@Sendable (JSONObject) -> JSONObject?)?
    public var beforeBreadcrumb: (@Sendable (Breadcrumb) -> Breadcrumb?)?
    /// Image name prefixes (e.g. an embedded framework) whose frames are in-app.
    public var inAppIncludes: [String]
    public var inAppExcludes: [String]
    /// Attach the call stack to `captureMessage` events.
    public var attachStacktrace: Bool
    /// false: no IP address (`{{auto}}`) is requested for the user.
    public var sendDefaultPii: Bool
    public var enableAppHangTracking: Bool
    public var appHangTimeout: TimeInterval
    /// Signals and Mach exceptions (reported on the next launch).
    public var enableNativeCrashHandling: Bool
    /// Mach exception server in addition to signal handlers (skipped while a
    /// debugger is attached).
    public var enableMachExceptionHandling: Bool
    public var enableUserInteractionTracing: Bool
    public var enableAppStartTracking: Bool
    public var enableFramesTracking: Bool
    /// `ui.load` transactions for screens shown through observed navigation
    /// controllers and `.bugCapsuleScreen(_:)`.
    public var enableScreenTracing: Bool
    /// Screen transactions wait for `BugCapsule.reportFullyDisplayed()`.
    public var enableTimeToFullDisplayTracing: Bool
    /// `http.client` spans and trace propagation for instrumented URLSessions.
    public var enableNetworkTracing: Bool
    /// Shake the device to open the feedback form (`BugCapsuleWindow` or
    /// `BugCapsule.handleShake()`).
    public var enableShakeToReport: Bool
    /// Feedback from the form also writes a capsule (nil: true in `qa` mode).
    public var captureCapsuleWithFeedback: Bool?
    /// Envelope outbox bounds (30 envelopes / 5 MiB / 7 days).
    public var outboxLimits: OutboxLimits

    public init(
        enabled: Bool = true, release: String? = nil, environment: String? = nil, dist: String? = nil,
        errorSampleRate: Double = 1, tracesSampleRate: Double? = nil,
        tracesSampler: (@Sendable (SamplingContext) -> Double?)? = nil, tracePropagationTargets: [String] = [],
        enableAutoSessionTracking: Bool = true, sessionTimeout: TimeInterval = 30, maxBreadcrumbs: Int = 100,
        beforeSend: (@Sendable (MonitoringEvent, EventHint) -> MonitoringEvent?)? = nil,
        beforeSendTransaction: (@Sendable (JSONObject) -> JSONObject?)? = nil,
        beforeBreadcrumb: (@Sendable (Breadcrumb) -> Breadcrumb?)? = nil, inAppIncludes: [String] = [],
        inAppExcludes: [String] = [], attachStacktrace: Bool = true, sendDefaultPii: Bool = false,
        enableAppHangTracking: Bool = true, appHangTimeout: TimeInterval = 2, enableNativeCrashHandling: Bool = true,
        enableMachExceptionHandling: Bool = true, enableUserInteractionTracing: Bool = true,
        enableAppStartTracking: Bool = true, enableFramesTracking: Bool = true, enableScreenTracing: Bool = true,
        enableTimeToFullDisplayTracing: Bool = false, enableNetworkTracing: Bool = true,
        enableShakeToReport: Bool = false, captureCapsuleWithFeedback: Bool? = nil,
        outboxLimits: OutboxLimits = OutboxLimits(maxCount: 30, maxBytes: 5 * 1024 * 1024)
    ) {
        self.enabled = enabled
        self.release = release
        self.environment = environment
        self.dist = dist
        self.errorSampleRate = errorSampleRate
        self.tracesSampleRate = tracesSampleRate
        self.tracesSampler = tracesSampler
        self.tracePropagationTargets = tracePropagationTargets
        self.enableAutoSessionTracking = enableAutoSessionTracking
        self.sessionTimeout = sessionTimeout
        self.maxBreadcrumbs = maxBreadcrumbs
        self.beforeSend = beforeSend
        self.beforeSendTransaction = beforeSendTransaction
        self.beforeBreadcrumb = beforeBreadcrumb
        self.inAppIncludes = inAppIncludes
        self.inAppExcludes = inAppExcludes
        self.attachStacktrace = attachStacktrace
        self.sendDefaultPii = sendDefaultPii
        self.enableAppHangTracking = enableAppHangTracking
        self.appHangTimeout = appHangTimeout
        self.enableNativeCrashHandling = enableNativeCrashHandling
        self.enableMachExceptionHandling = enableMachExceptionHandling
        self.enableUserInteractionTracing = enableUserInteractionTracing
        self.enableAppStartTracking = enableAppStartTracking
        self.enableFramesTracking = enableFramesTracking
        self.enableScreenTracing = enableScreenTracing
        self.enableTimeToFullDisplayTracing = enableTimeToFullDisplayTracing
        self.enableNetworkTracing = enableNetworkTracing
        self.enableShakeToReport = enableShakeToReport
        self.captureCapsuleWithFeedback = captureCapsuleWithFeedback
        self.outboxLimits = outboxLimits
    }

    /// Everything in the monitoring contract off.
    public static var disabled: BugCapsuleMonitoringOptions { BugCapsuleMonitoringOptions(enabled: false) }
}
