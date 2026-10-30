import CryptoKit
import Foundation

/// Why a policy envelope was rejected (§4, §5). The raw value is the
/// receipt `errorCode`.
public enum EmergencyRejection: String, Sendable, Equatable, CaseIterable {
    case malformed
    case unsupportedFormat = "unsupported_format"
    case unknownKey = "unknown_key"
    case badSignature = "bad_signature"
    case unsupportedSchema = "unsupported_schema"
    case wrongApplication = "wrong_application"
    case wrongEnvironment = "wrong_environment"
    case staleRevision = "stale_revision"
    case expiredOnArrival = "expired_on_arrival"
}

/// The parsed trust anchor (§2): the application id and the keys allowed to
/// sign its documents. Never fetched from the network.
struct EmergencyTrustAnchor: @unchecked Sendable {
    static let prefix = "bcek.v1."

    let applicationId: String
    // P256.Signing.PublicKey is a value type without mutable state.
    let keys: [String: P256.Signing.PublicKey]

    struct Invalid: Error, CustomStringConvertible, Sendable {
        let message: String
        var description: String { message }
    }

    static func parse(_ raw: String) throws -> EmergencyTrustAnchor {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix(prefix) else { throw Invalid(message: "not an emergency trust anchor (bcek.v1.…)") }
        guard let bytes = Base64URL.decode(String(s.dropFirst(prefix.count))),
            let json = try? JSON.parse(bytes), case .object(let o) = json
        else { throw Invalid(message: "the trust anchor is not base64url JSON") }
        guard let app = o["app"]?.stringValue, !app.isEmpty else { throw Invalid(message: "the trust anchor has no app id") }
        guard let list = o["keys"]?.arrayValue, !list.isEmpty else { throw Invalid(message: "the trust anchor has no keys") }
        var keys: [String: P256.Signing.PublicKey] = [:]
        for k in list {
            guard let kid = k["kid"]?.stringValue, !kid.isEmpty else { throw Invalid(message: "a trust anchor key has no kid") }
            guard k["alg"]?.stringValue == EmergencyContract.signatureAlgorithm else {
                throw Invalid(message: "trust anchor key \(kid) is not ES256")
            }
            guard let spki = k["spki"]?.stringValue, let der = Base64URL.decode(spki),
                let key = try? P256.Signing.PublicKey(derRepresentation: der)
            else { throw Invalid(message: "trust anchor key \(kid) is not a P-256 SubjectPublicKeyInfo") }
            keys[kid] = key
        }
        return EmergencyTrustAnchor(applicationId: app, keys: keys)
    }
}

/// RFC 4648 §5 base64url, with or without padding. Standard base64
/// characters (`+`, `/`) are accepted too, as Node's decoder does.
enum Base64URL {
    static func decode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.hasSuffix("=") { t.removeLast() }
        if t.count % 4 == 1 { return nil }
        t += String(repeating: "=", count: (4 - t.count % 4) % 4)
        return Data(base64Encoded: t)
    }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Outcome of verifying one envelope.
enum EmergencyVerification: Sendable, Equatable {
    case verified(EmergencyDocument)
    /// [revision]: the document's revision when the signature checked out
    /// and the payload carried one (for the FAILED receipt).
    case rejected(EmergencyRejection, revision: Int?)

    var rejection: EmergencyRejection? {
        if case .rejected(let r, _) = self { return r }
        return nil
    }
}

enum EmergencyVerifier {
    /// Verifies a signed envelope in the order of §4 and parses its document.
    /// The signature is checked over the decoded payload bytes before they
    /// are parsed; nothing is re-serialized.
    static func verify(envelope raw: JSONValue, anchor: EmergencyTrustAnchor, environment: String) -> EmergencyVerification {
        // 1. Shape.
        guard case .object(let e) = raw, let kid = e["kid"]?.stringValue, let payload = e["payload"]?.stringValue,
            let signature = e["signature"]?.stringValue
        else { return .rejected(.malformed, revision: nil) }
        // 2. Format and algorithm.
        guard e["format"]?.stringValue == EmergencyContract.wireFormat,
            e["alg"]?.stringValue == EmergencyContract.signatureAlgorithm
        else { return .rejected(.unsupportedFormat, revision: nil) }
        // 3. Key from the embedded anchor only.
        guard let key = anchor.keys[kid] else { return .rejected(.unknownKey, revision: nil) }
        // 4. Signature over the exact payload bytes.
        guard let bytes = Base64URL.decode(payload), let sigBytes = Base64URL.decode(signature),
            let sig = try? P256.Signing.ECDSASignature(derRepresentation: sigBytes), key.isValidSignature(sig, for: bytes)
        else { return .rejected(.badSignature, revision: nil) }
        // 5. Only now parse.
        guard let parsed = try? JSON.parse(bytes), case .object(let doc) = parsed else {
            return .rejected(.malformed, revision: nil)
        }
        let revision = integer(doc["revision"]).flatMap { $0 >= 0 ? $0 : nil }
        // 6–8. Binding.
        guard let schema = doc["schema_version"]?.doubleValue, schema == Double(EmergencyContract.schemaVersion) else {
            return .rejected(.unsupportedSchema, revision: revision)
        }
        guard doc["application_id"]?.stringValue == anchor.applicationId else {
            return .rejected(.wrongApplication, revision: revision)
        }
        guard doc["environment"]?.stringValue == environment else { return .rejected(.wrongEnvironment, revision: revision) }
        guard let document = parseDocument(doc) else { return .rejected(.malformed, revision: revision) }
        return .verified(document)
    }

