import Foundation

/// WebSocket capture and replay for `URLSessionWebSocketTask` (capsule-v2
/// §4.1, adapter `bugcapsule-ios.urlsession-websocket`, schema 1).
///
/// `URLSessionWebSocketTask` cannot be subclassed or intercepted by a
/// `URLProtocol`, so the app opens sockets through `BugCapsuleWebSocket`,
/// a wrapper with the same calls, and installs this integration:
///
/// ```swift
/// BugCapsule.start(config, integrations: [BugCapsuleURLSession(), BugCapsuleWebSockets()])
///
/// let socket = BugCapsuleWebSocket(session: .shared, url: URL(string: "wss://quotes.example.com/v1/stream")!)
/// socket.delegate = self                      // open / close callbacks
/// socket.resume()
/// try await socket.send(.string(#"{"op":"subscribe"}"#))
/// let message = try await socket.receive()
/// socket.cancel(with: .normalClosure, reason: nil)
/// ```
///
/// Capture records connect, open, send, message, error and close with a
/// connection id, the redacted URL as match key, the occurrence of that
/// key and the reconnect attempt. Text frames are payloads of kind `text`;
/// binary frames are metadata only (size) unless `captureBinary` is set.
/// Payloads follow the SDK redaction and the capsule-v2 bounds (64 KiB per
/// payload, 1 MiB rolling budget, 32 captured connections at a time).
///
/// Replay never opens a socket: connects are matched by key and
/// occurrence, sends are compared with the recording in order, and
/// `receive()` returns the recorded messages at their recorded offsets on
/// the replay clock. A connect, send or close that was not recorded fails
/// with `BugCapsuleReplayError` and reports `ws.unrecorded`.
public final class BugCapsuleWebSockets: BugCapsuleIntegration, @unchecked Sendable {
    public static let adapterId = "bugcapsule-ios.urlsession-websocket"
    public static let schema = 1

    public let name = "websocket"
    public var capabilities: [(String, String)] { [("interaction.websocket", "supported")] }

    /// The `manifest.dependencies` entry this integration records.
    public let descriptor: BugCapsuleAdapterDescriptor
    /// Query parameters left out of connect match keys (values that change
    /// per connection).
    public let ignoreQuery: Set<String>

    private let lock = NSLock()
    private weak var _session: BugCapsuleSession?
    private var failuresSinceOpen: [String: Int] = [:]

    private static let activeLock = NSLock()
    nonisolated(unsafe) private static weak var _active: BugCapsuleWebSockets?
    static var active: BugCapsuleWebSockets? { activeLock.locked { _active } }

    /// - Parameters:
    ///   - dependencyId: `data.dep` of the recorded events.
    ///   - captureBinary: keep binary frames (base64) instead of their size.
    ///     Only enable it when frames carry no personal data.
    public init(
        dependencyId: String = "ws", captureBinary: Bool = false,
        ignoreQuery: Set<String> = RequestKeyBuilder.defaultIgnoreQuery
    ) {
        descriptor = BugCapsuleAdapterDescriptor(
            dependencyId: dependencyId, kind: DependencyKinds.websocket, adapter: Self.adapterId,
            adapterVersion: sdkVersion, schema: Self.schema, operations: ["connect", "send", "receive", "close"],
            tested: [BugCapsuleTestedPackage("Foundation.URLSessionWebSocketTask", "iOS 15+/macOS 12+")],
            captureBinary: captureBinary)
        self.ignoreQuery = ignoreQuery
    }

    public func setUp(_ session: BugCapsuleSession) {
        lock.locked { _session = session }
        session.interactions.install(descriptor)
        Self.activeLock.locked { Self._active = self }
    }

    var session: BugCapsuleSession? { lock.locked { _session } }

    /// The match URL (capsule-v2 §4.1 `key` input): the redacted URL with
    /// sorted query parameters, minus the ignored ones and the fragment.
    func matchURL(_ url: URL, redactor: Redactor) -> (redacted: String, key: String) {
        let uri = redactor.redactURI(DartURI.parse(url.absoluteString))
        var plain = uri
        plain.fragment = nil
        var query: [String] = []
        for (name, values) in ((try? uri.queryParametersAll()) ?? []).sorted(by: { utf16Less($0.name, $1.name) }) {
            if ignoreQuery.contains(name) { continue }
            for v in values {
                let ek = DartURI.encodeQueryComponent(name)
                query.append(v.isEmpty ? ek : ek + "=" + DartURI.encodeQueryComponent(v))
            }
        }
        plain.query = query.isEmpty ? nil : query.joined(separator: "&")
        return (uri.string, interactionKey(plain.string, nil, .null))
    }

