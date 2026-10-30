import CryptoKit
import Foundation

// Emergency policy contract v1 (docs/emergency-client-v1.md): the types of a
// signed policy document and the evaluation every client reproduces exactly
// (§6). Pure code: no I/O, no clock.

/// What a policy tells the app to do with a feature (§4).
public enum EmergencyAction: String, Sendable, CaseIterable, Equatable {
    case allow = "ALLOW"
    case block = "BLOCK"
    case readOnly = "READ_ONLY"
    case requireUpdate = "REQUIRE_UPDATE"
    case showMaintenance = "SHOW_MAINTENANCE"
    case disableFeature = "DISABLE_FEATURE"
    case useSafeFallback = "USE_SAFE_FALLBACK"

    /// An action this SDK does not know is treated as `BLOCK` (fails safe).
    init(wire: String) {
        self = EmergencyAction(rawValue: wire) ?? .block
    }

    /// Ties at the same priority go to the more restrictive action (§6.5).
    var restrictiveness: Int {
        switch self {
        case .allow: return 0
        case .useSafeFallback: return 1
        case .readOnly: return 2
        case .disableFeature: return 3
        case .showMaintenance: return 4
        case .requireUpdate: return 5
        case .block: return 6
        }
    }
}

/// Where a decision came from (§7.4).
public enum EmergencyDecisionSource: String, Sendable, Equatable {
    /// A verified document that is still usable.
    case policy
    /// The last verified document after it expired (`useLastValidPolicy`).
    case stalePolicy = "stale_policy"
    /// No usable document: the feature's failure mode decided.
    case failureMode = "failure_mode"
    /// The SDK is replaying a Capsule: the decision recorded in it, or ALLOW
    /// when it has none for the feature (§7.8).
    case replay
}

/// What the app does with a feature when there is no usable policy document
/// (§7.4).
public enum EmergencyFailureMode: String, Sendable, Equatable {
    /// Allow (the default for every key).
    case failOpen = "FAIL_OPEN"
    /// Block. Use for actions that move money.
    case failClosed = "FAIL_CLOSED"
    /// Keep evaluating the last verified document after it expired; with no
    /// document at all, allow.
    case useLastValidPolicy = "USE_LAST_VALID_POLICY"
}

/// The answer for one feature (§6). Only `.allow` is `allowed`.
public struct EmergencyDecision: Sendable, Equatable {
    public var featureKey: String
    public var allowed: Bool
    public var action: EmergencyAction
    /// The policy's reason code; `POLICY_UNAVAILABLE` for a failure-mode
    /// decision; nil when no policy applies.
    public var reasonCode: String?
    public var policyId: String?
    public var policyRevision: Int?
    /// Revision of the document evaluated; nil when no document was used.
    public var documentRevision: Int?
    /// Text the operator wrote for users, safe to show as is.
    public var publicUserMessage: String?
    /// `REQUIRE_UPDATE`: the first version without the restriction.
    public var requiredVersion: String?
    /// `USE_SAFE_FALLBACK`: the name of the app-defined fallback.
    public var fallback: String?
    public var fallbackAvailable: Bool
    public var source: EmergencyDecisionSource

    public init(
        featureKey: String, allowed: Bool, action: EmergencyAction, reasonCode: String? = nil, policyId: String? = nil,
        policyRevision: Int? = nil, documentRevision: Int? = nil, publicUserMessage: String? = nil,
        requiredVersion: String? = nil, fallback: String? = nil, fallbackAvailable: Bool = false,
        source: EmergencyDecisionSource
    ) {
        self.featureKey = featureKey
        self.allowed = allowed
        self.action = action
        self.reasonCode = reasonCode
        self.policyId = policyId
        self.policyRevision = policyRevision
        self.documentRevision = documentRevision
        self.publicUserMessage = publicUserMessage
        self.requiredVersion = requiredVersion
        self.fallback = fallback
        self.fallbackAvailable = fallbackAvailable
        self.source = source
    }

    /// Reason code of decisions made without a usable document.
    public static let policyUnavailable = "POLICY_UNAVAILABLE"
}

