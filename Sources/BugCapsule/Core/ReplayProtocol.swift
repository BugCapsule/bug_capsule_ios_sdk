import Foundation

/// Replay protocol v1.1 between the `bugcapsule` CLI and the app
/// (runtimes-v1 §10).
public enum ReplayProtocol {
    public static let envURL = "BUGCAPSULE_REPLAY_URL"
    /// Launch argument the `BugCapsuleXCTest` helper adds; replay arms only
    /// when it is present (and only in DEBUG builds).
    public static let launchArgument = "-BugCapsuleReplay"
    public static let capsulePath = "/capsule"
    public static let settingsPath = "/settings"
    public static let resultPath = "/result"
    public static let stdoutPrefix = "BUGCAPSULE_RESULT::"
    /// Accessibility identifier of the element carrying the report for the UI test.
    public static let resultAccessibilityId = "bugcapsule.replay.result"
}

public enum ReplayStrategy: String, Sendable {
    case auto, pointer, semantic
}

public struct ReplaySettings: Sendable, Equatable {
    public var strategy: ReplayStrategy
    public var settleTimeoutMs: Int
    public var attempt: Int
    public var kind: String
    public var strictNetwork: Bool
    public var idleCompression: Bool
    public var attemptId: String?
    public var runtime: String?

    public init(
        strategy: ReplayStrategy = .auto, settleTimeoutMs: Int = 8000, attempt: Int = 1, kind: String = "replay",
        strictNetwork: Bool = true, idleCompression: Bool = true, attemptId: String? = nil, runtime: String? = nil
    ) {
        self.strategy = strategy
        self.settleTimeoutMs = settleTimeoutMs
        self.attempt = attempt
        self.kind = kind
        self.strictNetwork = strictNetwork
        self.idleCompression = idleCompression
        self.attemptId = attemptId
        self.runtime = runtime
    }

    public init(json j: JSONObject) {
        strategy = ReplayStrategy(rawValue: j["strategy"]?.stringValue ?? "auto") ?? .auto
        settleTimeoutMs = j["settleTimeoutMs"]?.intValue ?? 8000
        attempt = j["attempt"]?.intValue ?? 1
        kind = j["kind"]?.stringValue ?? "replay"
        strictNetwork = j["strictNetwork"]?.boolValue ?? true
        idleCompression = j["idleCompression"]?.boolValue ?? true
        attemptId = j["attemptId"]?.stringValue
        runtime = j["runtime"]?.stringValue
    }

    public var json: JSONValue {
        var o: JSONObject = [
            "strategy": .string(strategy.rawValue), "settleTimeoutMs": .int(settleTimeoutMs), "attempt": .int(attempt),
            "kind": .string(kind), "strictNetwork": .bool(strictNetwork), "idleCompression": .bool(idleCompression),
        ]
        if let attemptId { o["attemptId"] = .string(attemptId) }
        if let runtime { o["runtime"] = .string(runtime) }
        return .object(o)
    }
}

public enum ReplayOutcome: String, Sendable {
    case reproduced
    case notReproduced = "not_reproduced"
    case incompatible
    case noAssertion = "no_assertion"
    case error
}

public struct Divergence: Sendable, Equatable {
    public var type: String
    public var detail: String
    public var t: Int?

    public init(_ type: String, _ detail: String, t: Int? = nil) {
        self.type = type
        self.detail = detail
        self.t = t
    }

    public var json: JSONValue {
        var o: JSONObject = ["type": .string(type), "detail": .string(detail)]
        if let t { o["t"] = .int(t) }
        return .object(o)
    }
}

public struct ReplayReport: Sendable, Equatable {
    public var outcome: ReplayOutcome
    public var attempt: Int
    public var durationMs: Int
    public var strategy: ReplayStrategy
    public var expectedSignature: String?
    public var observed: FailureRecord?
    public var otherFailures: [FailureRecord]
    public var divergences: [Divergence]
    public var eventsDispatched: Int
    public var eventsExpected: Int?
    public var fixturesServed: Int
    public var compressedMs: Int
    public var gapsCompressed: Int
    public var buildGitSha: String?
    public var message: String?
    public var attemptId: String?
    public var runtime: String?

