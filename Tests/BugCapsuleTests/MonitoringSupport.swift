import Foundation
import XCTest

@testable import BugCapsule

/// The backend as a URLProtocol stub (`http://backend.test`), speaking the
/// monitoring-v1 contract: config, capsule upload and envelope ingest.
final class StubBackend: URLProtocol, @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let query: String?
        let headers: [String: String]
        let body: Data

        func header(_ name: String) -> String? {
            headers.first { $0.key.lowercased() == name.lowercased() }?.value
        }

        /// The JSON body, inflated when `Content-Encoding: gzip`.
        var json: JSONValue? {
            let raw = header("Content-Encoding") == "gzip" ? (try? Gzip.decompress(body, maxBytes: 20_000_000)) : body
            return raw.flatMap { try? JSON.parse($0) }
        }
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: Data = Data("{}".utf8)
    }

    static let lock = NSLock()
    nonisolated(unsafe) private static var _requests: [Request] = []
    nonisolated(unsafe) static var config: JSONObject = ["enabled": true, "sampleRate": 1]
    /// Next responses for `/v1/envelope` (then 200 with `accepted`).
    nonisolated(unsafe) static var envelopeResponses: [Response] = []

    static func reset() {
        lock.locked {
            _requests = []
            config = ["enabled": true, "sampleRate": 1]
            envelopeResponses = []
        }
    }

    static var requests: [Request] { lock.locked { _requests } }

    static func requests(_ path: String) -> [Request] { requests.filter { $0.path == path } }

    /// Every item of every envelope received, in order.
    static var items: [(type: String, payload: JSONObject)] {
        requests("/v1/envelope").flatMap { r -> [(String, JSONObject)] in
            (r.json?["items"]?.arrayValue ?? []).compactMap { item in
                guard let t = item["type"]?.stringValue, let p = item["payload"]?.objectValue else { return nil }
                return (t, p)
            }
        }
    }

    static func items(_ type: String) -> [JSONObject] { items.filter { $0.type == type }.map(\.payload) }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "backend.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        let url = request.url!
        let req = Request(
            method: request.httpMethod ?? "GET", path: url.path, query: url.query,
            headers: request.allHTTPHeaderFields ?? [:], body: body)
        let response: Response = Self.lock.locked {
            Self._requests.append(req)
            switch url.path {
            case "/v1/sdk/config":
                return Response(status: 200, body: JSON.encodeData(.object(Self.config)))
            case "/v1/capsules":
                return Response(status: 201, body: Data(#"{"id":"srv"}"#.utf8))
            case "/v1/envelope":
                if !Self.envelopeResponses.isEmpty { return Self.envelopeResponses.removeFirst() }
                let n = req.json?["items"]?.arrayValue?.count ?? 0
                return Response(status: 200, body: Data(#"{"accepted":\#(n),"rejected":[]}"#.utf8))
            default:
                return Response(status: 404)
            }
        }
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

let stubBackend = BugCapsuleBackendConfig(url: "http://backend.test", ingestKey: "bci_test_key_1234567890")

func stubTransport() -> BugCapsuleBackendClient {
    BugCapsuleBackendClient(config: stubBackend, protocolClasses: [StubBackend.self])
}

/// Quiet monitoring options for tests: no hang watchdog, no batching wait
/// in assertions (tests call `BugCapsule.flush`).
func testMonitoringOptions(
    tracesSampleRate: Double? = nil, targets: [String] = [], nativeCrashes: Bool = false,
    beforeSend: (@Sendable (MonitoringEvent, EventHint) -> MonitoringEvent?)? = nil
) -> BugCapsuleMonitoringOptions {
    BugCapsuleMonitoringOptions(
        tracesSampleRate: tracesSampleRate, tracePropagationTargets: targets, beforeSend: beforeSend,
        enableAppHangTracking: false, enableNativeCrashHandling: nativeCrashes, enableMachExceptionHandling: false)
}
