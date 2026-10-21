import Foundation
import XCTest

@testable import BugCapsule

@MainActor
final class ReplayEngineTests: XCTestCase {
    override func tearDown() async throws { await BugCapsule.resetForTesting() }

    func session(gitSha: String? = nil) -> BugCapsuleSession {
        BugCapsuleSession(
            config: BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa, gitSha: gitSha), integrations: [BugCapsuleURLSession()],
            overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory()))
    }

    let expected = FailureRecord.assertion("cart_total_non_negative", message: "", t: 300)

    func testDispatchesActionsAndTextAtRecordedTimesAndReproduces() async throws {
        var log: [String] = []
        let start = Date()
        BugCapsule.registerAction("cart.apply") { _ in
            log.append("apply \(Int(Date().timeIntervalSince(start) * 1000))")
            BugCapsule.fail("cart_total_non_negative")
        }
        BugCapsule.trackText("cart.coupon") { v in log.append("text \(v)") }
        let capsule = makeCapsule(
            events: [
                BugCapsuleEvent(seq: 1, t: 100, type: "text", data: ["id": "cart.coupon", "value": "SAVE100"]),
                BugCapsuleEvent(seq: 2, t: 250, type: "action", data: ["id": "cart.apply"]),
                BugCapsuleEvent(seq: 3, t: 300, type: "failure", data: expected.json.objectValue!),
            ], failure: expected)
        let engine = session().startReplayForTesting(capsule: capsule, settings: ReplaySettings(settleTimeoutMs: 500))!
        let report = await engine.run()
        XCTAssertEqual(report.outcome, .reproduced)
        XCTAssertEqual(report.observed?.signature, "assertion:cart_total_non_negative:")
        XCTAssertEqual(report.eventsDispatched, 2)
        XCTAssertEqual(report.eventsExpected, 2)
        XCTAssertEqual(report.strategy, .semantic)
        XCTAssertEqual(report.runtime, "ios")
        XCTAssertEqual(log.first, "text SAVE100")
        let applyMs = Int(log[1].split(separator: " ")[1])!
        XCTAssertGreaterThanOrEqual(applyMs, 240, "dispatched at its recorded time")
        XCTAssertTrue(assessAttempt(report).status == .reproduced)
    }

    func testNotReproducedIsCleanOnlyWhenEverythingRan() async throws {
        BugCapsule.registerAction("noop") { _ in }
        let capsule = makeCapsule(
            events: [
                BugCapsuleEvent(seq: 1, t: 50, type: "action", data: ["id": "noop"]),
                BugCapsuleEvent(seq: 2, t: 60, type: "action", data: ["id": "missing.action"]),
                BugCapsuleEvent(seq: 3, t: 70, type: "text", data: ["id": "untracked", "value": "x"]),
            ], failure: expected)
        let engine = session().startReplayForTesting(capsule: capsule, settings: ReplaySettings(settleTimeoutMs: 100))!
        let report = await engine.run()
        XCTAssertEqual(report.outcome, .notReproduced)
        XCTAssertEqual(report.eventsDispatched, 1)
        XCTAssertEqual(report.eventsExpected, 3)
        let types = report.divergences.map(\.type)
        XCTAssertTrue(types.contains("action.unregistered"))
        XCTAssertTrue(types.contains("text.untracked"))
        XCTAssertEqual(assessAttempt(report).status, .invalid)
    }

    func testOtherFailureIsDivergenceAndRedactedTextIsMaterial() async throws {
        BugCapsule.registerAction("boom") { _ in BugCapsule.fail("something_else") }
        BugCapsule.trackText("login.otp") { _ in }
        let capsule = makeCapsule(
            events: [
                BugCapsuleEvent(seq: 1, t: 10, type: "text", data: ["id": "login.otp", "value": "[REDACTED]"]),
                BugCapsuleEvent(seq: 2, t: 20, type: "action", data: ["id": "boom"]),
            ], failure: expected)
        let engine = session().startReplayForTesting(capsule: capsule, settings: ReplaySettings(settleTimeoutMs: 100))!
        let report = await engine.run()
        XCTAssertEqual(report.otherFailures.map(\.signature), ["assertion:something_else:"])
        XCTAssertTrue(report.divergences.contains { $0.type == "failure.other" })
        XCTAssertTrue(report.divergences.contains { $0.type == "text.redacted" })
    }

    func testPointerOnlyCapsuleReportsPointerUnsupported() async throws {
        let capsule = makeCapsule(
            events: [
                BugCapsuleEvent(seq: 1, t: 10, type: "pointer", data: ["phase": "down", "pointer": 1, "x": 1.0, "y": 2.0]),
                BugCapsuleEvent(seq: 2, t: 20, type: "pointer", data: ["phase": "up", "pointer": 1, "x": 1.0, "y": 2.0]),
            ], failure: expected)
        let engine = session().startReplayForTesting(capsule: capsule, settings: ReplaySettings(settleTimeoutMs: 50))!
        let report = await engine.run()
        XCTAssertTrue(report.divergences.contains { $0.type == "pointer.unsupported" })
        XCTAssertEqual(report.eventsExpected, 0)
        XCTAssertEqual(assessAttempt(report).status, .invalid, "pointer.unsupported is material")
        // Explicit pointer strategy also diverges.
        let engine2 = session().startReplayForTesting(capsule: makeCapsule(failure: expected), settings: ReplaySettings(strategy: .pointer, settleTimeoutMs: 10))!
        let r2 = await engine2.run()
        XCTAssertTrue(r2.divergences.contains { $0.type == "pointer.unsupported" })
    }

    func testIdleCompressionSkipsLongGapsAndVirtualClockFollows() async throws {
        BugCapsule.registerAction("late") { _ in }
        let capsule = makeCapsule(
            events: [BugCapsuleEvent(seq: 1, t: 6000, type: "action", data: ["id": "late"])], failure: nil)
        let s = session()
        let engine = s.startReplayForTesting(capsule: capsule, settings: ReplaySettings(settleTimeoutMs: 100))!
        let before = Date()
        let report = await engine.run()
        XCTAssertLessThan(Date().timeIntervalSince(before), 3, "a 6 s idle gap is compressed")
        XCTAssertEqual(report.outcome, .noAssertion)
        XCTAssertGreaterThan(report.compressedMs, 4000)
        XCTAssertEqual(report.gapsCompressed, 1)
        XCTAssertEqual(report.eventsDispatched, 1)
        let virtual = BugCapsule.now().timeIntervalSince1970 * 1000
        XCTAssertGreaterThanOrEqual(virtual, Double(capsule.checkpoint.wallClockMs + 5900), "virtual clock includes skipped time")
    }

    func testBusyNetworkWorkPreventsCompression() async throws {
        BugCapsule.registerAction("late") { _ in }
        let capsule = makeCapsule(events: [BugCapsuleEvent(seq: 1, t: 1800, type: "action", data: ["id": "late"])])
        let engine = session().startReplayForTesting(capsule: capsule, settings: ReplaySettings(settleTimeoutMs: 50))!
        let end = engine.beginWork()
        let report = await engine.run()
        end()
        XCTAssertEqual(report.compressedMs, 0)
    }

    func testGitShaMismatchIsExpectedDivergence() async throws {
        let capsule = makeCapsule(failure: expected, gitSha: "aaaa")
        let engine = session(gitSha: "bbbb").startReplayForTesting(capsule: capsule, settings: ReplaySettings(settleTimeoutMs: 10))!
        let report = await engine.run()
        XCTAssertEqual(report.divergences.first?.type, "build.gitSha")
        XCTAssertEqual(report.buildGitSha, "bbbb")
        XCTAssertEqual(assessAttempt(report).status, .clean, "build.gitSha is expected")
    }

    func testSeededRandomIsRestored() async throws {
        let capsule = makeCapsule()
        let a = BugCapsuleRandom(seed: capsule.manifest.session.seed)
        let expectedValues = (0..<5).map { _ in a.nextInt(1000) }
        _ = session().startReplayForTesting(capsule: capsule, settings: ReplaySettings())
        XCTAssertEqual((0..<5).map { _ in BugCapsule.random.nextInt(1000) }, expectedValues)
    }

    func testSchemaMismatchOnPeriodicCheckpointIsIncompatible() async throws {
        let capsule = makeCapsule(failure: expected, checkpointKind: .periodic, stateSchemaVersion: 2)
        let s = session()
        let box = ReportBox()
        let engine = s.startReplayForTesting(capsule: capsule, settings: ReplaySettings())
        XCTAssertNil(engine)
        _ = box
        XCTAssertFalse(s.isReplaying)
    }
}