    public init(
        outcome: ReplayOutcome, attempt: Int, durationMs: Int, strategy: ReplayStrategy,
        expectedSignature: String? = nil, observed: FailureRecord? = nil, otherFailures: [FailureRecord] = [],
        divergences: [Divergence] = [], eventsDispatched: Int = 0, eventsExpected: Int? = nil,
        fixturesServed: Int = 0, compressedMs: Int = 0, gapsCompressed: Int = 0, buildGitSha: String? = nil,
        message: String? = nil, attemptId: String? = nil, runtime: String? = nil
    ) {
        self.outcome = outcome
        self.attempt = attempt
        self.durationMs = durationMs
        self.strategy = strategy
        self.expectedSignature = expectedSignature
        self.observed = observed
        self.otherFailures = otherFailures
        self.divergences = divergences
        self.eventsDispatched = eventsDispatched
        self.eventsExpected = eventsExpected
        self.fixturesServed = fixturesServed
        self.compressedMs = compressedMs
        self.gapsCompressed = gapsCompressed
        self.buildGitSha = buildGitSha
        self.message = message
        self.attemptId = attemptId
        self.runtime = runtime
    }

    public init(json j: JSONObject) {
        outcome = ReplayOutcome(rawValue: j["outcome"]?.stringValue ?? "") ?? .error
        attempt = j["attempt"]?.intValue ?? 1
        durationMs = j["durationMs"]?.intValue ?? 0
        strategy = ReplayStrategy(rawValue: j["strategy"]?.stringValue ?? "auto") ?? .auto
        expectedSignature = j["expectedSignature"]?.stringValue
        observed = j["observed"]?.objectValue.map { FailureRecord(json: $0) }
        otherFailures = (j["otherFailures"]?.arrayValue ?? []).compactMap { $0.objectValue.map { FailureRecord(json: $0) } }
        divergences = (j["divergences"]?.arrayValue ?? []).compactMap { v in
            v.objectValue.map { Divergence($0["type"]?.stringValue ?? "", $0["detail"]?.stringValue ?? "", t: $0["t"]?.intValue) }
        }
        eventsDispatched = j["eventsDispatched"]?.intValue ?? 0
        eventsExpected = j["eventsExpected"]?.intValue
        fixturesServed = j["fixturesServed"]?.intValue ?? 0
        compressedMs = j["compressedMs"]?.intValue ?? 0
        gapsCompressed = j["gapsCompressed"]?.intValue ?? 0
        buildGitSha = j["buildGitSha"]?.stringValue
        message = j["message"]?.stringValue
        attemptId = j["attemptId"]?.stringValue
        runtime = j["runtime"]?.stringValue
    }

    public var json: JSONValue {
        var o: JSONObject = [
            "outcome": .string(outcome.rawValue),
            "attempt": .int(attempt),
            "durationMs": .int(durationMs),
            "strategy": .string(strategy.rawValue),
            "expectedSignature": expectedSignature.map { .string($0) } ?? .null,
            "observed": observed?.json ?? .null,
            "otherFailures": .array(otherFailures.map(\.json)),
            "divergences": .array(divergences.map(\.json)),
            "eventsDispatched": .int(eventsDispatched),
            "eventsExpected": eventsExpected.map { .int($0) } ?? .null,
            "fixturesServed": .int(fixturesServed),
            "compressedMs": .int(compressedMs),
            "gapsCompressed": .int(gapsCompressed),
            "buildGitSha": buildGitSha.map { .string($0) } ?? .null,
            "message": message.map { .string($0) } ?? .null,
        ]
        if let attemptId { o["attemptId"] = .string(attemptId) }
        if let runtime { o["runtime"] = .string(runtime) }
        return .object(o)
    }
}
