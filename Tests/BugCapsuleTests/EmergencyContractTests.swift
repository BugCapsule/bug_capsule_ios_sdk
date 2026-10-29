import CryptoKit
import Foundation
import XCTest

@testable import BugCapsule

/// The shared vectors of `spec-fixtures/emergency-v1` (emergency-client-v1
/// §9) and the verification rules of §2 and §4.
final class EmergencyContractTests: XCTestCase {
    private func fixture(_ name: String) throws -> JSONValue {
        try loadJSON(TestPaths.fixtures.appendingPathComponent("emergency-v1/\(name).json"))
    }

    // MARK: versions.json

    func testVersionCompareVectors() throws {
        let cases = try XCTUnwrap(try fixture("versions")["compare"]?.arrayValue)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let a = try XCTUnwrap(c["a"]?.stringValue)
            let b = try XCTUnwrap(c["b"]?.stringValue)
            XCTAssertEqual(EmergencyContract.compareVersions(a, b), c["result"]?.intValue, "compare(\(a), \(b))")
            // Antisymmetry.
            XCTAssertEqual(EmergencyContract.compareVersions(b, a), c["result"]?.intValue.map { -$0 }, "compare(\(b), \(a))")
        }
    }

    func testInvalidVersionVectors() throws {
        let cases = try XCTUnwrap(try fixture("versions")["invalid"]?.arrayValue)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let v = try XCTUnwrap(c["version"]?.stringValue)
            XCTAssertTrue(c["result"]?.isNull ?? false)
            XCTAssertNil(EmergencyContract.parseVersion(v), "\"\(v)\" must not parse")
            XCTAssertNil(EmergencyContract.compareVersions(v, "1.0.0"), "\"\(v)\"")
        }
    }

    func testVersionTargetedVectors() throws {
        let cases = try XCTUnwrap(try fixture("versions")["targeted"]?.arrayValue)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let ranges = (c["ranges"]?.arrayValue ?? []).map {
                EmergencyVersionRange(min: $0["min"]?.stringValue, max: $0["max"]?.stringValue)
            }
            let version = c["version"]?.stringValue
            XCTAssertEqual(
                EmergencyContract.versionTargeted(version, ranges), c["expected"]?.boolValue,
                "targeted(\(version ?? "nil"), \(ranges))")
        }
    }

    // MARK: rollout.json

    func testRolloutBucketVectors() throws {
        let cases = try XCTUnwrap(try fixture("rollout")["cases"]?.arrayValue)
        XCTAssertEqual(cases.count, 21)
        for c in cases {
            let seed = try XCTUnwrap(c["seed"]?.stringValue)
            let subject = try XCTUnwrap(c["subject"]?.stringValue)
            XCTAssertEqual(EmergencyContract.rolloutBucket(seed: seed, subject: subject), c["bucket"]?.intValue, "\(seed):\(subject)")
        }
        XCTAssertTrue(EmergencyContract.inRollout(basisPoints: 10000, seed: "s", subject: "x"))
        XCTAssertFalse(EmergencyContract.inRollout(basisPoints: 0, seed: "s", subject: "x"))
        XCTAssertTrue(EmergencyContract.inRollout(basisPoints: 1, seed: "s", subject: nil))
        XCTAssertTrue(EmergencyContract.inRollout(basisPoints: 1, seed: "s", subject: ""))
    }

    // MARK: evaluation.json

    func testEvaluationVectors() throws {
        let root = try fixture("evaluation")
        let docs = try XCTUnwrap(root["documents"]?.objectValue)
        let cases = try XCTUnwrap(root["cases"]?.arrayValue)
        XCTAssertEqual(cases.count, 27)
        for (i, c) in cases.enumerated() {
            let docName = try XCTUnwrap(c["document"]?.stringValue)
            let doc = try XCTUnwrap(docs[docName])
            let policies = try (doc["policies"]?.arrayValue ?? []).map { p -> EmergencyPolicy in
                try XCTUnwrap(EmergencyVerifier.parsePolicy(try XCTUnwrap(p.objectValue)), "policy of \(docName)")
            }
            let ctx = try XCTUnwrap(c["context"])
            let now = try XCTUnwrap(ctx["now"]?.stringValue.flatMap(EmergencyContract.parseTimestamp))
            let key = try XCTUnwrap(c["feature_key"]?.stringValue)
            let (d, winner) = EmergencyContract.evaluate(
                policies: policies, revision: try XCTUnwrap(doc["revision"]?.intValue), featureKey: key,
                context: EmergencyEvaluationContext(
                    platform: try XCTUnwrap(ctx["platform"]?.stringValue), appVersion: ctx["app_version"]?.stringValue,
                    subject: ctx["subject"]?.stringValue, nowMs: now),
                source: .policy)
            let e = try XCTUnwrap(c["expected"])
            let label = "case \(i) (\(docName), \(key))"
            XCTAssertEqual(d.featureKey, e["feature_key"]?.stringValue, label)
            XCTAssertEqual(d.allowed, e["allowed"]?.boolValue, label)
            XCTAssertEqual(d.action.rawValue, e["action"]?.stringValue, label)
            XCTAssertEqual(d.reasonCode, e["reason_code"]?.stringValue, label)
            XCTAssertEqual(d.policyId, e["policy_id"]?.stringValue, label)
            XCTAssertEqual(d.policyRevision, e["policy_revision"]?.intValue, label)
            XCTAssertEqual(d.documentRevision, e["document_revision"]?.intValue, label)
            XCTAssertEqual(d.publicUserMessage, e["public_user_message"]?.stringValue, label)
            XCTAssertEqual(d.requiredVersion, e["required_version"]?.stringValue, label)
            XCTAssertEqual(d.fallback, e["fallback"]?.stringValue, label)
            XCTAssertEqual(d.fallbackAvailable, e["fallback_available"]?.boolValue, label)
            XCTAssertEqual(winner?.policyId, d.policyId, label)
            XCTAssertEqual(d.source, .policy)
        }
    }

    // MARK: envelopes.json

    func testEnvelopeVectors() throws {
        let root = try fixture("envelopes")
        let env = try XCTUnwrap(root["environment"]?.stringValue)
        let app = try XCTUnwrap(root["application_id"]?.stringValue)
        let anchor = try EmergencyTrustAnchor.parse(try XCTUnwrap(root["anchor"]?.stringValue))
        let rotated = try EmergencyTrustAnchor.parse(try XCTUnwrap(root["anchor_rotated"]?.stringValue))
        XCTAssertEqual(anchor.applicationId, app)
        XCTAssertEqual(rotated.keys.count, 2)
        let cases = try XCTUnwrap(root["cases"]?.arrayValue)
        XCTAssertGreaterThanOrEqual(cases.count, 17)
        for c in cases {
            let name = try XCTUnwrap(c["name"]?.stringValue)
            let expected = try XCTUnwrap(c["expected"]?.stringValue)
            let envelope = try XCTUnwrap(c["envelope"])
            func check(_ outcome: EmergencyVerification, _ want: String, _ label: String) {
                switch outcome {
                case .verified(let doc):
                    XCTAssertEqual("ok", want, label)
                    if let rev = c["revision"]?.intValue { XCTAssertEqual(doc.revision, rev, label) }
                    XCTAssertEqual(doc.applicationId, app, label)
                    XCTAssertEqual(doc.environment, env, label)
                case .rejected(let reason, _):
                    XCTAssertEqual(reason.rawValue, want, label)
                }
            }
            check(EmergencyVerifier.verify(envelope: envelope, anchor: anchor, environment: env), expected, "\(name) with anchor")
            // With the rotated anchor the second key is trusted; nothing else changes.
            let rotatedExpected = name == "valid_second_key" ? "ok" : expected
            check(
                EmergencyVerifier.verify(envelope: envelope, anchor: rotated, environment: env), rotatedExpected,
                "\(name) with anchor_rotated")
        }
    }

    // MARK: anchors (§2)

    func testTrustAnchorParsing() throws {
        let signer = EmergencySigner()
        let ok = signer.anchor(app: "app-1")
        XCTAssertEqual(try EmergencyTrustAnchor.parse(ok).applicationId, "app-1")
        // Padded base64url is accepted too.
        let padded = EmergencyTrustAnchor.prefix + Data(
            JSON.encode([
                "app": "app-1", "keys": [["kid": .string(signer.kid), "alg": "ES256", "spki": .string(signer.spki)]],
            ]).utf8
        ).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        XCTAssertEqual(try EmergencyTrustAnchor.parse(padded).keys.count, 1)

        func invalid(_ s: String, _ label: String) {
            XCTAssertThrowsError(try EmergencyTrustAnchor.parse(s), label)
        }
        func anchor(_ o: JSONValue) -> String { EmergencyTrustAnchor.prefix + Base64URL.encode(JSON.encodeData(o)) }
        invalid("", "empty")
        invalid("bcek.v2." + ok.dropFirst(8), "other version")
        invalid("bcek.v1.!!!", "not base64")
        invalid(anchor(["keys": [["kid": "k", "alg": "ES256", "spki": .string(signer.spki)]]]), "no app")
        invalid(anchor(["app": "a", "keys": []]), "no keys")
        invalid(anchor(["app": "a", "keys": [["kid": "k", "alg": "RS256", "spki": .string(signer.spki)]]]), "other alg")
        invalid(anchor(["app": "a", "keys": [["kid": "k", "alg": "ES256", "spki": "AAAA"]]]), "bad spki")
        invalid(anchor(["app": "a", "keys": [["alg": "ES256", "spki": .string(signer.spki)]]]), "no kid")
        // One bad key invalidates the whole anchor.
        invalid(
            anchor([
                "app": "a",
                "keys": [
                    ["kid": "k1", "alg": "ES256", "spki": .string(signer.spki)], ["kid": "k2", "alg": "none", "spki": .string(signer.spki)],
                ],
            ]), "mixed")
    }

    // MARK: verification failures (§4)

    func testEachVerificationFailure() throws {
        let signer = EmergencySigner()
        let anchor = try EmergencyTrustAnchor.parse(signer.anchor(app: "app-1"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let doc = emergencyDocument(app: "app-1", revision: 3, issuedAt: now, expiresAt: now.addingTimeInterval(3600))
        func verify(_ e: JSONValue, env: String = "production") -> EmergencyRejection? {
            EmergencyVerifier.verify(envelope: e, anchor: anchor, environment: env).rejection
        }
        let good = signer.envelope(doc)
        XCTAssertNil(verify(good))

        func with(_ key: String, _ value: JSONValue?) -> JSONValue {
            var o = good.objectValue!
            o[key] = value
            return .object(o)
        }
        // 1. malformed
        XCTAssertEqual(verify(.array([good])), .malformed)
        XCTAssertEqual(verify(.string("x")), .malformed)
        XCTAssertEqual(verify(with("kid", nil)), .malformed)
        XCTAssertEqual(verify(with("payload", .int(1))), .malformed)
        XCTAssertEqual(verify(with("signature", .null)), .malformed)
        // Shape is checked before the format (spec order).
        var noKidOldFormat = with("kid", nil).objectValue!
        noKidOldFormat["format"] = "bugcapsule.emergency.v0"
        XCTAssertEqual(verify(.object(noKidOldFormat)), .malformed)
        // 2. unsupported_format
        XCTAssertEqual(verify(with("format", "bugcapsule.emergency.v2")), .unsupportedFormat)
        XCTAssertEqual(verify(with("format", nil)), .unsupportedFormat)
        XCTAssertEqual(verify(with("alg", "ES384")), .unsupportedFormat)
        // 3. unknown_key: a key inside the response is never trusted.
        XCTAssertEqual(verify(EmergencySigner(kid: "ek_other").envelope(doc)), .unknownKey)
        // 4. bad_signature
        let other = EmergencySigner(kid: signer.kid)
        XCTAssertEqual(verify(other.envelope(doc)), .badSignature)
        XCTAssertEqual(verify(with("signature", "!!!not-base64!!!")), .badSignature)
        XCTAssertEqual(verify(with("signature", .string(Base64URL.encode(Data([0x30, 0x02, 0x01]))))), .badSignature)
        XCTAssertEqual(verify(with("payload", "%%%")), .badSignature)
        var tampered = Array(Base64URL.decode(good["payload"]!.stringValue!)!)
        tampered[tampered.count / 2] ^= 0x01
        XCTAssertEqual(verify(with("payload", .string(Base64URL.encode(Data(tampered))))), .badSignature)
        // 5. malformed: signed, but not a JSON object.
        XCTAssertEqual(verify(signer.envelope(bytes: Data("[1,2]".utf8))), .malformed)
        XCTAssertEqual(verify(signer.envelope(bytes: Data("not json".utf8))), .malformed)
        // 6. unsupported_schema
        var future = doc
        future["schema_version"] = 2
        XCTAssertEqual(verify(signer.envelope(future)), .unsupportedSchema)
        var noSchema = doc
        noSchema["schema_version"] = nil
        XCTAssertEqual(verify(signer.envelope(noSchema)), .unsupportedSchema)
        // 7. wrong_application
        var otherApp = doc
        otherApp["application_id"] = "app-2"
        XCTAssertEqual(verify(signer.envelope(otherApp)), .wrongApplication)
        // 8. wrong_environment
        XCTAssertEqual(verify(good, env: "staging"), .wrongEnvironment)
        // A malformed policy field makes the whole document malformed.
        var badPolicy = doc
        badPolicy["policies"] = [emergencyPolicy(id: "p1", key: "checkout.pay", priority: .string("high"))]
        XCTAssertEqual(verify(signer.envelope(badPolicy)), .malformed)
        var badKey = doc
        badKey["policies"] = [emergencyPolicy(id: "p1", key: "Checkout.Pay")]
        XCTAssertEqual(verify(signer.envelope(badKey)), .malformed)
        var badExpiry = doc
        badExpiry["policies"] = [emergencyPolicy(id: "p1", key: "checkout.pay", expiresAt: "tomorrow")]
        XCTAssertEqual(verify(signer.envelope(badExpiry)), .malformed)
        var badDates = doc
        badDates["expires_at"] = 5
        XCTAssertEqual(verify(signer.envelope(badDates)), .malformed)
        // Rejections after the signature carry the document's revision (for the receipt).
        XCTAssertEqual(
            EmergencyVerifier.verify(envelope: signer.envelope(otherApp), anchor: anchor, environment: "production"),
            .rejected(.wrongApplication, revision: 3))
        XCTAssertEqual(
            EmergencyVerifier.verify(envelope: other.envelope(doc), anchor: anchor, environment: "production"),
            .rejected(.badSignature, revision: nil))
    }

    func testPaddedBase64AndUnknownFieldsAndActions() throws {
        let signer = EmergencySigner()
        let anchor = try EmergencyTrustAnchor.parse(signer.anchor(app: "app-1"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var doc = emergencyDocument(
            app: "app-1", revision: 1, issuedAt: now, expiresAt: now.addingTimeInterval(60),
            policies: [emergencyPolicy(id: "p1", key: "checkout.pay", action: "SELF_DESTRUCT")])
        doc["future_field"] = ["anything": true]
        var e = signer.envelope(doc).objectValue!
        // Padded base64url is accepted.
        let raw = Base64URL.decode(e["payload"]!.stringValue!)!
        e["payload"] = .string(raw.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_"))
        guard case .verified(let parsed) = EmergencyVerifier.verify(envelope: .object(e), anchor: anchor, environment: "production")
        else { return XCTFail("padded payload must verify") }
        // An unknown action fails safe: BLOCK.
        XCTAssertEqual(parsed.policies.first?.action, .block)
        XCTAssertEqual(parsed.policies.first?.actionName, "SELF_DESTRUCT")
    }

    func testFeatureKeyAndEnvironmentPatterns() {
        for k in ["checkout", "checkout.confirm_order", "a-b.c_d.0", String(repeating: "a", count: 64), "a.b.c.d.e.f.g.h"] {
            XCTAssertTrue(EmergencyContract.isFeatureKey(k), k)
        }
        for k in ["", "Checkout", "checkout.", ".x", "a..b", "checkout.*", String(repeating: "a", count: 65), "a.b.c.d.e.f.g.h.i", "é"] {
            XCTAssertFalse(EmergencyContract.isFeatureKey(k), k)
        }
        XCTAssertTrue(EmergencyContract.isFeatureKey("checkout.*", allowWildcard: true))
        XCTAssertFalse(EmergencyContract.isFeatureKey("*", allowWildcard: true))
        XCTAssertFalse(EmergencyContract.isFeatureKey(".*", allowWildcard: true))
        XCTAssertTrue(EmergencyContract.keyMatches("checkout.*", "checkout.pay"))
        XCTAssertTrue(EmergencyContract.keyMatches("checkout.*", "checkout.pay.card"))
        XCTAssertFalse(EmergencyContract.keyMatches("checkout.*", "checkout"))
        XCTAssertFalse(EmergencyContract.keyMatches("checkout.*", "checkoutx.pay"))
        XCTAssertTrue(EmergencyContract.isEnvironment("production"))
        XCTAssertTrue(EmergencyContract.isEnvironment("qa-2_eu"))
        XCTAssertFalse(EmergencyContract.isEnvironment("-prod"))
        XCTAssertFalse(EmergencyContract.isEnvironment("Prod"))
        XCTAssertFalse(EmergencyContract.isEnvironment(""))
        XCTAssertFalse(EmergencyContract.isEnvironment(String(repeating: "a", count: 41)))
    }

    func testBase64URL() {
        let data = Data((0..<64).map { UInt8($0 * 4) })
        let s = Base64URL.encode(data)
        XCTAssertFalse(s.contains("=") || s.contains("+") || s.contains("/"))
        XCTAssertEqual(Base64URL.decode(s), data)
        XCTAssertEqual(Base64URL.decode(data.base64EncodedString()), data)
        XCTAssertNil(Base64URL.decode("A"))
        XCTAssertNil(Base64URL.decode("ab$d"))
    }
}

// MARK: - test signing

/// A throwaway ES256 signing key and the anchor that trusts it.
struct EmergencySigner: @unchecked Sendable {
    let key = P256.Signing.PrivateKey()
    let kid: String

    init(kid: String = "ek_test\(UUID().uuidString.prefix(6).lowercased())") {
        self.kid = kid
    }

    var spki: String { Base64URL.encode(key.publicKey.derRepresentation) }

    func anchor(app: String, also others: [EmergencySigner] = []) -> String {
        let keys: [JSONValue] = ([self] + others).map { ["kid": .string($0.kid), "alg": "ES256", "spki": .string($0.spki)] }
        return EmergencyTrustAnchor.prefix + Base64URL.encode(JSON.encodeData(["app": .string(app), "keys": .array(keys)]))
    }

    func envelope(bytes: Data) -> JSONValue {
        let sig = try! key.signature(for: bytes)
        return [
            "format": "bugcapsule.emergency.v1", "alg": "ES256", "kid": .string(kid),
            "payload": .string(Base64URL.encode(bytes)), "signature": .string(Base64URL.encode(sig.derRepresentation)),
        ]
    }

    func envelope(_ doc: JSONObject) -> JSONValue { envelope(bytes: JSON.encodeData(.object(doc))) }
}

func emergencyTimestamp(_ d: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: d)
}

func emergencyDocument(
    app: String, environment: String = "production", revision: Int, issuedAt: Date, expiresAt: Date,
    policies: [JSONValue] = []
) -> JSONObject {
    [
        "type": "bugcapsule.emergency.policy-document", "schema_version": 1, "application_id": .string(app),
        "environment": .string(environment), "revision": .int(revision), "issued_at": .string(emergencyTimestamp(issuedAt)),
        "expires_at": .string(emergencyTimestamp(expiresAt)), "policies": .array(policies),
    ]
}

func emergencyPolicy(
    id: String, key: String, action: String = "BLOCK", revision: Int = 1, priority: JSONValue = 0,
    reasonCode: String = "INCIDENT", message: JSONValue = "Temporarily unavailable.", rolloutBasisPoints: Int = 10000,
    platforms: [String] = [], expiresAt: JSONValue = .null, fallback: JSONValue = .null
) -> JSONValue {
    [
        "policy_id": .string(id), "key": .string(key), "revision": .int(revision), "action": .string(action),
        "priority": priority, "severity": "P0", "incident_id": .null,
        "target_platforms": .array(platforms.map { .string($0) }), "version_ranges": [],
        "rollout_bp": .int(rolloutBasisPoints), "rollout_seed": "seed", "reason_code": .string(reasonCode),
        "public_user_message": message, "required_version": .null, "fallback": fallback, "expires_at": expiresAt,
    ]
}