    func attempt(_ key: String) -> Int { lock.locked { failuresSinceOpen[key] ?? 0 } }
    func noteOpened(_ key: String) { lock.locked { failuresSinceOpen[key] = 0 } }
    func noteFailed(_ key: String) { lock.locked { failuresSinceOpen[key, default: 0] += 1 } }
}

/// Open and close callbacks of a `BugCapsuleWebSocket` (the
/// `URLSessionWebSocketDelegate` methods of the task). All optional.
public protocol BugCapsuleWebSocketDelegate: AnyObject {
    func webSocket(_ socket: BugCapsuleWebSocket, didOpenWithProtocol protocol: String?)
    func webSocket(
        _ socket: BugCapsuleWebSocket, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    /// The task finished; [error] is nil after a clean close.
    func webSocket(_ socket: BugCapsuleWebSocket, didCompleteWithError error: Error?)
}

extension BugCapsuleWebSocketDelegate {
    public func webSocket(_ socket: BugCapsuleWebSocket, didOpenWithProtocol protocol: String?) {}
    public func webSocket(
        _ socket: BugCapsuleWebSocket, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {}
    public func webSocket(_ socket: BugCapsuleWebSocket, didCompleteWithError error: Error?) {}
}

/// Why replay failed an interaction instead of reaching the dependency.
public struct BugCapsuleReplayError: Error, LocalizedError, CustomStringConvertible, Sendable {
    /// `bugcapsule.unrecorded`, `bugcapsule.noPayload`, ...
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
    public var description: String { "\(code): \(message)" }
}

/// A WebSocket the SDK can record and replay: the calls of
/// `URLSessionWebSocketTask` (see `BugCapsuleWebSockets`). Thread-safe.
///
/// Live (capture, or no BugCapsule session): a real task on [session];
/// its open and close delegate callbacks reach `delegate`, the closures
/// and the session's own delegate. Replay: an in-memory connection served
/// from the capsule; nothing reaches the network.
public final class BugCapsuleWebSocket: @unchecked Sendable {
    public let url: URL
    public let protocols: [String]
    public weak var delegate: BugCapsuleWebSocketDelegate?
    /// Called when the handshake completed (protocol chosen by the server).
    public var onOpen: (@Sendable (String?) -> Void)?
    /// Called when the server's close frame arrived.
    public var onClose: (@Sendable (URLSessionWebSocketTask.CloseCode, Data?) -> Void)?

    private let lock = NSLock()
    private let urlSession: URLSession
    private let integration: BugCapsuleWebSockets?
    private let makeLive: (BugCapsuleWebSocket) -> WebSocketTransport
    private var transport: WebSocketTransport?
    private var capture: WebSocketCapture?
    private var pendingMaxMessageSize: Int?

    /// - Parameters:
    ///   - session: the session a live task is created on (its delegate
    ///     queue runs completion handlers and callbacks, live and replayed).
    ///   - url: `ws://` or `wss://` URL.
    ///   - protocols: subprotocols offered to the server.
    public convenience init(session: URLSession = .shared, url: URL, protocols: [String] = []) {
        self.init(session: session, url: url, protocols: protocols, integration: BugCapsuleWebSockets.active) { socket in
            URLSessionWebSocketTransport(session: session, url: url, protocols: protocols, events: socket)
        }
    }

    init(
        session: URLSession, url: URL, protocols: [String], integration: BugCapsuleWebSockets?,
        live: @escaping (BugCapsuleWebSocket) -> WebSocketTransport
    ) {
        urlSession = session
        self.url = url
        self.protocols = protocols
        self.integration = integration
        makeLive = live
    }

    /// The live task (nil in replay and before `resume`).
    public var task: URLSessionWebSocketTask? { lock.locked { transport }?.task }

    /// True when this socket is served from a capsule.
    public var isReplaying: Bool { lock.locked { transport } is ReplayWebSocketTransport }

    public var closeCode: URLSessionWebSocketTask.CloseCode { current().closeCode }
    public var closeReason: Data? { current().closeReason }