    /// The typed document; nil when any field the client relies on has the
    /// wrong type (a malformed policy makes the whole document malformed).
    /// Unknown fields are ignored.
    static func parseDocument(_ o: JSONObject) -> EmergencyDocument? {
        guard let app = o["application_id"]?.stringValue, let env = o["environment"]?.stringValue,
            let revision = integer(o["revision"]), revision >= 0,
            let issued = o["issued_at"]?.stringValue.flatMap(EmergencyContract.parseTimestamp),
            let expires = o["expires_at"]?.stringValue.flatMap(EmergencyContract.parseTimestamp),
            let list = o["policies"]?.arrayValue
        else { return nil }
        var policies: [EmergencyPolicy] = []
        policies.reserveCapacity(list.count)
        for item in list {
            guard case .object(let p) = item, let policy = parsePolicy(p) else { return nil }
            policies.append(policy)
        }
        return EmergencyDocument(
            applicationId: app, environment: env, revision: revision, issuedAtMs: issued, expiresAtMs: expires,
            policies: policies)
    }

    static func parsePolicy(_ p: JSONObject) -> EmergencyPolicy? {
        /// Absent or null: nil; a string: the string; anything else: malformed.
        func optionalString(_ key: String) -> String?? {
            guard let v = p[key], !v.isNull else { return .some(nil) }
            guard let s = v.stringValue else { return nil }
            return .some(s)
        }
        guard let policyId = p["policy_id"]?.stringValue, let key = p["key"]?.stringValue,
            EmergencyContract.isFeatureKey(key, allowWildcard: true), let revision = integer(p["revision"]),
            let actionName = p["action"]?.stringValue, let priority = integer(p["priority"]),
            let rollout = integer(p["rollout_bp"]), let seed = p["rollout_seed"]?.stringValue,
            let reasonCode = p["reason_code"]?.stringValue,
            let severity = optionalString("severity"), let incident = optionalString("incident_id"),
            let message = optionalString("public_user_message"), let required = optionalString("required_version"),
            let fallback = optionalString("fallback"), let expiresRaw = optionalString("expires_at")
        else { return nil }
        var platforms: [String] = []
        if let v = p["target_platforms"], !v.isNull {
            guard let a = v.arrayValue else { return nil }
            for x in a {
                guard let s = x.stringValue else { return nil }
                platforms.append(s)
            }
        }
        var ranges: [EmergencyVersionRange] = []
        if let v = p["version_ranges"], !v.isNull {
            guard let a = v.arrayValue else { return nil }
            for x in a {
                guard case .object(let r) = x else { return nil }
                let min = r["min"] ?? .null
                let max = r["max"] ?? .null
                guard min.isNull || min.stringValue != nil, max.isNull || max.stringValue != nil else { return nil }
                ranges.append(EmergencyVersionRange(min: min.stringValue, max: max.stringValue))
            }
        }
        var expiresMs: Int64?
        if let expiresRaw {
            guard let ms = EmergencyContract.parseTimestamp(expiresRaw) else { return nil }
            expiresMs = ms
        }
        return EmergencyPolicy(
            policyId: policyId, key: key, revision: revision, action: EmergencyAction(wire: actionName),
            actionName: actionName, priority: priority, severity: severity, incidentId: incident,
            targetPlatforms: platforms, versionRanges: ranges, rolloutBasisPoints: rollout, rolloutSeed: seed,
            reasonCode: reasonCode, publicUserMessage: message, requiredVersion: required, fallback: fallback,
            expiresAt: expiresMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }, expiresAtMs: expiresMs)
    }

    /// An integral JSON number (the document carries integers only).
    static func integer(_ v: JSONValue?) -> Int? {
        switch v {
        case .int(let i)?: return i
        case .double(let d)? where d.rounded() == d && abs(d) < 9_007_199_254_740_992: return Int(d)
        default: return nil
        }
    }
}