/// An inclusive version range; nil means unbounded on that side.
public struct EmergencyVersionRange: Sendable, Equatable {
    public var min: String?
    public var max: String?

    public init(min: String?, max: String?) {
        self.min = min
        self.max = max
    }
}

/// One policy of a verified document.
public struct EmergencyPolicy: Sendable, Equatable {
    public var policyId: String
    /// Exact feature key, or `prefix.*`.
    public var key: String
    public var revision: Int
    public var action: EmergencyAction
    /// The action as sent; differs from `action.rawValue` when this SDK
    /// does not know it (then `action` is `.block`).
    public var actionName: String
    public var priority: Int
    public var severity: String?
    public var incidentId: String?
    /// Empty: every platform.
    public var targetPlatforms: [String]
    /// Empty: every version.
    public var versionRanges: [EmergencyVersionRange]
    /// 0...10000; 10000 is everyone.
    public var rolloutBasisPoints: Int
    public var rolloutSeed: String
    public var reasonCode: String
    public var publicUserMessage: String?
    public var requiredVersion: String?
    public var fallback: String?
    /// After it the policy is ignored.
    public var expiresAt: Date?

    /// Milliseconds since the epoch, compared exactly like the reference.
    var expiresAtMs: Int64?
}

/// A verified policy document (§4).
struct EmergencyDocument: Sendable, Equatable {
    var applicationId: String
    var environment: String
    var revision: Int
    var issuedAtMs: Int64
    var expiresAtMs: Int64
    var policies: [EmergencyPolicy]

    var issuedAt: Date { Date(timeIntervalSince1970: TimeInterval(issuedAtMs) / 1000) }
    var expiresAt: Date { Date(timeIntervalSince1970: TimeInterval(expiresAtMs) / 1000) }
}

/// Inputs of one evaluation besides the document (§6).
struct EmergencyEvaluationContext: Sendable {
    var platform: String
    var appVersion: String?
    var subject: String?
    var nowMs: Int64
}

enum EmergencyContract {
    static let wireFormat = "bugcapsule.emergency.v1"
    static let signatureAlgorithm = "ES256"
    static let documentType = "bugcapsule.emergency.policy-document"
    static let schemaVersion = 1
    static let platform = "NATIVE_IOS"
    /// A document stays usable this long after `expires_at` (device clock skew).
    static let clockSkewMs: Int64 = 300_000

    // MARK: keys

