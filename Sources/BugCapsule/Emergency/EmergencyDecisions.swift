import CryptoKit
import Foundation

/// `manifest.capabilities` key that says whether a capsule holds every
/// decision (§7.8).
let emergencyDecisionsCapability = "emergency.decisions"

/// The subject as written in a capsule: never the subject itself (§7.8).
func emergencySubjectTag(_ subject: String) -> String {
    let digest = SHA256.hash(data: Data("bugcapsule.emergency.subject:\(subject)".utf8))
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
}

/// The latest decision of each feature key and subject, and whether all of
/// them could be kept. A decision is written when it changes, because apps
/// may evaluate during every layout. Thread-safe; nothing runs under its lock
/// but the bookkeeping, so it never waits on the recording.
final class EmergencyDecisionTracker: @unchecked Sendable {
    struct Pair: Hashable, Sendable {
        let key: String
        /// [emergencySubjectTag] of the subject the app passed.
        let tag: String?
    }

    enum Outcome: Equatable {
        case unchanged
        /// Write the latest decision of this pair.
        case changed(Pair)
        /// The first decision that didn't fit: `complete` just became false.
        case limitReached
    }

    let maxPairs: Int
    private let hash: @Sendable (String) -> String
    private let lock = NSLock()
    private var latest: [Pair: EmergencyDecision] = [:]
    private var tags: [String: String] = [:]
    private var _complete = true

    init(maxPairs: Int = 256, hash: @escaping @Sendable (String) -> String = emergencySubjectTag) {
        self.maxPairs = maxPairs
        self.hash = hash
    }

    /// False once a decision could not be recorded.
    var complete: Bool { lock.locked { _complete } }

    /// The pairs with a decision.
    var pairs: [Pair] { lock.locked { Array(latest.keys) } }

    func latest(of pair: Pair) -> EmergencyDecision? { lock.locked { latest[pair] } }

    /// True when this call made the tracker incomplete.
    func markIncomplete() -> Bool {
        lock.locked {
            defer { _complete = false }
            return _complete
        }
    }

    func track(_ decision: EmergencyDecision, subject: String?) -> Outcome {
        lock.locked {
            let pair = Pair(key: decision.featureKey, tag: subject.map(tagLocked))
            if let previous = latest[pair] {
                if previous == decision { return .unchanged }
            } else if latest.count >= maxPairs {
                defer { _complete = false }
                return _complete ? .limitReached : .unchanged
            }
            latest[pair] = decision
            return .changed(pair)
        }
    }

    /// [emergencySubjectTag], cached: hashing on every evaluation adds up.
    func tag(of subject: String) -> String { lock.locked { tagLocked(subject) } }

    private func tagLocked(_ subject: String) -> String {
        if let cached = tags[subject] { return cached }
        if tags.count >= maxPairs { tags.removeAll(keepingCapacity: true) }
        let tag = hash(subject)
        tags[subject] = tag
        return tag
    }

    func clear() {
        lock.locked {
            latest = [:]
            tags = [:]
            _complete = true
        }
    }

    /// Replay can use [clean], the capture rules' result for [original]: the
    /// fields it finds an entry by and acts on are unchanged. An app that
    /// redacts `key` would leave an entry no evaluation can find.
    static func isIntact(_ clean: JSONObject, original: JSONObject) -> Bool {
        ["key", "subject", "action"].allSatisfy { clean[$0] == original[$0] }
    }

    /// The `emergency.decision` event data of [decision].
    static func eventData(_ d: EmergencyDecision, tag: String?) -> JSONObject {
        var data: JSONObject = ["key": .string(d.featureKey)]
        if let tag { data["subject"] = .string(tag) }
        data["action"] = .string(d.action.rawValue)
        data["source"] = .string(d.source.rawValue)
        if let v = d.reasonCode { data["reasonCode"] = .string(v) }
        if let v = d.policyId { data["policyId"] = .string(v) }
        if let v = d.policyRevision { data["policyRevision"] = .int(v) }
        if let v = d.documentRevision { data["documentRevision"] = .int(v) }
        if let v = d.publicUserMessage { data["message"] = .string(v) }
        if let v = d.requiredVersion { data["requiredVersion"] = .string(v) }
        if let v = d.fallback { data["fallback"] = .string(v) }
        if d.fallbackAvailable { data["fallbackAvailable"] = .bool(true) }
        return data
    }
}

/// The decisions of a capsule, looked up during replay (§7.8). Immutable.
struct EmergencyDecisionScript: Sendable {
    private struct Entry: Sendable {
        let subject: String?
        let t: Int
        let decision: EmergencyDecision
    }

    private let byKey: [String: [Entry]]

    init(events: [BugCapsuleEvent]) {
        var byKey: [String: [Entry]] = [:]
        for e in events where e.type == EventTypes.emergencyDecision {
            let d = e.data
            // Not `EmergencyAction(wire:)`: that blocks an unknown action,
            // which only a verified document may do.
            guard let key = d["key"]?.stringValue, let action = d["action"]?.stringValue.flatMap(EmergencyAction.init(rawValue:))
            else { continue }
            let decision = EmergencyDecision(
                featureKey: key, allowed: action == .allow, action: action, reasonCode: d["reasonCode"]?.stringValue,
                policyId: d["policyId"]?.stringValue, policyRevision: d["policyRevision"]?.intValue,
                documentRevision: d["documentRevision"]?.intValue, publicUserMessage: d["message"]?.stringValue,
                requiredVersion: d["requiredVersion"]?.stringValue, fallback: d["fallback"]?.stringValue,
                fallbackAvailable: d["fallbackAvailable"]?.boolValue == true, source: .replay)
            byKey[key, default: []].append(Entry(subject: d["subject"]?.stringValue, t: e.t, decision: decision))
        }
        self.byKey = byKey
    }

    /// The decision the app saw for [key] at recorded time [t]; nil when the
    /// capsule has none for it.
    func lookup(key: String, subjectTag: String?, t: Int) -> EmergencyDecision? {
        guard let all = byKey[key] else { return nil }
        let same = all.filter { $0.subject == subjectTag }
        var latest: Entry?
        var earliest: Entry?
        for e in same.isEmpty ? all : same {
            if earliest == nil || e.t < earliest!.t { earliest = e }
            if e.t <= t && (latest == nil || e.t >= latest!.t) { latest = e }
        }
        return (latest ?? earliest)?.decision
    }
}
