import Foundation
import XCTest

@testable import BugCapsule

/// Server settings can only narrow what the app configured (BC-ENT-018), and
/// the ingest key never travels over plain http to a remote host.
final class RemoteNarrowingTests: XCTestCase {
    override func tearDown() async throws { await BugCapsule.resetForTesting() }

    // MARK: maxCapsuleBytes

    func testRemoteMaxCapsuleBytesIsClampedToTheBackendMaximum() throws {
        let max = RemoteCaptureConfig.maxRemoteCapsuleBytes
        XCTAssertEqual(max, 50 * 1024 * 1024)
        XCTAssertEqual(try RemoteCaptureConfig(json: ["maxCapsuleBytes": .int(Int.max)]).maxCapsuleBytes, max)
        XCTAssertEqual(try RemoteCaptureConfig(json: ["maxCapsuleBytes": .int(1 << 62)]).maxCapsuleBytes, max)
        XCTAssertEqual(try RemoteCaptureConfig(json: ["maxCapsuleBytes": .int(max + 1)]).maxCapsuleBytes, max)
        XCTAssertEqual(try RemoteCaptureConfig(json: ["maxCapsuleBytes": -5]).maxCapsuleBytes, 1)
        XCTAssertEqual(try RemoteCaptureConfig(json: ["maxCapsuleBytes": 2048]).maxCapsuleBytes, 2048)
    }

