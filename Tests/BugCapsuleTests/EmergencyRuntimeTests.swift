import Foundation
import XCTest

@testable import BugCapsule

/// A loopback backend for the emergency endpoints: serves one envelope (or
/// a forced status), answers `If-None-Match` with 304 and records receipts.
final class EmergencyTestBackend: @unchecked Sendable {
    let app: String
    private let lock = NSLock()
    private var _envelope: JSONValue?
    private var _etag: String?
    private var _forced: TestHTTPServer.Response?
    private var _delay: TimeInterval = 0
    private var _configBody = #"{"enabled":true,"sampleRate":1,"configTtlSeconds":300}"#
    private(set) var server: TestHTTPServer!

    init(app: String) throws {
        self.app = app
        server = try TestHTTPServer { [unowned self] req in self.respond(req) }
    }

    var backend: BugCapsuleBackendConfig { BugCapsuleBackendConfig(url: server.baseURL, ingestKey: "bci_test_key") }

    func serve(_ envelope: JSONValue?, etag: String? = nil) {
        lock.locked {
            _envelope = envelope
            _etag = etag
            _forced = nil
        }
    }

    func force(_ response: TestHTTPServer.Response?) { lock.locked { _forced = response } }
    func setDelay(_ d: TimeInterval) { lock.locked { _delay = d } }
    func setConfig(_ body: String) { lock.locked { _configBody = body } }