    public var maximumMessageSize: Int {
        get { lock.locked { transport?.maximumMessageSize ?? pendingMaxMessageSize ?? 1_048_576 } }
        set {
            let t: WebSocketTransport? = lock.locked {
                pendingMaxMessageSize = newValue
                return transport
            }
            t?.maximumMessageSize = newValue
        }
    }

    /// Creates the transport on first use: replay when the session replays
    /// a capsule, otherwise the live task (recorded while capturing).
    private func current() -> WebSocketTransport {
        if let t = lock.locked({ transport }) { return t }
        let made: WebSocketTransport
        var capture: WebSocketCapture?
        let owner = integration?.session ?? BugCapsuleSession.current
        if let owner, owner.isReplaying {
            // Replay never reaches the network, adapter installed or not.
            if let integration, let replay = owner.interactions.replay {
                made = ReplayWebSocketTransport(
                    socket: self, integration: integration, replay: replay, capsule: owner.replay?.capsule,
                    redactor: owner.redactor, queue: urlSession.delegateQueue)
            } else {
                made = BlockedWebSocketTransport(socket: self, replay: owner.replay, queue: urlSession.delegateQueue)
            }
        } else {
            made = makeLive(self)
            if let integration, let session = integration.session,
                session.interactions.captures(BugCapsuleWebSockets.adapterId)
            {
                let rec = session.interactions.recorder(integration.descriptor)
                if session.interactions.acquireActive() {
                    capture = WebSocketCapture(
                        integration: integration, runtime: session.interactions, rec: rec, url: url, protocols: protocols)
                } else {
                    rec.gap(
                        DependencyGaps.connectionsLimit,
                        "more than \(session.interactions.limits.maxActive) captured connections at once")
                }
            }
        }
        return lock.locked {
            if let t = transport { return t }
            transport = made
            self.capture = capture
            if let size = pendingMaxMessageSize { made.maximumMessageSize = size }
            return made
        }
    }

    private var recorder: WebSocketCapture? { lock.locked { capture } }

    // MARK: calls

    public func resume() {
        let t = current()
        recorder?.connect()
        t.resume()
    }

    public func send(
        _ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        let t = current()
        let index = recorder?.send(message)
        t.send(message) { [weak self] error in
            if let error, let index { self?.recorder?.sendFailed(index, error) }
            completionHandler(error)
        }
    }

    public func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            send(message) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    public func receive(
        completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void
    ) {
        current().receive { [weak self] result in
            switch result {
            case .success(let m): self?.recorder?.message(m)
            case .failure(let e): self?.recorder?.failed(e)
            }
            completionHandler(result)
        }
    }

    public func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { cont in
            receive { cont.resume(with: $0) }
        }
    }

    /// Sends a close frame and closes the connection (`cancel(with:reason:)`).
    public func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let t = current()
        recorder?.clientClose(closeCode, reason)
        t.cancel(code: closeCode, reason: reason)
    }

    /// Aborts the connection without a close frame (`URLSessionTask.cancel()`).
    public func cancel() {
        let t = current()
        recorder?.clientClose(nil, nil)
        t.abort()
    }

    /// Pings the server. Not recorded; in replay it succeeds at once while
    /// the connection is open.
    public func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {
        current().sendPing(pongReceiveHandler)
    }

    // MARK: transport events

    func transportDidOpen(_ proto: String?) {
        recorder?.opened(proto)
        delegate?.webSocket(self, didOpenWithProtocol: proto)
        onOpen?(proto)
    }

    func transportDidClose(_ code: URLSessionWebSocketTask.CloseCode, _ reason: Data?) {
        recorder?.serverClose(code, reason)
        delegate?.webSocket(self, didCloseWith: code, reason: reason)
        onClose?(code, reason)
    }

    func transportDidComplete(_ error: Error?) {
        recorder?.completed(error, closeCode: lock.locked { transport }?.closeCode ?? .invalid)
        delegate?.webSocket(self, didCompleteWithError: error)
    }
}

// MARK: - transports

