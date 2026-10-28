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
}
