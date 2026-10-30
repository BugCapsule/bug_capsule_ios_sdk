import Foundation
import XCTest

@testable import BugCapsule

final class ReleaseHealthPatchTests: XCTestCase {
    private final class Sent: @unchecked Sendable {
        var payloads: [JSONObject] = []
    }

    private let patched = PatchIdentity(baseBuildId: "base-1", patchSetDigest: "sha256:patched", engineAbi: 1, hostAbiHash: "sha256:host")
    private let bare = PatchIdentity(baseBuildId: "base-1", patchSetDigest: nil, engineAbi: 1, hostAbiHash: "sha256:host")

    private func health(_ file: URL?, _ identity: PatchIdentity?, _ sent: Sent) -> ReleaseHealth {
        ReleaseHealth(
            file: file, release: "app@1+1", environment: "production", timeout: 30, did: { "install" },
            patch: { identity }, emit: { sent.payloads.append($0) })
    }

    func testEveryUpdateCarriesThePatchStartingWithTheFirst() {
        let sent = Sent()
        let h = health(nil, patched, sent)
        h.start()
        h.end()

        XCTAssertEqual(sent.payloads.count, 2)
        for payload in sent.payloads {
            XCTAssertEqual(payload["patchBaseBuildId"]?.stringValue, "base-1")
            XCTAssertEqual(payload["patchSetDigest"]?.stringValue, "sha256:patched")
        }
    }

    func testTheBareBaseReportsItsBuildWithNoDigestTheRolloutControl() {
        let sent = Sent()
        health(nil, bare, sent).start()

        XCTAssertEqual(sent.payloads[0]["patchBaseBuildId"]?.stringValue, "base-1")
        XCTAssertNil(sent.payloads[0]["patchSetDigest"])
    }

    func testNoPatchRuntimeSendsNeitherField() {
        let sent = Sent()
        health(nil, nil, sent).start()

        XCTAssertNil(sent.payloads[0]["patchBaseBuildId"])
        XCTAssertNil(sent.payloads[0]["patchSetDigest"])
    }

    func testARecoveredSessionReportsThePatchItRanNotTheCurrentOne() throws {
        let file = tempDirectory().appendingPathComponent("session.json")
        health(file, patched, Sent()).start()

        let update = try XCTUnwrap(health(file, bare, Sent()).recoverPrevious(crashedAt: Date()))

        XCTAssertEqual(update["status"]?.stringValue, "crashed")
        XCTAssertEqual(update["patchBaseBuildId"]?.stringValue, "base-1")
        XCTAssertEqual(update["patchSetDigest"]?.stringValue, "sha256:patched")
    }

    func testASessionSavedBeforeIdentityExistedClaimsNoPatch() throws {
        let file = tempDirectory().appendingPathComponent("session.json")
        health(file, nil, Sent()).start()

        let update = try XCTUnwrap(health(file, patched, Sent()).recoverPrevious(crashedAt: Date()))

        XCTAssertNil(update["patchBaseBuildId"])
        XCTAssertNil(update["patchSetDigest"])
    }

    func testAScreenshotKeepsCapturedAtTAtOrBeforeTAfterTheAnchorShift() {
        let event = BugCapsuleEvent(seq: 1, t: 6998, type: "screenshot", data: ["schema": .int(1), "capturedAtT": .int(6998)])

        let shifted = event.shifted(1181)

        XCTAssertEqual(shifted.t, 5817)
        XCTAssertEqual(shifted.data["capturedAtT"]?.intValue, 5817)
        XCTAssertEqual(shifted.data["schema"]?.intValue, 1)
    }

    func testOtherEventsKeepTheirData() {
        let event = BugCapsuleEvent(seq: 2, t: 100, type: "action", data: ["id": .string("cart.checkout")])

        XCTAssertEqual(event.shifted(40).data, event.data)
    }
}