/// What `BugCapsuleWebSocket` drives: the live task or the replay.
protocol WebSocketTransport: AnyObject, Sendable {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping @Sendable (Error?) -> Void)
    func receive(completion: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    func cancel(code: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func abort()
    func sendPing(_ handler: @escaping @Sendable (Error?) -> Void)
    var closeCode: URLSessionWebSocketTask.CloseCode { get }
    var closeReason: Data? { get }
    var maximumMessageSize: Int { get set }
    var task: URLSessionWebSocketTask? { get }
}

extension WebSocketTransport {
    var task: URLSessionWebSocketTask? { nil }
}

/// The real `URLSessionWebSocketTask`, with a task delegate that reports
/// open, close and completion (and forwards them to the session delegate).
/// Like the task, it keeps the socket alive until the task completes, so
/// callbacks are recorded even when the app dropped its reference.
final class URLSessionWebSocketTransport: NSObject, WebSocketTransport, URLSessionWebSocketDelegate, @unchecked Sendable {
    let webSocketTask: URLSessionWebSocketTask
    private let lock = NSLock()
    private var _events: BugCapsuleWebSocket?
    private weak var sessionDelegate: URLSessionDelegate?
    private var events: BugCapsuleWebSocket? { lock.locked { _events } }

    init(session: URLSession, url: URL, protocols: [String], events: BugCapsuleWebSocket) {
        webSocketTask = session.webSocketTask(with: url, protocols: protocols)
        _events = events
        sessionDelegate = session.delegate
        super.init()
        webSocketTask.delegate = self
    }

    var task: URLSessionWebSocketTask? { webSocketTask }

    func resume() { webSocketTask.resume() }

    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping @Sendable (Error?) -> Void) {
        webSocketTask.send(message, completionHandler: completion)
    }

    func receive(completion: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        webSocketTask.receive(completionHandler: completion)
    }

    func cancel(code: URLSessionWebSocketTask.CloseCode, reason: Data?) { webSocketTask.cancel(with: code, reason: reason) }
    func abort() { webSocketTask.cancel() }
    func sendPing(_ handler: @escaping @Sendable (Error?) -> Void) { webSocketTask.sendPing(pongReceiveHandler: handler) }
    var closeCode: URLSessionWebSocketTask.CloseCode { webSocketTask.closeCode }
    var closeReason: Data? { webSocketTask.closeReason }
    var maximumMessageSize: Int {
        get { webSocketTask.maximumMessageSize }
        set { webSocketTask.maximumMessageSize = newValue }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        events?.transportDidOpen(`protocol`)
        (sessionDelegate as? URLSessionWebSocketDelegate)?.urlSession?(
            session, webSocketTask: webSocketTask, didOpenWithProtocol: `protocol`)
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        events?.transportDidClose(closeCode, reason)
        (sessionDelegate as? URLSessionWebSocketDelegate)?.urlSession?(
            session, webSocketTask: webSocketTask, didCloseWith: closeCode, reason: reason)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let events: BugCapsuleWebSocket? = lock.locked {
            defer { _events = nil }
            return _events
        }
        events?.transportDidComplete(error)
        (sessionDelegate as? URLSessionTaskDelegate)?.urlSession?(session, task: task, didCompleteWithError: error)
    }
}

// MARK: - capture

/// Records one live connection.
final class WebSocketCapture: @unchecked Sendable {
    private let integration: BugCapsuleWebSockets
    private let runtime: InteractionRuntime
    private let rec: DependencyRecorder
    private let lock = NSLock()
    let conn: String
    private let redactedURL: String
    private let key: String
    private let protocols: [String]
    private var sendIndex = 0
    private var messageIndex = 0
    private var connected = false
    private var isOpen = false
    private var errorRecorded = false
    private var clientClosed = false
    private var closeRecorded = false
    private var finished = false

    init(
        integration: BugCapsuleWebSockets, runtime: InteractionRuntime, rec: DependencyRecorder, url: URL,
        protocols: [String]
    ) {
        self.integration = integration
        self.runtime = runtime
        self.rec = rec
        self.protocols = protocols
        conn = rec.newId("ws")
        (redactedURL, key) = integration.matchURL(url, redactor: runtime.redactor())
    }

    /// Still recording (the session may have stopped, or the adapter was
    /// switched off remotely).
    private var live: Bool { runtime.captures(BugCapsuleWebSockets.adapterId) }

    func connect() {
        let first: Bool = lock.locked {
            if connected { return false }
            connected = true
            return true
        }
        guard first, live else { return }
        var d: JSONObject = [
            "conn": .string(conn), "url": .string(redactedURL), "key": .string(key),
            "occurrence": .int(rec.occurrences.next(key)), "attempt": .int(integration.attempt(key)),
        ]
        if !protocols.isEmpty { d["protocols"] = .array(protocols.map { .string($0) }) }
        rec.emit(InteractionTypes.wsConnect, d)
        rec.opened(conn, type: "ws")
    }

