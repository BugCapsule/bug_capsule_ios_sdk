import Foundation
import XCTest

@testable import BugCapsule

/// `spec/fixtures/conformance/*.json`, generated from the Dart reference.
final class ConformanceTests: XCTestCase {
    private func conformance(_ name: String) throws -> JSONValue {
        try loadJSON(TestPaths.fixtures.appendingPathComponent("conformance/\(name).json"))
    }

    func testRequestKeys() throws {
        let cases = try conformance("request-keys")["cases"]!.arrayValue!
        XCTAssertGreaterThan(cases.count, 20)
        for c in cases {
            let name = c["name"]!.stringValue!
            let rules: [EndpointRule] = (c["rules"]?.arrayValue ?? []).map { r in
                EndpointRule(
                    r["method"]!.stringValue!, r["path"]!.stringValue!,
                    ignoreQuery: Set((r["ignoreQuery"]?.arrayValue ?? []).compactMap(\.stringValue)),
                    ignoreBodyFields: Set((r["ignoreBodyFields"]?.arrayValue ?? []).compactMap(\.stringValue)),
                    matchBodyFields: r["matchBodyFields"]?.arrayValue?.compactMap(\.stringValue))
            }
            let builder = RequestKeyBuilder(
                rules: rules,
                globalIgnoreQuery: c["globalIgnoreQuery"]?.arrayValue.map { Set($0.compactMap(\.stringValue)) }
                    ?? RequestKeyBuilder.defaultIgnoreQuery,
                globalIgnoreBodyFields: Set((c["globalIgnoreBodyFields"]?.arrayValue ?? []).compactMap(\.stringValue)))
            var url = c["url"]!.stringValue!
            var body: RequestKeyBuilder.Body?
            switch c["body"] {
            case .string(let s)?: body = .text(s)
            case nil, .null?: body = nil
            case let v?: body = .json(v)
            }
            if c["redact"]?.boolValue == true {
                let redactor = Redactor(extraKeys: (c["redactKeys"]?.arrayValue ?? []).compactMap(\.stringValue))
                url = redactor.redactURL(url)
                if case .json(let v)? = body { body = .json(redactor.redactJSON(v)) }
            }
            XCTAssertEqual(
                builder.key(method: c["method"]!.stringValue!, url: url, body: body), c["expectedKey"]!.stringValue!,
                name)
        }
    }

    func testFailureSignatures() throws {
        let cases = try conformance("signatures")["cases"]!.arrayValue!
        for c in cases {
            let kind = FailureKind(rawValue: c["kind"]!.stringValue!)!
            XCTAssertEqual(
                FailureSignature.compute(kind, c["type"]!.stringValue!, c["message"]!.stringValue!),
                c["expected"]!.stringValue!)
        }
    }

    func testRedaction() throws {
        let f = try conformance("redaction")
        let redactor = Redactor(
            extraKeys: f["extraKeys"]!.arrayValue!.compactMap(\.stringValue),
            extraHeaders: f["extraHeaders"]!.arrayValue!.compactMap(\.stringValue))
        XCTAssertEqual(Redactor.placeholder, f["placeholder"]!.stringValue!)
        for c in f["keys"]!.arrayValue! {
            let key = c["key"]!.stringValue!
            XCTAssertEqual(redactor.isSensitiveKey(key), c["sensitive"]!.boolValue!, "key \(key)")
            XCTAssertEqual(redactor.isSensitiveQueryKey(key), c["sensitiveQuery"]!.boolValue!, "query key \(key)")
        }
        for c in f["headers"]!.arrayValue! {
            XCTAssertEqual(redactor.isSensitiveHeader(c["name"]!.stringValue!), c["sensitive"]!.boolValue!)
        }
        for c in f["scrubText"]!.arrayValue! {
            XCTAssertEqual(redactor.scrubText(c["input"]!.stringValue!), c["output"]!.stringValue!)
        }
        for c in f["redactUrl"]!.arrayValue! {
            let out = redactor.redactURL(c["input"]!.stringValue!)
            XCTAssertEqual(out, c["output"]!.stringValue!)
            let params = try DartURI.parse(out).queryParametersAll().flatMap { p in p.values.map { [p.name, $0] } }
            let expected = c["params"]!.arrayValue!.map { $0.arrayValue!.compactMap(\.stringValue) }
            XCTAssertEqual(params, expected, c["input"]!.stringValue!)
        }
        for c in f["redactHeaders"]!.arrayValue! {
            let out = redactor.redactHeaders(c["input"]!.objectValue!)
            XCTAssertEqual(JSONValue.object(out), c["output"]!)
            XCTAssertEqual(out.keys, c["output"]!.objectValue!.keys)
        }
        for c in f["redactJson"]!.arrayValue! {
            let out = redactor.redactJSON(c["input"]!)
            XCTAssertEqual(out, c["output"]!)
            // Embedded JSON strings are re-encoded exactly like Dart.
            XCTAssertEqual(JSON.encode(out), JSON.encode(c["output"]!))
        }
        for c in f["redactText"]!.arrayValue! {
            XCTAssertEqual(
                redactor.redactText(
                    fieldId: c["id"]!.stringValue!, value: c["value"]!.stringValue!,
                    sensitive: c["sensitive"]?.boolValue ?? false),
                c["output"]!.stringValue!)
        }
    }

