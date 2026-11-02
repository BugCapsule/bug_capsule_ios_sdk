import Foundation

// Port of `verdict.dart` (including verdict v2). The CLI computes verdicts; the port lets this SDK
// run `verdicts.json` and lets tools built on it apply the same rules.

public enum RunKind: String, Sendable { case replay, verify }

public enum Verdict: String, Sendable {
    case reproduced, notReproduced, fixed, stillFailing, flaky, incompatible, inconclusive
    /// verify (v2): baseline reproduced, every candidate attempt clean, but
    /// the evidence is weak or the capsule is partial. Sent to the backend
    /// as inconclusive, so it never satisfies a gate.
    case fixedQualified
    /// Replay containment was not kept (live traffic allowed): no conclusion.
    case unsafe

    public var wire: String {
        switch self {
        case .fixedQualified, .unsafe: return "inconclusive"
        case .reproduced, .stillFailing: return "reproduced"
        case .notReproduced, .fixed: return "not_reproduced"
        case .flaky: return "flaky"
        case .incompatible: return "incompatible"
        case .inconclusive: return "inconclusive"
        }
    }
}

public enum AttemptStatus: String, Sendable { case reproduced, clean, invalid }

public enum DivergencePolicy {
    /// Expected differences. Everything else, including divergence types this
    /// version does not know, is material.
    public static let expected: Set<String> = [
        "build.gitSha", "screen.size", "network.unused",
        // capsule-v2 §5: interactions recorded after the failure.
        "ws.unusedAfterFailure", "platform.unusedAfterFailure", "native.unusedAfterFailure",
    ]
    public static func isMaterial(_ d: Divergence) -> Bool { !expected.contains(d.type) }

    /// The capsule-v2 §8 reason code of a material interaction divergence,
    /// or nil for other divergence types.
    public static func reasonCode(_ type: String) -> String? {
        if type == "dependency.live" || type == "dependency.late" { return "interaction.live" }
        guard let dot = type.firstIndex(of: ".") else { return nil }
        let family = type[..<dot]
        guard family == "ws" || family == "platform" || family == "native" else { return nil }
        switch type[type.index(after: dot)...] {
        case "unused", "undelivered": return "interaction.missing"
        case "unrecorded": return "interaction.unexpected"
        case "mismatch": return "interaction.mismatch"
        case "noPayload": return "interaction.incomplete"
        case "unrestored": return "interaction.unrestored"
        default: return nil
        }
    }
}

public struct AttemptAssessment: Sendable {
    public let report: ReplayReport
    public let status: AttemptStatus
    public let reasons: [String]
    /// Machine-readable codes for `reasons` that concern interaction
    /// dependencies (capsule-v2 §8), e.g. `interaction.missing`. Sorted.
    public let reasonCodes: [String]

    public init(report: ReplayReport, status: AttemptStatus, reasons: [String], reasonCodes: [String] = []) {
        self.report = report
        self.status = status
        self.reasons = reasons
        self.reasonCodes = reasonCodes
    }
}

public func assessAttempt(_ r: ReplayReport) -> AttemptAssessment {
    var reasons: [String] = []
    var codes = Set<String>()
    switch r.outcome {
    case .reproduced:
        if r.expectedSignature == nil {
            reasons.append("reported a reproduction without an expected failure")
            return AttemptAssessment(report: r, status: .invalid, reasons: reasons)
        }
        return AttemptAssessment(report: r, status: .reproduced, reasons: [], reasonCodes: Set(r.reasonCodes + r.divergences.filter { $0.type == "failure.different_frame" }.map { $0.type }).sorted())
    case .inconclusive:
        reasons.append("inconclusive: \(r.message ?? r.observed.map { "observed \($0.signature)" } ?? "unknown")")
        codes.formUnion(r.reasonCodes)
    case .incompatible:
        reasons.append("incompatible: \(r.message ?? "capsule cannot run against this build")")
        if r.message?.hasPrefix("dependency.") == true { codes.insert("dependency.unsupported") }
    case .noAssertion:
        reasons.append("capsule has no failure assertion")
    case .error:
        reasons.append("replay error: \(r.message ?? "unknown")")
    case .notReproduced:
        if r.expectedSignature == nil { reasons.append("no expected failure to check") }
        if let expected = r.eventsExpected, r.eventsDispatched < expected {
            reasons.append("only \(r.eventsDispatched) of \(expected) recorded inputs were replayed")
        }
        for f in r.otherFailures { reasons.append("unexpected failure: \(f.signature)") }
        if r.otherFailures.contains(where: { $0.kind == .crash }) || (!r.otherFailures.isEmpty && r.expectedSignature?.hasPrefix("crash:") == true) { codes.insert("failure.different") }
        var material: [String] = []
        for d in r.divergences where DivergencePolicy.isMaterial(d) && !material.contains(d.type) {
            material.append(d.type)
        }
        for type in material {
            let n = r.divergences.filter { $0.type == type }.count
            reasons.append("divergence \(type)\(n > 1 ? " ×\(n)" : "")")
            if let code = DivergencePolicy.reasonCode(type) { codes.insert(code) }
        }
    }
    return AttemptAssessment(
        report: r, status: reasons.isEmpty ? .clean : .invalid, reasons: reasons, reasonCodes: codes.sorted())
}