    func opened(_ proto: String?) {
        lock.locked { isOpen = true }
        integration.noteOpened(key)
        guard live else { return }
        var d: JSONObject = ["conn": .string(conn)]
        if let proto, !proto.isEmpty { d["protocol"] = .string(proto) }
        rec.emit(InteractionTypes.wsOpen, d)
    }

    func send(_ message: URLSessionWebSocketTask.Message) -> Int {
        let index: Int = lock.locked {
            defer { sendIndex += 1 }
            return sendIndex
        }
        if live {
            rec.emit(
                InteractionTypes.wsSend,
                ["conn": .string(conn), "index": .int(index), "payload": payload(message).json])
        }
        return index
    }

    func sendFailed(_ index: Int, _ error: Error) {
        guard live else { return }
        rec.emit(
            InteractionTypes.wsError,
            ["conn": .string(conn), "phase": "send", "index": .int(index), "error": describe(error)])
    }

    func message(_ m: URLSessionWebSocketTask.Message) {
        let index: Int = lock.locked {
            defer { messageIndex += 1 }
            return messageIndex
        }
        guard live else { return }
        rec.emit(
            InteractionTypes.wsMessage, ["conn": .string(conn), "index": .int(index), "payload": payload(m).json])
    }

    /// A receive failed: the stream ended (or the connect failed).
    func failed(_ error: Error) {
        let phase: String? = lock.locked {
            if errorRecorded || clientClosed || closeRecorded { return nil }
            errorRecorded = true
            return isOpen ? "stream" : "connect"
        }
        guard let phase else { return }
        if phase == "connect" { integration.noteFailed(key) }
        guard live else { return }
        rec.emit(InteractionTypes.wsError, ["conn": .string(conn), "phase": .string(phase), "error": describe(error)])
    }

    func clientClose(_ code: URLSessionWebSocketTask.CloseCode?, _ reason: Data?) {
        let first: Bool = lock.locked {
            if clientClosed || closeRecorded { return false }
            clientClosed = true
            return true
        }
        guard first, live else { return }
        var d: JSONObject = ["conn": .string(conn), "initiator": "client"]
        if let code { d["code"] = .int(code.rawValue) }
        if let reason = reasonText(reason) { d["reason"] = .string(reason) }
        rec.emit(InteractionTypes.wsClose, d)
    }

    func serverClose(_ code: URLSessionWebSocketTask.CloseCode, _ reason: Data?) {
        let first: Bool = lock.locked {
            if closeRecorded { return false }
            closeRecorded = true
            return true
        }
        guard first else { return }
        if live {
            var d: JSONObject = ["conn": .string(conn), "initiator": "server", "code": .int(code.rawValue)]
            if let reason = reasonText(reason) { d["reason"] = .string(reason) }
            rec.emit(InteractionTypes.wsClose, d)
        }
        finish()
    }

    func completed(_ error: Error?, closeCode: URLSessionWebSocketTask.CloseCode) {
        if let error { failed(error) }
        let abnormal: Bool = lock.locked {
            if closeRecorded || !isOpen { return false }
            closeRecorded = true
            return true
        }
        if abnormal {
            integration.noteFailed(key)
            if live {
                let code = closeCode == .invalid ? 1006 : closeCode.rawValue
                rec.emit(InteractionTypes.wsClose, ["conn": .string(conn), "initiator": "unknown", "code": .int(code)])
            }
        }
        finish()
    }

    private func finish() {
        let first: Bool = lock.locked {
            if finished { return false }
            finished = true
            return true
        }
        guard first else { return }
        rec.closed(conn)
        runtime.releaseActive()
    }

    private func payload(_ m: URLSessionWebSocketTask.Message) -> InteractionPayload {
        switch m {
        case .string(let s): return rec.payload(s, kind: "text")
        case .data(let d): return rec.payload(d, kind: "binary")
        @unknown default: return InteractionPayload(mode: .omitted, replayable: false)
        }
    }

    private func describe(_ error: Error) -> JSONValue {
        let ns = error as NSError
        return ["type": .string(ns.domain), "code": .int(ns.code), "message": .string(runtime.redactor().scrubText(ns.localizedDescription))]
    }

    private func reasonText(_ reason: Data?) -> String? {
        guard let reason, !reason.isEmpty else { return nil }
        return runtime.redactor().scrubText(String(decoding: reason, as: UTF8.self)).dartPrefix(1000)
    }
}

// MARK: - replay

