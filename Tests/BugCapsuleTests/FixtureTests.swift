import Foundation
import XCTest

@testable import BugCapsule

/// Shared capsule fixtures (`spec/fixtures/capsule-v1`, `capsule-v2`) and
/// the vendored copy check.
final class FixtureTests: XCTestCase {
    func testVendoredFixturesMatchUpstream() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: TestPaths.upstreamFixtures.path) else {
            throw XCTSkip("bug_capsule_flutter_sdk is not checked out next to this repository")
        }
        func listing(_ root: URL) throws -> [String: Data] {
            var out: [String: Data] = [:]
            let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
            for case let url as URL in e where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                let rel = String(url.path.dropFirst(root.path.count))
                out[rel] = try Data(contentsOf: url)
            }
            return out
        }
        let mine = try listing(TestPaths.fixtures)
        let upstream = try listing(TestPaths.upstreamFixtures)
        XCTAssertEqual(
            Set(mine.keys), Set(upstream.keys),
            "spec-fixtures differs from ../bug_capsule_flutter_sdk/spec/fixtures; run tool/sync_spec.sh there")
        for (k, v) in upstream {
            XCTAssertEqual(mine[k], v, "\(k) differs from upstream; run tool/sync_spec.sh")
        }
    }

    func testValidFixturesDecodeAndReencode() throws {
        let files = try fixtureFiles("capsule-v1/valid")
        XCTAssertGreaterThanOrEqual(files.count, 7)
        for file in files {
            let doc = try loadJSON(file)["document"]!
            let gz = try Gzip.compress(JSON.encodeData(doc))
            let capsule = try CapsuleCodec.decode(gz)
            let reencoded = CapsuleCodec.toJSON(capsule)
            XCTAssertNil(validateCapsuleDocument(reencoded), file.lastPathComponent)
            // Round trip through bytes as well.
            let again = try CapsuleCodec.decode(try CapsuleCodec.encode(capsule))
            XCTAssertEqual(again.manifest.capsuleId, capsule.manifest.capsuleId)
            XCTAssertEqual(again.events.count, capsule.events.count, file.lastPathComponent)
        }
    }

    func testValidV2FixturesDecodeAndReencodeAsV2() throws {
        let files = try fixtureFiles("capsule-v2/valid")
        XCTAssertGreaterThanOrEqual(files.count, 5)
        for file in files {
            let doc = try loadJSON(file)["document"]!
            let capsule = try CapsuleCodec.decode(try Gzip.compress(JSON.encodeData(doc)))
            XCTAssertFalse(capsule.manifest.dependencies.isEmpty, file.lastPathComponent)
            let reencoded = CapsuleCodec.toJSON(capsule)
            XCTAssertEqual(reencoded["specVersion"], 2, file.lastPathComponent)
            XCTAssertNil(validateCapsuleDocument(reencoded), file.lastPathComponent)
            XCTAssertEqual(
                reencoded["manifest"]?["dependencies"]?.arrayValue?.count,
                doc["manifest"]?["dependencies"]?.arrayValue?.count, file.lastPathComponent)
            let again = try CapsuleCodec.decode(try CapsuleCodec.encode(capsule))
            XCTAssertEqual(again.manifest.dependencies, capsule.manifest.dependencies, file.lastPathComponent)
            XCTAssertEqual(again.events, capsule.events, file.lastPathComponent)
        }
    }

    func testV2FixtureModel() throws {
        let doc = try loadJSON(TestPaths.fixtures.appendingPathComponent("capsule-v2/valid/websocket.json"))["document"]!
        let capsule = try CapsuleCodec.fromJSON(doc.objectValue!)
        let dep = try XCTUnwrap(capsule.manifest.dependency("ws"))
        XCTAssertEqual(dep.kind, DependencyKinds.websocket)
        XCTAssertEqual(dep.adapter, "bug_capsule.web_socket_channel")
        XCTAssertEqual(dep.schema, 1)
        XCTAssertTrue(dep.required)
        XCTAssertEqual(dep.coverage, .complete)
        XCTAssertEqual(dep.tested.map(\.package), ["web_socket_channel"])
        let binary = capsule.events.first { $0.seq == 7 }!
        let payload = try XCTUnwrap(InteractionPayload(json: binary.data["payload"]))
        XCTAssertEqual(payload.mode, .metadata)
        XCTAssertFalse(payload.replayable)
        XCTAssertEqual(payload.bytes, 512)
    }

    func testV1DocumentIgnoresDependenciesAndStaysV1() throws {
        var doc = try loadJSON(TestPaths.fixtures.appendingPathComponent("capsule-v1/valid/minimal.json"))["document"]!
            .objectValue!
        var manifest = doc["manifest"]!.objectValue!
        manifest["dependencies"] = "not validated in v1"
        doc["manifest"] = .object(manifest)
        let capsule = try CapsuleCodec.fromJSON(doc)
        XCTAssertTrue(capsule.manifest.dependencies.isEmpty)
        XCTAssertEqual(CapsuleCodec.toJSON(capsule)["specVersion"], 1)
        XCTAssertNil(CapsuleCodec.toJSON(capsule)["manifest"]?["dependencies"])
    }

    func testInvalidV2FixturesNameTheErrorPath() throws {
        let files = try fixtureFiles("capsule-v2/invalid")
        XCTAssertGreaterThanOrEqual(files.count, 25)
        try assertInvalid(files)
    }

    func testReaderRejectsNewerThanV2() throws {
        let doc = try loadJSON(TestPaths.fixtures.appendingPathComponent("capsule-v2/invalid/spec-version-3.json"))
        XCTAssertThrowsError(try CapsuleCodec.decode(try Gzip.compress(JSON.encodeData(doc["document"]!)))) { e in
            XCTAssertEqual(
                (e as? CapsuleFormatError)?.message, "$.specVersion 3 is newer than this reader (v2); update BugCapsule")
        }
    }

    func testIosFixtureCarriesRuntimeAndCapabilities() throws {
        let doc = try loadJSON(TestPaths.fixtures.appendingPathComponent("capsule-v1/valid/ios-runtime.json"))["document"]!
        let capsule = try CapsuleCodec.fromJSON(doc.objectValue!)
        XCTAssertEqual(capsule.manifest.runtimeName, "ios")
        XCTAssertEqual(capsule.manifest.capability("input.pointer.replay"), "unsupported")
        XCTAssertEqual(capsule.manifest.runtime?.frameworks, ["uikit", "swiftui"])
    }

    func testInvalidFixturesNameTheErrorPath() throws {
        let files = try fixtureFiles("capsule-v1/invalid")
        XCTAssertGreaterThanOrEqual(files.count, 30)
        XCTAssertTrue(files.contains { $0.lastPathComponent == "spec-version-3.json" })
        XCTAssertFalse(files.contains { $0.lastPathComponent == "spec-version-2.json" }, "v2 readers accept specVersion 2")
        try assertInvalid(files)
    }

    private func assertInvalid(_ files: [URL]) throws {
        for file in files {
            let fixture = try loadJSON(file)
            let doc = fixture["document"]!
            let path = fixture["errorPath"]!.stringValue!
            do {
                _ = try CapsuleCodec.decode(try Gzip.compress(JSON.encodeData(doc)))
                XCTFail("\(file.lastPathComponent) was accepted")
            } catch let e as CapsuleFormatError {
                let msg = e.message.hasPrefix("malformed capsule: ") ? String(e.message.dropFirst(19)) : e.message
                XCTAssertTrue(
                    msg.hasPrefix(path + " ") || msg == path,
                    "\(file.lastPathComponent): expected an error at \(path), got \(e.message)")
            }
        }
    }
}

