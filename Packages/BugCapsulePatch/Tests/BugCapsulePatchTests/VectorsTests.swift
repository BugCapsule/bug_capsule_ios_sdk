import BcpatchRuntime
import Foundation
import XCTest

@testable import BugCapsulePatch

/// The shared vectors, through the real C ABI on a Simulator.
final class VectorsTests: XCTestCase {
    private func fixture(_ name: String) throws -> Any {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    }

    private func call(_ engine: OpaquePointer?, _ op: UInt32, _ a: Data, _ b: Data = Data()) -> (code: String?, body: Data) {
        var out = BcpBuf(ptr: nil, len: 0)
        let status = a.withUnsafeBytes { ra in
            b.withUnsafeBytes { rb in
                bcp_call(engine, op, ra.bindMemory(to: UInt8.self).baseAddress, ra.count, rb.bindMemory(to: UInt8.self).baseAddress, rb.count, 0, &out)
            }
        }
        let body = out.ptr.map { Data(bytes: $0, count: out.len) } ?? Data()
        bcp_buf_free(out)
        if status == 0 { return (nil, body) }
        let e = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        return (e?["code"] as? String ?? "?", body)
    }

    func testEvalVectorsAgreeOnOutputFuelAndMemory() throws {
        let cases = try XCTUnwrap(fixture("eval") as? [[String: Any]])
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let types = try JSONSerialization.data(withJSONObject: ["input": c["input"], "output": c["output"]])
            let head = String(data: types.dropLast(), encoding: .utf8) ?? ""
            let request = Data("\(head),\"value\":\(c["value"] as? String ?? "")}".utf8)
            let module = try XCTUnwrap(Data(base64Encoded: c["module"] as? String ?? ""))
            let r = call(nil, 12, module, request)
            XCTAssertEqual(r.code, c["code"] as? String, name)
            guard r.code == nil else { continue }
            let doc = try XCTUnwrap(JSONSerialization.jsonObject(with: r.body) as? [String: Any], name)
            XCTAssertEqual(doc["steps"] as? Int, c["steps"] as? Int, name)
            XCTAssertEqual(doc["memory"] as? Int, c["memory"] as? Int, name)
            XCTAssertEqual(doc["output"] as? NSObject, c["expected"] as? NSObject, name)
        }
        XCTAssertGreaterThanOrEqual(cases.count, 40)
    }

    private func open(_ wire: [String: Any]) throws -> OpaquePointer? {
        var cfg = try XCTUnwrap(wire["target"] as? [String: Any])
        cfg["storeDir"] = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        cfg["installationId"] = "i"
        cfg["trustRoots"] = [wire["trustRoot"]]
        let json = try JSONSerialization.data(withJSONObject: cfg)
        var handle: OpaquePointer?
        var out = BcpBuf(ptr: nil, len: 0)
        let status = json.withUnsafeBytes { bcp_open($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &handle, &out) }
        bcp_buf_free(out)
        XCTAssertEqual(status, 0)
        return handle
    }

    func testArtifactAndChannelVectorsAgree() throws {
        let wire = try XCTUnwrap(fixture("wire") as? [String: Any])
        for a in try XCTUnwrap(wire["artifacts"] as? [[String: Any]]) {
            let e = try open(wire)
            let r = call(e, 2, try XCTUnwrap(Data(base64Encoded: a["bundle"] as? String ?? "")))
            XCTAssertEqual(r.code, a["code"] as? String, a["name"] as? String ?? "?")
            bcp_close(e)
        }
        for c in try XCTUnwrap(wire["channels"] as? [[String: Any]]) {
            let e = try open(wire)
            let r = call(e, 3, try XCTUnwrap(Data(base64Encoded: c["document"] as? String ?? "")), try XCTUnwrap(Data(base64Encoded: c["signature"] as? String ?? "")))
            XCTAssertEqual(r.code, c["code"] as? String, c["name"] as? String ?? "?")
            bcp_close(e)
        }
    }
}
