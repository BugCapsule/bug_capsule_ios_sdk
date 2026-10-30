import Foundation
import XCTest

@testable import BugCapsule

/// An app session delegate: answers challenges and redirects, counting them.
final class AppSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _challenges: [URLAuthenticationChallenge] = []
    private var _redirects: [URLRequest] = []
    let followRedirects: Bool
    let answerDelay: TimeInterval
    init(followRedirects: Bool = true, answerDelay: TimeInterval = 0) {
        self.followRedirects = followRedirects
        self.answerDelay = answerDelay
    }

    var challenges: [URLAuthenticationChallenge] { lock.locked { _challenges } }
    var redirects: [URLRequest] { lock.locked { _redirects } }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        lock.locked { _challenges.append(challenge) }
        if challenge.previousFailureCount > 0 { return completionHandler(.cancelAuthenticationChallenge, nil) }
        completionHandler(.useCredential, URLCredential(user: "app", password: "secret", persistence: .none))
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        lock.locked { _redirects.append(request) }
        let answer = followRedirects ? request : nil
        guard answerDelay > 0 else { return completionHandler(answer) }
        DispatchQueue.global().asyncAfter(deadline: .now() + answerDelay) { completionHandler(answer) }
    }
}

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
            case "/auth" where req.headers["authorization"] == nil, "/deny":
                return .init(status: 401, headers: ["WWW-Authenticate": #"Basic realm="test""#])
            case "/auth": return .init(status: 200, body: Data((req.headers["authorization"] ?? "").utf8))
            case "/redirect": return .init(status: 302, headers: ["Location": "/final"], body: Data("moved".utf8))
            case "/final": return .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"final":true}"#.utf8))
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

    // MARK: the app's session delegate

    private var httpEvents: [BugCapsuleEvent] {
        BugCapsuleSession.current!.recorderForTesting!.window().events.filter { $0.type == EventTypes.http }
    }

    private func waitForEvents(_ n: Int, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where httpEvents.count < n { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertGreaterThanOrEqual(httpEvents.count, n, file: file, line: line)
    }

    func testAuthChallengeReachesTheAppsSessionDelegate() async throws {
        let delegate = AppSessionDelegate()
        let session = URLSession(configuration: instrumented(), delegate: delegate, delegateQueue: nil)
        let (data, response) = try await session.data(from: url("/auth"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(delegate.challenges.map(\.protectionSpace.authenticationMethod), [NSURLAuthenticationMethodHTTPBasic])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "Basic " + Data("app:secret".utf8).base64EncodedString())
    }

    func testAppCancellingARejectedCredentialFailsTheRequest() async throws {
        let delegate = AppSessionDelegate()
        let session = URLSession(configuration: instrumented(), delegate: delegate, delegateQueue: nil)
        do {
            _ = try await session.data(from: url("/deny"))
            XCTFail("expected the cancelled challenge to fail the request")
        } catch let e as URLError {
            XCTAssertEqual(e.code, .cancelled)
        }
        XCTAssertEqual(delegate.challenges.map(\.previousFailureCount), [0, 1])
        XCTAssertEqual(delegate.challenges.last?.proposedCredential?.user, "app")
    }

    func testRedirectIsReportedToTheAppsSessionDelegateAndRecordedPerHop() async throws {
        let delegate = AppSessionDelegate()
        let session = URLSession(configuration: instrumented(), delegate: delegate, delegateQueue: nil)
        let (data, response) = try await session.data(from: url("/redirect"))
        XCTAssertEqual(try JSON.parse(data), ["final": true])
        XCTAssertEqual(response.url, url("/final"))
        XCTAssertEqual(delegate.redirects.map(\.url), [url("/final")])
        await waitForEvents(2)
        guard httpEvents.count == 2 else { return XCTFail("one http event per hop: \(httpEvents.map(\.data))") }
        XCTAssertEqual(httpEvents.map { $0.data["key"] }, ["GET 127.0.0.1/redirect", "GET 127.0.0.1/final"])
        XCTAssertEqual(httpEvents[0].data["status"], 302)
        XCTAssertEqual(httpEvents[0].data["responseHeaders"]?["location"], "/final")
        XCTAssertEqual(httpEvents[0].data["bodyEncoding"], "json")
        XCTAssertEqual(httpEvents[1].data["responseBody"], ["final": true])
        XCTAssertEqual(server.requests.map(\.path), ["/redirect", "/final"])
    }

    func testA3xxNeverOvertakesTheAppsAnswerToFollowTheRedirect() async throws {
        for answerDelay in [0, 0.0002, 0.001, 0.005, 0.05] {
            let session = URLSession(
                configuration: instrumented(), delegate: AppSessionDelegate(answerDelay: answerDelay), delegateQueue: nil)
            for _ in 0..<20 {
                let (data, response) = try await session.data(from: url("/redirect"))
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "the app answered after \(answerDelay)s")
                XCTAssertEqual(try? JSON.parse(data), ["final": true])
            }
        }
    }

    func testAppCanRefuseARedirect() async throws {
        let delegate = AppSessionDelegate(followRedirects: false)
        let session = URLSession(configuration: instrumented(), delegate: delegate, delegateQueue: nil)
        let (data, response) = try await session.data(from: url("/redirect"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 302)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "moved")
        XCTAssertEqual(delegate.redirects.count, 1)
        XCTAssertEqual(server.requests.map(\.path), ["/redirect"], "the redirect is not followed below the SDK")
    }

    func testSessionWithoutDelegateFollowsRedirectsAndUsesDefaultChallengeHandling() async throws {
        let session = URLSession(configuration: instrumented())
        let (data, _) = try await session.data(from: url("/redirect"))
        XCTAssertEqual(try JSON.parse(data), ["final": true])
        let (_, response) = try await session.data(from: url("/auth"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401, "no credential: the 401 response, as without the SDK")
    }
}
