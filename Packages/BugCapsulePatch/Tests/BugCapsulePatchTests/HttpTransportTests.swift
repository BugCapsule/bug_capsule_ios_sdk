import Foundation
import Network
import XCTest

@testable import BugCapsulePatch

/// A minimal real HTTP server on loopback, so URLSession's actual behavior is
/// what gets tested: redirects, cancellation and headers.
private final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var responses: [Data] = []
    private var heard: [String] = []
    private var trickle = false
    let queue = DispatchQueue(label: "loopback")

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    var port: Int { Int(listener.port?.rawValue ?? 0) }
    var requests: [String] { lock.withLock { heard } }

    func enqueue(_ status: Int, _ body: Data = Data(), headers: [String: String] = [:], declaredLength: Int? = nil) {
        var head = "HTTP/1.1 \(status) X\r\nConnection: close\r\nContent-Length: \(declaredLength ?? body.count)\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        lock.withLock { responses.append(Data((head + "\r\n").utf8) + body) }
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
    }

    /// Reads until the headers and the declared body have arrived.
    private func read(_ c: NWConnection, _ soFar: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, _ in
            guard let self else { return }
            let all = soFar + (data ?? Data())
            let text = String(decoding: all, as: UTF8.self)
            let head = text.components(separatedBy: "\r\n\r\n").first ?? ""
            let length = head.lowercased().components(separatedBy: "\r\n").first { $0.hasPrefix("content-length:") }
                .flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
            let bodySeen = text.utf8.count - head.utf8.count - 4
            if !done, !text.contains("\r\n\r\n") || bodySeen < length {
                self.read(c, all)
                return
            }
            self.lock.withLock { self.heard.append(text) }
            if self.lock.withLock({ self.trickle }) {
                c.send(content: Data("HTTP/1.1 200 X\r\nContent-Length: 1000000\r\n\r\n".utf8), completion: .idempotent)
                self.drip(c)
                return
            }
            let reply = self.lock.withLock { self.responses.isEmpty ? Data() : self.responses.removeFirst() }
            // A brief linger, so the client reads the response before the close.
            c.send(content: reply, completion: .contentProcessed { [queue = self.queue] _ in
                queue.asyncAfter(deadline: .now() + 0.2) { c.cancel() }
            })
        }
    }

    private func drip(_ c: NWConnection) {
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, c.state == .ready else { return }
            c.send(content: Data([1]), completion: .contentProcessed { [weak self] e in if e == nil { self?.drip(c) } })
        }
    }

    /// The next connection gets one byte every 100 ms, forever.
    func enqueueTrickle() {
        lock.withLock { trickle = true }
    }

    func stop() { listener.cancel() }
}

final class HttpTransportTests: XCTestCase {
    private var server: LoopbackServer!
    private var t: HttpPatchTransport!
    private let digest = "sha256:" + String(repeating: "a", count: 64)

    override func setUpWithError() throws {
        server = try LoopbackServer()
        t = try HttpPatchTransport(
            baseURL: "http://127.0.0.1:\(server.port)", deliveryToken: "bcpd_secret", applicationId: "com.shop", platform: "ios",
            distributionProfile: "internal", baseBuildId: "build-1", installationId: "install-1", timeout: 3)
    }

    override func tearDown() { server.stop() }

    private func reason(_ f: () async throws -> Void) async -> String? {
        do {
            try await f()
            return nil
        } catch let e as PatchHTTPError {
            return e.reason
        } catch {
            return "other: \(error)"
        }
    }

    func testFetchesTheChannelWithScopeTokenAndExactBytes() async throws {
        let body = #"{"channel":{"document":"AQI=","signature":"Aw=="},"keyring":{"version":2,"document":"BA==","signature":"BQ=="}}"#
        server.enqueue(200, Data(body.utf8), headers: ["ETag": "\"abc\""])
        let c = try await t.fetchChannel(etag: nil)
        XCTAssertEqual(c?.document, Data([1, 2]))
        XCTAssertEqual(c?.keyringDocument, Data([4]))
        XCTAssertEqual(c?.etag, "\"abc\"")
        let r = try XCTUnwrap(server.requests.first).lowercased()
        XCTAssertTrue(r.contains("/v1/apps/com.shop/patches/channel?platform=ios&distributionprofile=internal&basebuildid=build-1"))
        XCTAssertTrue(r.contains("authorization: bearer bcpd_secret"))
    }

