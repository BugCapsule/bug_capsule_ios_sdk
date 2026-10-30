import Foundation
import XCTest

@testable import BugCapsulePatch

private final class Fake: PatchTransport, @unchecked Sendable {
    var channel: SignedChannel
    var artifact: Data
    var downloads = 0
    var offline = false

    init(_ channel: SignedChannel, _ artifact: Data) {
        self.channel = channel
        self.artifact = artifact
    }

    func fetchChannel(etag: String?) async throws -> SignedChannel? {
        if offline { throw URLError(.notConnectedToInternet) }
        return etag == channel.etag ? nil : channel
    }

    func fetchArtifact(digest: String) async throws -> Data {
        downloads += 1
        return artifact
    }

    func postReceipts(_ batch: Data) async throws {
        if offline { throw URLError(.notConnectedToInternet) }
    }
}

/// The real runtime on a Simulator, with a fake network.
final class UpdaterTests: XCTestCase {
    private var wire: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "wire", withExtension: "json", subdirectory: "Fixtures"))
        wire = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func named(_ list: String, _ name: String) -> [String: Any] {
        (wire[list] as? [[String: Any]] ?? []).first { $0["name"] as? String == name } ?? [:]
    }

    private func bundle(_ name: String) -> Data { Data(base64Encoded: named("artifacts", name)["bundle"] as? String ?? "") ?? Data() }

    private func channel(_ name: String) -> SignedChannel {
        let c = named("channels", name)
        return SignedChannel(document: Data(base64Encoded: c["document"] as? String ?? "") ?? Data(), signature: Data(base64Encoded: c["signature"] as? String ?? "") ?? Data(), etag: name)
    }

    private func open(_ dir: String) -> BugCapsulePatch {
        let t = wire["target"] as? [String: Any] ?? [:]
        let m = (t["modules"] as? [[String: String]])?.first ?? [:]
        return BugCapsulePatch.open(
            config: PatchConfig(
                storeDir: dir, projectId: t["projectId"] as? String ?? "", applicationId: t["applicationId"] as? String ?? "",
                environment: t["environment"] as? String ?? "", distributionProfile: t["distributionProfile"] as? String ?? "",
                baseBuildId: t["baseBuildId"] as? String ?? "", installationId: "i", trustRoots: [wire["trustRoot"] as? String ?? ""],
                platform: t["platform"] as? String ?? ""
            ),
            modules: [PatchContract(id: m["id"] ?? "", inputSchema: m["input"] ?? "", outputSchema: m["output"] ?? "")]
        )
    }

    private func dir() -> String { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path }

    func testDownloadsStagesAndKeepsTheRunningGeneration() async throws {
        let patch = open(dir())
        let r = await PatchUpdater(patch: patch, transport: Fake(channel("valid"), bundle("valid"))).checkForUpdate()
        XCTAssertEqual(r.state, .restartRequired)
        XCTAssertEqual(r.artifactDigest, wire["artifactDigest"] as? String)
        XCTAssertEqual(try patch.status()["state"] as? String, "BASE")
    }

    func testFailedDownloadIsRetried() async throws {
        let patch = open(dir())
        let net = Fake(channel("valid"), bundle("payload bit flip"))
        let updater = PatchUpdater(patch: patch, transport: net)
        let first = await updater.checkForUpdate()
        XCTAssertEqual(first.reason, "verify_failed")
        net.artifact = bundle("valid")
        let second = await updater.checkForUpdate()
        XCTAssertEqual(second.state, .restartRequired)
        XCTAssertEqual(net.downloads, 2)
    }

    func testForgedMetadataAndOutagesAreResults() async throws {
        let patch = open(dir())
        let forged = await PatchUpdater(patch: patch, transport: Fake(channel("bad signer"), bundle("valid"))).checkForUpdate()
        XCTAssertEqual(forged.reason, "bad_signature")
        let net = Fake(channel("valid"), bundle("valid"))
        net.offline = true
        let outage = await PatchUpdater(patch: patch, transport: net).checkForUpdate()
        XCTAssertEqual(outage.state, .failed)
    }

    func testReceiptsAreOnlyAcknowledgedOnceUploaded() async throws {
        let patch = open(dir())
        let net = Fake(channel("valid"), bundle("valid"))
        let updater = PatchUpdater(patch: patch, transport: net)
        _ = await updater.checkForUpdate()
        net.offline = true
        do {
            _ = try await updater.flushReceipts()
            XCTFail("expected the upload to fail")
        } catch {}
        XCTAssertFalse((try patch.receipts()["receipts"] as? [Any] ?? []).isEmpty)
        net.offline = false
        let sent = try await updater.flushReceipts()
        XCTAssertGreaterThan(sent, 0)
        XCTAssertTrue((try patch.receipts()["receipts"] as? [Any] ?? []).isEmpty)
    }
}