final class ReportBox: @unchecked Sendable {
    var reports: [ReplayReport] = []
}

final class ReplayProtocolTests: XCTestCase {
    func testGateNeedsDebugLaunchArgumentAndURL() {
        let url = "http://127.0.0.1:5555/a/token"
        #if DEBUG
            XCTAssertTrue(ReplayGate.compiledIn)
            XCTAssertNil(ReplayGate.replayURL(environment: ["BUGCAPSULE_REPLAY_URL": url], arguments: ["App"]), "no UI test argument")
            XCTAssertNil(ReplayGate.replayURL(environment: [:], arguments: ["App", "-BugCapsuleReplay"]), "no URL")
            XCTAssertNil(
                ReplayGate.replayURL(environment: ["BUGCAPSULE_REPLAY_URL": "myapp://evil"], arguments: ["App", "-BugCapsuleReplay"]),
                "only http(s)")
            XCTAssertEqual(ReplayGate.replayURL(environment: ["BUGCAPSULE_REPLAY_URL": url], arguments: ["App", "-BugCapsuleReplay"]), url)
        #else
            // Release build (`swift test -c release`): replay cannot arm at all.
            XCTAssertFalse(ReplayGate.compiledIn)
            XCTAssertNil(ReplayGate.replayURL(configURL: url, environment: ["BUGCAPSULE_REPLAY_URL": url], arguments: ["App", "-BugCapsuleReplay"]))
        #endif
    }