    func testVerdicts() throws {
        let f = try conformance("verdicts")
        XCTAssertEqual(Set(f["expectedDivergences"]!.arrayValue!.compactMap(\.stringValue)), DivergencePolicy.expected)
        for c in f["cases"]!.arrayValue! {
            let name = c["name"]!.stringValue!
            let reports = c["reports"]!.arrayValue!.map { r -> ReplayReport in
                var o = r.objectValue!
                if o["attempt"] == nil { o["attempt"] = 1 }
                // The fixture lists divergences by type and other failures by signature.
                if let ds = o["divergences"]?.arrayValue {
                    o["divergences"] = .array(ds.map { $0.stringValue.map { ["type": .string($0), "detail": ""] } ?? $0 })
                }
                if let fs = o["otherFailures"]?.arrayValue {
                    o["otherFailures"] = .array(
                        fs.map { f in
                            f.stringValue.map { ["kind": "exception", "signature": .string($0), "type": "E"] } ?? f
                        })
                }
                return ReplayReport(json: o)
            }
            let kind = RunKind(rawValue: c["kind"]!.stringValue!)!
            let e = evaluateRun(kind, requestedAttempts: c["requested"]!.intValue!, reports: reports)
            XCTAssertEqual(e.verdict.rawValue, c["verdict"]!.stringValue!, name)
            XCTAssertEqual(e.verdict.wire, c["wire"]!.stringValue!, name)
            XCTAssertEqual(e.exitCode, c["exitCode"]!.intValue!, name)
            XCTAssertEqual(e.validAttempts, c["validAttempts"]!.intValue!, name)
            XCTAssertEqual(e.attempts.map(\.status.rawValue), c["attemptStatuses"]!.arrayValue!.compactMap(\.stringValue), name)
            XCTAssertEqual(e.reasonCodes, c["reasonCodes"]!.arrayValue!.compactMap(\.stringValue), name)
        }
    }

    // MARK: interactions.json (capsule-v2)

    func testInteractionTypedValues() throws {
        let cases = try conformance("interactions")["typedValues"]!.arrayValue!
        XCTAssertGreaterThanOrEqual(cases.count, 15)
        for c in cases {
            let name = c["name"]!.stringValue!
            let encoded = c["encoded"]!
            let reencoded = TypedValue.encode(TypedValue.decode(encoded))
            // Tagged map entries keep their order (arrays); plain objects
            // decode to dictionaries and re-encode with sorted keys.
            XCTAssertEqual(reencoded, c["reencoded"]!, name)
            XCTAssertEqual(
                RequestKeyBuilder.canonicalJSON(reencoded), RequestKeyBuilder.canonicalJSON(c["reencoded"]!), name)
            XCTAssertEqual(RequestKeyBuilder.canonicalJSON(encoded), c["canonical"]!.stringValue!, name)
            XCTAssertEqual(RequestKeyBuilder.hash(RequestKeyBuilder.canonicalJSON(encoded)), c["hash"]!.stringValue!, name)
        }
    }

