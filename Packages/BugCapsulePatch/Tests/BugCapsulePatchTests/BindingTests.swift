import BugCapsule
import Foundation
import XCTest

@testable import BugCapsulePatch

/// The real runtime on a Simulator: a replay pin must change what callers run.
final class BindingTests: XCTestCase {
    private var wire: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "wire", withExtension: "json", subdirectory: "Fixtures"))
        wire = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func artifact(_ name: String) -> Data {
        let a = (wire["artifacts"] as? [[String: Any]] ?? []).first { $0["name"] as? String == name }
        return Data(base64Encoded: a?["bundle"] as? String ?? "") ?? Data()
    }

    private var module: PatchModule<Int, Int> {
        let m = ((wire["target"] as? [String: Any])?["modules"] as? [[String: String]])?.first ?? [:]
        return PatchModule(id: m["id"] ?? "", inputSchema: m["input"] ?? "", outputSchema: m["output"] ?? "", encode: { $0 }, decode: { $0 as? Int ?? -1 }, fallback: { $0 })
    }

    private func binding(_ dir: String) -> BugCapsulePatchBinding {
        let t = wire["target"] as? [String: Any] ?? [:]
        return BugCapsulePatchBinding(
            config: PatchConfig(
                storeDir: dir, projectId: t["projectId"] as? String ?? "", applicationId: t["applicationId"] as? String ?? "",
                environment: t["environment"] as? String ?? "", distributionProfile: t["distributionProfile"] as? String ?? "",
                baseBuildId: t["baseBuildId"] as? String ?? "", installationId: "install-1", trustRoots: [wire["trustRoot"] as? String ?? ""],
                platform: t["platform"] as? String ?? ""),
            modules: [module.contract])
    }

    private func dir() -> String { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path }

    func testHoldersOfTheHandleFollowAReplayPin() throws {
        let b = binding(dir())
        let held = b.patch
        XCTAssertEqual(held.call(module, 1).value, 1, "live store is on base")
        let id = try b.pinForReplay(bundle: artifact("valid"), keyring: nil, keyringSignature: nil)
        XCTAssertNotNil(id?.patchSetDigest)
        XCTAssertTrue(b.patch === held)
        XCTAssertEqual(held.call(module, 1).value, 2, "the handle now runs the pinned artifact")
        XCTAssertEqual(try held.status()["replay"] as? Bool, true)
        XCTAssertThrowsError(try held.stage(artifact("valid")), "replay is read-only")
    }

    func testABareBasePinIgnoresAPatchActiveInTheLiveStore() throws {
        let d = dir()
        let live = binding(d)
        try live.patch.stage(artifact("valid"))
        let reopened = binding(d)
        // The first handle still owns the store lock, so release it through a pin.
        _ = try live.pinForReplay(bundle: nil, keyring: nil, keyringSignature: nil)
        XCTAssertEqual(reopened.patch.call(module, 1).value, 2)
        let held = reopened.patch
        let id = try reopened.pinForReplay(bundle: nil, keyring: nil, keyringSignature: nil)
        XCTAssertNil(id?.patchSetDigest)
        XCTAssertEqual(held.call(module, 1).value, 1)
    }

    func testARefusedArtifactThrowsAndLeavesTheHandleAlone() throws {
        let b = binding(dir())
        let held = b.patch
        XCTAssertThrowsError(try b.pinForReplay(bundle: artifact("payload bit flip"), keyring: nil, keyringSignature: nil))
        XCTAssertTrue(held.available)
    }
}
