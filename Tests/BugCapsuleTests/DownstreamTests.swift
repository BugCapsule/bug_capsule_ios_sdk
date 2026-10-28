import Foundation
import XCTest

@testable import BugCapsule

/// Requests re-issued below the SDK's protocol, against a loopback server.
@MainActor
final class DownstreamSessionTests: XCTestCase {
    var server: TestHTTPServer!

    override func setUp() async throws {
        await BugCapsule.resetForTesting()
        server = try TestHTTPServer { req in
            let path = req.path.split(separator: "?").first.map(String.init) ?? req.path
            switch path {
            case "/echo":
                var headers = JSONObject()
                for (k, v) in req.headers { headers[k] = .string(v) }
                return .init(status: 200, headers: ["Content-Type": "application/json"], body: JSON.encodeData(.object(headers)))
            case "/setcookie":
                return .init(status: 200, headers: ["Set-Cookie": "sid=PRIVATE123; Path=/"], body: Data("{}".utf8))
            case "/slow": return .init(status: 200, body: Data("slow".utf8), delay: 0.6)
            case "/fast": return .init(status: 200, body: Data("fast".utf8))
            default: return .init(status: 404)
            }
        }
        BugCapsule.start(
            BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa), integrations: [BugCapsuleURLSession()],
            overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory()))
    }

    override func tearDown() async throws {
        await BugCapsule.resetForTesting()
        server.stop()
    }

    private func url(_ path: String) -> URL { URL(string: server.baseURL + path)! }

    private func instrumented(_ config: URLSessionConfiguration = .ephemeral) -> URLSessionConfiguration {
        config.timeoutIntervalForRequest = 5  // a lost response fails the test instead of hanging it
        BugCapsule.instrument(config)
        return config
    }

    func testConcurrentRequestsOnTwoSessionsGetTheirOwnResponses() async throws {
        let a = URLSession(configuration: instrumented())
        let slow = Task { try await a.data(from: self.url("/slow")).0 }
        try await Task.sleep(nanoseconds: 200_000_000)
        // Each downstream session numbers its tasks from 1, so both requests
        // below run as task 1 of their session.
        let b = URLSession(configuration: instrumented())
        let (fast, _) = try await b.data(from: url("/fast"))
        let slowBody = try await slow.value
        XCTAssertEqual(String(decoding: fast, as: UTF8.self), "fast")
        XCTAssertEqual(String(decoding: slowBody, as: UTF8.self), "slow")
    }

    private func headers(_ data: Data) throws -> JSONValue { try JSON.parse(data) }

    func testHeadersOfOneConfigurationDontReachAnotherSessionsRequests() async throws {
        let a = URLSession(configuration: instrumented())
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["Authorization": "Bearer FIRSTPARTY_SECRET", "X-Api-Key": "K123"]
        let b = URLSession(configuration: instrumented(config))  // instrumented last
        let (echoA, _) = try await a.data(from: url("/echo"))
        let (echoB, _) = try await b.data(from: url("/echo"))
        XCTAssertNil(try headers(echoA)["authorization"])
        XCTAssertNil(try headers(echoA)["x-api-key"])
        XCTAssertEqual(try headers(echoB)["authorization"], "Bearer FIRSTPARTY_SECRET", "a session keeps its own headers")
        XCTAssertEqual(try headers(echoB)["x-api-key"], "K123")
    }

    func testEphemeralCookiesStayInTheSessionsOwnStorage() async throws {
        let site = url("/")
        for c in HTTPCookieStorage.shared.cookies(for: site) ?? [] { HTTPCookieStorage.shared.deleteCookie(c) }
        let config = instrumented()
        _ = instrumented(.default)  // instrumented last, uses the shared cookie storage
        let session = URLSession(configuration: config)
        _ = try await session.data(from: url("/setcookie"))
        XCTAssertEqual(HTTPCookieStorage.shared.cookies(for: site)?.map(\.name) ?? [], [])
        XCTAssertEqual(config.httpCookieStorage?.cookies(for: site)?.map(\.value), ["PRIVATE123"])
        let (echo, _) = try await session.data(from: url("/echo"))
        XCTAssertEqual(try headers(echo)["cookie"], "sid=PRIVATE123", "the session sends its own cookie back")
    }

    func testRequestsOfUninstrumentedConfigurationsUseTheDefaultConfiguration() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["Authorization": "Bearer FIRSTPARTY_SECRET"]
        _ = instrumented(config)
        // As with instrumentSharedSession(): the base class, not a class of `instrument(_:)`.
        let plain = URLSessionConfiguration.ephemeral
        plain.protocolClasses = [BugCapsuleURLProtocol.self]
        let (echo, _) = try await URLSession(configuration: plain).data(from: url("/echo"))
        XCTAssertNil(try headers(echo)["authorization"])
    }

    func testReinstrumentingReplacesTheSDKProtocol() {
        let config = instrumented()
        BugCapsule.instrument(config)
        XCTAssertEqual(config.protocolClasses?.filter { BugCapsuleURLSession.isSDKProtocol($0) }.count, 1)
        XCTAssertTrue(BugCapsuleURLSession.isSDKProtocol(config.protocolClasses!.first!))
    }

    func testIdleDownstreamSessionIsClosedAndReopened() async throws {
        DownstreamSession.idleTimeout = 0.1
        defer { DownstreamSession.idleTimeout = 60 }
        let session = URLSession(configuration: instrumented())
        let (first, _) = try await session.data(from: url("/fast"))
        try await Task.sleep(nanoseconds: 400_000_000)
        let (second, _) = try await session.data(from: url("/fast"))
        XCTAssertEqual(String(decoding: first, as: UTF8.self), "fast")
        XCTAssertEqual(String(decoding: second, as: UTF8.self), "fast")
    }
}
