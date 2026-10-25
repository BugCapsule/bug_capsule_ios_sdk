import Foundation
import XCTest

@testable import BugCapsule

final class OutboxTests: XCTestCase {
    func gz(_ s: String) throws -> Data { try Gzip.compress(Data(s.utf8)) }

    func testCountLimitEvictsOldestFirst() async throws {
        let clock = TestClock()
        let dir = tempDirectory()
        let outbox = UploadOutbox(directory: dir, limits: OutboxLimits(maxCount: 3), now: { clock.now })
        for i in 0..<5 {
            let ok = await outbox.enqueue(capsuleId: "c\(i)", bytes: try gz("capsule \(i)"))
            XCTAssertTrue(ok || i < 3)
            clock.advance(1)
        }
        let ids = await outbox.entries().map(\.capsuleId)
        XCTAssertEqual(ids, ["c2", "c3", "c4"])
    }

    func testByteLimitAndOversizedCapsule() async throws {
        let clock = TestClock()
        let outbox = UploadOutbox(directory: tempDirectory(), limits: OutboxLimits(maxBytes: 100), now: { clock.now })
        let big = Data(repeating: 0x1f, count: 101)
        let rejected = await outbox.enqueue(capsuleId: "big", bytes: big)
        XCTAssertFalse(rejected, "larger than the outbox is never queued")
        let a = Data([0x1f, 0x8b] + [UInt8](repeating: 1, count: 58))
        _ = await outbox.enqueue(capsuleId: "a", bytes: a)
        clock.advance(1)
        _ = await outbox.enqueue(capsuleId: "b", bytes: a)
        let ids = await outbox.entries().map(\.capsuleId)
        XCTAssertEqual(ids, ["b"], "the oldest is evicted to stay under 100 bytes")
    }

    func testAgeLimit() async throws {
        let clock = TestClock()
        let dir = tempDirectory()
        let outbox = UploadOutbox(directory: dir, limits: OutboxLimits(maxAge: 3600), now: { clock.now })
        _ = await outbox.enqueue(capsuleId: "old", bytes: try gz("x"))
        clock.advance(7200)
        _ = await outbox.enqueue(capsuleId: "new", bytes: try gz("y"))
        let ids = await outbox.entries().map(\.capsuleId)
        XCTAssertEqual(ids, ["new"])
    }

    func testTempFilesRemovedAndCorruptFilesDropped() async throws {
        let dir = tempDirectory()
        try Data("partial".utf8).write(to: dir.appendingPathComponent("1_x.bugcapsule.123.tmp"))
        try Data("not gzip".utf8).write(to: dir.appendingPathComponent("1_corrupt.bugcapsule"))
        try gz("ok").write(to: dir.appendingPathComponent("2_good.bugcapsule"))
        let outbox = UploadOutbox(directory: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("1_x.bugcapsule.123.tmp").path))
        let uploaded = OrderBox()
        _ = await outbox.flush(upload: { _ in uploaded.add("u"); return UploadResult(.uploaded) }, allowed: { true })
        XCTAssertEqual(uploaded.items.count, 1, "only the valid capsule is uploaded")
        let left = await outbox.entries()
        XCTAssertTrue(left.isEmpty, "corrupt file deleted, uploaded file deleted")
    }

    func testRetryBackoffWithJitterAndRetryAfter() async throws {
        let clock = TestClock()
        let outbox = UploadOutbox(directory: tempDirectory(), now: { clock.now }, random: { 0.5 })
        _ = await outbox.enqueue(capsuleId: "a", bytes: try gz("a"))
        let r1 = await outbox.flush(upload: { _ in UploadResult(.retryLater) }, allowed: { true }, onlyId: "a")
        XCTAssertEqual(r1?.status, .retryLater)
        var retryAt = await outbox.retryAt
        XCTAssertEqual(retryAt!.timeIntervalSince(clock.now), 30, accuracy: 0.01, "first failure: 30 s (jitter midpoint)")
        // Before retryAt nothing is attempted.
        let calls = OrderBox()
        _ = await outbox.flush(upload: { _ in calls.add("x"); return UploadResult(.uploaded) }, allowed: { true })
        XCTAssertTrue(calls.items.isEmpty)
        clock.advance(31)
        _ = await outbox.flush(upload: { _ in UploadResult(.retryLater) }, allowed: { true })
        retryAt = await outbox.retryAt
        XCTAssertEqual(retryAt!.timeIntervalSince(clock.now), 60, accuracy: 0.01, "second failure doubles")
        clock.advance(61)
        _ = await outbox.flush(upload: { _ in UploadResult(.retryLater, retryAfter: 900) }, allowed: { true })
        retryAt = await outbox.retryAt
        XCTAssertEqual(retryAt!.timeIntervalSince(clock.now), 900, accuracy: 0.01, "Retry-After wins when longer")
        clock.advance(901)
        let ok = await outbox.flush(upload: { _ in UploadResult(.uploaded) }, allowed: { true }, onlyId: "a")
        XCTAssertEqual(ok?.status, .uploaded)
        let none = await outbox.retryAt
        XCTAssertNil(none)
    }

    func testBackoffCapsAtOneHour() async throws {
        let clock = TestClock()
        let outbox = UploadOutbox(directory: tempDirectory(), now: { clock.now }, random: { 0.5 })
        _ = await outbox.enqueue(capsuleId: "a", bytes: try gz("a"))
        for _ in 0..<12 {
            _ = await outbox.flush(upload: { _ in UploadResult(.retryLater) }, allowed: { true })
            clock.advance(4000)
        }
        clock.advance(-4000)
        let retryAt = await outbox.retryAt
        XCTAssertEqual(retryAt!.timeIntervalSince(clock.now), 3600, accuracy: 0.01)
    }

    func testRejectedIsDroppedAndAllowedIsChecked() async throws {
        let outbox = UploadOutbox(directory: tempDirectory())
        _ = await outbox.enqueue(capsuleId: "a", bytes: try gz("a"))
        _ = await outbox.flush(upload: { _ in UploadResult(.uploaded) }, allowed: { false })
        var n = await outbox.entries().count
        XCTAssertEqual(n, 1, "not allowed: nothing uploaded")
        _ = await outbox.flush(upload: { _ in UploadResult(.rejected, message: "invalid") }, allowed: { true })
        n = await outbox.entries().count
        XCTAssertEqual(n, 0, "permanent rejection drops the capsule")
    }

    func testPurge() async throws {
        let outbox = UploadOutbox(directory: tempDirectory())
        _ = await outbox.enqueue(capsuleId: "a", bytes: try gz("a"))
        _ = await outbox.enqueue(capsuleId: "b", bytes: try gz("b"))
        let purged = await outbox.purge()
        XCTAssertEqual(purged, 2)
        let n = await outbox.entries().count
        XCTAssertEqual(n, 0)
    }

    func testSynchronousCrashWriteIsPickedUp() async throws {
        let dir = tempDirectory()
        XCTAssertTrue(UploadOutbox.writeSynchronously(directory: dir, capsuleId: "crash-1", bytes: try gz("c")))
        let outbox = UploadOutbox(directory: dir)
        let ids = await outbox.entries().map(\.capsuleId)
        XCTAssertEqual(ids, ["crash-1"])
    }
}

