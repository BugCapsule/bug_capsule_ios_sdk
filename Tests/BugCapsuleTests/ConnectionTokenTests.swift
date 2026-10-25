import Foundation
import XCTest

@testable import BugCapsule

/// Connection token v1 (spec-fixtures/connection-token-v1) and token-only setup.
final class ConnectionTokenVectorTests: XCTestCase {
    struct Vectors {
        var valid: [(name: String, token: String, url: String, ingestKey: String)] = []
        var invalid: [(name: String, token: String, error: String)] = []
    }

    static func vectors() throws -> Vectors {
        let doc = try loadJSON(TestPaths.fixtures.appendingPathComponent("connection-token-v1/vectors.json"))
        var v = Vectors()
        for item in doc["valid"]?.arrayValue ?? [] {
            v.valid.append(
                (item["name"]!.stringValue!, item["token"]!.stringValue!, item["url"]!.stringValue!, item["ingestKey"]!.stringValue!))
        }
        for item in doc["invalid"]?.arrayValue ?? [] {
            v.invalid.append((item["name"]!.stringValue!, item["token"]!.stringValue!, item["error"]!.stringValue!))
        }
        return v
    }

    func testEveryVector() throws {
        let v = try Self.vectors()
        XCTAssertEqual(v.valid.count, 6)
        XCTAssertEqual(v.invalid.count, 18)
        for c in v.valid {
            switch BugCapsuleConnectionToken.parse(c.token) {
            case .success(let backend):
                XCTAssertEqual(backend, BugCapsuleBackendConfig(url: c.url, ingestKey: c.ingestKey), c.name)
            case .failure(let e):
                XCTFail("\(c.name): \(e)")
            }
        }
        for c in v.invalid {
            switch BugCapsuleConnectionToken.parse(c.token) {
            case .success(let backend):
                XCTFail("\(c.name): parsed as \(backend)")
            case .failure(let e):
                XCTAssertEqual(e.code.rawValue, c.error, c.name)
                XCTAssertFalse(e.message.isEmpty, c.name)
            }
        }
    }

    func testPaddingIsAccepted() throws {
        let hosted = try Self.vectors().valid.first { $0.name == "hosted" }!
        let payload = hosted.token.dropFirst("bcsdk.v1.".count)
        let pad = (4 - payload.count % 4) % 4
        XCTAssertGreaterThan(pad, 0, "the vector needs padding to make this test meaningful")
        let padded = hosted.token + String(repeating: "=", count: pad)
        XCTAssertEqual(try BugCapsuleBackendConfig(token: padded), BugCapsuleBackendConfig(url: hosted.url, ingestKey: hosted.ingestKey))
    }

    func testMessagesSayWhatWasPastedInstead() {
        func message(_ t: String) -> String {
            if case .failure(let e) = BugCapsuleConnectionToken.parse(t) { return e.message }
            return ""
        }
        XCTAssertTrue(message("bci_" + String(repeating: "k", count: 43)).contains("ingest key, not a connection token"))
        XCTAssertTrue(message("bct_" + String(repeating: "k", count: 43)).contains("ingest key, not a connection token"))
        XCTAssertTrue(message("bcs_" + String(repeating: "k", count: 43)).contains("secret key"))
        XCTAssertTrue(message("bcsdk.v7.e30").contains("newer BugCapsule iOS SDK"))
        XCTAssertTrue(message(" ").contains("empty"))
        XCTAssertThrowsError(try BugCapsuleBackendConfig(token: "nope")) { error in
            XCTAssertEqual((error as? BugCapsuleTokenError)?.code, .invalidToken)
        }
    }
}

/// Builds a v1 token for a test backend.
func makeConnectionToken(api: String, key: String) -> String {
    let json = JSON.encodeData(["api": .string(api), "key": .string(key), "note": "test"])
    let b64 = json.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "bcsdk.v1." + b64
}

final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String
    init(_ v: String) { _value = v }
    var value: String {
        get { lock.locked { _value } }
        set { lock.locked { _value = newValue } }
    }
}

