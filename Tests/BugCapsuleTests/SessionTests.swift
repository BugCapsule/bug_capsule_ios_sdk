import Foundation
import XCTest

@testable import BugCapsule

struct DemoError: Error, CustomStringConvertible {
    let id: Int
    var description: String { "checkout failed for order \(id) token=abcdef123456" }
}

@MainActor
final class SessionCaptureTests: XCTestCase {
    var dir: URL!
    var transport: FakeTransport!

    override func setUp() async throws {
        await BugCapsule.resetForTesting()
        dir = tempDirectory()
        transport = FakeTransport()
    }

    override func tearDown() async throws { await BugCapsule.resetForTesting() }

    func start(_ config: BugCapsuleConfig? = nil, integrations: [BugCapsuleIntegration] = []) {
        var c = config ?? BugCapsuleConfig(appVersion: "1.0", appBuild: "7", mode: .qa)
        c.backend = BugCapsuleBackendConfig(url: "http://backend.test", ingestKey: "bci_test")
        BugCapsule.start(
            c, integrations: integrations,
            overrides: BugCapsuleTestOverrides(storageDirectory: dir, transport: transport, captureSettleDelay: 0.05))
    }

    func waitUntil(_ timeout: TimeInterval = 5, _ cond: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func savedCapsules() throws -> [Capsule] {
        try BugCapsule.savedCaptures().map { try CapsuleCodec.decode(Data(contentsOf: $0)) }
    }

    func testReportedErrorIsCapturedRedactedAndUploaded() async throws {
        start(BugCapsuleConfig(appVersion: "1.0", appBuild: "7", mode: .qa, gitSha: "abc123", gitDirty: false, labels: ["ticket": "QA-1", "password": "x"]))
        BugCapsule.log("user typed password=hunter2")
        BugCapsule.recordAction("cart.checkout", payload: ["apiKey": "k-123"])
        BugCapsule.textChanged("login.password", value: "hunter2")
        BugCapsule.textChanged("coupon", value: "SAVE10")
        BugCapsule.report(error: DemoError(id: 42))
        await waitUntil { self.transport.uploadCount == 1 }
        XCTAssertEqual(transport.uploadCount, 1)
        let capsule = try CapsuleCodec.decode(transport.lastUpload!)
        let m = capsule.manifest
        XCTAssertEqual(m.failure?.signature, "exception:DemoError:checkout failed for order # token=[REDACTED]")
        XCTAssertEqual(m.failure?.type, "DemoError")
        XCTAssertEqual(m.runtimeName, "ios")
        XCTAssertEqual(m.sdkName, "bugcapsule-ios")
        XCTAssertEqual(m.capability("input.pointer.replay"), "unsupported")
        XCTAssertEqual(m.capability("crash.uncaught"), "partial")
        XCTAssertEqual(m.eligibility.status, .eligible)
        XCTAssertEqual(m.gitSha, "abc123")
        XCTAssertEqual(m.labels.first { $0.0 == "password" }?.1, "[REDACTED]")
        // Redaction happened before anything was written.
        let raw = String(decoding: try Gzip.decompress(transport.lastUpload!, maxBytes: 10_000_000), as: UTF8.self)
        XCTAssertFalse(raw.contains("hunter2"))
        XCTAssertFalse(raw.contains("k-123"))
        XCTAssertFalse(raw.contains("abcdef123456"))
        XCTAssertTrue(raw.contains("SAVE10"))
        let saved = try savedCapsules()
        XCTAssertEqual(saved.first?.manifest.capsuleId, m.capsuleId, "saved locally as well")
        let fileRaw = String(decoding: try Gzip.decompress(Data(contentsOf: BugCapsule.savedCaptures()[0]), maxBytes: 10_000_000), as: UTF8.self)
        XCTAssertFalse(fileRaw.contains("hunter2"))
        XCTAssertEqual(capsule.events.map(\.type), ["log", "action", "text", "text", "failure"])
        XCTAssertEqual(capsule.checkpoint.kind, .launch)
    }

    func testAtMostThreeAutoCapsulesOnePerSignature() async throws {
        start()
        for i in 0..<6 { BugCapsule.fail("assert_\(i % 4)") }
        BugCapsule.fail("assert_0")
        await waitUntil { self.transport.uploadCount >= 3 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(transport.uploadCount, 3)
        XCTAssertEqual(Set(try savedCapsules().compactMap { $0.manifest.failure?.signature }).count, 3)
    }

    func testManualCaptureWithoutFailureIsIneligible() async throws {
        start()
        let r = await BugCapsule.capture(note: "looks odd")
        XCTAssertEqual(r?.eligibility.status, .ineligible)
        XCTAssertTrue(r!.eligibility.missing.contains { $0.dependency == "failure.assertion" && $0.blocking })
        XCTAssertTrue(r!.eligibility.missing.contains { $0.dependency == "build.gitSha" })
    }

    func testUploadsWaitForASuccessfulConfigFetch() async throws {
        transport.configResults = [.failed(message: "offline", status: nil, retryAfter: nil)]
        start()
        BugCapsule.fail("offline_failure")
        await waitUntil { (try? self.savedCapsules().count) == 1 }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.uploadCount, 0, "no config yet: queued, not uploaded")
        let queued = await BugCapsuleSession.current!.outbox!.entries()
        XCTAssertEqual(queued.count, 1)
        // Connectivity is back.
        transport.configResults = [.fetched(RemoteCaptureConfig(fetchedAtMs: epochMs()))]
        await BugCapsule.refreshRemoteConfig()
        await BugCapsule.flushUploads()
        XCTAssertEqual(transport.uploadCount, 1)
    }

    func testKillSwitchStopsRecordingAndPurgesQueuedAndSaved() async throws {
        transport.configResults = [.failed(message: "offline", status: nil, retryAfter: nil)]
        start()
        BugCapsule.fail("before_kill")
        await waitUntil { (try? self.savedCapsules().count) == 1 }
        let session = BugCapsuleSession.current!
        session.applyRemote(nil, RemoteCaptureConfig(enabled: false, fetchedAtMs: epochMs()))
        XCTAssertFalse(BugCapsule.isRecording)
        await waitUntil { BugCapsule.savedCaptures().isEmpty }
        XCTAssertTrue(BugCapsule.savedCaptures().isEmpty)
        try await Task.sleep(nanoseconds: 100_000_000)
        let queued = await session.outbox!.entries()
        XCTAssertTrue(queued.isEmpty)
        BugCapsule.fail("after_kill")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(BugCapsule.savedCaptures().isEmpty, "nothing is captured after the kill switch")
    }

    func testCachedKillSwitchDisablesRecordingAtLaunch() async throws {
        let store = try CapsuleStore(root: dir)
        try store.configCache.write(
            scope: RemoteConfigController.scope(for: BugCapsuleBackendConfig(url: "http://backend.test", ingestKey: "bci_test")),
            config: RemoteCaptureConfig(enabled: false, fetchedAtMs: 1))
        start()
        XCTAssertFalse(BugCapsule.isRecording)
    }

    func testRemoteRedactKeysReRedactTheBufferAndDropHTTP() async throws {
        start()
        let session = BugCapsuleSession.current!
        BugCapsule.recordAction("profile.save", payload: ["memberNo": "M-1"])
        session.record(EventTypes.http, ["key": "GET x/", "url": "https://x/"])
        session.applyRemote(nil, RemoteCaptureConfig(redactKeys: ["memberNo"], fetchedAtMs: epochMs()))
        let events = session.recorderForTesting!.window().events
        XCTAssertEqual(events.map(\.type), ["action"])
        XCTAssertEqual(events[0].data["payload"]?["memberNo"], "[REDACTED]")
        let r = await BugCapsule.capture()
        XCTAssertTrue(r!.eligibility.missing.contains { $0.dependency == "events.redaction" })
    }

    func testProductionSamplingAndLoweredRate() async throws {
        BugCapsule.start(
            BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .production, productionSampleRate: 0.1),
            overrides: BugCapsuleTestOverrides(storageDirectory: dir, random: { 0.5 }))
        XCTAssertFalse(BugCapsule.isRecording, "0.5 >= 0.1: not sampled")
        await BugCapsule.resetForTesting()
        BugCapsule.start(
            BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .production, productionSampleRate: 0.6),
            overrides: BugCapsuleTestOverrides(storageDirectory: dir, random: { 0.5 }))
        XCTAssertTrue(BugCapsule.isRecording)
        // Remote lowers to 0.4: keep probability 0.4/0.6 = 0.67 > 0.5 → keeps recording.
        BugCapsuleSession.current!.applyRemote(nil, RemoteCaptureConfig(sampleRate: 0.4, fetchedAtMs: epochMs()))
        XCTAssertTrue(BugCapsule.isRecording)
        // Lowered to 0.1: keep 0.25 < 0.5 → stops.
        BugCapsuleSession.current!.applyRemote(nil, RemoteCaptureConfig(sampleRate: 0.1, fetchedAtMs: epochMs()))
        XCTAssertFalse(BugCapsule.isRecording)
    }

    func testUncaughtExceptionIsWrittenSynchronouslyToTheOutbox() async throws {
        transport.configResults = [.failed(message: "offline", status: nil, retryAfter: nil)]
        start()
        BugCapsule.recordAction("home.refresh")
        let session = BugCapsuleSession.current!
        let exception = NSException(name: NSExceptionName("HomeBannerInconsistency"), reason: "tier missing for 3 picks", userInfo: nil)
        session.handleUncaughtException(exception)
        let entries = UploadOutbox.entries(in: session.outbox!.directory)
        XCTAssertEqual(entries.count, 1, "written before returning")
        let capsule = try CapsuleCodec.decode(Data(contentsOf: entries[0].file))
        XCTAssertEqual(capsule.manifest.failure?.signature, "exception:HomeBannerInconsistency:tier missing for # picks")
        XCTAssertTrue(capsule.manifest.eligibility.missing.contains { $0.dependency == "crash.persisted" })
        XCTAssertEqual(capsule.events.last?.type, "failure")
    }

    func testPointerOnlyCapsuleNeedsPointerReplay() async throws {
        start()
        let s = BugCapsuleSession.current!
        s.record(EventTypes.pointer, ["phase": "down", "pointer": 1, "x": 10.0, "y": 20.0, "kind": "touch"])
        s.record(EventTypes.pointer, ["phase": "up", "pointer": 1, "x": 10.0, "y": 20.0, "kind": "touch"])
        BugCapsule.fail("x")
        await waitUntil { self.transport.uploadCount == 1 }
        let c = try CapsuleCodec.decode(transport.lastUpload!)
        XCTAssertEqual(c.manifest.eligibility.status, .partial)
        XCTAssertTrue(c.manifest.eligibility.missing.contains { $0.dependency == "capability.input.pointer.replay" })
    }

    func testPeriodicCheckpointBecomesTheStartAfterEviction() async throws {
        var c = BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa, maxEvents: 3)
        c.backend = nil
        let state = BugCapsuleStateIntegration()
        BugCapsule.start(c, integrations: [state], overrides: BugCapsuleTestOverrides(storageDirectory: dir, captureSettleDelay: 0.01))
        var coupon = "SAVE10"
        state.register("cart", snapshot: { ["coupon": .string(coupon)] }, restore: { _ in })
        BugCapsule.log("1")
        BugCapsule.checkpointNow()
        coupon = "SAVE100"
        for i in 2...6 { BugCapsule.log("\(i)") }
        let r = await BugCapsule.capture()
        let capsule = try CapsuleCodec.decode(Data(contentsOf: r!.file))
        XCTAssertEqual(capsule.checkpoint.kind, .periodic)
        XCTAssertEqual(capsule.checkpoint.data["state"]?["cart"]?["coupon"], "SAVE10")
        XCTAssertEqual(capsule.manifest.droppedEvents, 3)
        XCTAssertTrue(r!.eligibility.missing.contains { $0.dependency == "events.window" }, "events between checkpoint and window were evicted")
    }

    func testBeforeRecordCanDropEvents() async throws {
        var c = BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa)
        c.beforeRecord = { type, data in type == EventTypes.log ? nil : data }
        start(c)
        BugCapsule.log("dropped")
        BugCapsule.recordAction("kept")
        XCTAssertEqual(BugCapsuleSession.current!.recorderForTesting!.window().events.map(\.type), ["action"])
    }

    func testDisabledConfigNeverRecords() async throws {
        start(BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa, enabled: false))
        XCTAssertFalse(BugCapsule.isRecording)
        BugCapsule.fail("nope")
        let r = await BugCapsule.capture()
        XCTAssertNil(r)
    }

    func testCorruptStorageDirectoryLeavesTheAppRunning() async throws {
        let file = tempDirectory().appendingPathComponent("not-a-dir")
        try Data("x".utf8).write(to: file)
        BugCapsule.start(BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa), overrides: BugCapsuleTestOverrides(storageDirectory: file))
        XCTAssertTrue(BugCapsule.isStarted)
        XCTAssertFalse(BugCapsule.isRecording, "setup failed: the app runs without capture")
        BugCapsule.fail("x")  // must not crash
    }
}

