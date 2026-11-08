#if os(iOS)
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

/// Throws like the HTTP transport on a 503, or returns `next`.
private final class Throwing503: PatchTransport, @unchecked Sendable {
    var next: SignedChannel?
    var error: PatchHTTPError?
    var downloads = 0
    var etags: [String?] = []
    let artifact: Data
    init(_ artifact: Data) { self.artifact = artifact }
    func fetchChannel(etag: String?) async throws -> SignedChannel? {
        etags.append(etag)
        if let error { throw error }
        return next
    }
    func fetchArtifact(digest: String) async throws -> Data {
        downloads += 1
        return artifact
    }
    func postReceipts(_ batch: Data) async throws {}
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

    // MARK: 503 channel_invalidated with a keyring (P0-3)

    private func rings() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "keyrings", withExtension: "json", subdirectory: "Fixtures"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func ring(_ r: [String: Any], _ name: String) -> (Data, Data) {
        let k = (r["keyrings"] as? [[String: Any]] ?? []).first { $0["name"] as? String == name } ?? [:]
        return (Data(base64Encoded: k["document"] as? String ?? "") ?? Data(), Data(base64Encoded: k["signature"] as? String ?? "") ?? Data())
    }

    private func invalidated(_ r: [String: Any], _ name: String?) -> PatchHTTPError {
        guard let name else { return PatchHTTPError("channel_invalidated", status: 503, retryAfter: 30) }
        let (d, s) = ring(r, name)
        return PatchHTTPError("channel_invalidated", status: 503, retryAfter: 30, keyringDocument: d, keyringSignature: s)
    }

    func testInvalidatedAppliesOnlyVerifiedKeyringsNeverStagesAndRevocationSurvivesRestart() async throws {
        let r = try rings()
        let sc = r["signerChannel"] as? [String: Any] ?? [:]
        let signerDoc = Data(base64Encoded: sc["document"] as? String ?? "") ?? Data()
        let signerSig = Data(base64Encoded: sc["signature"] as? String ?? "") ?? Data()
        let path = dir()
        let patch = open(path)
        let net = Throwing503(bundle("valid"))
        let (ad, asig) = ring(r, "authorize")
        net.next = SignedChannel(document: signerDoc, signature: signerSig, etag: "a", keyringDocument: ad, keyringSignature: asig)
        let updater = PatchUpdater(patch: patch, transport: net)
        let first = await updater.checkForUpdate()
        XCTAssertEqual(first.state, .restartRequired)
        let staged = try patch.status()["pending"] as? String
        for (name, code) in [("forged", "bad_signature"), ("other project", "wrong_target")] {
            net.error = invalidated(r, name)
            let res = await updater.checkForUpdate()
            XCTAssertEqual(res.state, .failed, name)
            XCTAssertEqual(res.reason, "channel_invalidated; keyring_rejected:\(code)", name)
            XCTAssertEqual(res.retryAfter, 30)
        }
        net.error = invalidated(r, "revoke")
        let revoked = await updater.checkForUpdate()
        XCTAssertEqual(revoked.reason, "channel_invalidated")
        XCTAssertEqual(net.downloads, 1, "a 503 never downloads")
        XCTAssertEqual(try patch.status()["pending"] as? String, staged, "a 503 never changes what is staged")
        net.error = invalidated(r, "stale")
        let stale = await updater.checkForUpdate()
        XCTAssertEqual(stale.reason, "channel_invalidated; keyring_rejected:stale")
        _ = patch

        // A fresh store learns authorize then revoke only from 503s. Scoped so
        // the engine and its lock are released before the restart.
        let fresh = dir()
        do {
            let net2 = Throwing503(bundle("valid"))
            let u2 = PatchUpdater(patch: open(fresh), transport: net2)
            net2.error = invalidated(r, "authorize")
            let a = await u2.checkForUpdate()
            XCTAssertEqual(a.reason, "channel_invalidated")
            net2.error = invalidated(r, "revoke")
            let b = await u2.checkForUpdate()
            XCTAssertEqual(b.reason, "channel_invalidated")
        }
        let restarted = open(fresh)
        XCTAssertEqual(try restarted.status()["owner"] as? Bool, true, "the earlier engine released its lock")
        XCTAssertThrowsError(try restarted.applyChannel(signerDoc, signature: signerSig)) { e in
            XCTAssertEqual((e as? PatchError)?.code, "untrusted_key")
            XCTAssertTrue((e as? PatchError)?.message.contains("revoked") ?? false, "refused as revoked after restart")
        }
    }

    /// The shipped runtime carries E1 (engine ddced0a): status reports `degraded`.
    func testShippedRuntimeReportsDegradedField() throws {
        let patch = open(dir())
        XCTAssertEqual(try patch.status()["degraded"] as? Bool, false)
    }

    func testNextCheckAfterA503RetriesTheChannel() async throws {
        let r = try rings()
        let patch = open(dir())
        let net = Throwing503(bundle("valid"))
        net.error = invalidated(r, nil)
        let updater = PatchUpdater(patch: patch, transport: net)
        let failed = await updater.checkForUpdate()
        XCTAssertEqual(failed.state, .failed)
        net.error = nil
        net.next = channel("valid")
        let ok = await updater.checkForUpdate()
        XCTAssertEqual(ok.state, .restartRequired)
        XCTAssertEqual(net.etags, [nil, nil], "no ETag recorded from a 503")
    }

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

#endif