public struct RunEvaluation: Sendable {
    public let kind: RunKind
    public let requestedAttempts: Int
    public let verdict: Verdict
    public let attempts: [AttemptAssessment]
    public let reasons: [String]
    /// Interaction reason codes over all attempts (capsule-v2 §8), sorted.
    public let reasonCodes: [String]

    public var reproductions: Int { attempts.filter { $0.status == .reproduced }.count }
    public var cleanAttempts: Int { attempts.filter { $0.status == .clean }.count }
    public var validAttempts: Int { reproductions + cleanAttempts }

    /// 0 success, 1 the opposite, 2 flaky, 3 inconclusive / incompatible,
    /// 4 fixed with qualifications, 5 unsafe.
    public var exitCode: Int {
        switch verdict {
        case .reproduced, .fixed: return 0
        case .notReproduced, .stillFailing: return 1
        case .flaky: return 2
        case .incompatible, .inconclusive: return 3
        case .fixedQualified: return 4
        case .unsafe: return 5
        }
    }
}

public func evaluateRun(_ kind: RunKind, requestedAttempts: Int, reports: [ReplayReport]) -> RunEvaluation {
    let attempts = reports.map(assessAttempt)
    var reasons: [String] = []
    func add(_ r: String) { if !reasons.contains(r) { reasons.append(r) } }
    for a in attempts { a.reasons.forEach(add) }
    if reports.count > requestedAttempts { add("\(reports.count) reports for \(requestedAttempts) requested attempts") }
    let missing = requestedAttempts - attempts.count
    if missing > 0 { add("\(missing) of \(requestedAttempts) requested attempts did not run") }
    if requestedAttempts <= 0 { add("no attempts were requested") }
    let n = requestedAttempts
    let r = attempts.filter { $0.status == .reproduced }.count
    let c = attempts.filter { $0.status == .clean }.count
    let verdict: Verdict
    if reports.contains(where: { $0.divergences.contains { $0.type == unsafeLiveDivergence } }) {
        add("live traffic was allowed during replay")
        verdict = .unsafe
    } else if reports.contains(where: { $0.outcome == .incompatible }) {
        verdict = .incompatible
    } else if n <= 0 || reports.count > n {
        verdict = .inconclusive
    } else if kind == .replay {
        verdict = r == n ? .reproduced : c == n ? .notReproduced : (r > 0 && c > 0) ? .flaky : .inconclusive
    } else {
        verdict = c == n ? .fixed : (r > 0 && c > 0) ? .flaky : r > 0 ? .stillFailing : .inconclusive
    }
    return RunEvaluation(
        kind: kind, requestedAttempts: n, verdict: verdict, attempts: attempts, reasons: reasons,
        reasonCodes: Set(attempts.flatMap(\.reasonCodes)).sorted())
}

// MARK: verdict v2

/// Divergence a runner adds when the user let live traffic through
/// (`--allow-live`): the attempt proves nothing either way.
public let unsafeLiveDivergence = "replay.unsafe_live"

/// Baseline attempts below this never support FIXED.
public let minBaselineAttempts = 3
/// Candidate attempts are never fewer than this, nor more than `maxCandidateAttempts`.
public let minCandidateAttempts = 5
public let maxCandidateAttempts = 30

/// The baseline build's result for a capsule (verdict-v2).
public struct BaselineResult: Sendable, Equatable {
    public var revision: String
    public var attempts: Int
    public var reproduced: Int
    public var cached: Bool

    public init(revision: String, attempts: Int, reproduced: Int, cached: Bool = false) {
        self.revision = revision
        self.attempts = attempts
        self.reproduced = reproduced
        self.cached = cached
    }

    public init?(json j: JSONObject) {
        guard let revision = j["revision"]?.stringValue, let attempts = j["attempts"]?.intValue,
            let reproduced = j["reproduced"]?.intValue
        else { return nil }
        self.init(revision: revision, attempts: attempts, reproduced: reproduced, cached: j["cached"] == .bool(true))
    }

    public var json: JSONValue {
        ["revision": .string(revision), "attempts": .int(attempts), "reproduced": .int(reproduced), "cached": .bool(cached)]
    }
}

/// Lower bound of the Wilson 95% interval of [successes] / [n].
public func wilsonLower(_ successes: Int, _ n: Int) -> Double {
    if n <= 0 { return 0 }
    let z = 1.959963984540054
    let nd = Double(n)
    let p = Double(successes) / nd
    let z2 = z * z
    let centre = p + z2 / (2 * nd)
    let margin = z * (p * (1 - p) / nd + z2 / (4 * nd * nd)).squareRoot()
    return min(max((centre - margin) / (1 + z2 / nd), 0), 1)
}