    func testNoContentAndNotModifiedMeanNothingToDo() async throws {
        server.enqueue(304)
        let a = try await t.fetchChannel(etag: "\"abc\"")
        XCTAssertNil(a)
        XCTAssertTrue(server.requests.first?.lowercased().contains("if-none-match: \"abc\"") == true)
        server.enqueue(204)
        let b = try await t.fetchChannel(etag: nil)
        XCTAssertNil(b)
    }

    func testDeclaredOversizeIsRefusedWithoutItsBody() async {
        // More than URLSession's sniffing window, or the response isn't surfaced.
        server.enqueue(200, Data(count: 4096), declaredLength: HttpPatchTransport.maxArtifactBytes + 1)
        let r = await reason { _ = try await self.t.fetchArtifact(digest: self.digest) }
        XCTAssertEqual(r, "response_too_large")
    }

    func testOversizeChannelStopsAtTheLimit() async {
        server.enqueue(200, Data(count: HttpPatchTransport.maxChannelBytes + 1))
        let r = await reason { _ = try await self.t.fetchChannel(etag: nil) }
        XCTAssertEqual(r, "response_too_large")
    }

    func testABodyCutShortIsAFailureNotAShortSuccess() async {
        server.enqueue(200, Data(count: 16), declaredLength: 1024)
        let r = await reason { _ = try await self.t.fetchArtifact(digest: self.digest) }
        XCTAssertNotNil(r, "a truncated body must not be returned")
    }

    func testAnErrorBodyIsNotReadToTheEnd() async {
        server.enqueue(500, Data(count: 1024), declaredLength: 10 << 20)
        let start = Date()
        let r = await reason { _ = try await self.t.fetchArtifact(digest: self.digest) }
        XCTAssertEqual(r, "http_error")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testATrickledBodyCannotOutliveTheAbsoluteDeadline() async throws {
        let quick = try HttpPatchTransport(
            baseURL: "http://127.0.0.1:\(server.port)", deliveryToken: "x", applicationId: "a", platform: "ios",
            distributionProfile: "d", baseBuildId: "b", installationId: "i", timeout: 1, artifactTimeout: 1)
        server.enqueueTrickle()
        let start = Date()
        let r = await reason { _ = try await quick.fetchArtifact(digest: self.digest) }
        XCTAssertEqual(r, "timed_out")
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testRedirectsAreNotFollowed() async throws {
        let other = try LoopbackServer()
        defer { other.stop() }
        server.enqueue(302, headers: ["Location": "http://127.0.0.1:\(other.port)/steal"])
        let r = await reason { _ = try await self.t.fetchArtifact(digest: self.digest) }
        XCTAssertEqual(r, "redirect_refused")
        XCTAssertTrue(other.requests.isEmpty, "the token must not follow a redirect")
    }

    func testErrorsAreTyped() async {
        for (status, want) in [(401, "unauthorized"), (404, "not_found"), (410, "gone"), (429, "rate_limited"), (500, "http_error")] {
            server.enqueue(status)
            let r = await reason { _ = try await self.t.fetchArtifact(digest: self.digest) }
            XCTAssertEqual(r, want)
        }
    }

    func testMalformedDigestNeverReachesAPath() async {
        let r = await reason { _ = try await self.t.fetchArtifact(digest: "../secrets") }
        XCTAssertEqual(r, "bad_digest")
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testReceiptsMapToTheApiAndDropUnknownEvents() async throws {
        server.enqueue(202, Data("{}".utf8))
        let batch: [String: Any] = [
            "receipts": [
                ["seq": 1, "event": "staged", "digest": digest, "reason": NSNull(), "at": 5],
                ["seq": 2, "event": "something_new", "digest": NSNull(), "reason": NSNull(), "at": 6],
            ],
            "status": ["activeDigest": NSNull(), "pending": digest, "channelRevision": 4],
        ]
        try await t.postReceipts(JSONSerialization.data(withJSONObject: batch))
        let r = try XCTUnwrap(server.requests.first)
        XCTAssertTrue(r.contains("install-1"))
        XCTAssertFalse(r.contains("something_new"))
    }

    func testPlainHttpIsRefusedOutsideLoopback() {
        XCTAssertThrowsError(try HttpPatchTransport(baseURL: "http://example.com", deliveryToken: "x", applicationId: "a", platform: "p", distributionProfile: "d", baseBuildId: "b", installationId: "i"))
    }
}
