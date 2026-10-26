import Foundation
import Network
import XCTest

@testable import BugCapsule

/// A scripted WebSocket server behind the live transport seam of
/// `BugCapsuleWebSocket` (deterministic capture tests without a network).
final class FakeWebSocketServer: @unchecked Sendable {
    private let lock = NSLock()
    /// Answers a client frame: frames sent back at the same instant.
    var reply: @Sendable (_ connection: Int, _ message: URLSessionWebSocketTask.Message) -> [URLSessionWebSocketTask.Message] = {
        _, _ in []
    }
    /// Refuse connections to URLs containing this.
    var refuse: String?
    var openDelayMs = 5
    private(set) var connections: [FakeLiveSocket] = []

    var connectionCount: Int { lock.locked { connections.count } }

    func connection(_ i: Int) -> FakeLiveSocket { lock.locked { connections[i] } }

    func factory() -> (BugCapsuleWebSocket) -> WebSocketTransport {
        { [self] socket in
            lock.locked {
                let c = FakeLiveSocket(server: self, socket: socket, number: connections.count)
                connections.append(c)
                return c
            }
        }
    }
}

final class FakeLiveSocket: WebSocketTransport, @unchecked Sendable {
    /// Held until the connection completes, as URLSession holds a task.
    private var socket: BugCapsuleWebSocket?
    private let server: FakeWebSocketServer
    let number: Int
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "fake-ws")
    private var inbox: [URLSessionWebSocketTask.Message] = []
    private var receivers: [@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void] = []
    private var terminal: Error?
    private var _closeCode: URLSessionWebSocketTask.CloseCode = .invalid
    private(set) var sent: [URLSessionWebSocketTask.Message] = []
    private var isOpen = false
    /// Frames the app sent before the handshake completed (URLSession queues them).
    private var early: [(URLSessionWebSocketTask.Message, @Sendable (Error?) -> Void)] = []
    var maximumMessageSize = 1_048_576

    init(server: FakeWebSocketServer, socket: BugCapsuleWebSocket, number: Int) {
        self.server = server
        self.socket = socket
        self.number = number
    }

    var closeCode: URLSessionWebSocketTask.CloseCode { lock.locked { _closeCode } }
    var closeReason: Data? { nil }

    func resume() {
        let refused = server.refuse.map { lock.locked { socket }?.url.absoluteString.contains($0) ?? false } ?? false
        queue.asyncAfter(deadline: .now() + .milliseconds(server.openDelayMs)) { [weak self] in
            guard let self else { return }
            if refused {
                self.end(URLError(.cannotConnectToHost))
                self.completed(URLError(.cannotConnectToHost))
            } else {
                let socket = self.lock.locked { self.socket }
                socket?.transportDidOpen(socket?.protocols.first)
                let queued = self.lock.locked { () -> [(URLSessionWebSocketTask.Message, @Sendable (Error?) -> Void)] in
                    self.isOpen = true
                    defer { self.early = [] }
                    return self.early
                }
                for (m, c) in queued { self.send(m, completion: c) }
            }
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping @Sendable (Error?) -> Void) {
        let queued: Bool = lock.locked {
            if !isOpen {
                early.append((message, completion))
                return true
            }
            sent.append(message)
            return false
        }
        if queued { return }
        let replies = server.reply(number, message)
        queue.async { [weak self] in
            completion(nil)
            self?.push(replies)
        }
    }

    /// Server frames, delivered back to back (same millisecond).
    func push(_ messages: [URLSessionWebSocketTask.Message]) {
        for m in messages {
            let r: (@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)? = lock.locked {
                if receivers.isEmpty {
                    inbox.append(m)
                    return nil
                }
                return receivers.removeFirst()
            }
            r?(.success(m))
        }
    }

    /// The network drops the connection.
    func drop() {
        queue.async { [weak self] in
            guard let self else { return }
            let e = URLError(.networkConnectionLost)
            self.end(e)
            self.completed(e)
        }
    }

    private func end(_ error: Error) {
        let waiting = lock.locked { () -> [@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void] in
            if terminal == nil { terminal = error }
            defer { receivers = [] }
            return receivers
        }
        for w in waiting { w(.failure(error)) }
    }

    func receive(completion: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        let now: Result<URLSessionWebSocketTask.Message, Error>? = lock.locked {
            if !inbox.isEmpty { return .success(inbox.removeFirst()) }
            if let terminal { return .failure(terminal) }
            receivers.append(completion)
            return nil
        }
        if let now { queue.async { completion(now) } }
    }

    func cancel(code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.locked { self._closeCode = code }
            self.lock.locked { self.socket }?.transportDidClose(code, reason)
            self.end(NSError(domain: NSPOSIXErrorDomain, code: 57))
            self.completed(nil)
        }
    }

    private func completed(_ error: Error?) {
        let s = lock.locked { () -> BugCapsuleWebSocket? in
            defer { socket = nil }
            return socket
        }
        s?.transportDidComplete(error)
    }

    func abort() { drop() }

    func sendPing(_ handler: @escaping @Sendable (Error?) -> Void) { queue.async { handler(nil) } }
}