final class CodecBoundsTests: XCTestCase {
    func testRejectsNonGzip() {
        XCTAssertThrowsError(try CapsuleCodec.decode(Data("{}".utf8))) { e in
            XCTAssertEqual((e as? CapsuleFormatError)?.message, "not a gzip file")
        }
    }

    func testGzipBombStopsWhileInflating() throws {
        // 64 MiB of zeros compresses to ~64 KiB.
        let bomb = try Gzip.compress(Data(count: 64 * 1024 * 1024))
        XCTAssertLessThan(bomb.count, 200_000)
        let start = Date()
        XCTAssertThrowsError(try CapsuleCodec.decode(bomb, maxDecompressedBytes: 1024 * 1024)) { e in
            XCTAssertEqual(
                (e as? CapsuleFormatError)?.message, "decompressed capsule exceeds \(1024 * 1024) bytes")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertThrowsError(try Gzip.decompress(bomb, maxBytes: 100_000)) { e in
            XCTAssertEqual(e as? GzipError, .tooLarge(100_000))
        }
    }

    func testTruncatedGzipIsRejected() throws {
        let gz = try Gzip.compress(Data(repeating: 65, count: 10000))
        XCTAssertThrowsError(try CapsuleCodec.decode(gz.prefix(gz.count / 2)))
    }

    func testJSONValueCountIsCheckedBeforeParsing() throws {
        // 4,000,001 values: "[" + "0," * 4_000_000 + "0]"
        var s = "["
        s += String(repeating: "0,", count: 4_000_000)
        s += "0]"
        XCTAssertGreaterThan(CapsuleCodec.countJSONValues(Array(s.utf8), limit: CapsuleLimits.maxJSONValues), 4_000_000)
        XCTAssertThrowsError(try CapsuleCodec.decode(try Gzip.compress(Data(s.utf8)))) { e in
            XCTAssertEqual((e as? CapsuleFormatError)?.message, "$ has more than 4000000 JSON values")
        }
        // Separators inside strings do not count.
        XCTAssertEqual(CapsuleCodec.countJSONValues(Array(#"{"a":"x,y,[{","b":"\",{"}"#.utf8), limit: 100), 3)
    }

    func testVeryDeepNestingIsRejectedWithoutRecursingForever() throws {
        let deep = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)
        XCTAssertThrowsError(try CapsuleCodec.decode(try Gzip.compress(Data(deep.utf8)))) { e in
            XCTAssertTrue((e as? CapsuleFormatError)?.message.contains("$ nests deeper than 100 levels") == true, "\(e)")
        }
    }

    func testIntegersStayIntegers() throws {
        let v = try JSON.parse(#"{"a":1,"b":1.0,"c":-0.5,"d":1e3,"e":12345678901234567890}"#)
        XCTAssertEqual(v["a"], .int(1))
        XCTAssertEqual(v["b"], .double(1.0))
        XCTAssertEqual(v["d"], .double(1000))
        XCTAssertEqual(JSON.encode(v), #"{"a":1,"b":1.0,"c":-0.5,"d":1000.0,"e":12345678901234567000.0}"#)
    }

    func testDoubleFormattingMatchesDart() {
        let cases: [(Double, String)] = [
            (1.5, "1.5"), (100, "100.0"), (0.1, "0.1"), (1e21, "1e+21"), (1.5e21, "1.5e+21"), (1e-7, "1e-7"),
            (0.000001, "0.000001"), (123456.789, "123456.789"), (-2.25, "-2.25"), (0, "0.0"), (402, "402.0"),
            (5e-324, "5e-324"), (1.7976931348623157e308, "1.7976931348623157e+308"),
        ]
        for (d, s) in cases { XCTAssertEqual(JSON.formatDouble(d), s, "\(d)") }
    }

    func testStringEscapesMatchDart() {
        XCTAssertEqual(JSON.encode(.string("a\"b\\c\n\t\u{01}/é中")), "\"a\\\"b\\\\c\\n\\t\\u0001/é中\"")
    }
}
