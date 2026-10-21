import Foundation

/// Routes downstream URLSession callbacks to the protocol instance that
/// started each task.
final class DownstreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = DownstreamDelegate()
    let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "com.bugcapsule.downstream"
        return q
    }()
    private let lock = NSLock()
    private var handlers: [Int: BugCapsuleURLProtocol] = [:]

    func register(_ task: URLSessionTask, _ handler: BugCapsuleURLProtocol) {
        lock.locked { handlers[task.taskIdentifier] = handler }
    }

    private func handler(_ task: URLSessionTask) -> BugCapsuleURLProtocol? { lock.locked { handlers[task.taskIdentifier] } }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        handler(dataTask)?.downstreamResponse(response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handler(dataTask)?.downstreamData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let h = lock.locked { handlers.removeValue(forKey: task.taskIdentifier) }
        h?.downstreamComplete(error)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// The SDK's URL protocol: records exchanges while capturing and serves
/// fixtures while replaying. Inserted by `BugCapsule.instrument(_:)`.
public final class BugCapsuleURLProtocol: URLProtocol, @unchecked Sendable {
    static let handledKey = "com.bugcapsule.handled"

    /// Marks SDK-internal requests (backend, replay channel) and downstream
    /// requests so this protocol never intercepts them.
    static func markInternal(_ request: inout URLRequest) {
        let m = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: handledKey, in: m)
        request = m as URLRequest
    }

    public override class func canInit(with request: URLRequest) -> Bool {
        if URLProtocol.property(forKey: handledKey, in: request) != nil { return false }
        guard let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard BugCapsuleURLSession.active != nil, let s = BugCapsuleSession.current else { return false }
        // Monitoring alone (session not recording) still wants spans,
        // trace headers and http breadcrumbs.
        return s.isReplaying || s.isRecording || (s.monitoring?.isActive ?? false)
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private let lock = NSLock()
    private var clientThread: Thread?
    private var runLoopModes: [String] = [RunLoop.Mode.default.rawValue]
    private var stopped = false
    private var innerTask: URLSessionDataTask?

    // capture state
    private var capturing = false
    private var started: TimeInterval = 0
    private var base: JSONObject = JSONObject()
    private var excluded = false
    private var captureBodies = true
    private var responseHead: JSONObject?
    private var response: HTTPURLResponse?
    private var retained: Data? = Data()
    private var limit = 0
    private var recorded = false
    private var finishedDownstream = false
    private var waitTimer: DispatchSourceTimer?
    private var contentType: String?
    private var endWork: (@Sendable () -> Void)?

    // monitoring state
    private var httpSpan: BugCapsuleSpan?
    private var monitorOnly = false
    private var statusCode: Int?

    // MARK: thread hop

    private final class Trampoline: NSObject {
        let block: () -> Void
        init(_ block: @escaping () -> Void) { self.block = block }
        @objc func run() { block() }
    }

    /// URLProtocol client callbacks must happen on the thread that called `startLoading`.
    private func onClient(_ block: @escaping () -> Void) {
        let (thread, modes) = lock.locked { (clientThread, runLoopModes) }
        guard let thread else {
            block()
            return
        }
        let t = Trampoline(block)
        t.perform(#selector(Trampoline.run), on: thread, with: nil, waitUntilDone: false, modes: modes)
    }

    private var isStopped: Bool { lock.locked { stopped } }

    // MARK: loading

    public override func startLoading() {
        lock.locked {
            clientThread = Thread.current
            if let mode = RunLoop.current.currentMode, mode != .default {
                runLoopModes.append(mode.rawValue)
            }
        }
        guard let session = BugCapsuleSession.current, let net = BugCapsuleURLSession.active else {
            forwardDownstream(request, body: nil, record: false)
            return
        }
        if let replay = session.replay {
            startReplay(session: session, net: net, replay: replay)
        } else if session.isRecording {
            startCapture(session: session, net: net)
        } else if let monitoring = session.monitoring {
            startMonitoring(session: session, monitoring: monitoring)
        } else {
            forwardDownstream(request, body: nil, record: false)
        }
    }

    /// `http.client` span and propagation headers. The headers go on the
    /// forwarded copy only: recorded request headers and request keys are
    /// computed from the app's request.
    private func startTracing(_ session: BugCapsuleSession, redactor: Redactor) -> URLRequest {
        guard let tracer = session.monitoring?.tracer else { return request }
        let http = tracer.startHTTP(request, redactor: redactor)
        lock.locked { httpSpan = http.span }
        var out = request
        for (k, v) in http.headers { out.setValue(v, forHTTPHeaderField: k) }
        return out
    }

    /// Not recording: forward with tracing, leave an http breadcrumb.
    private func startMonitoring(session: BugCapsuleSession, monitoring: Monitoring) {
        let redactor = session.redactor
        let (body, oneShot) = requestBody()
        lock.locked {
            started = uptime()
            monitorOnly = true
            base = [
                "method": .string((request.httpMethod ?? "GET").uppercased()),
                "url": .string(redactor.redactURL(request.url?.absoluteString ?? "")),
            ]
        }
        forwardDownstream(startTracing(session, redactor: redactor), body: oneShot ? nil : body, record: false)
    }

    private func finishMonitoring(error: Error?) {
        let (span, only, status, data) = lock.locked { () -> (BugCapsuleSpan?, Bool, Int?, JSONObject) in
            let s = httpSpan
            httpSpan = nil
            let only = monitorOnly
            monitorOnly = false
            return (s, only, statusCode, base)
        }
        Tracer.finishHTTP(span, status: status, error: error)
        guard only, let session = BugCapsuleSession.current else { return }
        var d = data
        d["status"] = .int(status ?? 0)
        d["durationMs"] = .int(elapsedMs)
        if let error {
            d["error"] = .object(Self.errorJSON(error, afterResponse: status != nil, redactor: session.redactor))
        }
        session.record(EventTypes.http, d)
    }

    public override func stopLoading() {
        let (task, wasCapturing, timer, end) = lock.locked { () -> (URLSessionDataTask?, Bool, DispatchSourceTimer?, (@Sendable () -> Void)?) in
            stopped = true
            let e = endWork
            endWork = nil
            return (innerTask, capturing && !finishedDownstream, waitTimer, e)
        }
        timer?.cancel()
        end?()
        if lock.locked({ !finishedDownstream }) {
            finishMonitoring(error: URLError(.cancelled))
        }
        if wasCapturing {
            // The app cancelled while the exchange was in flight.
            if lock.locked({ responseHead != nil }) {
                finishRecording(["bodyEncoding": "truncated", "error": ["type": "cancel", "message": "response stream cancelled"]])
            } else {
                recordError(["type": "cancel", "message": "request cancelled"], status: 0)
            }
        }
        task?.cancel()
    }

    /// The body as the app gave it: `httpBody` (also looked up on the task's
    /// original request, as URLSession turns bodies into streams for
    /// protocols), or a one-shot `httpBodyStream`.
    private func requestBody() -> (data: Data?, oneShot: Bool) {
        if let b = request.httpBody { return (b, false) }
        if let b = task?.originalRequest?.httpBody { return (b, false) }
        if request.httpBodyStream != nil { return (nil, true) }
        return (nil, false)
    }

    private func forwardDownstream(_ original: URLRequest, body: Data?, record: Bool) {
        var inner = original
        if let body, inner.httpBody == nil, inner.httpBodyStream == nil { inner.httpBody = body }
        BugCapsuleURLProtocol.markInternal(&inner)
        let task = BugCapsuleURLSession.downstream().dataTask(with: inner)
        lock.locked {
            capturing = record
            innerTask = task
        }
        DownstreamDelegate.shared.register(task, self)
        task.resume()
    }

    // MARK: capture

    private func startCapture(session: BugCapsuleSession, net: BugCapsuleURLSession) {
        let redactor = session.redactor
        let started = uptime()
        let excluded = net.exclude?(request) ?? false
        let captureBodies = session.captureNetworkBodies && !excluded
        let (body, oneShot) = requestBody()
        let requestType = request.value(forHTTPHeaderField: "Content-Type")
        let key = net.key(for: request, body: oneShot ? nil : body, redactor: redactor)
        let (occurrence, id) = net.nextOccurrence(key)

        var requestBody: JSONValue = .null
        var requestEncoding = "json"
        if oneShot {
            requestEncoding = "omitted"
        } else if let body, !body.isEmpty {
            if !captureBodies || BugCapsuleURLSession.isMultipart(requestType) {
                requestEncoding = "omitted"
            } else if body.count > session.maxBodyBytes {
                requestEncoding = "truncated"
            } else {
                (requestBody, requestEncoding) = net.decode(body, contentType: requestType, redactor: redactor)
            }
        }
        var base: JSONObject = [
            "id": .int(id), "key": .string(key), "occurrence": .int(occurrence),
            "method": .string((request.httpMethod ?? "GET").uppercased()),
            "url": .string(redactor.redactURL(request.url?.absoluteString ?? "")),
        ]
        if !excluded {
            base["requestHeaders"] = .object(
                redactor.redactHeaders((request.allHTTPHeaderFields ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))
        }
        base["requestBody"] = requestBody
        base["requestEncoding"] = .string(requestEncoding)
        if excluded { base["excluded"] = true }
        lock.locked {
            self.started = started
            self.base = base
            self.excluded = excluded
            self.captureBodies = captureBodies
        }
        net.began(self)
        forwardDownstream(startTracing(session, redactor: redactor), body: oneShot ? nil : body, record: true)
    }

    private var elapsedMs: Int { Int(((uptime() - lock.locked { started }) * 1000).rounded(.down)) }

    private func record(_ extra: JSONObject) {
        let data: JSONObject? = lock.locked {
            if recorded { return nil }
            recorded = true
            var d = responseHead ?? base
            for (k, v) in extra { d[k] = v }
            retained = nil
            return d
        }
        lock.locked { waitTimer?.cancel() }
        BugCapsuleURLSession.active?.ended(self)
        guard var data else { return }
        if data["durationMs"] == nil { data["durationMs"] = .int(elapsedMs) }
        BugCapsuleSession.current?.record(EventTypes.http, data)
    }

    /// The exchange as far as it got, for a capsule written while it is in flight.
    func pendingSnapshot() -> JSONObject? {
        lock.locked {
            guard capturing, !recorded, !stopped else { return nil }
            var d = responseHead ?? base
            if d["status"] == nil { d["status"] = 0 }
            d["bodyEncoding"] = "omitted"
            d["pending"] = true
            d["error"] = ["type": "pending", "message": "still in flight when the capsule was written"]
            d["durationMs"] = .int(Int(((uptime() - started) * 1000).rounded(.down)))
            return d
        }
    }

    private func recordError(_ error: JSONObject, status: Int) {
        var extra: JSONObject = ["status": .int(status), "bodyEncoding": "omitted", "error": .object(error)]
        extra["durationMs"] = .int(elapsedMs)
        record(extra)
    }

    private func finishRecording(_ extra: JSONObject) {
        var e = extra
        e["durationMs"] = .int(elapsedMs)
        record(e)
    }

    static func errorJSON(_ error: Error, afterResponse: Bool, redactor: Redactor?) -> JSONObject {
        let ns = error as NSError
        let type: String
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut: type = afterResponse ? "receiveTimeout" : "connectionTimeout"
            case NSURLErrorCancelled: type = "cancel"
            default: type = "connectionError"
            }
        } else {
            type = "connectionError"
        }
        let message = ns.localizedDescription
        return [
            "type": .string(type), "message": .string(redactor?.scrubText(message) ?? message),
            "domain": .string(ns.domain), "code": .int(ns.code),
        ]
    }

    func downstreamResponse(_ response: URLResponse) {
        if isStopped { return }
        if let http = response as? HTTPURLResponse { lock.locked { statusCode = http.statusCode } }
        let capturing = lock.locked { self.capturing }
        if capturing, let http = response as? HTTPURLResponse {
            let session = BugCapsuleSession.current
            let net = BugCapsuleURLSession.active
            let redactor = session?.redactor ?? Redactor()
            let contentType = http.value(forHTTPHeaderField: "Content-Type")
            var head = lock.locked { base }
            head["status"] = .int(http.statusCode)
            head["statusMessage"] = .string(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
            let excluded = lock.locked { self.excluded }
            if !excluded {
                let headers = http.allHeaderFields.compactMap { k, v -> (String, String)? in
                    guard let k = k as? String else { return nil }
                    return (k, "\(v)")
                }.sorted { $0.0.lowercased() < $1.0.lowercased() }
                head["responseHeaders"] = .object(redactor.redactHeaders(headers))
            }
            let sse = (contentType ?? "").lowercased().contains("event-stream")
            let bodies = lock.locked { captureBodies }
            lock.locked {
                responseHead = head
                self.response = http
                self.contentType = contentType
            }
            if sse || !bodies {
                finishRecording(["bodyEncoding": "omitted"])
            } else {
                let type = (contentType ?? "").lowercased()
                let limit = BugCapsuleURLSession.isText(type) ? (session?.maxBodyBytes ?? 256 * 1024) : (net?.maxBinaryBytes ?? 64 * 1024)
                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + (net?.maxBodyWait ?? 30))
                timer.setEventHandler { [weak self] in self?.finishRecording(["bodyEncoding": "truncated"]) }
                lock.locked {
                    self.limit = limit
                    waitTimer = timer
                }
                timer.resume()
            }
        }
        onClient { [weak self] in
            guard let self, !self.isStopped else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
    }

    func downstreamData(_ data: Data) {
        if isStopped { return }
        let overflow: Bool = lock.locked {
            guard capturing, !recorded, var r = retained else { return false }
            if r.count + data.count <= limit {
                r.append(data)
                retained = r
                return false
            }
            retained = nil
            return true
        }
        if overflow { finishRecording(["bodyEncoding": "truncated"]) }
        onClient { [weak self] in
            guard let self, !self.isStopped else { return }
            self.client?.urlProtocol(self, didLoad: data)
        }
    }

    func downstreamComplete(_ error: Error?) {
        let (capturing, hadResponse, stopped) = lock.locked { () -> (Bool, Bool, Bool) in
            let s = self.stopped
            finishedDownstream = true
            return (self.capturing, responseHead != nil, s)
        }
        if !stopped { finishMonitoring(error: error) }
        if stopped { return }
        if capturing {
            let redactor = BugCapsuleSession.current?.redactor
            if let error {
                let json = Self.errorJSON(error, afterResponse: hadResponse, redactor: redactor)
                if hadResponse {
                    finishRecording(["bodyEncoding": "truncated", "error": .object(json)])
                } else {
                    recordError(json, status: 0)
                }
            } else if hadResponse {
                let (bytes, type) = lock.locked { (retained, contentType) }
                if let bytes, let net = BugCapsuleURLSession.active, let redactor {
                    let (body, encoding) = net.decode(bytes, contentType: type, redactor: redactor)
                    finishRecording(["responseBody": body, "bodyEncoding": .string(encoding)])
                } else {
                    finishRecording(["bodyEncoding": "truncated"])
                }
            }
        }
        let end = lock.locked { () -> (@Sendable () -> Void)? in
            let e = endWork
            endWork = nil
            return e
        }
        end?()
        onClient { [weak self] in
            guard let self, !self.isStopped else { return }
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
            } else {
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    // MARK: replay

    private func startReplay(session: BugCapsuleSession, net: BugCapsuleURLSession, replay: ReplayContext) {
        let (body, oneShot) = requestBody()
        let key = net.key(for: request, body: oneShot ? nil : body, redactor: session.redactor)
        guard let lookup = replay.fixtures.take(key) else {
            replay.diverge("network.unrecorded", key)
            if !replay.settings.strictNetwork {
                lock.locked { endWork = replay.beginWork() }
                forwardDownstream(request, body: oneShot ? nil : body, record: false)
                return
            }
            let error = URLError(
                .cannotConnectToHost,
                userInfo: [NSLocalizedDescriptionKey: "BugCapsule replay: no recorded response for \(key)"])
            onClient { [weak self] in
                guard let self, !self.isStopped else { return }
                self.client?.urlProtocol(self, didFailWithError: error)
            }
            return
        }
        if lookup.reused { replay.diverge("network.reused", key) }
        let fixture = lookup.fixture
        replay.fixtureServed()
        if fixture.isPending {
            // In flight when the capsule was written: the app never got a
            // response, so replay keeps the request open (until cancelled).
            return
        }
        // Keep the recorded latency so response ordering (and races) replay.
        let end = replay.beginWork()
        lock.locked { endWork = end }
        let delay = Double(fixture.durationMs) / 1000
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let e = self.lock.locked { () -> (@Sendable () -> Void)? in
                let e = self.endWork
                self.endWork = nil
                return e
            }
            guard let e else { return }  // stopped (cancelled) meanwhile
            e()
            self.serve(fixture, key: key, replay: replay)
        }
    }

    private func serve(_ fixture: HttpFixture, key: String, replay: ReplayContext) {
        if let error = fixture.error, fixture.status == 0 {
            let code: URLError.Code
            if let raw = error["code"]?.intValue, error["domain"]?.stringValue == NSURLErrorDomain {
                code = URLError.Code(rawValue: raw)
            } else {
                switch error["type"]?.stringValue {
                case "connectionTimeout", "receiveTimeout": code = .timedOut
                case "cancel": code = .cancelled
                default: code = .cannotConnectToHost
                }
            }
            let err = URLError(code, userInfo: [NSLocalizedDescriptionKey: error["message"]?.stringValue ?? "recorded error"])
            onClient { [weak self] in
                guard let self, !self.isStopped else { return }
                self.client?.urlProtocol(self, didFailWithError: err)
            }
            return
        }
        if !fixture.hasBody && fixture.status != 204 { replay.diverge("network.noBody", key) }
        var headers: [String: String] = [:]
        for (k, v) in fixture.responseHeaders where !["content-length", "content-encoding", "transfer-encoding"].contains(k) {
            headers[k] = v
        }
        let body = BugCapsuleURLSession.encodeBody(fixture.responseBody, encoding: fixture.bodyEncoding)
        let url = request.url ?? URL(string: "http://localhost/")!
        let response = HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        onClient { [weak self] in
            guard let self, !self.isStopped else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { self.client?.urlProtocol(self, didLoad: body) }
            self.client?.urlProtocolDidFinishLoading(self)
            replay.activity()
        }
    }
}