@MainActor
final class TokenSetupTests: XCTestCase {
    var dir: URL!
    var logs: OrderBox!
    let key = "bct_" + String(repeating: "Q", count: 43)

    override func setUp() async throws {
        await BugCapsule.resetForTesting()
        dir = tempDirectory()
        let logs = OrderBox()
        self.logs = logs
        BugCapsuleLog.sinkForTesting = { logs.add($0) }
    }

    override func tearDown() async throws {
        await BugCapsule.resetForTesting()
        BugCapsuleLog.sinkForTesting = nil
    }

    var overrides: BugCapsuleTestOverrides { BugCapsuleTestOverrides(storageDirectory: dir, captureSettleDelay: 0.05) }

    func waitUntil(_ timeout: TimeInterval = 8, _ cond: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    nonisolated static func okBackend(_ req: TestHTTPServer.Request) -> TestHTTPServer.Response {
        switch req.path {
        case let p where p.hasSuffix("/v1/sdk/config"):
            return .init(status: 200, body: Data(#"{"enabled":true,"sampleRate":1,"configTtlSeconds":300}"#.utf8))
        case let p where p.hasSuffix("/v1/capsules"):
            return .init(status: 201, body: Data(#"{"id":"srv-1"}"#.utf8))
        case let p where p.hasSuffix("/v1/envelope"):
            return .init(status: 200, body: Data(#"{"accepted":1,"rejected":[]}"#.utf8))
        default:
            return .init(status: 404)
        }
    }

    func testTokenOnlySetupFetchesConfigThenConfirmsDataSeparately() async throws {
        let server = try TestHTTPServer(handler: Self.okBackend)
        defer { server.stop() }
        BugCapsule.start(token: makeConnectionToken(api: server.baseURL + "/", key: key), overrides: overrides)
        await waitUntil { BugCapsule.status.connection.state == .connected }
        var s = BugCapsule.status.connection
        XCTAssertEqual(s.state, .connected)
        XCTAssertEqual(s.source, .token)
        XCTAssertEqual(s.apiURL, server.baseURL, "trailing slash removed")
        XCTAssertNotNil(s.configFetchedAt)
        XCTAssertNil(s.firstCapsuleAcceptedAt, "fetching config is not data accepted")
        XCTAssertNil(s.reason)
        let first = server.requests.first!
        XCTAssertEqual(first.method, "GET")
        XCTAssertEqual(first.path, "/v1/sdk/config")
        XCTAssertEqual(first.headers["authorization"], "Bearer \(key)")

        // Defaults: app version/build from the main bundle, capture on.
        let config = BugCapsule.session!.config
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(config.appVersion, (info["CFBundleShortVersionString"] as? String) ?? "0")
        XCTAssertEqual(config.appBuild, (info["CFBundleVersion"] as? String) ?? "0")
        XCTAssertEqual(config.backend, BugCapsuleBackendConfig(url: server.baseURL, ingestKey: key))
        XCTAssertTrue(BugCapsule.isRecording)

        BugCapsule.fail("token_setup_check", "first data")
        await waitUntil { BugCapsule.status.connection.firstCapsuleAcceptedAt != nil }
        await BugCapsule.flush(timeout: 3)
        await waitUntil { BugCapsule.status.connection.firstEventAcceptedAt != nil }
        s = BugCapsule.status.connection
        XCTAssertNotNil(s.firstCapsuleAcceptedAt)
        XCTAssertNotNil(s.firstEventAcceptedAt)
        let capsule = server.requests.first { $0.path == "/v1/capsules" }
        XCTAssertEqual(capsule?.method, "POST")
        XCTAssertEqual(capsule?.headers["authorization"], "Bearer \(key)")
        XCTAssertEqual(server.requests.first { $0.path == "/v1/envelope" }?.headers["authorization"], "Bearer \(key)")

        // Connected is not full instrumentation.
        let i = BugCapsule.status.instrumentation
        XCTAssertEqual(i.missing, ["network", "navigation", "app_state"])
        XCTAssertFalse(logs.items.contains { $0.contains("token") }, "nothing to complain about: \(logs.items)")
    }

    func testExplicitBackendStillWorksAndWinsOverToken() async throws {
        let server = try TestHTTPServer(handler: Self.okBackend)
        defer { server.stop() }
        let legacy = "bci_" + String(repeating: "k", count: 43)
        let hosted = try ConnectionTokenVectorTests.vectors().valid.first { $0.name == "hosted" }!
        BugCapsule.start(
            BugCapsuleConfig(
                token: hosted.token, appVersion: "1", appBuild: "1", mode: .qa,
                backend: BugCapsuleBackendConfig(url: server.baseURL + "/bc/", ingestKey: legacy)),
            overrides: overrides)
        await waitUntil { BugCapsule.status.connection.state == .connected }
        XCTAssertEqual(server.requests.first?.path, "/bc/v1/sdk/config")
        XCTAssertEqual(server.requests.first?.headers["authorization"], "Bearer \(legacy)")
        XCTAssertEqual(BugCapsule.status.connection.source, .backend)
        XCTAssertEqual(BugCapsule.status.connection.apiURL, server.baseURL + "/bc/", "the explicit backend is used unchanged")
        XCTAssertEqual(logs.items.filter { $0.contains("ignoring token") }.count, 1)
    }

    func testLegacyConfigWithoutTokenIsUnchanged() async throws {
        let server = try TestHTTPServer(handler: Self.okBackend)
        defer { server.stop() }
        BugCapsule.start(
            BugCapsuleConfig(mode: .qa, backend: BugCapsuleBackendConfig(url: server.baseURL, ingestKey: "bci_legacy")),
            overrides: overrides)
        await waitUntil { BugCapsule.status.connection.state == .connected }
        XCTAssertEqual(server.requests.first?.headers["authorization"], "Bearer bci_legacy")
        XCTAssertEqual(BugCapsule.status.connection.source, .backend)
        XCTAssertNil(BugCapsule.session?.tokenError)
        XCTAssertTrue(logs.items.isEmpty, "\(logs.items)")
    }

    func testInvalidOrUnsupportedTokenNeverThrowsAndRunsWithoutBackend() async throws {
        let future = try ConnectionTokenVectorTests.vectors().invalid.first { $0.error == "unsupported_token_version" }!.token
        for (token, state) in [
            ("bcsdk.v1.not-json", BugCapsuleConnectionState.invalidToken),
            ("bci_" + String(repeating: "x", count: 43), .invalidToken),
            (future, .unsupportedTokenVersion),
        ] {
            dir = tempDirectory()
            let logs = OrderBox()
            BugCapsuleLog.sinkForTesting = { logs.add($0) }
            let started = Date()
            BugCapsule.start(token: token, overrides: overrides)
            XCTAssertLessThan(Date().timeIntervalSince(started), 1, "start never waits")
            XCTAssertTrue(BugCapsule.isStarted)
            let s = BugCapsule.status.connection
            XCTAssertEqual(s.state, state)
            XCTAssertEqual(s.source, .token)
            XCTAssertEqual(s.reason, state.rawValue)
            XCTAssertNotNil(s.message)
            XCTAssertNil(s.apiURL)
            XCTAssertNil(BugCapsule.session?.outbox, "no backend, nothing queued for upload")
            // The app keeps working: failures are still saved on the device.
            BugCapsule.fail("still_fine")
            await waitUntil { !BugCapsule.savedCaptures().isEmpty }
            XCTAssertEqual(BugCapsule.savedCaptures().count, 1)
            XCTAssertEqual(logs.items.filter { $0.contains("[bugcapsule] the SDK token can't be used (\(state.rawValue))") }.count, 1)
            await BugCapsule.resetForTesting()
        }
    }

    func testRevokedTokenStopsCaptureWithTheBackendsReason() async throws {
        let detail = "this SDK token was revoked; generate a new token in the BugCapsule dashboard"
        let server = try TestHTTPServer { req in
            .init(
                status: 401, headers: ["Content-Type": "application/problem+json"],
                body: JSON.encodeData(["code": "unauthorized", "reason": "token_revoked", "detail": .string(detail)]))
        }
        defer { server.stop() }
        BugCapsule.start(token: makeConnectionToken(api: server.baseURL, key: key), overrides: overrides)
        XCTAssertTrue(BugCapsule.isRecording, "records until the backend says otherwise")
        await waitUntil { BugCapsule.status.connection.state == .rejected }
        let s = BugCapsule.status.connection
        XCTAssertEqual(s.state, .rejected)
        XCTAssertEqual(s.reason, "token_revoked")
        XCTAssertEqual(s.message, detail)
        XCTAssertNil(s.configFetchedAt)
        XCTAssertFalse(BugCapsule.isRecording, "capture stopped (kill switch)")
        await BugCapsule.refreshRemoteConfig()
        BugCapsule.fail("after_revocation")
        await BugCapsule.flushUploads()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(server.requests.allSatisfy { $0.path == "/v1/sdk/config" }, "\(server.requests.map(\.path))")
        XCTAssertTrue(BugCapsule.savedCaptures().isEmpty)
        let refused = logs.items.filter { $0.contains("refused this app's SDK token (token_revoked): \(detail)") }
        XCTAssertEqual(refused.count, 1, "logged once: \(logs.items)")
    }

    func testOfflineNeverBlocksAndDataWaitsInTheOutbox() async throws {
        // Nothing listens on port 9: connection refused.
        let started = Date()
        BugCapsule.start(BugCapsuleConfig(token: makeConnectionToken(api: "http://127.0.0.1:9", key: key), mode: .qa), overrides: overrides)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        await waitUntil { BugCapsule.status.connection.state == .offline }
        let s = BugCapsule.status.connection
        XCTAssertEqual(s.state, .offline)
        XCTAssertTrue(s.message?.contains("could not be reached") ?? false)
        BugCapsule.fail("while_offline")
        var pending = 0
        for _ in 0..<100 where pending == 0 {
            try await Task.sleep(nanoseconds: 30_000_000)
            pending = await BugCapsule.session?.outbox?.entries().count ?? 0
        }
        XCTAssertEqual(pending, 1, "the capsule waits in the outbox")
        XCTAssertTrue(BugCapsule.isRecording)
    }

    func testServerErrorsThenRecoveryUploadsTheOutbox() async throws {
        let mode = FlagBox("down")
        let server = try TestHTTPServer { req in
            mode.value == "down" ? .init(status: 503, body: Data(#"{"code":"unavailable"}"#.utf8)) : Self.okBackend(req)
        }
        defer { server.stop() }
        BugCapsule.start(BugCapsuleConfig(token: makeConnectionToken(api: server.baseURL, key: key), mode: .qa), overrides: overrides)
        await waitUntil { BugCapsule.status.connection.state == .offline }
        XCTAssertEqual(BugCapsule.status.connection.state, .offline)
        XCTAssertEqual(BugCapsule.status.connection.reason, "HTTP 503")
        BugCapsule.fail("while_down")
        var pending = 0
        for _ in 0..<100 where pending == 0 {
            try await Task.sleep(nanoseconds: 30_000_000)
            pending = await BugCapsule.session?.outbox?.entries().count ?? 0
        }
        XCTAssertEqual(pending, 1)

        mode.value = "up"
        await BugCapsule.refreshRemoteConfig()
        await BugCapsule.flushUploads()
        XCTAssertEqual(BugCapsule.status.connection.state, .connected)
        let left = await BugCapsule.session?.outbox?.entries().count
        XCTAssertEqual(left, 0)
        XCTAssertNotNil(BugCapsule.status.connection.firstCapsuleAcceptedAt)
        XCTAssertTrue(server.requests.contains { $0.path == "/v1/capsules" })
    }

    func testHangingBackendNeverBlocksStartOrTheApp() async throws {
        let server = try TestHTTPServer { _ in
            Thread.sleep(forTimeInterval: 3)
            return .init(status: 503)
        }
        defer { server.stop() }
        let started = Date()
        BugCapsule.start(BugCapsuleConfig(token: makeConnectionToken(api: server.baseURL, key: key), mode: .qa), overrides: overrides)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "start does not wait for the network")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(BugCapsule.status.connection.state, .connecting)
        let failed = Date()
        BugCapsule.fail("while_hanging")
        BugCapsule.log("still responsive")
        XCTAssertLessThan(Date().timeIntervalSince(failed), 0.5)
    }

    func testStatusReportsInstalledAdapters() async throws {
        let state = BugCapsuleStateIntegration()
        BugCapsule.start(
            BugCapsuleConfig(mode: .qa), integrations: [BugCapsuleURLSession(), BugCapsuleUserDefaults(keys: ["k"]), state],
            overrides: overrides)
        BugCapsule.instrument(URLSessionConfiguration.ephemeral)
        let s = BugCapsule.status
        XCTAssertEqual(s.connection.state, .notConfigured)
        XCTAssertNil(s.connection.source)
        XCTAssertTrue(s.instrumentation.network)
        XCTAssertTrue(s.instrumentation.appState)
        XCTAssertFalse(s.instrumentation.navigation)
        XCTAssertEqual(s.instrumentation.missing, ["navigation"])
    }

    func testStatusBeforeStart() {
        XCTAssertEqual(BugCapsule.status.connection.state, .notConfigured)
        XCTAssertFalse(BugCapsule.status.instrumentation.recording)
    }
}

final class RefusalParsingTests: XCTestCase {
    func testConfigFetchParsesTheProblemReasonAndDetail() async throws {
        let server = try TestHTTPServer { _ in
            .init(status: 401, body: Data(#"{"code":"unauthorized","reason":"token_expired","detail":"rotate: use the new token"}"#.utf8))
        }
        defer { server.stop() }
        let client = BugCapsuleBackendClient(config: BugCapsuleBackendConfig(url: server.baseURL, ingestKey: "bct_x"))
        guard case .failed(_, let status, _, let reason, let detail) = await client.fetchConfig() else { return XCTFail() }
        XCTAssertEqual(status, 401)
        XCTAssertEqual(reason, "token_expired")
        XCTAssertEqual(detail, "rotate: use the new token")
    }

    func testControllerKeepsLastFailureAndCallsOnRejectedOnce() async {
        let rejections = OrderBox()
        let results = RemoteConfigTests.ResultsBox([
            .failed(message: "x", status: nil, retryAfter: nil),
            .failed(message: "HTTP 401", status: 401, retryAfter: nil, reason: "token_unknown", detail: "check the token"),
            .failed(message: "HTTP 401", status: 401, retryAfter: nil, reason: "token_unknown", detail: "check the token"),
            .fetched(RemoteCaptureConfig(fetchedAtMs: epochMs())),
        ])
        let c = RemoteConfigController(
            fetch: { results.next() }, cache: MemoryConfigCache(), scope: "s", onChange: { _, _ in }, autoSchedule: false,
            onRejected: { rejections.add($0.reason ?? "") })
        await c.refresh()
        var failure = await c.lastFailure
        XCTAssertEqual(failure?.isOffline, true)
        await c.refresh()
        await c.refresh()
        failure = await c.lastFailure
        XCTAssertEqual(failure?.reason, "token_unknown")
        XCTAssertEqual(failure?.detail, "check the token")
        let rejected = await c.keyRejected
        XCTAssertTrue(rejected)
        XCTAssertEqual(rejections.items, ["token_unknown"])
        var fetched = await c.fetchedThisSession
        XCTAssertNil(fetched)
        await c.refresh()
        fetched = await c.fetchedThisSession
        XCTAssertNotNil(fetched)
        failure = await c.lastFailure
        XCTAssertNil(failure)
    }
}