    func testInteractionKeys() throws {
        let cases = try conformance("interactions")["keys"]!.arrayValue!
        XCTAssertGreaterThanOrEqual(cases.count, 6)
        for c in cases {
            XCTAssertEqual(
                interactionKey(c["scope"]!.stringValue!, c["method"]?.stringValue, c["args"] ?? .null),
                c["key"]!.stringValue!)
        }
    }

    func testInteractionPayloads() throws {
        let cases = try conformance("interactions")["payloads"]!.arrayValue!
        XCTAssertGreaterThanOrEqual(cases.count, 7)
        let redactor = Redactor()
        for c in cases {
            let name = c["name"]!.stringValue!
            let encoder = PayloadEncoder(
                redactor: { redactor },
                budget: PayloadBudget(InteractionLimits(maxPayloadBytes: c["maxPayloadBytes"]?.intValue ?? 64 * 1024)),
                stats: DependencyStats(), now: { 0 }, captureBinary: c["captureBinary"]?.boolValue ?? false,
                redactedReplayable: c["redactedReplayable"]?.boolValue ?? false)
            let payload = encoder.encode(TypedValue.decode(c["value"]!), kind: c["kind"]?.stringValue)
            XCTAssertEqual(payload.json, c["payload"]!, name)
        }
    }

    func testInteractionSchedules() throws {
        let cases = try conformance("interactions")["schedules"]!.arrayValue!
        XCTAssertGreaterThanOrEqual(cases.count, 5)
        for c in cases {
            let name = c["name"]!.stringValue!
            let result = runSchedule(c)
            XCTAssertEqual(result.matched, c["matched"]!, name)
            XCTAssertEqual(result.deliveries, c["deliveries"]!, name)
            XCTAssertEqual(result.unused, c["unused"]!, name)
        }
    }

    /// The conformance driver of `generate_conformance.dart` (`_schedule`).
    private func runSchedule(_ c: JSONValue) -> (matched: JSONValue, deliveries: JSONValue, unused: JSONValue) {
        var seq = 0
        let events = c["events"]!.arrayValue!.map { e -> BugCapsuleEvent in
            seq += 1
            return BugCapsuleEvent(seq: seq, t: e["t"]!.intValue!, type: e["type"]!.stringValue!, data: e["data"]!.objectValue!)
        }
        let clock = ManualClock()
        var deliveries: [JSONValue] = []
        let script = InteractionScript(
            events: events, dependencies: Set(c["deps"]!.arrayValue!.compactMap(\.stringValue)), clock: { clock.now },
            base: c["base"]!.intValue!)
        let deliver: (RecordedInteraction) -> Void = { r in deliveries.append(["seq": .int(r.event.seq), "at": .int(clock.now)]) }
        func advance(to target: Int) {
            while let next = script.nextDueAt, next <= target {
                if next > clock.now { clock.now = next }
                script.pump()
            }
            clock.now = target
            script.pump()
        }
        var matched: [JSONValue] = []
        for step in c["steps"]!.arrayValue! {
            advance(to: step["at"]!.intValue!)
            switch step["op"]!.stringValue! {
            case "runStarted": script.runStarted(at: clock.now)
            case "bind": script.bind(step["scope"]!.stringValue!, deliver)
            case "unbind": script.unbind(step["scope"]!.stringValue!)
            case "take":
                let r = script.take(dep: step["dep"]!.stringValue!, type: step["type"]!.stringValue!, key: step["key"]!.stringValue!)
                matched.append(r.map { .int($0.event.seq) } ?? .null)
            case "takeNext":
                let r = script.takeNext(
                    scope: step["scope"]!.stringValue!, types: Set(step["types"]!.arrayValue!.compactMap(\.stringValue)))
                matched.append(r.map { .int($0.event.seq) } ?? .null)
            default: XCTFail("unknown op")
            }
            script.pump()
        }
        while let next = script.nextDueAt { advance(to: next) }
        let unused = script.unused(failureT: c["failureT"]?.intValue).map { t, d -> JSONValue in
            ["type": .string(t), "detail": .string(d)]
        }
        return (.array(matched), .array(deliveries), .array(unused))
    }
}