    @MainActor
    func testApplyingAHugeCapsuleSizeIsClampedAndDoesNotOverflowTheJournal() async throws {
        BugCapsule.start(
            BugCapsuleConfig(appVersion: "1.0", appBuild: "1", mode: .qa),
            overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory(), transport: FakeTransport()))
        let session = try XCTUnwrap(BugCapsuleSession.current)
        XCTAssertTrue(session.isRecording, "the crash journal (2x the cap) exists")
        // A config built in code bypasses JSON parsing; 2 * Int.max would trap.
        session.applyRemote(nil, RemoteCaptureConfig(maxCapsuleBytes: Int.max, fetchedAtMs: 1))
        XCTAssertEqual(session.maxCapsuleBytes, RemoteCaptureConfig.maxRemoteCapsuleBytes)
        session.applyRemote(nil, RemoteCaptureConfig(maxCapsuleBytes: 4096, fetchedAtMs: 2))
        XCTAssertEqual(session.maxCapsuleBytes, 4096)
    }

    // MARK: tracePropagationTargets

    func testAServerListCanRemoveDestinationsButNotAddThem() {
        let app = ["api.shop.test"]
        let server = ["api.shop.test/cart", "evil.test"]
        XCTAssertTrue(Tracer.matches("https://api.shop.test/cart/1", targets: app, narrowedBy: server))
        XCTAssertFalse(
            Tracer.matches("https://api.shop.test/profile", targets: app, narrowedBy: server), "narrowed away")
        XCTAssertFalse(
            Tracer.matches("https://evil.test/x", targets: app, narrowedBy: server), "a foreign host the app never listed")
        XCTAssertFalse(Tracer.matches("https://api.shop.test/cart", targets: app, narrowedBy: []), "an empty list removes all")
        XCTAssertFalse(Tracer.matches("https://evil.test/x", targets: [], narrowedBy: ["evil.test"]))
    }

    func testServerEntriesArePlainTextNeverPatterns() {
        XCTAssertFalse(Tracer.matches("https://api.shop.test/cart", targets: ["api.shop.test"], narrowedBy: ["/.*/"]))
        XCTAssertTrue(
            Tracer.matches("https://api.shop.test/a/.*/b", targets: ["api.shop.test"], narrowedBy: ["/.*/"]),
            "matched literally")
    }

    func testWithoutAServerListTheAppListAppliesAsBefore() {
        XCTAssertTrue(Tracer.matches("https://api.shop.test/cart", targets: ["/^https://api\\./"]))
        XCTAssertTrue(Tracer.matches("https://api.shop.test/cart", targets: ["/^https://api\\./"], narrowedBy: nil))
        XCTAssertFalse(Tracer.matches("https://cdn.shop.test/a.png", targets: ["/^https://api\\./"]))
        XCTAssertTrue(
            Tracer.matches("https://api.shop.test/cart", targets: ["/^https://api\\./"], narrowedBy: ["shop.test/cart"]),
            "app patterns keep working under a server list")
    }

    // MARK: Retry-After

    func testRetryAfterHeaderIsCappedAtOneDay() throws {
        func parse(_ value: String) -> TimeInterval? {
            let r = HTTPURLResponse(
                url: URL(string: "https://bugs.example.com")!, statusCode: 429, httpVersion: nil,
                headerFields: ["Retry-After": value])!
            return BugCapsuleBackendClient.retryAfter(r)
        }
        XCTAssertEqual(parse("120"), 120)
        XCTAssertEqual(parse("31536000"), 86400)
        XCTAssertEqual(parse("\(Int.max)"), 86400)
        XCTAssertEqual(parse("-5"), 0)
    }

    // MARK: explicit backend config

    func refusal(_ url: String, _ key: String = "bci_abcdefghijklmnopqrstuvwx") -> String? {
        BugCapsuleBackendConfig(url: url, ingestKey: key).refusal
    }

    func testAcceptsHTTPSAndLocalDevelopmentHosts() {
        XCTAssertNil(refusal("https://bugs.example.com"))
        XCTAssertNil(refusal("https://192.168.1.20:8443"))
        XCTAssertNil(refusal("http://127.0.0.1:8787"))
        XCTAssertNil(refusal("http://localhost:8787"))
        XCTAssertNil(refusal("http://10.0.2.2:8787"))
        XCTAssertNil(refusal("http://[::1]:8787"))
    }

    func testRefusesPlainHTTPToARemoteOrLANHost() throws {
        XCTAssertTrue(try XCTUnwrap(refusal("http://api.example.com")).contains("https"))
        XCTAssertTrue(try XCTUnwrap(refusal("http://192.168.1.20:8787")).contains("https"))
        XCTAssertNotNil(refusal("ftp://api.example.com"))
        XCTAssertNotNil(refusal("not a url"))
    }

    func testRefusesASecretKey() throws {
        XCTAssertTrue(try XCTUnwrap(refusal("https://bugs.example.com", "bcs_abcdefghijklmnopqrstuvwx")).contains("secret"))
    }

    @MainActor
    func testARefusedBackendLeavesTheAppRunningWithoutUploads() async throws {
        for (url, key) in [("http://api.example.com", "bci_test"), ("https://bugs.example.com", "bcs_secret_key_123456")] {
            await BugCapsule.resetForTesting()
            BugCapsule.start(
                BugCapsuleConfig(
                    appVersion: "1.0", mode: .qa, backend: BugCapsuleBackendConfig(url: url, ingestKey: key),
                    monitoring: .disabled),
                overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory()))
            let session = try XCTUnwrap(BugCapsuleSession.current, "start never fails")
            XCTAssertNil(session.config.backend)
            XCTAssertTrue(session.isRecording, "capture still runs on the device")
            let c = BugCapsule.status.connection
            XCTAssertEqual(c.state, .notConfigured)
            XCTAssertEqual(c.source, .backend)
            XCTAssertNil(c.apiURL)
            XCTAssertEqual(c.reason, "invalid_backend")
        }
    }

    func testARefusedEmergencyBackendIsNotUsed() async throws {
        var c = EmergencyConfiguration(
            trustAnchor: EmergencySigner().anchor(app: "7c9e6679-7425-40de-944b-e07fc1f90ae7"),
            backend: BugCapsuleBackendConfig(url: "http://api.example.com", ingestKey: "bci_test_key"))
        c.testHooks = EmergencyTestHooks(
            storageDirectory: tempDirectory(), now: { Date() }, random: { 0.5 }, autoSchedule: false,
            isReplaying: { false }, observeLifecycle: false)
        c.testHooks?.requestTimeout = loopbackRequestTimeout
        let r = EmergencyRuntime(configuration: c, notify: { _ in })
        await r.refresh(.manual)
        XCTAssertEqual(r.status().lastError?.code, "invalid_backend")
    }
}