/// Candidate attempts so that a build still failing at the baseline's lower
/// rate would pass every attempt with probability below 1%.
public func requiredCandidateAttempts(_ baselineReproduced: Int, _ baselineAttempts: Int) -> Int {
    let low = wilsonLower(baselineReproduced, baselineAttempts)
    if low <= 0 { return maxCandidateAttempts }
    if low >= 1 { return minCandidateAttempts }
    let n = Int((log(0.01) / log(1 - low)).rounded(.up))
    return min(max(n, minCandidateAttempts), maxCandidateAttempts)
}

/// `verify` under verdict v2 (port of `evaluateVerifyV2`): [candidate] are
/// the candidate build's reports, [baseline] the baseline build's result
/// (nil when none could be built).
///
/// FIXED needs a baseline that reproduced in every one of at least
/// `minBaselineAttempts` attempts, at least `requiredCandidateAttempts`
/// candidate attempts all clean, strong positive evidence in each, and an
/// eligible capsule. Weak evidence or a partial capsule gives
/// `.fixedQualified`; no evidence at all is inconclusive.
public func evaluateVerifyV2(
    requestedAttempts: Int, candidate: [ReplayReport], baseline: BaselineResult?, eligibility: EligibilityStatus
) -> RunEvaluation {
    let v1 = evaluateRun(.verify, requestedAttempts: requestedAttempts, reports: candidate)
    var reasons = v1.reasons
    var codes = Set(v1.reasonCodes)
    func result(_ verdict: Verdict, _ reason: String? = nil, _ code: String? = nil) -> RunEvaluation {
        if let reason { reasons.append(reason) }
        if let code { codes.insert(code) }
        return RunEvaluation(
            kind: .verify, requestedAttempts: requestedAttempts, verdict: verdict, attempts: v1.attempts, reasons: reasons,
            reasonCodes: codes.sorted())
    }

    if candidate.contains(where: { $0.divergences.contains { $0.type == unsafeLiveDivergence } }) {
        return result(.unsafe, "live traffic was allowed during replay", "replay.unsafe")
    }
    if v1.verdict == .incompatible || v1.verdict == .stillFailing { return result(v1.verdict) }
    guard let baseline else {
        return result(
            .inconclusive,
            "no baseline: the capsule's build could not be replayed, so nothing shows this harness reproduces the failure",
            "baseline.unavailable")
    }
    if baseline.reproduced == 0 {
        return result(
            .inconclusive, "the baseline build did not reproduce the failure in \(baseline.attempts) attempts",
            "baseline.not_reproduced")
    }
    if baseline.reproduced < baseline.attempts {
        return result(
            .flaky, "the baseline build reproduced in \(baseline.reproduced) of \(baseline.attempts) attempts", "baseline.flaky")
    }
    if baseline.attempts < minBaselineAttempts {
        return result(
            .inconclusive, "the baseline ran \(baseline.attempts) attempts; at least \(minBaselineAttempts) are needed",
            "baseline.too_few")
    }
    let needed = requiredCandidateAttempts(baseline.reproduced, baseline.attempts)
    if requestedAttempts < needed {
        return result(
            .inconclusive,
            "\(requestedAttempts) candidate attempts; \(needed) are needed after a \(baseline.reproduced)/\(baseline.attempts) baseline",
            "attempts.too_few")
    }
    if v1.verdict != .fixed { return result(v1.verdict) }
    if eligibility == .ineligible {
        return result(.inconclusive, "the capsule is ineligible for replay", "capsule.ineligible")
    }
    let levels = v1.attempts.map { $0.report.evidence?.level ?? .none }
    if levels.contains(.none) {
        var failed: [String] = []
        for a in v1.attempts {
            for name in a.report.evidence?.failedPostconditions ?? [] where !failed.contains(name) { failed.append(name) }
        }
        if !failed.isEmpty {
            return result(.stillFailing, "postconditions did not hold: \(failed.joined(separator: ", "))", "postcondition.failed")
        }
        return result(
            .inconclusive,
            "no positive evidence: nothing shows the failing path ran (update the SDK, or register a postcondition with BugCapsule.expect)",
            "evidence.none")
    }
    let weak = levels.contains(.weak)
    let partial = eligibility == .partial
    if weak || partial {
        var parts: [String] = []
        if weak { parts.append("only shows the recorded failure point was passed (no assertion or postcondition held)") }
        if partial { parts.append("the capsule is partial: some inputs were not recorded") }
        return result(.fixedQualified, parts.joined(separator: "; "), weak ? "evidence.weak" : "capsule.partial")
    }
    return result(.fixed)
}