/// Replay without `BugCapsuleWebSockets` installed: every call fails and
/// the connect reports `ws.unrecorded` (the socket must not go live).
final class BlockedWebSocketTransport: WebSocketTransport, @unchecked Sendable {
    private weak var socket: BugCapsuleWebSocket?
    private let replay: ReplayContext?
    private let queue: OperationQueue
    private let error = BugCapsuleReplayError(
        code: "bugcapsule.unrecorded", message: "replay: BugCapsuleWebSockets is not installed, the socket stays closed")
    var maximumMessageSize = 1_048_576

    init(socket: BugCapsuleWebSocket, replay: ReplayContext?, queue: OperationQueue) {
        self.socket = socket
        self.replay = replay
        self.queue = queue
    }

    var closeCode: URLSessionWebSocketTask.CloseCode { .invalid }
    var closeReason: Data? { nil }

    func resume() {
        let url = Redactor().redactURL(socket?.url.absoluteString ?? "")
        replay?.diverge("ws.unrecorded", "connect \(url): BugCapsuleWebSockets is not installed")
        let error = self.error
        queue.addOperation { [weak self] in self?.socket?.transportDidComplete(error) }
    }

    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping @Sendable (Error?) -> Void) {
        let error = self.error
        queue.addOperation { completion(error) }
    }

    func receive(completion: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        let error = self.error
        queue.addOperation { completion(.failure(error)) }
    }

    func cancel(code: URLSessionWebSocketTask.CloseCode, reason: Data?) {}
    func abort() {}
    func sendPing(_ handler: @escaping @Sendable (Error?) -> Void) {
        let error = self.error
        queue.addOperation { handler(error) }
    }
}

/// An in-memory connection served from the capsule. Like a task, it keeps
/// the socket alive until the connection completes.
final class ReplayWebSocketTransport: WebSocketTransport, @unchecked Sendable {
    private var _socket: BugCapsuleWebSocket?
    private var socket: BugCapsuleWebSocket? { lock.locked { _socket } }
    private let integration: BugCapsuleWebSockets
    private let replay: InteractionReplay
    private let queue: OperationQueue
    private let redactor: Redactor
    private let dep: String
    private let encoder: PayloadEncoder
    private let lock = NSLock()

    private var conn: String?
    private var scope: String?
    private var resumed = false
    private var isOpen = false
    private var inbox: [URLSessionWebSocketTask.Message] = []
    private var receivers: [@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void] = []
    /// Sends waiting for the recorded send error (by index).
    private var failingSends: [Int: @Sendable (Error?) -> Void] = [:]
    private var terminal: Error?
    private var sendIndex = 0
    private var messageIndex = 0
    private var _closeCode: URLSessionWebSocketTask.CloseCode = .invalid
    private var _closeReason: Data?
    private var completed = false
    var maximumMessageSize = 1_048_576

    init(
        socket: BugCapsuleWebSocket, integration: BugCapsuleWebSockets, replay: InteractionReplay, capsule: Capsule?,
        redactor: Redactor, queue: OperationQueue
    ) {
        _socket = socket
        self.integration = integration
        self.replay = replay
        self.redactor = redactor
        self.queue = queue
        dep = replay.dependencyId(adapter: BugCapsuleWebSockets.adapterId) ?? integration.descriptor.dependencyId
        encoder = PayloadEncoder(
            redactor: { redactor }, budget: PayloadBudget(InteractionLimits(maxWindowPayloadBytes: .max)),
            stats: DependencyStats(), now: { 0 }, captureBinary: integration.descriptor.captureBinary,
            redactedReplayable: integration.descriptor.redactedReplayable)
    }

    var closeCode: URLSessionWebSocketTask.CloseCode { lock.locked { _closeCode } }
    var closeReason: Data? { lock.locked { _closeReason } }

    private func async(_ body: @escaping @Sendable () -> Void) { queue.addOperation(body) }

    private var name: String { lock.locked { conn } ?? "unmatched connection" }

    func resume() {
        let first: Bool = lock.locked {
            if resumed { return false }
            resumed = true
            return true
        }
        guard first, let socket else { return }
        let (redacted, key) = integration.matchURL(socket.url, redactor: redactor)
        guard let r = replay.take(dep: dep, type: InteractionTypes.wsConnect, key: key) else {
            replay.diverge("ws.unrecorded", "connect \(redacted): no recorded connection left for this URL")
            fail(BugCapsuleReplayError(code: "bugcapsule.unrecorded", message: "replay: no recorded WebSocket connection to \(redacted)"))
            return
        }
        let conn = r.data["conn"]?.stringValue ?? ""
        let scope = "ws:\(conn)"
        lock.locked {
            self.conn = conn
            self.scope = scope
        }
        replay.bind(scope) { [self] r in deliver(r) }
    }