    func testChannelFetchesAndReportsWithAttemptId() throws {
        let capsule = makeCapsule(failure: FailureRecord.assertion("a", message: "", t: 1))
        let bytes = try CapsuleCodec.encode(capsule)
        let server = try TestHTTPServer { req in
            switch req.path {
            case "/a/tok/settings": return .init(status: 200, body: Data(#"{"strategy":"auto","settleTimeoutMs":1234,"attempt":2,"kind":"verify","strictNetwork":true,"idleCompression":true,"attemptId":"att-1","runtime":"ios"}"#.utf8))
            case "/a/tok/capsule": return .init(status: 200, body: bytes)
            case "/a/tok/result": return .init(status: 204)
            default: return .init(status: 404)
            }
        }
        defer { server.stop() }
        let channel = ReplayChannel(baseURL: server.baseURL + "/a/tok")
        let (c, settings) = try channel.fetchSync()
        XCTAssertEqual(c.manifest.capsuleId, capsule.manifest.capsuleId)
        XCTAssertEqual(settings.settleTimeoutMs, 1234)
        XCTAssertEqual(settings.kind, "verify")
        XCTAssertEqual(settings.attemptId, "att-1")
        let status = channel.deliver(ReplayReport(outcome: .reproduced, attempt: 2, durationMs: 5, strategy: .semantic), attemptId: "att-1")
        XCTAssertEqual(status, .accepted)
        let posted = try JSON.parse(server.requests.last!.body)
        XCTAssertEqual(posted["attemptId"], "att-1")
        XCTAssertEqual(posted["outcome"], "reproduced")
    }

    func testStaleAttemptIsNotRetried() throws {
        let server = try TestHTTPServer { req in req.path.hasSuffix("/result") ? .init(status: 410) : .init(status: 404) }
        defer { server.stop() }
        let channel = ReplayChannel(baseURL: server.baseURL + "/a/old")
        let status = channel.deliver(ReplayReport(outcome: .reproduced, attempt: 1, durationMs: 1, strategy: .semantic), attemptId: "x")
        XCTAssertEqual(status, .stale(410))
        XCTAssertEqual(server.requests.count, 1, "a stale attempt is not retried")
        let server2 = try TestHTTPServer { _ in .init(status: 409) }
        defer { server2.stop() }
        XCTAssertEqual(
            ReplayChannel(baseURL: server2.baseURL + "/a/t").deliver(
                ReplayReport(outcome: .error, attempt: 1, durationMs: 1, strategy: .auto), attemptId: "wrong"),
            .stale(409))
    }

    func testUnknownTokenFailsTheFetch() throws {
        let server = try TestHTTPServer { _ in .init(status: 404) }
        defer { server.stop() }
        XCTAssertThrowsError(try ReplayChannel(baseURL: server.baseURL + "/a/nope").fetchSync(timeout: 5))
    }

    func testReportJSONShape() {
        let r = ReplayReport(
            outcome: .notReproduced, attempt: 1, durationMs: 10, strategy: .semantic, expectedSignature: "x",
            divergences: [Divergence("network.unused", "GET a/", t: 5)], eventsDispatched: 2, eventsExpected: 2,
            attemptId: "id", runtime: "ios")
        let j = r.json
        XCTAssertEqual(j["outcome"], "not_reproduced")
        XCTAssertEqual(j["observed"], .null)
        XCTAssertEqual(j["divergences"]?.arrayValue?.first?["t"], 5)
        XCTAssertEqual(ReplayReport(json: j.objectValue!), r)
    }
}