final class RemoteConfigTests: XCTestCase {
    func controller(
        _ results: [ConfigFetchResult], clock: TestClock, cache: MemoryConfigCache = MemoryConfigCache(), scope: String = "s",
        changes: OrderBox = OrderBox()
    ) -> RemoteConfigController {
        let box = ResultsBox(results)
        return RemoteConfigController(
            fetch: { box.next() }, cache: cache, scope: scope, onChange: { _, next in changes.add(next.enabled ? "enabled" : "disabled") },
            now: { clock.now }, random: { 0.5 }, autoSchedule: false)
    }

    final class ResultsBox: @unchecked Sendable {
        var results: [ConfigFetchResult]
        let lock = NSLock()
        init(_ r: [ConfigFetchResult]) { results = r }
        func next() -> ConfigFetchResult { lock.locked { results.count > 1 ? results.removeFirst() : results[0] } }
    }

    func testTTLFreshnessAndScheduling() async {
        let clock = TestClock()
        let ms = Int(clock.now.timeIntervalSince1970 * 1000)
        let c = controller([.fetched(RemoteCaptureConfig(configTtlSeconds: 120, fetchedAtMs: ms))], clock: clock)
        await c.refresh()
        var fresh = await c.isFresh
        XCTAssertTrue(fresh)
        let delay = await c.scheduledDelay
        XCTAssertEqual(delay, 120)
        clock.advance(121)
        fresh = await c.isFresh
        XCTAssertFalse(fresh)
        let allowed = await c.uploadsAllowed
        XCTAssertTrue(allowed, "stale for refresh, but within maxStale for uploads")
        clock.advance(8 * 24 * 3600)
        let stillAllowed = await c.uploadsAllowed
        XCTAssertFalse(stillAllowed, "older than maxStale (7 days)")
    }

    func testMinimumIntervalIs30Seconds() async {
        let clock = TestClock()
        let c = controller([.fetched(RemoteCaptureConfig(configTtlSeconds: 1, fetchedAtMs: 0))], clock: clock)
        await c.refresh()
        let delay = await c.scheduledDelay
        XCTAssertEqual(delay, 30)
    }

    func testFailureBackoffAndRetryAfter() async {
        let clock = TestClock()
        let c = controller(
            [
                .failed(message: "x", status: 500, retryAfter: nil), .failed(message: "x", status: 500, retryAfter: nil),
                .failed(message: "x", status: 503, retryAfter: 600),
            ], clock: clock)
        await c.refresh()
        var d = await c.scheduledDelay
        XCTAssertEqual(d, 30)
        await c.refresh()
        d = await c.scheduledDelay
        XCTAssertEqual(d, 60)
        await c.refresh()
        d = await c.scheduledDelay
        XCTAssertEqual(d, 600)
        for _ in 0..<20 { await c.refresh() }
        d = await c.scheduledDelay
        XCTAssertEqual(d, 1800, "capped at 30 min")
        let allowed = await c.uploadsAllowed
        XCTAssertFalse(allowed, "no config yet: uploads wait for a successful fetch")
    }