@MainActor
final class RestorationTests: XCTestCase {
    override func tearDown() async throws { await BugCapsule.resetForTesting() }

    func testUserDefaultsSnapshotAndRestore() async throws {
        let suite = "bugcapsule.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("[{\"sku\":\"mug\"}]", forKey: "cart_cache")
        defaults.set(3, forKey: "launches")
        defaults.set(true, forKey: "onboarded")
        defaults.set(1.5, forKey: "zoom")
        defaults.set(["a", "b"], forKey: "recent")
        defaults.set("s3cret", forKey: "auth_token")
        defaults.set("ignored", forKey: "not_allowlisted")
        let ud = BugCapsuleUserDefaults(keys: ["cart_cache", "launches", "onboarded", "zoom", "recent", "auth_token"], suiteName: suite)
        let session = BugCapsuleSession(
            config: BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa), integrations: [ud],
            overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory()))
        ud.setUp(session)
        let snap = ud.snapshot(.launch)!.objectValue!
        XCTAssertEqual(snap["launches"], ["type": "int", "value": 3])
        XCTAssertEqual(snap["onboarded"], ["type": "bool", "value": true])
        XCTAssertEqual(snap["zoom"], ["type": "double", "value": 1.5])
        XCTAssertEqual(snap["recent"], ["type": "stringArray", "value": ["a", "b"]])
        XCTAssertEqual(snap["auth_token"]?["value"], "[REDACTED]")
        XCTAssertNil(snap["not_allowlisted"])