    /// An inbound recorded event is due.
    private func deliver(_ r: RecordedInteraction) {
        switch r.type {
        case InteractionTypes.wsOpen:
            lock.locked { isOpen = true }
            let proto = r.data["protocol"]?.stringValue
            async { [weak self] in self?.socket?.transportDidOpen(proto) }
        case InteractionTypes.wsMessage:
            let index = r.data["index"]?.intValue ?? 0
            guard let p = r.payload("payload"), p.replayable else {
                let p = r.payload("payload")
                replay.diverge(
                    "ws.noPayload",
                    "\(name) message #\(index): recorded as \(p?.mode.rawValue ?? "missing")"
                        + (p?.kind.map { " \($0)" } ?? "") + (p?.bytes.map { ", \($0) bytes" } ?? ""))
                return
            }
            let message: URLSessionWebSocketTask.Message
            switch p.decoded {
            case let d as Data: message = .data(d)
            case let s as String: message = p.kind == "binary" ? .data(Data(s.utf8)) : .string(s)
            case let other: message = .string(JSON.encode(TypedValue.encode(other)))
            }
            let receiver: (@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)? = lock.locked {
                messageIndex += 1
                if receivers.isEmpty {
                    inbox.append(message)
                    return nil
                }
                return receivers.removeFirst()
            }
            if let receiver { async { receiver(.success(message)) } }
        case InteractionTypes.wsError:
            let error = recordedError(r.data["error"]?.objectValue)
            if r.data["phase"]?.stringValue == "send" {
                let index = r.data["index"]?.intValue ?? -1
                if let waiting = lock.locked({ failingSends.removeValue(forKey: index) }) { async { waiting(error) } }
                return
            }
            // URLSession sets the close code before failing the receive;
            // a recorded close that follows completes the connection.
            let scope = lock.locked { self.scope } ?? ""
            let close = replay.answers(scope: scope, after: r.event.seq).first { $0.type == InteractionTypes.wsClose }
            if let close {
                let code = close.data["code"]?.intValue.flatMap { URLSessionWebSocketTask.CloseCode(rawValue: $0) } ?? .invalid
                lock.locked {
                    _closeCode = code
                    _closeReason = close.data["reason"]?.stringValue.map { Data($0.utf8) }
                }
            }
            fail(error, report: close == nil)
        case InteractionTypes.wsClose:
            let code = r.data["code"]?.intValue.flatMap { URLSessionWebSocketTask.CloseCode(rawValue: $0) } ?? .invalid
            let reason = r.data["reason"]?.stringValue.map { Data($0.utf8) }
            let initiator = r.data["initiator"]?.stringValue
            lock.locked {
                _closeCode = code
                _closeReason = reason
            }
            if let scope = lock.locked({ scope }) { replay.unbind(scope) }
            let notConnected = NSError(
                domain: NSPOSIXErrorDomain, code: 57, userInfo: [NSLocalizedDescriptionKey: "Socket is not connected"])
            if initiator == "server" {
                async { [weak self] in self?.socket?.transportDidClose(code, reason) }
                fail(notConnected, report: false)
                complete(nil)
            } else {
                fail(lock.locked { terminal } ?? notConnected)
            }
        default:
            break
        }
    }

    /// Ends the connection with [error]: waiting and later receives fail.
    private func fail(_ error: Error, report: Bool = true) {
        let waiting: [@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void] = lock.locked {
            if terminal == nil { terminal = error }
            let w = receivers
            receivers = []
            return w
        }
        let e = lock.locked { terminal } ?? error
        for w in waiting { async { w(.failure(e)) } }
        if report { complete(e) }
    }

    private func complete(_ error: Error?) {
        let socket: BugCapsuleWebSocket? = lock.locked {
            if completed { return nil }
            completed = true
            defer { _socket = nil }
            return _socket
        }
        guard let socket else { return }
        if let scope = lock.locked({ scope }) { replay.unbind(scope) }
        async { socket.transportDidComplete(error) }
    }