    /// `^[a-z0-9_-]{1,64}(\.[a-z0-9_-]{1,64}){0,7}$`, optionally followed by
    /// `.*` when [wildcard] is allowed.
    static func isFeatureKey(_ key: String, allowWildcard: Bool = false) -> Bool {
        var bytes = Array(key.utf8)
        if allowWildcard, bytes.count >= 2, bytes[bytes.count - 1] == UInt8(ascii: "*"),
            bytes[bytes.count - 2] == UInt8(ascii: ".")
        {
            bytes.removeLast(2)
        }
        if bytes.isEmpty || bytes.count > 200 { return false }
        var segments = 0
        var length = 0
        for b in bytes {
            if b == UInt8(ascii: ".") {
                if length == 0 { return false }
                segments += 1
                length = 0
                continue
            }
            let ok =
                (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z")) || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
                || b == UInt8(ascii: "_") || b == UInt8(ascii: "-")
            if !ok { return false }
            length += 1
            if length > 64 { return false }
        }
        if length == 0 { return false }
        return segments + 1 <= 8
    }

    /// `^[a-z0-9][a-z0-9_-]{0,39}$`.
    static func isEnvironment(_ env: String) -> Bool {
        let bytes = Array(env.utf8)
        guard !bytes.isEmpty, bytes.count <= 40 else { return false }
        for (i, b) in bytes.enumerated() {
            let alnum = (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z")) || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
            if i == 0 ? !alnum : !(alnum || b == UInt8(ascii: "_") || b == UInt8(ascii: "-")) { return false }
        }
        return true
    }

    /// Exact match, or `prefix.*` covering every key below `prefix`
    /// (byte-wise, as the reference compares code units).
    static func keyMatches(_ pattern: String, _ featureKey: String) -> Bool {
        if pattern.hasSuffix(".*") {
            return featureKey.utf8.starts(with: pattern.utf8.dropLast())
        }
        return pattern.utf8.elementsEqual(featureKey.utf8)
    }

    // MARK: versions (§6.3)

    struct ParsedVersion: Equatable {
        var nums: [Int]
        var pre: [String]?
    }

    /// `v?N(.N){0,5}(-pre)?(+build)?`, each N 1–9 ASCII digits, surrounding
    /// whitespace ignored. Nil for anything else.
    static func parseVersion(_ raw: String) -> ParsedVersion? {
        let s = Array(raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        var i = 0
        func isDigit(_ b: UInt8) -> Bool { b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") }
        func isIdent(_ b: UInt8) -> Bool {
            isDigit(b) || (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z")) || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
                || b == UInt8(ascii: "-")
        }
        if i < s.count, s[i] == UInt8(ascii: "v") || s[i] == UInt8(ascii: "V") { i += 1 }
        var nums: [Int] = []
        while true {
            let start = i
            var n = 0
            while i < s.count, isDigit(s[i]) {
                n = n * 10 + Int(s[i] - UInt8(ascii: "0"))
                i += 1
                if i - start > 9 { return nil }
            }
            if i == start { return nil }
            nums.append(n)
            if i < s.count, s[i] == UInt8(ascii: "."), nums.count < 6 {
                i += 1
                continue
            }
            break
        }
        /// Dot-separated non-empty identifiers of `[0-9A-Za-z-]`, up to `stop`.
        func identifiers(stop: UInt8?) -> [String]? {
            var out: [String] = []
            var current: [UInt8] = []
            while i < s.count, s[i] != stop {
                let b = s[i]
                if b == UInt8(ascii: ".") {
                    if current.isEmpty { return nil }
                    out.append(String(decoding: current, as: UTF8.self))
                    current = []
                } else if isIdent(b) {
                    current.append(b)
                } else {
                    return nil
                }
                i += 1
            }
            if current.isEmpty { return nil }
            out.append(String(decoding: current, as: UTF8.self))
            return out
        }
        var pre: [String]?
        if i < s.count, s[i] == UInt8(ascii: "-") {
            i += 1
            guard let p = identifiers(stop: UInt8(ascii: "+")) else { return nil }
            pre = p
        }
        if i < s.count, s[i] == UInt8(ascii: "+") {
            i += 1
            guard identifiers(stop: nil) != nil else { return nil }
        }
        return i == s.count ? ParsedVersion(nums: nums, pre: pre) : nil
    }

    /// -1, 0 or 1; nil when either side does not parse.
    static func compareVersions(_ a: String, _ b: String) -> Int? {
        guard let x = parseVersion(a), let y = parseVersion(b) else { return nil }
        for i in 0..<max(x.nums.count, y.nums.count) {
            let p = i < x.nums.count ? x.nums[i] : 0
            let q = i < y.nums.count ? y.nums[i] : 0
            if p != q { return p < q ? -1 : 1 }
        }
        switch (x.pre, y.pre) {
        case (nil, nil): return 0
        case (nil, _): return 1
        case (_, nil): return -1
        case (let xp?, let yp?):
            for i in 0..<max(xp.count, yp.count) {
                if i >= xp.count { return -1 }
                if i >= yp.count { return 1 }
                let p = xp[i]
                let q = yp[i]
                let pn = p.utf8.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
                let qn = q.utf8.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
                if pn && qn {
                    let d = compareNumeric(p, q)
                    if d != 0 { return d }
                } else if pn != qn {
                    return pn ? -1 : 1
                } else if p != q {
                    return p.utf8.lexicographicallyPrecedes(q.utf8) ? -1 : 1
                }
            }
            return 0
        }
    }

    /// Compares two ASCII digit strings by value, at any length.
    private static func compareNumeric(_ a: String, _ b: String) -> Int {
        let x = a.drop { $0 == "0" }
        let y = b.drop { $0 == "0" }
        if x.count != y.count { return x.count < y.count ? -1 : 1 }
        if x == y { return 0 }
        return x.utf8.lexicographicallyPrecedes(y.utf8) ? -1 : 1
    }

    /// Whether [version] falls in any of [ranges] (§6.2). No ranges, or a
    /// version that is nil or does not parse: targeted. A bound that does not
    /// parse counts as satisfied, as in the reference.
    static func versionTargeted(_ version: String?, _ ranges: [EmergencyVersionRange]) -> Bool {
        if ranges.isEmpty { return true }
        guard let version, parseVersion(version) != nil else { return true }
        return ranges.contains { r in
            let lower = r.min.map { (compareVersions(version, $0) ?? 0) >= 0 } ?? true
            let upper = r.max.map { (compareVersions(version, $0) ?? 0) <= 0 } ?? true
            return lower && upper
        }
    }

    // MARK: rollout (§6.4)

    /// 0...9999: the first 4 bytes of SHA-256(UTF-8 "<seed>:<subject>") as a
    /// big-endian UInt32, mod 10000.
    static func rolloutBucket(seed: String, subject: String) -> Int {
        let digest = Array(SHA256.hash(data: Data("\(seed):\(subject)".utf8)))
        let n = UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])
        return Int(n % 10000)
    }

    static func inRollout(basisPoints: Int, seed: String, subject: String?) -> Bool {
        if basisPoints >= 10000 { return true }
        if basisPoints <= 0 { return false }
        // A partial rollout needs a stable subject; without one the restriction applies.
        guard let subject, !subject.isEmpty else { return true }
        return rolloutBucket(seed: seed, subject: subject) < basisPoints
    }

    // MARK: evaluation (§6)

    /// The reference decision over [policies] of a document at [revision],
    /// plus the winning policy (nil: no candidate, ALLOW).
    static func evaluate(
        policies: [EmergencyPolicy], revision: Int, featureKey: String, context ctx: EmergencyEvaluationContext,
        source: EmergencyDecisionSource
    ) -> (EmergencyDecision, EmergencyPolicy?) {
        let candidates = policies.filter { p in
            keyMatches(p.key, featureKey) && (p.expiresAtMs.map { $0 > ctx.nowMs } ?? true)
                && (p.targetPlatforms.isEmpty || p.targetPlatforms.contains(ctx.platform))
                && versionTargeted(ctx.appVersion, p.versionRanges)
                && inRollout(basisPoints: p.rolloutBasisPoints, seed: p.rolloutSeed, subject: ctx.subject)
        }
        let winner = candidates.min { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            if a.action.restrictiveness != b.action.restrictiveness {
                return a.action.restrictiveness > b.action.restrictiveness
            }
            let ae = a.key.utf8.elementsEqual(featureKey.utf8)
            let be = b.key.utf8.elementsEqual(featureKey.utf8)
            if ae != be { return ae }
            return utf16Less(a.policyId, b.policyId)
        }
        guard let w = winner else {
            return (
                EmergencyDecision(
                    featureKey: featureKey, allowed: true, action: .allow, documentRevision: revision, source: source), nil
            )
        }
        let decision = EmergencyDecision(
            featureKey: featureKey, allowed: w.action == .allow, action: w.action, reasonCode: w.reasonCode,
            policyId: w.policyId, policyRevision: w.revision, documentRevision: revision,
            publicUserMessage: w.publicUserMessage, requiredVersion: w.requiredVersion, fallback: w.fallback,
            fallbackAvailable: w.action == .useSafeFallback && w.fallback != nil, source: source)
        return (decision, w)
    }

    // MARK: timestamps

    /// ISO-8601 UTC (or with an offset) with optional fractional seconds, as
    /// milliseconds since the epoch.
    static func parseTimestamp(_ s: String) -> Int64? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return Int64((d.timeIntervalSince1970 * 1000).rounded()) }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: s) { return Int64((d.timeIntervalSince1970 * 1000).rounded()) }
        return nil
    }

    static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }
}