        // Replay into an emptied store.
        defaults.removePersistentDomain(forName: suite)
        defaults.set("[\"legacy\"]", forKey: "stale_value_from_before")
        let capsule = makeCapsule(checkpointData: ["user_defaults": .object(snap)])
        let replaySession = BugCapsuleSession(
            config: BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa), integrations: [ud],
            overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory()))
        let engine = replaySession.startReplayForTesting(capsule: capsule, settings: ReplaySettings())!
        let restored = UserDefaults(suiteName: suite)!
        XCTAssertEqual(restored.string(forKey: "cart_cache"), "[{\"sku\":\"mug\"}]")
        XCTAssertEqual(restored.integer(forKey: "launches"), 3)
        XCTAssertEqual(restored.bool(forKey: "onboarded"), true)
        XCTAssertEqual(restored.stringArray(forKey: "recent"), ["a", "b"])
        let report = engine.buildReport()
        XCTAssertTrue(report.divergences.contains { $0.type == "storage.redacted" && $0.detail == "auth_token" })
        defaults.removePersistentDomain(forName: suite)
    }

    func testStateRestoreLateAndMissing() async throws {
        let state = BugCapsuleStateIntegration()
        let capsule = makeCapsule(checkpointData: ["state": ["cart": ["coupon": "SAVE10"], "never": ["x": 1]]])
        let session = BugCapsuleSession(
            config: BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa), integrations: [state],
            overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory()))
        let engine = session.startReplayForTesting(capsule: capsule, settings: ReplaySettings())!
        var coupon = ""
        state.register("cart", snapshot: { ["coupon": .string(coupon)] }, restore: { json in coupon = json["coupon"]?.stringValue ?? "" })
        XCTAssertEqual(coupon, "SAVE10")
        let report = engine.buildReport()
        XCTAssertTrue(report.divergences.contains { $0.type == "restore.missing" })
        XCTAssertFalse(report.divergences.contains { $0.type == "restore.late" })
    }

    func testMissingIntegrationIsReported() async throws {
        let capsule = makeCapsule(checkpointData: ["shared_preferences": ["k": ["type": "int", "value": 1]]])
        let session = BugCapsuleSession(
            config: BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa), integrations: [],
            overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory()))
        let engine = session.startReplayForTesting(capsule: capsule, settings: ReplaySettings())!
        let types = engine.buildReport().divergences.map(\.type)
        XCTAssertTrue(types.contains("restore.missingIntegration"))
        XCTAssertTrue(types.contains("integration.missing"), "urlsession was captured but is not set up")
    }

    func testNavigationRestoreNeedsARestorer() async throws {
        let nav = BugCapsuleNavigation()
        let capsule = makeCapsule(checkpointData: ["navigation": ["route": "/cart", "backStack": ["/", "/cart"]]], checkpointKind: .periodic)
        let session = BugCapsuleSession(
            config: BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa), integrations: [nav],
            overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory()))
        let engine = session.startReplayForTesting(capsule: capsule, settings: ReplaySettings())!
        XCTAssertTrue(engine.buildReport().divergences.contains { $0.type == "restore.navigation" })
    }
}
