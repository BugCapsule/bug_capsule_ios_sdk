import Foundation
import XCTest

@testable import BugCapsule

/// Local data lifecycle (BC-ENT-038): clearing, collection consent, the
/// saved-capture TTL and how files are written.
@MainActor
final class LocalDataTests: XCTestCase {
    var dir: URL!
    var transport: FakeTransport!
    var suite: String!

    override func setUp() async throws {
        await BugCapsule.resetForTesting()
        dir = tempDirectory()
        transport = FakeTransport()
        suite = "bugcapsule-tests.\(UUID().uuidString)"
        CollectionConsent.defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        await BugCapsule.resetForTesting()
        UserDefaults().removePersistentDomain(forName: suite)
        CollectionConsent.defaults = .standard
    }

    func start(_ config: BugCapsuleConfig? = nil) {
        var c = config ?? BugCapsuleConfig(appVersion: "1.0", appBuild: "7", mode: .qa)
        c.backend = BugCapsuleBackendConfig(url: "https://backend.test", ingestKey: "bci_test")
        BugCapsule.start(
            c, overrides: BugCapsuleTestOverrides(storageDirectory: dir, transport: transport, captureSettleDelay: 0.05))
    }

    func files(_ sub: String) -> [String] {
        let url = dir.appendingPathComponent(sub)
        return ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    /// Files an earlier run could have left: queued and saved capsules, a
    /// queued envelope, a journal, monitoring state, emergency policies.
    func seedEarlierRun() throws {
        let fm = FileManager.default
        for sub in ["captures", "outbox", "envelopes", "journal/99999", "monitoring", "crash-bridge/events", "emergency"] {
            try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let x = Data("x".utf8)
        try x.write(to: dir.appendingPathComponent("captures/a.bugcapsule"))
        try x.write(to: dir.appendingPathComponent("outbox/1_a.bugcapsule"))
        try x.write(to: dir.appendingPathComponent("envelopes/1_e.envelope"))
        try x.write(to: dir.appendingPathComponent("journal/99999/header.json"))
        try x.write(to: dir.appendingPathComponent("monitoring/install_id"))
        try x.write(to: dir.appendingPathComponent("monitoring/crash.report"))
        try x.write(to: dir.appendingPathComponent("crash-bridge/events/1-a.json"))
        try x.write(to: dir.appendingPathComponent("emergency/policies.production.json"))
        try x.write(to: dir.appendingPathComponent("remote_config.json"))
    }

    func assertCollectedDataGone(file: StaticString = #filePath, line: UInt = #line) {
        for sub in ["captures", "outbox", "envelopes", "journal", "crash-bridge/events"] {
            XCTAssertEqual(files(sub), [], sub, file: file, line: line)
        }
        XCTAssertFalse(files("monitoring").contains("install_id"), file: file, line: line)
        XCTAssertFalse(files("monitoring").contains("crash.report"), file: file, line: line)
        XCTAssertEqual(files("emergency"), ["policies.production.json"], "guards keep working offline", file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("remote_config.json").path),
                      "the kill switch is kept", file: file, line: line)
    }

    // MARK: clearLocalData

    func testWipeDeletesCollectedDataAndKeepsPoliciesAndDirectories() throws {
        try seedEarlierRun()
        LocalData.wipe(root: dir)
        assertCollectedDataGone()
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("outbox").path, isDirectory: &isDir) && isDir.boolValue,
                      "directories stay for the running outbox and the native crash writer")
    }

    func testClearLocalDataOnARunningSessionStopsRecordingAndDeletesCaptures() async throws {
        start()
        XCTAssertTrue(BugCapsule.isRecording)
        transport.uploadResults = [UploadResult(.retryLater)]
        BugCapsule.fail("checkout.total", "negative")
        let r = await BugCapsule.capture(note: "before clear")
        XCTAssertNotNil(r)
        XCTAssertFalse(BugCapsule.savedCaptures().isEmpty)
        try seedEarlierRun()

        BugCapsule.clearLocalData()

        XCTAssertFalse(BugCapsule.isRecording, "the buffer of this run is dropped")
        XCTAssertEqual(BugCapsule.savedCaptures(), [])
        assertCollectedDataGone()
        let after = await BugCapsule.capture()
        XCTAssertNil(after, "nothing from before the clear can be written again")
    }

    // MARK: consent

    func testConsentOffAtStartCapturesNothingAndPurgesEarlierData() async throws {
        try seedEarlierRun()
        BugCapsule.setCollectionEnabled(false)
        start()
        XCTAssertTrue(BugCapsule.isStarted)
        XCTAssertFalse(BugCapsule.isRecording)
        XCTAssertFalse(BugCapsule.isCollectionEnabled)
        assertCollectedDataGone()
        BugCapsule.fail("x")
        let r = await BugCapsule.capture()
        XCTAssertNil(r)
        await BugCapsule.flushUploads()
        XCTAssertEqual(transport.uploadCount, 0)
        XCTAssertEqual(transport.configFetches, 0, "no backend contact without consent")
    }

    func testDefaultComesFromConfigUntilTheAppDecides() async throws {
        start(BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa, collectionEnabledByDefault: false))
        XCTAssertFalse(BugCapsule.isCollectionEnabled)
        XCTAssertFalse(BugCapsule.isRecording)
        XCTAssertNil(CollectionConsent.stored)

        BugCapsule.setCollectionEnabled(true)
        XCTAssertTrue(BugCapsule.isRecording, "consent off at start: capture is set up now")
        XCTAssertEqual(CollectionConsent.stored, true)
    }

    func testTurningCollectionOffStopsCaptureUploadAndPurgesTheQueue() async throws {
        start()
        transport.uploadResults = [UploadResult(.retryLater)]
        BugCapsule.fail("checkout.total", "negative")
        _ = await BugCapsule.capture()
        let uploadsBefore = transport.uploadCount
        XCTAssertFalse(files("outbox").isEmpty, "queued after a retryable failure")

        BugCapsule.setCollectionEnabled(false)

        XCTAssertFalse(BugCapsule.isRecording)
        XCTAssertEqual(files("outbox"), [])
        XCTAssertEqual(BugCapsule.savedCaptures(), [])
        BugCapsule.fail("again")
        await BugCapsule.flushUploads()
        XCTAssertEqual(transport.uploadCount, uploadsBefore)
        let allowed = await BugCapsuleSession.current!.uploadsAllowed
        XCTAssertFalse(allowed)

        // Back on in the same run: persisted, applied on the next launch.
        BugCapsule.setCollectionEnabled(true)
        XCTAssertFalse(BugCapsule.isRecording)
        await BugCapsule.resetForTesting()
        start()
        XCTAssertTrue(BugCapsule.isRecording)
    }

    func testConsentPersistsAcrossLaunches() async throws {
        BugCapsule.setCollectionEnabled(false)
        start()
        XCTAssertFalse(BugCapsule.isRecording)
        await BugCapsule.resetForTesting()
        start()
        XCTAssertFalse(BugCapsule.isRecording, "the stored choice wins over the default")
        XCTAssertEqual(CollectionConsent.defaults.object(forKey: CollectionConsent.key) as? Bool, false)
    }

    // MARK: saved-capture TTL

    func testSavedCapturesExpireAfterSevenDays() throws {
        let store = try CapsuleStore(root: dir)
        let old = try store.save(capsuleId: "old", bytes: Data("o".utf8))
        let fresh = try store.save(capsuleId: "fresh", bytes: Data("f".utf8))
        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: eightDaysAgo], ofItemAtPath: old.path)
        XCTAssertEqual(CapsuleStore.maxSavedCaptureAge, 7 * 24 * 3600)

        XCTAssertEqual(store.savedCaptures().map(\.lastPathComponent), [fresh.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "deleted, not only hidden")

        // Also on open (a launch after a week offline).
        let stale = try store.save(capsuleId: "stale", bytes: Data("s".utf8))
        try FileManager.default.setAttributes([.modificationDate: eightDaysAgo], ofItemAtPath: stale.path)
        _ = try CapsuleStore(root: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    // MARK: file writes

    func testWriteAtomicallyReplacesInPlaceAndLeavesNoTempFiles() throws {
        let file = dir.appendingPathComponent("f.json")
        try FileIO.writeAtomically(Data("one".utf8), to: file)
        try FileIO.writeAtomically(Data("two".utf8), to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "two")
        XCTAssertEqual(files(""), ["f.json"])
    }

    func testWritesAreProtectedUntilFirstUnlock() throws {
        #if os(iOS)
            let file = dir.appendingPathComponent("p.json")
            try FileIO.writeAtomically(Data("one".utf8), to: file)
            try FileIO.writeAtomically(Data("two".utf8), to: file)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
            let sub = dir.appendingPathComponent("sub")
            try FileIO.ensureDirectory(sub)
            let dirAttributes = try FileManager.default.attributesOfItem(atPath: sub.path)
            XCTAssertEqual(dirAttributes[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
        #else
            XCTAssertNil(FileIO.protection, "macOS has no data protection classes")
        #endif
    }
}