    private func respond(_ req: TestHTTPServer.Request) -> TestHTTPServer.Response {
        lock.locked {
            if req.path.contains("/emergency/receipts") { return .init(status: 204) }
            if req.path.hasPrefix("/v1/sdk/config") { return .init(status: 200, body: Data(_configBody.utf8)) }
            if req.path.hasSuffix("/v1/capsules") { return .init(status: 201, body: Data(#"{"id":"srv"}"#.utf8)) }
            if req.path.hasSuffix("/v1/envelope") { return .init(status: 200, body: Data(#"{"accepted":1,"rejected":[]}"#.utf8)) }
            guard req.path.contains("/emergency/policies") else { return .init(status: 404) }
            if var forced = _forced {
                forced.delay = _delay
                return forced
            }
            guard let envelope = _envelope else { return .init(status: 503, delay: _delay) }
            var headers: [String: String] = ["Content-Type": "application/json"]
            if let etag = _etag {
                headers["ETag"] = etag
                if req.headers["if-none-match"] == etag { return .init(status: 304, headers: headers, delay: _delay) }
            }
            return .init(status: 200, headers: headers, body: JSON.encodeData(envelope), delay: _delay)
        }
    }

    var policyRequests: [TestHTTPServer.Request] { server.requests.filter { $0.path.contains("/emergency/policies") } }
    var receipts: [JSONValue] {
        server.requests.filter { $0.path.contains("/emergency/receipts") }.compactMap { try? JSON.parse($0.body) }
    }

    func stop() { server.stop() }
}

final class EmergencyRuntimeTests: XCTestCase {
    let app = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
    var dir: URL!
    var clock: TestClock!
    var signer: EmergencySigner!
    var backend: EmergencyTestBackend!

    override func setUp() async throws {
        dir = tempDirectory()
        clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        signer = EmergencySigner()
        backend = try EmergencyTestBackend(app: app)
    }

    override func tearDown() async throws {
        backend.stop()
        await BugCapsuleEmergency.shared.resetForTesting()
        await BugCapsule.resetForTesting()
    }

    func waitUntil(_ timeout: TimeInterval = 5, _ cond: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func configuration(
        anchor: String? = nil, environment: String = "production", interval: TimeInterval = 60,
        modes: [String: EmergencyFailureMode] = [:], backend explicit: BugCapsuleBackendConfig?? = nil,
        replaying: Bool = false, autoSchedule: Bool = false, random: Double = 0.5
    ) -> EmergencyConfiguration {
        var c = EmergencyConfiguration(
            trustAnchor: anchor ?? signer.anchor(app: app), environment: environment, refreshInterval: interval,
            failureModes: modes, backend: explicit ?? backend.backend, appVersion: "2.4.1")
        let clock = self.clock!
        c.testHooks = EmergencyTestHooks(
            storageDirectory: dir, now: { clock.now }, random: { random }, autoSchedule: autoSchedule,
            isReplaying: { replaying }, observeLifecycle: false)
        return c
    }

    func runtime(_ c: EmergencyConfiguration? = nil, notify: @escaping @Sendable (EmergencySnapshot) -> Void = { _ in })
        -> EmergencyRuntime
    {
        EmergencyRuntime(configuration: c ?? configuration(), notify: notify)
    }

    /// A signed envelope whose document blocks `checkout.confirm_order`.
    func envelope(
        revision: Int, issuedOffset: TimeInterval = 0, ttl: TimeInterval = 3600, reason: String = "INCIDENT",
        signer s: EmergencySigner? = nil, policies: [JSONValue]? = nil
    ) -> JSONValue {
        let issued = clock.now.addingTimeInterval(issuedOffset)
        let doc = emergencyDocument(
            app: app, revision: revision, issuedAt: issued, expiresAt: issued.addingTimeInterval(ttl),
            policies: policies ?? [emergencyPolicy(id: "p-\(revision)", key: "checkout.confirm_order", reasonCode: reason)])
        return (s ?? signer).envelope(doc)
    }

    // MARK: acceptance (§5)

    func testAcceptsVerifiedDocumentAndEvaluatesIt() async throws {
        backend.serve(envelope(revision: 5), etag: "\"e5\"")
        let r = runtime()
        XCTAssertEqual(r.evaluate(featureKey: "checkout.confirm_order", subject: nil).0.source, .failureMode)
        await r.refresh(.manual)
        let (d, policy) = r.evaluate(featureKey: "checkout.confirm_order", subject: nil)
        XCTAssertEqual(d.action, .block)
        XCTAssertFalse(d.allowed)
        XCTAssertEqual(d.source, .policy)
        XCTAssertEqual(d.documentRevision, 5)
        XCTAssertEqual(d.publicUserMessage, "Temporarily unavailable.")
        XCTAssertEqual(policy?.policyId, "p-5")
        XCTAssertEqual(r.evaluate(featureKey: "checkout.view_cart", subject: nil).0.action, .allow)
        let s = r.status()
        XCTAssertEqual(s.state, .usable)
        XCTAssertEqual(s.revision, 5)
        XCTAssertNil(s.lastError)
        XCTAssertNotNil(s.lastFetchAt)
        // The request carries the contract's query and credential.
        let req = try XCTUnwrap(backend.policyRequests.first)
        XCTAssertTrue(req.path.hasPrefix("/v1/apps/\(app)/emergency/policies?"), req.path)
        for part in ["environment=production", "platform=NATIVE_IOS", "app_version=2.4.1", "sdk_version="] {
            XCTAssertTrue(req.path.contains(part), "\(part) in \(req.path)")
        }
        XCTAssertEqual(req.headers["authorization"], "Bearer bci_test_key")
        XCTAssertNil(req.headers["if-none-match"])
    }

    func testStaleRevisionIsRejected() async throws {
        backend.serve(envelope(revision: 5, reason: "FIVE"))
        let r = runtime()
        await r.refresh(.manual)
        backend.serve(envelope(revision: 4, issuedOffset: 60, reason: "FOUR"))
        await r.refresh(.manual)
        XCTAssertEqual(r.status().revision, 5)
        XCTAssertEqual(r.status().lastError?.code, "stale_revision")
        XCTAssertEqual(r.evaluate(featureKey: "checkout.confirm_order", subject: nil).0.reasonCode, "FIVE")
        await waitUntil { self.backend.receipts.count >= 2 }
        let failed = backend.receipts.first { $0["status"] == "FAILED" }
        XCTAssertEqual(failed?["errorCode"], "stale_revision")
        XCTAssertEqual(failed?["revision"], 4)
    }

    func testSameRevisionNotLaterIsIgnoredAndLaterIsAccepted() async throws {
        backend.serve(envelope(revision: 7, reason: "FIRST"))
        let notified = Counter()
        let r = runtime { _ in notified.increment() }
        await r.refresh(.manual)
        XCTAssertEqual(notified.value, 1)
        // Same revision, older issued_at: nothing changes, no receipt, no notification.
        backend.serve(envelope(revision: 7, issuedOffset: -30, reason: "OLDER"))
        await r.refresh(.manual)
        // Same revision, same issued_at: ignored too.
        backend.serve(envelope(revision: 7, issuedOffset: 0, reason: "SAME"))
        await r.refresh(.manual)
        XCTAssertEqual(r.evaluate(featureKey: "checkout.confirm_order", subject: nil).0.reasonCode, "FIRST")
        XCTAssertNil(r.status().lastError)
        XCTAssertEqual(notified.value, 1)
        // Same revision re-issued later (longer TTL): accepted.
        backend.serve(envelope(revision: 7, issuedOffset: 30, reason: "REISSUED"))
        await r.refresh(.manual)
        XCTAssertEqual(r.evaluate(featureKey: "checkout.confirm_order", subject: nil).0.reasonCode, "REISSUED")
        XCTAssertEqual(notified.value, 2)
        await waitUntil(1) { self.backend.receipts.count >= 2 }
        // One APPLIED receipt for revision 7, however often it was applied.
        XCTAssertEqual(backend.receipts.count, 1)
    }

    func testExpiredOnArrivalIsRejected() async throws {
        backend.serve(envelope(revision: 2, issuedOffset: -4000, ttl: 4000 - 301))
        let r = runtime()
        await r.refresh(.manual)
        XCTAssertEqual(r.status().state, .none)
        XCTAssertEqual(r.status().lastError?.code, "expired_on_arrival")
        // Within the 300 s clock-skew allowance it is accepted (and usable).
        backend.serve(envelope(revision: 3, issuedOffset: -4000, ttl: 4000 - 299))
        await r.refresh(.manual)
        XCTAssertEqual(r.status().revision, 3)
        XCTAssertEqual(r.status().state, .usable)
    }

    func testEveryVerificationFailureIsRejectedAndKeepsTheCurrentDocument() async throws {
        backend.serve(envelope(revision: 1))
        let r = runtime()
        await r.refresh(.manual)
        let other = EmergencySigner(kid: signer.kid)
        var otherApp = emergencyDocument(app: "other", revision: 9, issuedAt: clock.now, expiresAt: clock.now.addingTimeInterval(60))
        otherApp["policies"] = []
        let cases: [(JSONValue, String)] = [
            (["not": "an envelope"], "malformed"),
            (envelope(revision: 2, signer: other), "bad_signature"),
            (envelope(revision: 2, signer: EmergencySigner(kid: "ek_unknown")), "unknown_key"),
            (signer.envelope(otherApp), "wrong_application"),
            (
                signer.envelope(
                    emergencyDocument(
                        app: app, environment: "staging", revision: 9, issuedAt: clock.now,
                        expiresAt: clock.now.addingTimeInterval(60))), "wrong_environment"
            ),
        ]
        for (e, code) in cases {
            backend.serve(e)
            await r.refresh(.manual)
            XCTAssertEqual(r.status().lastError?.code, code)
            XCTAssertEqual(r.status().revision, 1, code)
        }
        // A body that is not JSON.
        backend.force(.init(status: 200, body: Data("<html>".utf8)))
        await r.refresh(.manual)
        XCTAssertEqual(r.status().lastError?.code, "malformed")
        XCTAssertEqual(r.evaluate(featureKey: "checkout.confirm_order", subject: nil).0.action, .block)
    }

    // MARK: cache (§5, §7.1)

    func testCacheIsPersistedAndVerifiedAgainInANewInstance() async throws {
        backend.serve(envelope(revision: 11), etag: "\"e11\"")
        let first = runtime()
        await first.refresh(.manual)
        first.dispose()
        backend.stop()

        // Offline: the next process starts from the cache without the network.
        let second = runtime()
        let d = second.evaluate(featureKey: "checkout.confirm_order", subject: nil).0
        XCTAssertEqual(d.action, .block)
        XCTAssertEqual(d.source, .policy)
        XCTAssertEqual(d.documentRevision, 11)
        XCTAssertEqual(second.status().state, .usable)
        await second.refresh(.manual)
        XCTAssertEqual(second.status().lastError?.code, "network_error")
        XCTAssertEqual(second.evaluate(featureKey: "checkout.confirm_order", subject: nil).0.action, .block)

        // The file holds envelope, ETag, received_at and highest revision.
        let file = try loadJSON(dir.appendingPathComponent("policies.production.json"))
        XCTAssertEqual(file["etag"], "\"e11\"")
        XCTAssertEqual(file["highest_revision"], 11)
        XCTAssertEqual(file["received_at_ms"]?.intValue, Int(EmergencyContract.milliseconds(clock.now)))
        XCTAssertNotNil(file["envelope"]?["signature"]?.stringValue)
        // The installation id lives in its own file.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("installation-id").path))
        XCTAssertEqual(first.installationId, second.installationId)
        XCTAssertEqual(first.installationId.count, 22)
    }

    func testTamperedCacheIsDiscarded() async throws {
        backend.serve(envelope(revision: 4))
        await runtime().refresh(.manual)
        let url = dir.appendingPathComponent("policies.production.json")
        var file = try loadJSON(url).objectValue!
        var env = file["envelope"]!.objectValue!
        let other = envelope(revision: 4, signer: EmergencySigner(kid: signer.kid))
        env["signature"] = other["signature"]
        file["envelope"] = .object(env)
        try JSON.encodeData(.object(file)).write(to: url)
        let r = runtime()
        XCTAssertEqual(r.status().state, .none)
        XCTAssertEqual(r.evaluate(featureKey: "checkout.confirm_order", subject: nil).0.source, .failureMode)
        // The highest revision survives: an older document is still refused.
        backend.serve(envelope(revision: 3))
        await r.refresh(.manual)
        XCTAssertEqual(r.status().lastError?.code, "stale_revision")
    }

    func testCacheIsDiscardedWhenTheAnchorChanges() async throws {
        backend.serve(envelope(revision: 8))
        await runtime().refresh(.manual)
        // A new anchor (another key) no longer verifies the cached envelope.
        let rotated = EmergencySigner()
        let r = runtime(configuration(anchor: rotated.anchor(app: app)))
        XCTAssertEqual(r.status().state, .none)
        let file = try loadJSON(dir.appendingPathComponent("policies.production.json"))
        XCTAssertTrue(file["envelope"]?.isNull ?? false)
        // An anchor for another application drops the highest revision too.
        let otherApp = runtime(configuration(anchor: rotated.anchor(app: "16fd2706-8baf-433b-82eb-8c7fada847da")))
        XCTAssertEqual(otherApp.status().state, .none)
        let file2 = try loadJSON(dir.appendingPathComponent("policies.production.json"))
        XCTAssertTrue(file2["highest_revision"]?.isNull ?? false)
        // The anchor with both keys keeps verifying after a rotation.
        backend.serve(envelope(revision: 9, signer: rotated))
        let both = runtime(configuration(anchor: signer.anchor(app: app, also: [rotated])))
        await both.refresh(.manual)
        XCTAssertEqual(both.status().revision, 9)
        XCTAssertEqual(runtime(configuration(anchor: signer.anchor(app: app, also: [rotated]))).status().revision, 9)
    }

    // MARK: failure modes (§7.4)

    func testExpiryAppliesEachFailureMode() async throws {
        let c = configuration(modes: [
            "pay.open": .failOpen, "pay.closed": .failClosed, "pay.last": .useLastValidPolicy,
        ])
        backend.serve(
            envelope(
                revision: 3, ttl: 600,
                policies: [
                    emergencyPolicy(id: "a", key: "pay.*", reasonCode: "PAY_HALT"),
                ]))
        let r = runtime(c)
        await r.refresh(.manual)
        for k in ["pay.open", "pay.closed", "pay.last", "pay.other"] {
            XCTAssertEqual(r.evaluate(featureKey: k, subject: nil).0.source, .policy, k)
        }
        // Still usable up to expires_at + 300 s.
        clock.advance(600 + 300)
        XCTAssertEqual(r.status().state, .usable)
        XCTAssertEqual(r.evaluate(featureKey: "pay.closed", subject: nil).0.source, .policy)
        clock.advance(1)
        XCTAssertEqual(r.status().state, .expired)
        let open = r.evaluate(featureKey: "pay.open", subject: nil).0
        XCTAssertEqual(open, EmergencyRuntime.unavailable("pay.open", allowed: true))
        XCTAssertEqual(open.reasonCode, "POLICY_UNAVAILABLE")
        XCTAssertEqual(open.source, .failureMode)
        let closed = r.evaluate(featureKey: "pay.closed", subject: nil).0
        XCTAssertFalse(closed.allowed)
        XCTAssertEqual(closed.action, .block)
        XCTAssertEqual(closed.reasonCode, "POLICY_UNAVAILABLE")
        XCTAssertEqual(closed.source, .failureMode)
        let last = r.evaluate(featureKey: "pay.last", subject: nil).0
        XCTAssertEqual(last.action, .block)
        XCTAssertEqual(last.reasonCode, "PAY_HALT")
        XCTAssertEqual(last.source, .stalePolicy)
        XCTAssertEqual(last.documentRevision, 3)
        // Default for every other key: fail open.
        XCTAssertEqual(r.evaluate(featureKey: "pay.other", subject: nil).0.action, .allow)

        // USE_LAST_VALID_POLICY without any document: allow, as FAIL_OPEN.
        let empty = runtime(configuration(environment: "staging", modes: ["pay.last": .useLastValidPolicy, "pay.closed": .failClosed]))
        let none = empty.evaluate(featureKey: "pay.last", subject: nil).0
        XCTAssertTrue(none.allowed)
        XCTAssertEqual(none.source, .failureMode)
        XCTAssertEqual(none.reasonCode, "POLICY_UNAVAILABLE")
        XCTAssertFalse(empty.evaluate(featureKey: "pay.closed", subject: nil).0.allowed)
    }

    func testWildcardFailureModeMatching() {
        let r = runtime(
            configuration(modes: [
                "checkout.*": .failClosed, "checkout.pay.*": .useLastValidPolicy, "checkout.pay.card": .failOpen,
                "wallet": .failClosed, "Bad Key": .failClosed, "*": .failClosed,
            ]))
        XCTAssertEqual(r.failureMode(for: "checkout.confirm_order"), .failClosed)
        XCTAssertEqual(r.failureMode(for: "checkout.pay.apple"), .useLastValidPolicy)  // longest prefix
        XCTAssertEqual(r.failureMode(for: "checkout.pay.card"), .failOpen)  // exact beats any prefix
        XCTAssertEqual(r.failureMode(for: "checkout.pay"), .failClosed)  // `checkout.pay.*` doesn't cover `checkout.pay`
        XCTAssertEqual(r.failureMode(for: "checkout"), .failOpen)  // `checkout.*` doesn't cover `checkout`
        XCTAssertEqual(r.failureMode(for: "checkoutx.pay"), .failOpen)
        XCTAssertEqual(r.failureMode(for: "wallet"), .failClosed)
        XCTAssertEqual(r.failureMode(for: "wallet.send"), .failOpen)  // no global or implicit wildcard
        XCTAssertEqual(r.failureMode(for: "search"), .failOpen)
    }

    func testInvalidAnchorTurnsPoliciesOff() async throws {
        let r = runtime(configuration(anchor: "bcek.v1.garbage", modes: ["pay.*": .failClosed]))
        XCTAssertEqual(r.status().lastError?.code, "invalid_anchor")
        await r.refresh(.manual)
        XCTAssertTrue(backend.policyRequests.isEmpty)
        XCTAssertEqual(r.evaluate(featureKey: "search", subject: nil).0.source, .failureMode)
        XCTAssertFalse(r.evaluate(featureKey: "pay.send", subject: nil).0.allowed)
        let badEnv = runtime(configuration(environment: "Prod!"))
        XCTAssertEqual(badEnv.status().lastError?.code, "invalid_environment")
    }

    // MARK: HTTP (§3)

    func testNotModifiedSendsIfNoneMatch() async throws {
        backend.serve(envelope(revision: 6), etag: "W/\"rev-6\"")
        let r = runtime()
        await r.refresh(.manual)
        let firstFetch = try XCTUnwrap(r.status().lastFetchAt)
        clock.advance(30)
        await r.refresh(.manual)
        let reqs = backend.policyRequests
        XCTAssertEqual(reqs.count, 2)
        XCTAssertEqual(reqs[1].headers["if-none-match"], "W/\"rev-6\"")
        XCTAssertEqual(r.status().revision, 6)
        XCTAssertNil(r.status().lastError)
        XCTAssertGreaterThan(try XCTUnwrap(r.status().lastFetchAt), firstFetch)
        XCTAssertEqual(r.scheduledDelay, 60)
        // 304 does not extend the document: it still expires on its own expires_at.
        clock.advance(3600 + 301)
        XCTAssertEqual(r.status().state, .expired)
    }

    func testCredentialRefusalStopsScheduledFetchesButKeepsTheCache() async throws {
        backend.serve(envelope(revision: 2))
        let r = runtime(configuration(autoSchedule: true))
        await r.refresh(.manual)
        for status in [401, 403, 404] {
            backend.force(.init(status: status, body: Data(#"{"reason":"token_revoked"}"#.utf8)))
            await r.refresh(.manual)
            XCTAssertTrue(r.status().credentialRejected, "\(status)")
            XCTAssertEqual(r.status().lastError?.code, "credential_rejected")
            XCTAssertEqual(r.status().lastError?.httpStatus, status)
        }
        let before = backend.policyRequests.count
        await r.refresh(.scheduled)
        await r.refresh(.foreground)
        await r.onForeground()
        XCTAssertEqual(backend.policyRequests.count, before, "no scheduled or foreground fetch after a refusal")
        // The cached document stays in use.
        XCTAssertEqual(r.evaluate(featureKey: "checkout.confirm_order", subject: nil).0.source, .policy)
        // A manual refresh still runs and a success clears the refusal.
        backend.serve(envelope(revision: 2))
        await r.refresh(.manual)
        XCTAssertFalse(r.status().credentialRejected)
        r.dispose()
    }

    func testBackoffRetryAfterAndJoinedFetches() async throws {
        let r = runtime(configuration(interval: 20))
        backend.force(.init(status: 503))
        var delays: [TimeInterval] = []
        for _ in 0..<8 {
            await r.refresh(.manual)
            delays.append((try XCTUnwrap(r.scheduledDelay)).rounded())
        }
        XCTAssertEqual(delays, [20, 40, 80, 160, 320, 640, 900, 900])
        XCTAssertEqual(r.status().lastError?.code, "http_error")
        XCTAssertEqual(r.status().lastError?.httpStatus, 503)
        // Retry-After raises the delay when larger.
        backend.force(.init(status: 429, headers: ["Retry-After": "3600"]))
        await r.refresh(.manual)
        XCTAssertEqual(r.scheduledDelay, 3600)
        // 409 emergency_not_configured is a failed fetch.
        backend.force(.init(status: 409, body: Data(#"{"code":"integration_not_configured","reason":"emergency_not_configured"}"#.utf8)))
        await r.refresh(.manual)
        XCTAssertEqual(r.status().lastError?.code, "emergency_not_configured")
        XCTAssertFalse(r.status().credentialRejected)
        // A success resets the failure count.
        backend.serve(envelope(revision: 1))
        await r.refresh(.manual)
        XCTAssertEqual(r.scheduledDelay, 20)
        backend.force(.init(status: 500))
        await r.refresh(.manual)
        XCTAssertEqual(r.scheduledDelay, 20)

        // Jitter: ±20 %.
        let low = runtime(configuration(environment: "low", interval: 20, random: 0))
        let high = runtime(configuration(environment: "high", interval: 20, random: 0.999_999))
        await low.refresh(.manual)
        await high.refresh(.manual)
        XCTAssertEqual(try XCTUnwrap(low.scheduledDelay), 16, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(high.scheduledDelay), 24, accuracy: 0.001)

        // Concurrent calls join the fetch in flight.
        backend.serve(envelope(revision: 2))
        backend.setDelay(0.3)
        let before = backend.policyRequests.count
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<8 { g.addTask { await r.refresh(.manual) } }
            g.addTask { await r.refresh(.foreground) }
            g.addTask { await r.refresh(.scheduled) }
        }
        XCTAssertEqual(backend.policyRequests.count - before, 1)
        XCTAssertEqual(r.status().revision, 2)
    }

    func testOversizedBodyIsAFailedFetch() async throws {
        backend.force(.init(status: 200, body: Data(repeating: 0x20, count: EmergencyHTTPTransport.maxBodyBytes + 1)))
        let r = runtime()
        await r.refresh(.manual)
        XCTAssertEqual(r.status().lastError?.code, "body_too_large")
        XCTAssertTrue(backend.receipts.isEmpty)
    }

    func testBackgroundStopsTimersAndForegroundFetches() async throws {
        backend.serve(envelope(revision: 1))
        let r = runtime(configuration(interval: 15, autoSchedule: true))
        await r.refresh(.manual)
        XCTAssertEqual(backend.policyRequests.count, 1)
        XCTAssertTrue(r.hasPendingTimer)
        XCTAssertEqual(r.scheduledDelay, 15)
        // Background: no timer, and a timer that fired late does not fetch.
        r.onBackground()
        XCTAssertFalse(r.hasPendingTimer)
        await r.refresh(.scheduled)
        XCTAssertEqual(backend.policyRequests.count, 1)
        // Resume (didBecomeActive after the background): fetch and re-arm.
        clock.advance(10)
        await r.onActive()
        XCTAssertEqual(backend.policyRequests.count, 2)
        XCTAssertTrue(r.hasPendingTimer)
        // Active without a background in between (e.g. Control Center): nothing.
        await r.onActive()
        XCTAssertEqual(backend.policyRequests.count, 2)
        // willEnterForeground right after a fetch is throttled; later it fetches.
        await r.onForeground()
        XCTAssertEqual(backend.policyRequests.count, 2)
        clock.advance(3)
        r.onBackground()
        await r.onForeground()
        XCTAssertEqual(backend.policyRequests.count, 3)
        XCTAssertTrue(r.hasPendingTimer)
        r.dispose()
        XCTAssertFalse(r.hasPendingTimer)
    }

    // MARK: receipts (§7.3)

    func testReceiptsAreSentOncePerRevisionStatusAndCode() async throws {
        backend.serve(envelope(revision: 3))
        let r = runtime()
        await r.refresh(.manual)
        await r.refresh(.manual)  // same document: ignored, no receipt
        let bad = envelope(revision: 4, signer: EmergencySigner(kid: signer.kid))
        backend.serve(bad)
        await r.refresh(.manual)
        await r.refresh(.manual)  // same rejection again: no second receipt
        backend.serve(envelope(revision: 4, issuedOffset: 1))
        await r.refresh(.manual)
        await waitUntil { self.backend.receipts.count >= 3 }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let receipts = backend.receipts
        XCTAssertEqual(receipts.count, 3)
        let applied3 = try XCTUnwrap(receipts.first { $0["revision"] == 3 && $0["status"] == "APPLIED" })
        XCTAssertEqual(applied3["environment"], "production")
        XCTAssertEqual(applied3["platform"], "NATIVE_IOS")
        XCTAssertEqual(applied3["installationId"]?.stringValue, r.installationId)
        XCTAssertEqual(applied3["appVersion"], "2.4.1")
        XCTAssertEqual(applied3["sdkVersion"]?.stringValue, sdkVersion)
        XCTAssertTrue(applied3["errorCode"]?.isNull ?? false)
        // bad_signature: the payload is never trusted, so the receipt names the current revision.
        let failed = try XCTUnwrap(receipts.first { $0["status"] == "FAILED" })
        XCTAssertEqual(failed["errorCode"], "bad_signature")
        XCTAssertEqual(failed["revision"], 3)
        XCTAssertNotNil(receipts.first { $0["revision"] == 4 && $0["status"] == "APPLIED" })
        let req = try XCTUnwrap(backend.server.requests.first { $0.path.contains("/receipts") })
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/v1/apps/\(app)/emergency/receipts")
        XCTAssertEqual(req.headers["authorization"], "Bearer bci_test_key")
        // The id is 16 random bytes in base64url.
        XCTAssertEqual(Base64URL.decode(r.installationId)?.count, 16)
    }

    // MARK: replay (§7.4)

    func testReplayMakesNoNetworkCallsAndAllowsEverything() async throws {
        backend.serve(envelope(revision: 1))
        await runtime().refresh(.manual)  // a cached BLOCK exists
        await waitUntil { self.backend.receipts.count == 1 }
        let before = backend.server.requests.count
        let r = runtime(configuration(modes: ["checkout.*": .failClosed], replaying: true))
        await r.refresh(.manual)
        await r.onForeground()
        let d = r.evaluate(featureKey: "checkout.confirm_order", subject: nil).0
        XCTAssertTrue(d.allowed)
        XCTAssertEqual(d.source, .replay)
        XCTAssertNil(d.reasonCode)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(backend.server.requests.count, before)
    }

    // MARK: concurrency (§5)

    func testConcurrentEvaluationsNeverSeeAHalfAppliedRevision() async throws {
        let r = runtime()
        let stop = Counter()
        let mismatches = Counter()
        let evaluations = Counter()
        let readers = (0..<4).map { _ in
            Thread {
                while stop.value == 0 {
                    let (d, p) = r.evaluate(featureKey: "checkout.confirm_order", subject: nil)
                    evaluations.increment()
                    guard let rev = d.documentRevision else { continue }
                    if d.reasonCode != "R\(rev)" || p?.policyId != "p-\(rev)" || d.policyRevision != rev {
                        mismatches.increment()
                    }
                }
            }
        }
        readers.forEach { $0.start() }
        for rev in 1...25 {
            backend.serve(
                envelope(
                    revision: rev,
                    policies: [emergencyPolicy(id: "p-\(rev)", key: "checkout.*", revision: rev, reasonCode: "R\(rev)")]))
            await r.refresh(.manual)
            XCTAssertEqual(r.status().revision, rev)
        }
        stop.increment()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(mismatches.value, 0)
        XCTAssertGreaterThan(evaluations.value, 25)
    }

    // MARK: public API

    func testBeforeInitializeEverythingIsAllowedAndNothingThrows() async {
        let e = BugCapsuleEmergency()
        let d = e.evaluate(featureKey: "checkout.confirm_order")
        XCTAssertTrue(d.allowed)
        XCTAssertEqual(d.action, .allow)
        XCTAssertEqual(d.source, .failureMode)
        XCTAssertEqual(d.reasonCode, "POLICY_UNAVAILABLE")
        XCTAssertTrue(e.isFeatureAllowed("anything at all"))
        XCTAssertNil(e.getPolicy("checkout.confirm_order"))
        XCTAssertFalse(e.status.isInitialized)
        XCTAssertEqual(e.status.state, .none)
        XCTAssertEqual(e.snapshot.policies, [])
        await e.refreshPolicies()
        XCTAssertTrue(BugCapsule.emergency === BugCapsuleEmergency.shared)
    }

    func testInitializeDoesNotWaitAndObserversAndStreamGetSnapshots() async throws {
        backend.serve(envelope(revision: 12))
        backend.setDelay(0.5)
        let e = BugCapsuleEmergency()
        var stream = e.changes.makeAsyncIterator()
        let mainThread = Counter()
        let received = Locked<[Int?]>([])
        let observation = e.observe { snapshot in
            if Thread.isMainThread { mainThread.increment() }
            received.mutate { $0.append(snapshot.revision) }
        }
        let start = Date()
        e.initialize(configuration(autoSchedule: false))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3, "initialize must not wait for the network")
        XCTAssertTrue(e.isInitialized)
        XCTAssertEqual(e.evaluate(featureKey: "checkout.confirm_order").source, .failureMode)
        e.initialize(configuration())  // ignored
        let first = await stream.next()
        XCTAssertNil(first?.revision)  // the startup snapshot (no cache)
        let second = await stream.next()
        XCTAssertEqual(second?.revision, 12)
        XCTAssertEqual(second?.state, .usable)
        XCTAssertEqual(second?.policies.first?.key, "checkout.confirm_order")
        await waitUntil { received.value.count >= 2 }
        XCTAssertEqual(received.value, [nil, 12])
        XCTAssertEqual(mainThread.value, 2)
        XCTAssertEqual(e.evaluate(featureKey: "checkout.confirm_order").action, .block)
        XCTAssertFalse(e.isFeatureAllowed("checkout.confirm_order"))
        XCTAssertEqual(e.getPolicy("checkout.confirm_order")?.reasonCode, "INCIDENT")
        XCTAssertEqual(e.status.revision, 12)
        // A cancelled observation gets nothing more.
        observation.cancel()
        backend.setDelay(0)
        backend.serve(envelope(revision: 13))
        await e.refreshPolicies()
        let third = await stream.next()
        XCTAssertEqual(third?.revision, 13)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(received.value, [nil, 12])
        await e.resetForTesting()
        XCTAssertFalse(e.isInitialized)
    }

    func testObjectiveCSurface() async throws {
        backend.serve(envelope(revision: 21))
        let e = BugCapsuleEmergency()
        XCTAssertTrue(e.responds(to: NSSelectorFromString("initializeWithConfiguration:")))
        XCTAssertTrue(e.responds(to: NSSelectorFromString("evaluateFeatureKey:subject:")))
        XCTAssertTrue(e.responds(to: NSSelectorFromString("isFeatureAllowed:subject:")))
        XCTAssertTrue(e.responds(to: NSSelectorFromString("refreshPoliciesWithCompletion:")))
        XCTAssertTrue(e.responds(to: NSSelectorFromString("observeChanges:")))
        XCTAssertTrue(BugCapsuleEmergency.responds(to: NSSelectorFromString("sharedInstance")))
        XCTAssertNotNil(NSClassFromString("BCEmergencyDecision"))
        XCTAssertNotNil(NSClassFromString("BCEmergencyConfiguration"))

        let config = EmergencyConfigurationObject(trustAnchor: signer.anchor(app: app))
        config.backendURL = backend.backend.url
        config.ingestKey = backend.backend.ingestKey
        config.appVersion = "2.4.1"
        config.setFailureMode(.failClosed, forKey: "wallet.*")
        let swift = config.swiftValue
        XCTAssertEqual(swift.failureModes, ["wallet.*": .failClosed])
        XCTAssertEqual(swift.backend, backend.backend)
        var hooked = swift
        hooked.testHooks = configuration().testHooks
        e.initialize(hooked)
        let refreshed = expectation(description: "completion")
        e.refreshPolicies { refreshed.fulfill() }
        await fulfillment(of: [refreshed], timeout: 5)
        let d = e.decisionObject(featureKey: "checkout.confirm_order", subject: nil)
        XCTAssertFalse(d.allowed)
        XCTAssertEqual(d.action, .block)
        XCTAssertEqual(d.actionName, "BLOCK")
        XCTAssertEqual(d.documentRevision, 21)
        XCTAssertEqual(d.policyRevision, 1)
        XCTAssertEqual(d.source, "policy")
        XCTAssertFalse(e.isFeatureAllowed("checkout.confirm_order", subject: nil))
        XCTAssertEqual(e.stateName, "usable")
        let observed = expectation(description: "observer")
        let token = e.observeChanges { observed.fulfill() }
        backend.serve(envelope(revision: 22))
        await e.refreshPolicies()
        await fulfillment(of: [observed], timeout: 5)
        token.cancel()
    }

    func testUsesTheConnectionOfStartAndIgnoresTheCaptureKillSwitch() async throws {
        backend.serve(envelope(revision: 31))
        backend.setConfig(#"{"enabled":false,"sampleRate":0,"configTtlSeconds":300}"#)
        // Initialized before start, without its own connection.
        BugCapsule.emergency.initialize(configuration(backend: .some(nil)))
        await waitUntil { BugCapsule.emergency.status.lastError?.code == "no_backend" }
        XCTAssertEqual(BugCapsule.emergency.status.lastError?.code, "no_backend")
        let storage = tempDirectory()
        let backendConfig = backend.backend
        await MainActor.run {
            BugCapsule.start(
                BugCapsuleConfig(appVersion: "2.4.1", mode: .production, backend: backendConfig, monitoring: .disabled),
                overrides: BugCapsuleTestOverrides(storageDirectory: storage))
        }
        await waitUntil { BugCapsule.emergency.status.revision == 31 }
        XCTAssertEqual(BugCapsule.emergency.status.revision, 31)
        await BugCapsule.refreshRemoteConfig()
        XCTAssertFalse(BugCapsule.isRecording, "the remote kill switch turned capture off")
        let d = BugCapsule.emergency.evaluate(featureKey: "checkout.confirm_order")
        XCTAssertEqual(d.action, .block, "guards keep working with capture disabled")
        XCTAssertEqual(d.source, .policy)
    }
}

/// Thread-safe counter for tests.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.locked { n } }
    func increment() { lock.locked { n += 1 } }
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.locked { v } }
    func mutate(_ f: (inout T) -> Void) { lock.locked { f(&v) } }
}
