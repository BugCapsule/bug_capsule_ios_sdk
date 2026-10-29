import Foundation
import XCTest

@testable import BugCapsule

@MainActor
final class NetworkCaptureTests: XCTestCase {
    var urlSession: URLSession!
    var net: BugCapsuleURLSession!

    override func setUp() async throws {
        await BugCapsule.resetForTesting()
        FakeServerProtocol.reset()
        net = BugCapsuleURLSession(
            rules: [EndpointRule("POST", "/api/checkout", ignoreBodyFields: ["timestamp", "nonce"])], maxBinaryBytes: 16,
            maxBodyWait: 1)
        var config = BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa, maxBodyBytes: 128)
        config.redactKeys = ["loyaltyId"]
        BugCapsule.start(config, integrations: [net], overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory()))
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeServerProtocol.self]
        BugCapsule.instrument(c)
        XCTAssertTrue(BugCapsuleURLSession.isSDKProtocol(c.protocolClasses!.first!))
        urlSession = URLSession(configuration: c)
    }

    override func tearDown() async throws {
        await BugCapsule.resetForTesting()
    }

    private var httpEvents: [BugCapsuleEvent] {
        BugCapsuleSession.current!.recorderForTesting!.window().events.filter { $0.type == EventTypes.http }
    }

    private func waitForEvents(_ n: Int, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where httpEvents.count < n { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertGreaterThanOrEqual(httpEvents.count, n, file: file, line: line)
    }

    func testRecordsExchangeWithKeyOccurrenceRedactionAndUntouchedStream() async throws {
        let chunks = [Data(#"{"items":[1,2],"#.utf8), Data(#""token":"abc","n":null}"#.utf8)]
        FakeServerProtocol.routes["/api/cart"] = .init(chunks: chunks)
        var req = URLRequest(url: URL(string: "https://shop.test/api/cart?lang=en&token=secret")!)
        req.setValue("Bearer abcdefghijk", forHTTPHeaderField: "Authorization")
        let (data1, r1) = try await urlSession.data(for: req)
        let (data2, _) = try await urlSession.data(for: req)
        XCTAssertEqual(data1, chunks[0] + chunks[1], "the app receives the bytes unchanged")
        XCTAssertEqual(data2, data1)
        XCTAssertEqual((r1 as? HTTPURLResponse)?.statusCode, 200)
        await waitForEvents(2)
        let e = httpEvents[0].data
        XCTAssertEqual(e["key"], "GET shop.test/api/cart?lang=en&token=[REDACTED]")
        XCTAssertEqual(e["occurrence"], 0)
        XCTAssertEqual(httpEvents[1].data["occurrence"], 1)
        // redactURL encodes the placeholder; the event-level scrub then normalizes it (as the Dart SDK does).
        XCTAssertEqual(e["url"], "https://shop.test/api/cart?lang=en&token=[REDACTED]")
        XCTAssertEqual(e["requestHeaders"]?["authorization"], "[REDACTED]")
        XCTAssertEqual(e["status"], 200)
        XCTAssertEqual(e["bodyEncoding"], "json")
        XCTAssertEqual(e["responseBody"]?["token"], "[REDACTED]")
        XCTAssertEqual(e["responseBody"]?["items"], [1, 2])
        XCTAssertNotNil(e["durationMs"]?.intValue)
    }

    func testRequestBodyIsHashedWithRuleAndRecorded() async throws {
        FakeServerProtocol.routes["/api/checkout"] = .init()
        var req = URLRequest(url: URL(string: "https://shop.test/api/checkout")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"{"cart_id":"c1","amount":3,"timestamp":17,"nonce":5,"loyaltyId":"L1"}"#.utf8)
        _ = try await urlSession.data(for: req)
        await waitForEvents(1)
        let e = httpEvents[0].data
        let expected = RequestKeyBuilder(rules: [EndpointRule("POST", "/api/checkout", ignoreBodyFields: ["timestamp", "nonce"])])
            .key(method: "POST", url: "https://shop.test/api/checkout", body: .json(["cart_id": "c1", "amount": 3, "loyaltyId": "[REDACTED]"]))
        XCTAssertEqual(e["key"]?.stringValue, expected)
        XCTAssertEqual(e["requestEncoding"], "json")
        XCTAssertEqual(e["requestBody"]?["loyaltyId"], "[REDACTED]")
        XCTAssertNotNil(FakeServerProtocol.bodies.first ?? nil, "the body still reaches the server")
    }

    func testOneShotBodyStreamIsKeyedWithoutHashAndOmitted() async throws {
        FakeServerProtocol.routes["/upload"] = .init()
        var req = URLRequest(url: URL(string: "https://shop.test/upload")!)
        req.httpMethod = "POST"
        req.httpBodyStream = InputStream(data: Data("stream-body".utf8))
        _ = try await urlSession.data(for: req)
        await waitForEvents(1)
        XCTAssertEqual(httpEvents[0].data["key"], "POST shop.test/upload")
        XCTAssertEqual(httpEvents[0].data["requestEncoding"], "omitted")
        XCTAssertEqual(FakeServerProtocol.bodies.first ?? nil, Data("stream-body".utf8), "the stream is forwarded untouched")
    }

    func testBodyLargerThanLimitIsTruncatedButDeliveredInFull() async throws {
        let big = Data(String(repeating: "x", count: 200).utf8)
        FakeServerProtocol.routes["/big"] = .init(headers: ["Content-Type": "text/plain"], chunks: [big.prefix(100), big.suffix(100)])
        let (data, _) = try await urlSession.data(from: URL(string: "https://shop.test/big")!)
        XCTAssertEqual(data, big)
        await waitForEvents(1)
        XCTAssertEqual(httpEvents[0].data["bodyEncoding"], "truncated")
        XCTAssertNil(httpEvents[0].data["responseBody"])
    }

    func testBinaryBodiesAreBase64WithinTheBinaryLimit() async throws {
        FakeServerProtocol.routes["/img"] = .init(headers: ["Content-Type": "image/png"], chunks: [Data([1, 2, 3, 4])])
        _ = try await urlSession.data(from: URL(string: "https://shop.test/img")!)
        await waitForEvents(1)
        XCTAssertEqual(httpEvents[0].data["bodyEncoding"], "base64")
        XCTAssertEqual(httpEvents[0].data["responseBody"], .string(Data([1, 2, 3, 4]).base64EncodedString()))
    }

    func testConnectionErrorIsRecordedAndRaisedToTheApp() async throws {
        FakeServerProtocol.routes["/down"] = .init(error: URLError(.cannotConnectToHost))
        do {
            _ = try await urlSession.data(from: URL(string: "https://shop.test/down")!)
            XCTFail("expected an error")
        } catch let e as URLError {
            XCTAssertEqual(e.code, .cannotConnectToHost)
        }
        await waitForEvents(1)
        let e = httpEvents[0].data
        XCTAssertEqual(e["status"], 0)
        XCTAssertEqual(e["error"]?["type"], "connectionError")
        XCTAssertEqual(e["error"]?["code"], .int(URLError.cannotConnectToHost.rawValue))
    }

    func testTimeoutBeforeResponseIsConnectionTimeout() async throws {
        FakeServerProtocol.routes["/slow"] = .init(error: URLError(.timedOut))
        _ = try? await urlSession.data(from: URL(string: "https://shop.test/slow")!)
        await waitForEvents(1)
        XCTAssertEqual(httpEvents[0].data["error"]?["type"], "connectionTimeout")
    }

    func testCancelIsRecorded() async throws {
        FakeServerProtocol.routes["/hang"] = .init(delay: 5)
        let task = urlSession.dataTask(with: URL(string: "https://shop.test/hang")!)
        task.resume()
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        await waitForEvents(1)
        XCTAssertEqual(httpEvents[0].data["error"]?["type"], "cancel")
    }

    func testStillStreamingAfterWaitLimitIsRecordedTruncated() async throws {
        FakeServerProtocol.routes["/stream"] = .init(chunks: [Data("{".utf8)], hang: true)
        let task = urlSession.dataTask(with: URL(string: "https://shop.test/stream")!)
        task.resume()
        await waitForEvents(1)  // maxBodyWait = 1 s
        XCTAssertEqual(httpEvents.first?.data["bodyEncoding"], "truncated")
        task.cancel()
    }

    func testInFlightExchangeIsWrittenAsPending() async throws {
        FakeServerProtocol.routes["/api/profile"] = .init(delay: 5)
        let task = urlSession.dataTask(with: URL(string: "https://shop.test/api/profile")!)
        task.resume()
        try await Task.sleep(nanoseconds: 150_000_000)
        let built = BugCapsuleSession.current!.buildCapsule(failure: FailureRecord.assertion("x", message: "", t: 1), labels: [:])!
        let pending = built.capsule.events.filter { $0.type == EventTypes.http }
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].data["pending"], true)
        XCTAssertEqual(pending[0].data["key"], "GET shop.test/api/profile")
        XCTAssertEqual(pending[0].data["error"]?["type"], "pending")
        XCTAssertNil(validateCapsuleDocument(CapsuleCodec.toJSON(built.capsule)))
        task.cancel()
    }

    func testNotRecordingPassesThrough() async throws {
        await BugCapsule.resetForTesting()
        FakeServerProtocol.routes["/x"] = .init()
        let (data, _) = try await urlSession.data(from: URL(string: "https://shop.test/x")!)
        XCTAssertEqual(data, Data(#"{"ok":true}"#.utf8))
    }

    func testBodiesOffRecordsAtHeadersAsOmitted() async throws {
        BugCapsuleSession.current!.applyRemote(nil, RemoteCaptureConfig(captureNetworkBodies: false, fetchedAtMs: epochMs()))
        FakeServerProtocol.routes["/a"] = .init()
        _ = try await urlSession.data(from: URL(string: "https://shop.test/a")!)
        await waitForEvents(1)
        XCTAssertEqual(httpEvents[0].data["bodyEncoding"], "omitted")
        XCTAssertEqual(httpEvents[0].data["responseBody"], .null)
    }
}

@MainActor
final class NetworkReplayTests: XCTestCase {
    var urlSession: URLSession!
    var engine: ReplayEngine!

    override func tearDown() async throws {
        await BugCapsule.resetForTesting()
    }

    private func startReplay(_ events: [BugCapsuleEvent], strict: Bool = true) {
        FakeServerProtocol.reset()
        FakeServerProtocol.routes["/live"] = .init(chunks: [Data(#"{"live":true}"#.utf8)])
        let net = BugCapsuleURLSession()
        let session = BugCapsuleSession(
            config: BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa), integrations: [net],
            overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory()))
        engine = session.startReplayForTesting(capsule: makeCapsule(events: events), settings: ReplaySettings(strictNetwork: strict))
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeServerProtocol.self]
        BugCapsule.instrument(c)
        urlSession = URLSession(configuration: c)
    }

    func testServesByKeyAndOccurrenceAfterRecordedLatency() async throws {
        startReplay([
            httpEvent(seq: 1, t: 100, key: "GET shop.test/api/a", occurrence: 1, body: ["n": 2], durationMs: 150),
            httpEvent(seq: 2, t: 50, key: "GET shop.test/api/a", occurrence: 0, body: ["n": 1], durationMs: 150),
        ])
        let start = Date()
        let (d1, r1) = try await urlSession.data(from: URL(string: "https://shop.test/api/a")!)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.14, "recorded latency is kept")
        let (d2, _) = try await urlSession.data(from: URL(string: "https://shop.test/api/a")!)
        XCTAssertEqual(try JSON.parse(d1), ["n": 1])
        XCTAssertEqual(try JSON.parse(d2), ["n": 2])
        XCTAssertEqual((r1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "content-type"), "application/json")
        let (d3, _) = try await urlSession.data(from: URL(string: "https://shop.test/api/a")!)
        XCTAssertEqual(try JSON.parse(d3), ["n": 2], "beyond the recorded count the last fixture is served again")
        let report = engine.buildReport()
        XCTAssertEqual(report.fixturesServed, 3)
        XCTAssertTrue(report.divergences.contains { $0.type == "network.reused" })
        XCTAssertTrue(FakeServerProtocol.hits.isEmpty, "replay never reaches the server below")
    }

    func testRaceOrderIsPreservedByRecordedDurations() async throws {
        startReplay([
            httpEvent(seq: 1, t: 300, key: "GET shop.test/api/profile", body: ["who": "p"], durationMs: 300),
            httpEvent(seq: 2, t: 80, key: "GET shop.test/api/recs", body: ["who": "r"], durationMs: 80),
        ])
        let order = OrderBox()
        let s: URLSession = urlSession
        let done = expectation(description: "both")
        done.expectedFulfillmentCount = 2
        s.dataTask(with: URL(string: "https://shop.test/api/profile")!) { _, _, _ in order.add("profile"); done.fulfill() }.resume()
        s.dataTask(with: URL(string: "https://shop.test/api/recs")!) { _, _, _ in order.add("recs"); done.fulfill() }.resume()
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(order.items, ["recs", "profile"])
    }

    func testStrictUnrecordedRequestFailsWithConnectionError() async throws {
        startReplay([httpEvent(seq: 1, t: 10, key: "GET shop.test/api/other")])
        do {
            _ = try await urlSession.data(from: URL(string: "https://shop.test/live")!)
            XCTFail("expected a connection error")
        } catch let e as URLError {
            XCTAssertEqual(e.code, .cannotConnectToHost)
        }
        let report = engine.buildReport()
        XCTAssertTrue(report.divergences.contains { $0.type == "network.unrecorded" && $0.detail == "GET shop.test/live" })
        XCTAssertTrue(report.divergences.contains { $0.type == "network.unused" && $0.detail == "GET shop.test/api/other" })
        XCTAssertTrue(FakeServerProtocol.hits.isEmpty)
    }

    func testLenientUnrecordedRequestGoesThrough() async throws {
        startReplay([], strict: false)
        let (data, _) = try await urlSession.data(from: URL(string: "https://shop.test/live")!)
        XCTAssertEqual(try JSON.parse(data), ["live": true])
        XCTAssertEqual(FakeServerProtocol.hits, ["/live"])
        XCTAssertTrue(engine.buildReport().divergences.contains { $0.type == "network.unrecorded" })
    }

    func testRecordedErrorIsRaisedNatively() async throws {
        startReplay([
            httpEvent(seq: 1, t: 10, key: "GET shop.test/api/x", status: 0, body: .null, durationMs: 10,
                error: ["type": "connectionTimeout", "message": "timed out", "domain": .string(NSURLErrorDomain), "code": .int(NSURLErrorTimedOut)],
                encoding: "omitted")
        ])
        do {
            _ = try await urlSession.data(from: URL(string: "https://shop.test/api/x")!)
            XCTFail("expected an error")
        } catch let e as URLError {
            XCTAssertEqual(e.code, .timedOut)
        }
    }

    func testCancellationStopsTheDelay() async throws {
        startReplay([httpEvent(seq: 1, t: 10, key: "GET shop.test/api/slow", durationMs: 5000)])
        let task = urlSession.dataTask(with: URL(string: "https://shop.test/api/slow")!)
        let done = expectation(description: "cancelled")
        let started = Date()
        let observed = OrderBox()
        let t2 = urlSession.dataTask(with: URL(string: "https://shop.test/api/none")!) { _, _, _ in }
        _ = t2
        let cancelTask = urlSession.dataTask(with: URL(string: "https://shop.test/api/slow")!) { _, _, error in
            observed.add((error as? URLError)?.code == .cancelled ? "cancelled" : "other")
            done.fulfill()
        }
        cancelTask.resume()
        try await Task.sleep(nanoseconds: 100_000_000)
        cancelTask.cancel()
        await fulfillment(of: [done], timeout: 2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(observed.items, ["cancelled"])
        _ = task
    }

    func testPendingFixtureIsHeldOpen() async throws {
        var e = httpEvent(seq: 1, t: 10, key: "GET shop.test/api/profile", status: 0, body: .null, durationMs: 400, error: ["type": "pending"], encoding: "omitted")
        e.data["pending"] = true
        startReplay([e])
        let done = expectation(description: "never completes")
        done.isInverted = true
        let task = urlSession.dataTask(with: URL(string: "https://shop.test/api/profile")!) { _, _, _ in done.fulfill() }
        task.resume()
        await fulfillment(of: [done], timeout: 0.8)
        let report = engine.buildReport()
        XCTAssertEqual(report.fixturesServed, 1)
        XCTAssertFalse(report.divergences.contains { $0.type.hasPrefix("network.") && $0.type != "network.unused" })
        task.cancel()
    }

    private func redirectFixtures() -> [BugCapsuleEvent] {
        var hop = httpEvent(seq: 1, t: 10, key: "GET shop.test/old", status: 302, body: .null, durationMs: 5)
        hop.data["responseHeaders"] = ["location": "/new"]
        return [hop, httpEvent(seq: 2, t: 20, key: "GET shop.test/new", body: ["moved": true], durationMs: 5)]
    }

    func testRecordedRedirectIsFollowedThroughTheAppsSession() async throws {
        startReplay(redirectFixtures())
        let delegate = AppSessionDelegate()
        let session = URLSession(configuration: urlSession.configuration, delegate: delegate, delegateQueue: nil)
        let (data, response) = try await session.data(from: URL(string: "https://shop.test/old")!)
        XCTAssertEqual(try JSON.parse(data), ["moved": true])
        XCTAssertEqual(response.url, URL(string: "https://shop.test/new"))
        XCTAssertEqual(delegate.redirects.map(\.url), [URL(string: "https://shop.test/new")])
        XCTAssertFalse(engine.buildReport().divergences.contains { $0.type.hasPrefix("network.") })
    }

    func testAppRefusingARecordedRedirectGetsTheRedirectResponse() async throws {
        startReplay(redirectFixtures())
        let session = URLSession(
            configuration: urlSession.configuration, delegate: AppSessionDelegate(followRedirects: false), delegateQueue: nil)
        let (_, response) = try await session.data(from: URL(string: "https://shop.test/old")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 302)
        XCTAssertTrue(engine.buildReport().divergences.contains { $0.type == "network.unused" && $0.detail == "GET shop.test/new" })
    }

    func testFixtureWithoutBodyReportsNoBody() async throws {
        startReplay([httpEvent(seq: 1, t: 10, key: "GET shop.test/api/nb", body: .null, durationMs: 5, encoding: "truncated")])
        _ = try await urlSession.data(from: URL(string: "https://shop.test/api/nb")!)
        XCTAssertTrue(engine.buildReport().divergences.contains { $0.type == "network.noBody" })
    }
}

final class OrderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [String] = []
    func add(_ s: String) { lock.locked { _items.append(s) } }
    var items: [String] { lock.locked { _items } }
}