    func testCacheIsScopedPerBackendAndKey() async {
        let cache = MemoryConfigCache()
        let clock = TestClock()
        let a = RemoteConfigController.scope(for: BugCapsuleBackendConfig(url: "http://a", ingestKey: "bci_1"))
        let b = RemoteConfigController.scope(for: BugCapsuleBackendConfig(url: "http://a", ingestKey: "bci_2"))
        XCTAssertNotEqual(a, b)
        let ctrl = controller([.fetched(RemoteCaptureConfig(enabled: false, fetchedAtMs: 1))], clock: clock, cache: cache, scope: a)
        await ctrl.refresh()
        XCTAssertNotNil(cache.read(scope: a))
        XCTAssertNil(cache.read(scope: b), "a config cached for another environment never applies")
        let other = controller([.failed(message: "x", status: nil, retryAfter: nil)], clock: clock, cache: cache, scope: b)
        await other.loadCached()
        let current = await other.current
        XCTAssertNil(current)
    }

    func testKillSwitchAndUnauthorized() async {
        let clock = TestClock()
        let changes = OrderBox()
        let c = controller(
            [
                .fetched(RemoteCaptureConfig(enabled: false, fetchedAtMs: Int(clock.now.timeIntervalSince1970 * 1000))),
                .failed(message: "unauthorized", status: 401, retryAfter: nil),
            ], clock: clock, changes: changes)
        await c.refresh()
        var allowed = await c.captureAllowed
        XCTAssertFalse(allowed)
        await c.refresh()
        let rejected = await c.keyRejected
        XCTAssertTrue(rejected)
        allowed = await c.uploadsAllowed
        XCTAssertFalse(allowed)
        XCTAssertEqual(changes.items, ["disabled", "disabled"])
    }

    func testParsingClampsAndRejectsWrongTypes() throws {
        let c = try RemoteCaptureConfig(json: ["sampleRate": 3, "configTtlSeconds": 999_999, "maxCapsuleBytes": 0])
        XCTAssertEqual(c.sampleRate, 1)
        XCTAssertEqual(c.configTtlSeconds, 86400)
        XCTAssertEqual(c.maxCapsuleBytes, 1)
        XCTAssertThrowsError(try RemoteCaptureConfig(json: ["enabled": "yes"]))
    }
}

final class BackendClientTests: XCTestCase {
    func testConfigAndUploadStatusMapping() async throws {
        let statuses = OrderBox()
        let server = try TestHTTPServer { req in
            statuses.add("\(req.method) \(req.path)")
            switch req.path {
            case "/v1/sdk/config":
                return .init(status: 200, body: Data(#"{"enabled":true,"sampleRate":0.5,"configTtlSeconds":60}"#.utf8))
            default:
                return .init(status: 429, headers: ["Retry-After": "120"], body: Data(#"{"code":"rate_limited"}"#.utf8))
            }
        }
        defer { server.stop() }
        let client = BugCapsuleBackendClient(config: BugCapsuleBackendConfig(url: server.baseURL + "/", ingestKey: "bci_test"))
        guard case .fetched(let config) = await client.fetchConfig() else { return XCTFail("fetch failed") }
        XCTAssertEqual(config.sampleRate, 0.5)
        let result = await client.upload(try Gzip.compress(Data("x".utf8)))
        XCTAssertEqual(result.status, .retryLater)
        XCTAssertEqual(result.retryAfter, 120)
        XCTAssertEqual(result.message, "rate_limited")
        let upload = server.requests.last!
        XCTAssertEqual(upload.headers["authorization"], "Bearer bci_test")
        XCTAssertEqual(upload.headers["content-type"], "application/octet-stream")
        XCTAssertTrue(Gzip.isGzip(upload.body))
    }

    func testPermanentRejectionAndUnauthorizedConfig() async throws {
        let server = try TestHTTPServer { req in
            req.path == "/v1/sdk/config" ? .init(status: 401) : .init(status: 400, body: Data(#"{"code":"invalid_capsule"}"#.utf8))
        }
        defer { server.stop() }
        let client = BugCapsuleBackendClient(config: BugCapsuleBackendConfig(url: server.baseURL, ingestKey: "bci_x"))
        guard case .failed(_, let status, _, _, _) = await client.fetchConfig() else { return XCTFail() }
        XCTAssertEqual(status, 401)
        let result = await client.upload(Data([0x1f, 0x8b]))
        XCTAssertEqual(result.status, .rejected)
    }

    func testNetworkErrorIsRetryLater() async {
        let client = BugCapsuleBackendClient(config: BugCapsuleBackendConfig(url: "http://127.0.0.1:9", ingestKey: "bci_x"))
        let result = await client.upload(Data([0x1f, 0x8b]))
        XCTAssertEqual(result.status, .retryLater)
    }
}
