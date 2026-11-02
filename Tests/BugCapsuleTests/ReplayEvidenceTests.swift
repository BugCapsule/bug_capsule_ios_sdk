import Foundation
import XCTest

@testable import BugCapsule

/// Verdict v2 evidence: a clean replay says whether the capsule's assertion
/// ran and held, what the postconditions returned, and whether replay got
/// past the recorded failure point.
@MainActor
final class ReplayEvidenceTests: XCTestCase {
    override func tearDown() async throws { await BugCapsule.resetForTesting() }

    /// The capsule's failure is the assertion `cart.total`.
    private func engine(failureT: Int = 50) throws -> ReplayEngine {
        let capsule = makeCapsule(failure: FailureRecord.assertion("cart.total", message: "total was negative", t: failureT))
        let session = BugCapsuleSession(
            config: BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa), integrations: [],
            overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory()))
        return try XCTUnwrap(session.startReplayForTesting(capsule: capsule, settings: ReplaySettings(settleTimeoutMs: 100)))
    }

    func testAFixedAppReportsTheAssertionAndPostconditions() async throws {
        let e = try engine()
        BugCapsule.expect("cart.total_positive") { true }
        BugCapsule.check("cart.total", true)
        let r = await e.run()
        XCTAssertEqual(r.outcome, .notReproduced)
        let evidence = try XCTUnwrap(r.evidence)
        XCTAssertEqual(evidence.assertionPassed, true)
        XCTAssertEqual(evidence.postconditions, ["cart.total_positive": true])
        XCTAssertTrue(evidence.failurePointPassed)
        XCTAssertEqual(evidence.level, .strong)
        // Survives the result channel's JSON.
        let decoded = ReplayReport(json: try XCTUnwrap(JSON.parse(JSON.encode(r.json)).objectValue))
        XCTAssertEqual(decoded.evidence, evidence)
        XCTAssertEqual(decoded.evidence?.level, .strong)
    }

    func testAnAppThatNeverEvaluatesTheAssertionHasAtMostWeakEvidence() async throws {
        let r = await (try engine()).run()
        XCTAssertEqual(r.outcome, .notReproduced)
        XCTAssertNil(r.evidence?.assertionPassed)
        XCTAssertEqual(r.evidence?.failurePointPassed, true)
        XCTAssertEqual(r.evidence?.level, .weak)
        XCTAssertFalse(JSON.encode(r.json).contains("assertionPassed"))
    }

    func testACheckOfAnotherAssertionIsNotEvidenceForThisOne() async throws {
        let e = try engine()
        BugCapsule.check("profile.loaded", true)
        let r = await e.run()
        XCTAssertNil(r.evidence?.assertionPassed)
    }

    func testAPostconditionThatDidNotHoldLeavesNoEvidence() async throws {
        let e = try engine()
        BugCapsule.expect("cart.total_positive") { false }
        e.checkPassed("cart.total")
        let r = await e.run()
        XCTAssertEqual(r.evidence?.failedPostconditions, ["cart.total_positive"])
        XCTAssertEqual(r.evidence?.level, EvidenceLevel.none)
    }

    func testAReproductionCarriesNoFixEvidence() async throws {
        let e = try engine()
        var evaluated = false
        BugCapsule.expect("cart.total_positive") {
            evaluated = true
            return true
        }
        BugCapsule.check("cart.total", true)
        BugCapsule.check("cart.total", false, "total was negative")
        let r = await e.run()
        XCTAssertEqual(r.outcome, .reproduced)
        XCTAssertEqual(r.evidence?.level, EvidenceLevel.none)
        XCTAssertNil(r.evidence?.assertionPassed)
        XCTAssertEqual(r.evidence?.postconditions, [:])
        XCTAssertFalse(evaluated, "postconditions run only after a replay without the failure")
    }

    func testExpectAndCheckOutsideReplayAreNoOps() {
        BugCapsule.expect("anything") { XCTFail("never evaluated outside replay"); return false }
        BugCapsule.check("cart.total", true)
    }

    func testPreV2ReportsDecodeWithoutEvidence() {
        let r = ReplayReport(json: ["outcome": "not_reproduced", "attempt": 1])
        XCTAssertNil(r.evidence)
        XCTAssertNil(r.json["evidence"])
    }
}
