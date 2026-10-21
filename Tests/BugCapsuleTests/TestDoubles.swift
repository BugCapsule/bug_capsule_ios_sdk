import Foundation
import Network
import XCTest

@testable import BugCapsule

/// A loopback HTTP/1.1 server (one request per connection) for the replay
/// channel and backend client tests.
final class TestHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "test-http")
    private let lock = NSLock()
    private var _requests: [Request] = []
    var handler: @Sendable (Request) -> Response

    var requests: [Request] { lock.locked { _requests } }
    private(set) var port: UInt16 = 0

    init(handler: @escaping @Sendable (Request) -> Response) throws {
        self.handler = handler
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    var baseURL: String { "http://127.0.0.1:\(port)" }

    func stop() { listener.cancel() }

    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        var buffer = Data()
        func readMore() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
                guard let self else { return }
                if let data { buffer.append(data) }
                if let req = Self.parse(buffer) {
                    self.lock.locked { self._requests.append(req) }
                    let res = self.handler(req)
                    var head = "HTTP/1.1 \(res.status) X\r\nContent-Length: \(res.body.count)\r\nConnection: close\r\n"
                    for (k, v) in res.headers { head += "\(k): \(v)\r\n" }
                    head += "\r\n"
                    conn.send(content: Data(head.utf8) + res.body, completion: .contentProcessed { _ in conn.cancel() })
                    return
                }
                if done || error != nil {
                    conn.cancel()
                    return
                }
                readMore()
            }
        }
        readMore()
    }

    static func parse(_ data: Data) -> Request? {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<range.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().components(separatedBy: " ")
        var headers: [String: String] = [:]
        for l in lines {
            if let c = l.firstIndex(of: ":") {
                headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[range.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: first[0], path: first.count > 1 ? first[1] : "/", headers: headers, body: Data(body.prefix(length)))
    }
}

/// Backend transport double.
final class FakeTransport: BugCapsuleTransport, @unchecked Sendable {
    private let lock = NSLock()
    var configResults: [ConfigFetchResult] = [.fetched(RemoteCaptureConfig(fetchedAtMs: epochMs()))]
    var uploadResults: [UploadResult] = []
    private(set) var uploads: [Data] = []
    private(set) var configFetches = 0

    func fetchConfig() async -> ConfigFetchResult {
        lock.locked {
            configFetches += 1
            if configResults.count > 1 { return configResults.removeFirst() }
            if case .fetched(var c) = configResults.first! {
                c.fetchedAtMs = epochMs()
                return .fetched(c)
            }
            return configResults.first!
        }
    }

    func upload(_ bytes: Data) async -> UploadResult {
        lock.locked {
            uploads.append(bytes)
            return uploadResults.isEmpty ? UploadResult(.uploaded, serverId: "srv") : uploadResults.removeFirst()
        }
    }

    var uploadCount: Int { lock.locked { uploads.count } }
    var lastUpload: Data? { lock.locked { uploads.last } }
}

struct MemoryConfigCache: RemoteConfigCache {
    final class Box: @unchecked Sendable {
        var items: [String: RemoteCaptureConfig] = [:]
        let lock = NSLock()
    }
    let box = Box()
    func read(scope: String) -> RemoteCaptureConfig? { box.lock.locked { box.items[scope] } }
    func write(scope: String, config: RemoteCaptureConfig) throws { box.lock.locked { box.items[scope] = config } }
}

/// Mutable clock for outbox / remote config tests.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    init(_ t: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.t = t }
    var now: Date { lock.locked { t } }
    func advance(_ s: TimeInterval) { lock.locked { t = t.addingTimeInterval(s) } }
}

/// In-process fake server below the SDK's protocol (as the demo app's).
final class FakeServerProtocol: URLProtocol, @unchecked Sendable {
    struct Route: Sendable {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var chunks: [Data] = [Data(#"{"ok":true}"#.utf8)]
        var delay: TimeInterval = 0.01
        var error: URLError?
        /// Never finishes (for cancellation tests).
        var hang = false
    }

    nonisolated(unsafe) static var routes: [String: Route] = [:]
    nonisolated(unsafe) static var hits: [String] = []
    nonisolated(unsafe) static var bodies: [Data?] = []
    nonisolated(unsafe) static var headers: [[String: String]] = []
    static let lock = NSLock()

    static func reset() {
        lock.locked {
            routes = [:]
            hits = []
            bodies = []
            headers = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "shop.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var cancelled = false

    override func startLoading() {
        let path = request.url?.path ?? "/"
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var d = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                d.append(buf, count: n)
            }
            stream.close()
            body = d
        }
        let route = Self.lock.locked { () -> Route in
            Self.hits.append(path)
            Self.bodies.append(body)
            Self.headers.append(request.allHTTPHeaderFields ?? [:])
            return Self.routes[path] ?? Route(status: 404, chunks: [Data("{}".utf8)])
        }
        let client = self.client
        let thread = Thread.current
        _ = thread
        DispatchQueue.global().asyncAfter(deadline: .now() + route.delay) { [self] in
            if self.cancelled { return }
            if let e = route.error {
                client?.urlProtocol(self, didFailWithError: e)
                return
            }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: route.status, httpVersion: "HTTP/1.1", headerFields: route.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for c in route.chunks { client?.urlProtocol(self, didLoad: c) }
            if !route.hang { client?.urlProtocolDidFinishLoading(self) }
        }
    }

    override func stopLoading() { cancelled = true }
}