/// Records what the app saw (thread-safe).
final class SeenLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    func add(_ s: String) { lock.locked { _lines.append(s) } }
    var lines: [String] { lock.locked { _lines } }
    func count(_ prefix: String) -> Int { lines.filter { $0.hasPrefix(prefix) }.count }
}

func messageText(_ m: URLSessionWebSocketTask.Message) -> String {
    switch m {
    case .string(let s): return s
    case .data(let d): return "<\(d.count) bytes>"
    @unknown default: return "?"
    }
}

/// Waits until [cond] holds (polling), up to [timeout].
func eventually(
    _ timeout: TimeInterval = 5, isolation: isolated (any Actor)? = #isolation, _ cond: () -> Bool
) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !cond() {
        if Date() > end { return false }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
}

/// A location provider with scripted fixes; `failing` throws when used
/// (the replay must never reach the dependency).
final class ScriptedLocationProvider: BugCapsuleLocationProvider, @unchecked Sendable {
    let failing: Bool
    private let lock = NSLock()
    private(set) var calls = 0
    var fixes: [BugCapsuleLocationFix] = [
        BugCapsuleLocationFix(latitude: 52.52, longitude: 13.405, accuracy: 5),
        BugCapsuleLocationFix(latitude: 52.5201, longitude: 13.4051, accuracy: 8.5),
        BugCapsuleLocationFix(latitude: 52.5202, longitude: 13.4052, accuracy: 8.5),
    ]

    init(failing: Bool) { self.failing = failing }

    struct Unavailable: Error {}

    private func use() throws {
        lock.locked { calls += 1 }
        if failing { throw Unavailable() }
    }

    func currentLocation() async throws -> BugCapsuleLocationFix {
        try use()
        return fixes[0]
    }

    func startUpdates(
        accuracy: String, _ handler: @escaping @Sendable (Result<BugCapsuleLocationFix, Error>) -> Void
    ) throws -> @Sendable () -> Void {
        try use()
        let fixes = self.fixes
        let stopped = StopFlag()
        DispatchQueue.global().async {
            for f in fixes {
                Thread.sleep(forTimeInterval: 0.03)
                if stopped.value { return }
                handler(.success(f))
            }
        }
        return { stopped.value = true }
    }

    func heading() async throws -> Double {
        try use()
        return 271.5
    }
}

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.locked { _value } }
        set { lock.locked { _value = newValue } }
    }
}

/// Asserts that [cond] becomes true within [timeout].
func expectEventually(
    _ message: @autoclosure () -> String = "", timeout: TimeInterval = 5, file: StaticString = #filePath,
    line: UInt = #line, isolation: isolated (any Actor)? = #isolation, _ cond: () -> Bool
) async {
    let ok = await eventually(timeout, cond)
    XCTAssertTrue(ok, message(), file: file, line: line)
}

/// A loopback WebSocket server (Network.framework): answers each text frame
/// with `echo:<text>`, closes with 4000 when it receives `bye`.
final class LoopbackWebSocketServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-ws")
    private(set) var port: UInt16 = 0

    init() throws {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    var url: URL { URL(string: "ws://127.0.0.1:\(port)/stream?session=s3cr3t")! }

    func stop() { listener.cancel() }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        func next() {
            c.receiveMessage { data, context, _, error in
                guard error == nil, let data, let context else { return }
                let meta = context.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if meta?.opcode == .close { c.cancel(); return }
                let text = String(decoding: data, as: UTF8.self)
                if text == "bye" {
                    let m = NWProtocolWebSocket.Metadata(opcode: .close)
                    m.closeCode = .privateCode(4000)
                    let ctx = NWConnection.ContentContext(identifier: "close", metadata: [m])
                    c.send(content: Data(), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
                    return
                }
                let m = NWProtocolWebSocket.Metadata(opcode: .text)
                let ctx = NWConnection.ContentContext(identifier: "text", metadata: [m])
                c.send(content: Data("echo:\(text)".utf8), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
                next()
            }
        }
        next()
    }
}
