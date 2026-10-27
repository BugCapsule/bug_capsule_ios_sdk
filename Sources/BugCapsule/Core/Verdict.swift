import Foundation

// Port of `verdict.dart`. The CLI computes verdicts; the port lets this SDK
// run `verdicts.json` and lets tools built on it apply the same rules.

public enum RunKind: String, Sendable { case replay, verify }

public enum Verdict: String, Sendable {
    case reproduced, notReproduced, fixed, stillFailing, flaky, incompatible, inconclusive

    public var wire: String {
        switch self {
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

    public var exitCode: Int {
        switch verdict {
        case .reproduced, .fixed: return 0
        case .notReproduced, .stillFailing: return 1
        case .flaky: return 2
        case .incompatible, .inconclusive: return 3
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
    if reports.contains(where: { $0.outcome == .incompatible }) {
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