    private func recordedError(_ e: JSONObject?) -> Error {
        NSError(
            domain: e?["type"]?.stringValue ?? "BugCapsuleReplay", code: e?["code"]?.intValue ?? -1,
            userInfo: [NSLocalizedDescriptionKey: e?["message"]?.stringValue ?? "recorded WebSocket error"])
    }

    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping @Sendable (Error?) -> Void) {
        let (scope, terminal, index): (String?, Error?, Int) = lock.locked {
            defer { sendIndex += 1 }
            return (self.scope, self.terminal, sendIndex)
        }
        if let terminal {
            async { completion(terminal) }
            return
        }
        guard let scope, let r = replay.takeNext(scope: scope, types: [InteractionTypes.wsSend]) else {
            replay.diverge("ws.unrecorded", "\(name) send #\(index): not in the recording")
            let e = BugCapsuleReplayError(code: "bugcapsule.unrecorded", message: "replay: send #\(index) on \(name) was not recorded")
            async { completion(e) }
            return
        }
        let mine: InteractionPayload
        switch message {
        case .string(let s): mine = encoder.encode(s, kind: "text")
        case .data(let d): mine = encoder.encode(d, kind: "binary")
        @unknown default: mine = InteractionPayload(mode: .omitted, replayable: false)
        }
        let recorded = r.payload("payload") ?? .none
        if !recorded.sameAs(mine) {
            replay.diverge(
                "ws.mismatch",
                "\(name) send #\(r.data["index"]?.intValue ?? index): recorded \(Self.preview(recorded)), replay sent \(Self.preview(mine))")
        }
        // The recording answered this send with an error: fail it when due.
        let recordedIndex = r.data["index"]?.intValue ?? index
        let fails = replay.answers(scope: scope, after: r.event.seq).contains {
            $0.type == InteractionTypes.wsError && $0.data["phase"] == "send" && $0.data["index"]?.intValue == recordedIndex
        }
        if fails {
            lock.locked { failingSends[recordedIndex] = completion }
        } else {
            async { completion(nil) }
        }
    }

    static func preview(_ p: InteractionPayload) -> String {
        guard p.replayable || p.value != nil, let v = p.value else {
            return "\(p.mode.rawValue) \(p.kind ?? "value") (\(p.bytes ?? 0) bytes)"
        }
        let s = v.stringValue ?? JSON.encode(v)
        return s.dartLength > 120 ? "\"\(s.dartPrefix(120))…\"" : "\"\(s)\""
    }

    func receive(completion: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        enum Next { case message(URLSessionWebSocketTask.Message), error(Error), wait }
        let next: Next = lock.locked {
            if !inbox.isEmpty { return .message(inbox.removeFirst()) }
            if let terminal { return .error(terminal) }
            receivers.append(completion)
            return .wait
        }
        switch next {
        case .message(let m): async { completion(.success(m)) }
        case .error(let e): async { completion(.failure(e)) }
        case .wait: break
        }
    }

    func cancel(code: URLSessionWebSocketTask.CloseCode, reason: Data?) { close(code: code, reason: reason) }

    func abort() { close(code: nil, reason: nil) }

    private func close(code: URLSessionWebSocketTask.CloseCode?, reason: Data?) {
        guard let scope = lock.locked({ scope }), lock.locked({ terminal }) == nil else {
            fail(cancelled(), report: lock.locked { scope } == nil)
            return
        }
        if let r = replay.takeNext(scope: scope, types: [InteractionTypes.wsClose]) {
            let recordedCode = r.data["code"]?.intValue
            if recordedCode != code?.rawValue {
                replay.diverge(
                    "ws.mismatch",
                    "\(name) close: recorded code \(recordedCode.map(String.init) ?? "none"), replay \(code.map { String($0.rawValue) } ?? "none")")
            }
            // The recorded close that follows (server echo, or the abort's
            // `unknown` close) completes it.
            fail(cancelled(), report: false)
        } else {
            replay.diverge("ws.unrecorded", "\(name) close from the client: not in the recording")
            replay.unbind(scope)
            lock.locked {
                _closeCode = code ?? .invalid
                _closeReason = reason
            }
            fail(cancelled(), report: false)
            complete(code == nil ? cancelled() : nil)
        }
    }

    private func cancelled() -> Error { URLError(.cancelled) }

    func sendPing(_ handler: @escaping @Sendable (Error?) -> Void) {
        let error = lock.locked { terminal }
        async { handler(error) }
    }
}
