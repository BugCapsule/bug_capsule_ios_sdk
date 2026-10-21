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
        }
    }
}
