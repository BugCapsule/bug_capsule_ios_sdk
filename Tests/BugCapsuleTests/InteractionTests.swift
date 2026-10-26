import Foundation
import XCTest

@testable import BugCapsule

/// Native adapter API (capsule-v2 §4.3) through the offline conformance
/// helper, with the example location adapter.
final class NativeAdapterTests: XCTestCase {
    func testExampleLocationAdapterRoundTripIsClean() async throws {
        let report = try await BugCapsuleAdapterConformance.run(
            makeAdapter: { replaying in BugCapsuleLocationAdapter(provider: ScriptedLocationProvider(failing: replaying)) }
        ) { adapter, log in
            let location = adapter as! BugCapsuleLocationAdapter
            let fix = try await location.currentLocation()
            log.append("current \(fix.latitude),\(fix.longitude) ±\(fix.accuracy)")
            let seen = SeenLog()
            let updates = try location.updates { fix in seen.add("fix \(fix.latitude) ±\(fix.accuracy)") }
            _ = await eventually { seen.lines.count >= 2 }
            updates.cancel()
            for line in seen.lines.prefix(2) { log.append(line) }
        }
        XCTAssertTrue(report.isClean, report.problems.joined(separator: "\n"))
        XCTAssertEqual(
            report.captureLog, ["current 52.52,13.405 ±5.0", "fix 52.52 ±5.0", "fix 52.5201 ±8.5"])
        XCTAssertEqual(CapsuleCodec.writeVersion(report.capsule), 2)
        let dep = try XCTUnwrap(report.dependency)
        XCTAssertEqual(dep.kind, DependencyKinds.native)
        XCTAssertEqual(dep.adapter, BugCapsuleLocationAdapter.adapterId)
        XCTAssertEqual(dep.coverage, .complete)
        XCTAssertEqual(dep.operations, ["location.current", "location.updates"])
        let types = report.capsule.events.map(\.type)
        XCTAssertEqual(Array(types.prefix(3)), ["native.call", "native.result", "native.subscribe"])
        XCTAssertTrue(types.contains("native.event"))
        XCTAssertEqual(types.last, "native.cancel")
        // Accuracy 5.0 is an integral double: it survives as a double.
        let result = report.capsule.events[1].data["value"]?["value"]
        XCTAssertEqual(result?["accuracy"], ["$t": "double", "v": "5.0"])
    }

    func testUnsupportedOperationIsAnExplicitGapAndFailsInReplay() async throws {
        let report = try await BugCapsuleAdapterConformance.run(
            makeAdapter: { replaying in BugCapsuleLocationAdapter(provider: ScriptedLocationProvider(failing: replaying)) }
        ) { adapter, log in
            let location = adapter as! BugCapsuleLocationAdapter
            _ = try await location.currentLocation()
            do {
                log.append("heading \(try await location.heading())")
            } catch {
                log.append("heading failed: \(error)")
            }
        }
        XCTAssertFalse(report.isClean)
        XCTAssertEqual(report.gaps.map(\.code), [DependencyGaps.operationUnsupported])
        XCTAssertEqual(report.dependency?.coverage, .partial)
        XCTAssertEqual(report.captureLog, ["heading 271.5"])
        XCTAssertEqual(report.replayLog, ["heading failed: bugcapsule.unrecorded: replay: location.heading was not recorded"])
        XCTAssertEqual(report.divergences.map(\.type), ["native.unrecorded"])
        XCTAssertTrue(report.capsule.manifest.eligibility.missing.contains { $0.dependency == "dependency.location" })
    }

    func testReplayNeverCallsTheDependencyAndReportsArgumentMismatch() async throws {
        let replayProvider = ScriptedLocationProvider(failing: true)
        let report = try await BugCapsuleAdapterConformance.run(
            makeAdapter: { replaying in
                BugCapsuleLocationAdapter(provider: replaying ? replayProvider : ScriptedLocationProvider(failing: false))
            }
        ) { adapter, log in
            let location = adapter as! BugCapsuleLocationAdapter
            // Replay asks for a different accuracy than the recording.
            let accuracy = location.isReplaying ? "coarse" : "best"
            let updates = try location.updates(accuracy: accuracy, onFix: { _ in }, onError: { log.append("error \($0)") })
            try? await Task.sleep(nanoseconds: 150_000_000)
            updates.cancel()
        }
        XCTAssertEqual(replayProvider.calls, 0, "replay must not reach the dependency")
        XCTAssertTrue(report.divergences.contains { $0.type == "native.mismatch" }, "\(report.divergences)")
        XCTAssertTrue(report.divergences.contains { $0.type == "native.unused" })
        XCTAssertEqual(assessAttempt(
            ReplayReport(outcome: .notReproduced, attempt: 1, durationMs: 1, strategy: .semantic, expectedSignature: "x",
                divergences: report.divergences)).reasonCodes, ["interaction.mismatch", "interaction.missing"])
    }

    /// A small adapter with an instance-scoped call.
    final class Store: BugCapsuleNativeAdapter, @unchecked Sendable {
        let descriptor: BugCapsuleAdapterDescriptor
        var bridge: BugCapsuleNativeBridge = .detached(BugCapsuleAdapterDescriptor(dependencyId: "x", adapter: "x", adapterVersion: "1"))
        let calls = SeenLog()
        let replaying: Bool
        init(replaying: Bool, required: Bool = true) {
            self.replaying = replaying
            descriptor = BugCapsuleAdapterDescriptor(
                dependencyId: "store", adapter: "test.store", adapterVersion: "1", required: required, operations: ["doc.get"])
        }
        func attach(_ bridge: BugCapsuleNativeBridge) { self.bridge = bridge }
        func get(_ path: String, app: String?) async throws -> String {
            let calls = self.calls
            let v = try await bridge.call("doc.get", args: ["path": path], instance: app) {
                calls.add("live \(path)")
                return "doc:\(path)"
            }
            return v as? String ?? "?"
        }
    }

    func testInstanceScopesMatchingAndReplayNeverGoesLive() async throws {
        let replayStore = SeenLog()
        let report = try await BugCapsuleAdapterConformance.run(makeAdapter: { replaying in
            let s = Store(replaying: replaying)
            if replaying { replayStore.add("made") }
            return s
        }) { adapter, log in
            let store = adapter as! Store
            log.append(try await store.get("carts/1", app: "primary"))
            if store.replaying {
                // Another instance, then other arguments on the same instance.
                do { _ = try await store.get("carts/1", app: "secondary") } catch { log.append("secondary failed") }
                do { _ = try await store.get("carts/2", app: "primary") } catch { log.append("other args failed") }
                if !store.calls.lines.isEmpty { log.append("LIVE") }
            }
        }
        XCTAssertEqual(report.capsule.events[0].data["key"]?.stringValue?.hasPrefix("doc.get@primary||"), true)
        XCTAssertEqual(report.replayLog, ["doc:carts/1", "secondary failed", "other args failed"])
        XCTAssertEqual(report.divergences.map(\.type), ["native.unrecorded", "native.unrecorded"])
    }

    func testNoRecordingOrCaptureOnlyAdapterFailsInsteadOfGoingLive() async throws {
        // Nothing recorded for the adapter at all.
        let none = try await BugCapsuleAdapterConformance.run(makeAdapter: { Store(replaying: $0) }) { adapter, log in
            let store = adapter as! Store
            guard store.replaying else { return }
            do { log.append(try await store.get("a", app: nil)) } catch { log.append("failed \(store.calls.lines)") }
        }
        XCTAssertNil(none.dependency)
        XCTAssertEqual(none.replayLog, ["failed []"])
        XCTAssertEqual(none.divergences.map(\.type), ["native.unrecorded"])

        // A capture-only (diagnostic) adapter is recorded but never served.
        let diagnostic = try await BugCapsuleAdapterConformance.run(makeAdapter: { Store(replaying: $0, required: false) }) {
            adapter, log in
            let store = adapter as! Store
            do { log.append(try await store.get("a", app: nil)) } catch { log.append("failed \(store.calls.lines)") }
        }
        XCTAssertEqual(diagnostic.dependency?.coverage, .diagnostic)
        XCTAssertEqual(diagnostic.dependency?.required, false)
        XCTAssertEqual(diagnostic.replayLog, ["failed []"])
        XCTAssertEqual(diagnostic.divergences.map(\.type), ["native.unrecorded"])
    }

    func testRecordedErrorsAndRedactionReplay() async throws {
        final class Vault: BugCapsuleNativeAdapter, @unchecked Sendable {
            let descriptor = BugCapsuleAdapterDescriptor(
                dependencyId: "vault", adapter: "test.vault", adapterVersion: "1", operations: ["vault.get"],
                redactedReplayable: true, nondeterministicFields: ["requestedAt"])
            var bridge: BugCapsuleNativeBridge!
            let replaying: Bool
            init(replaying: Bool) { self.replaying = replaying }
            func attach(_ bridge: BugCapsuleNativeBridge) { self.bridge = bridge }
            func get(_ key: String) async throws -> String {
                let replaying = self.replaying
                let wire = try await bridge.call("vault.get", args: ["key": key, "requestedAt": Date().timeIntervalSince1970]) {
                    if replaying { throw BugCapsuleNativeError(code: "live.called") }
                    if key == "missing" { throw BugCapsuleNativeError(code: "not_found", message: "no \(key)") }
                    return ["user": "u1", "password": "hunter2"] as [String: Any?]
                }
                let d = wire as! [String: Any?]
                return "\(d["user"]! ?? "")/\(d["password"]! ?? "")"
            }
        }
        let report = try await BugCapsuleAdapterConformance.run(makeAdapter: { Vault(replaying: $0) }) { adapter, log in
            let vault = adapter as! Vault
            log.append(try await vault.get("account"))
            do { _ = try await vault.get("missing") } catch let e as BugCapsuleNativeError { log.append("\(e.code) \(e.message ?? "")") }
        }
        // Capture hands the app the real value; the replay the redacted one
        // (declared replayable), so the logs differ only there.
        XCTAssertEqual(report.captureLog, ["u1/hunter2", "not_found no missing"])
        XCTAssertEqual(report.replayLog, ["u1/[REDACTED]", "not_found no missing"])
        XCTAssertTrue(report.divergences.isEmpty, "\(report.divergences)")
        XCTAssertTrue(report.gaps.contains { $0.code == DependencyGaps.payloadRedacted })
        let raw = JSON.encode(CapsuleCodec.toJSON(report.capsule))
        XCTAssertFalse(raw.contains("hunter2"))
    }
}

/// WebSocket capture and replay through real sessions and the replay
/// engine; the network side is a scripted server behind the live seam.
@MainActor
final class WebSocketTests: XCTestCase {
    override func setUp() async throws { await BugCapsule.resetForTesting() }
    override func tearDown() async throws { await BugCapsule.resetForTesting() }

    let quotesURL = URL(string: "wss://quotes.example.com/v1/stream?token=abc123&ts=99")!

    private func startCapture(_ ws: BugCapsuleWebSockets = BugCapsuleWebSockets(), extra: [BugCapsuleIntegration] = []) {
        BugCapsule.start(
            BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa), integrations: [ws] + extra,
            overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory(), captureSettleDelay: 0.05))
        let s = BugCapsuleSession.current!
        s.setAnchorForTesting(s.now())
    }

    private func socket(_ url: URL, _ server: FakeWebSocketServer, protocols: [String] = []) -> BugCapsuleWebSocket {
        BugCapsuleWebSocket(
            session: .shared, url: url, protocols: protocols, integration: BugCapsuleWebSockets.active, live: server.factory())
    }

    private func capsule(_ failure: Bool = true) async throws -> Capsule {
        let resultValue = await BugCapsule.capture()
        let result = try XCTUnwrap(resultValue)
        return try CapsuleCodec.decode(Data(contentsOf: result.file))
    }

    private func replay(
        _ capsule: Capsule, integrations: [BugCapsuleIntegration] = [BugCapsuleWebSockets()], settleMs: Int = 1500
    ) async -> ReplayReport? {
        await BugCapsule.resetForTesting()
        let session = BugCapsuleSession(
            config: BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa), integrations: integrations,
            overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory()))
        guard let engine = session.startReplayForTesting(capsule: capsule, settings: ReplaySettings(settleTimeoutMs: settleMs))
        else { return nil }
        return await engine.run()
    }

    /// The app under test: two identical quote streams opened at once; a
    /// duplicate quote (two equal frames in the same millisecond) is the bug.
    private func quotesApp(_ server: FakeWebSocketServer, _ log: SeenLog) {
        BugCapsule.registerAction("quotes.open") { [self] _ in
            let a = socket(quotesURL, server, protocols: ["quotes.v1"])
            let b = socket(quotesURL, server, protocols: ["quotes.v1"])
            a.onOpen = { p in log.add("open a \(p ?? "-")") }
            a.resume()
            b.resume()
            Task {
                do {
                    try await a.send(.string(#"{"op":"subscribe","symbol":"ACME"}"#))
                    try await b.send(.string(#"{"op":"subscribe","symbol":"ACME"}"#))
                    var quotesA: [String] = []
                    for _ in 0..<2 { quotesA.append(messageText(try await a.receive())) }
                    for q in quotesA { log.add("a \(q)") }
                    for _ in 0..<2 { log.add("b \(messageText(try await b.receive()))") }
                    if quotesA[0] == quotesA[1] { BugCapsule.fail("quote_duplicate", "two equal quotes") }
                    a.cancel(with: .normalClosure, reason: nil)
                    b.cancel(with: .goingAway, reason: Data("bye".utf8))
                    log.add("done")
                } catch {
                    log.add("error \(error)")
                }
            }
        }
    }

    private func quotesServer() -> FakeWebSocketServer {
        let server = FakeWebSocketServer()
        server.reply = { connection, _ in
            connection == 0
                ? [.string(#"{"symbol":"ACME","price":12.5,"seq":1}"#), .string(#"{"symbol":"ACME","price":12.5,"seq":1}"#)]
                : [.string(#"{"symbol":"ACME","price":13,"seq":1}"#), .string(#"{"symbol":"ACME","price":13.5,"seq":2}"#)]
        }
        return server
    }

    func testRaceRoundTripReproducesWithEqualTimestampsAndIdenticalConnections() async throws {
        let server = quotesServer()
        let log = SeenLog()
        quotesApp(server, log)
        startCapture()
        BugCapsule.recordAction("quotes.open")
        _ = ActionRegistry.shared.invoke("quotes.open", payload: nil)
        await expectEventually("\(log.lines)") { log.lines.contains("done") }
        _ = await eventually { BugCapsuleSession.current!.recorderForTesting!.window().events.filter { $0.type == "ws.close" }.count == 4 }
        let capsule = try await capsule()
        let captured = log.lines.filter { $0.hasPrefix("a ") || $0.hasPrefix("b ") }

        // The capsule: spec v2 with the WebSocket dependency.
        XCTAssertEqual(CapsuleCodec.writeVersion(capsule), 2)
        XCTAssertNil(validateCapsuleDocument(CapsuleCodec.toJSON(capsule)))
        let dep = try XCTUnwrap(capsule.manifest.dependency("ws"))
        XCTAssertEqual(dep.adapter, "bugcapsule-ios.urlsession-websocket")
        XCTAssertEqual(dep.kind, "websocket")
        XCTAssertEqual(dep.schema, 1)
        XCTAssertTrue(dep.required)
        XCTAssertEqual(dep.coverage, .complete)
        let connects = capsule.events(ofType: "ws.connect")
        XCTAssertEqual(connects.map { $0.data["occurrence"] }, [0, 1], "identical connections by order")
        XCTAssertEqual(connects[0].data["key"], connects[1].data["key"])
        XCTAssertEqual(connects[0].data["url"], "wss://quotes.example.com/v1/stream?token=[REDACTED]&ts=99")
        XCTAssertFalse(connects[0].data["key"]!.stringValue!.contains("ts=99"), "ignored query values leave the key")
        XCTAssertEqual(connects[0].data["protocols"], ["quotes.v1"])
        XCTAssertEqual(connects.map { $0.data["attempt"] }, [0, 0])
        let messages = capsule.events(ofType: "ws.message").filter { $0.data["conn"] == connects[0].data["conn"] }
        XCTAssertEqual(messages.count, 2)
        XCTAssertLessThanOrEqual(messages[1].t - messages[0].t, 2, "duplicate frames back to back")
        XCTAssertEqual(messages[0].data["payload"]?["kind"], "text")
        XCTAssertEqual(messages[0].data["payload"]?["mode"], "full")
        let closes = capsule.events(ofType: "ws.close").map { $0.data["initiator"]?.stringValue ?? "" }
        XCTAssertEqual(closes.sorted(), ["client", "client", "server", "server"])
        XCTAssertEqual(capsule.events(ofType: "ws.open").count, 2)
        XCTAssertTrue(log.lines.contains("open a quotes.v1"), "open callback: \(log.lines)")
        XCTAssertFalse(JSON.encode(CapsuleCodec.toJSON(capsule)).contains("abc123"))

        // The race at its sharpest: the duplicates at the very same
        // millisecond (seq orders them).
        var raced = capsule
        let sameT = messages[0].t
        raced.events = capsule.events.map { e in
            var e = e
            if e.seq == messages[1].seq { e.t = sameT }
            return e
        }
        XCTAssertNil(validateCapsuleDocument(CapsuleCodec.toJSON(raced)))

        // Replay: no socket reaches the server; the failure reproduces.
        let liveBefore = server.connectionCount
        let replayLog = SeenLog()
        quotesApp(server, replayLog)
        let reportValue = await replay(raced)
        let report = try XCTUnwrap(reportValue)
        XCTAssertEqual(server.connectionCount, liveBefore, "replay never opens a live socket")
        XCTAssertEqual(report.outcome, .reproduced, "\(report.divergences) \(replayLog.lines)")
        XCTAssertEqual(report.divergences.filter(DivergencePolicy.isMaterial), [])
        _ = await eventually { replayLog.lines.contains("done") }
        XCTAssertEqual(replayLog.lines.filter { $0.hasPrefix("a ") || $0.hasPrefix("b ") }, captured)
        XCTAssertEqual(assessAttempt(report).status, .reproduced)
    }

    func testUnrecordedConnectFailsWithoutNetworkAndSendMismatchIsMaterial() async throws {
        let server = quotesServer()
        let log = SeenLog()
        quotesApp(server, log)
        startCapture()
        BugCapsule.recordAction("quotes.open")
        _ = ActionRegistry.shared.invoke("quotes.open", payload: nil)
        await expectEventually { log.lines.contains("done") }
        let capsule = try await capsule()

        // Replay with an app that changed: another URL and another frame.
        let replayLog = SeenLog()
        let completed = SeenLog()
        final class Delegate: BugCapsuleWebSocketDelegate {
            let log: SeenLog
            init(_ log: SeenLog) { self.log = log }
            func webSocket(_ socket: BugCapsuleWebSocket, didCompleteWithError error: Error?) {
                log.add("complete \(error.map { "\($0)" } ?? "nil")")
            }
        }
        let delegate = Delegate(completed)
        BugCapsule.registerAction("quotes.open") { [self] _ in
            let other = socket(URL(string: "wss://other.example.com/feed")!, server)
            other.delegate = delegate
            other.resume()
            let a = socket(quotesURL, server, protocols: ["quotes.v1"])
            a.resume()
            Task {
                do {
                    _ = try await other.receive()
                } catch {
                    replayLog.add("other \(error)")
                }
                try? await a.send(.string(#"{"op":"subscribe","symbol":"OTHER"}"#))
                replayLog.add("a \(messageText(try await a.receive()))")
            }
        }
        let reportValue = await replay(capsule, settleMs: 300)
        let report = try XCTUnwrap(reportValue)
        XCTAssertEqual(server.connectionCount, 2, "only the capture's two sockets were live")
        await expectEventually { replayLog.lines.contains { $0.hasPrefix("other ") } }
        XCTAssertEqual(
            replayLog.lines.first { $0.hasPrefix("other ") },
            "other bugcapsule.unrecorded: replay: no recorded WebSocket connection to wss://other.example.com/feed")
        await expectEventually { completed.lines.contains { $0.hasPrefix("complete bugcapsule.unrecorded") } }
        let types = report.divergences.map(\.type)
        XCTAssertTrue(types.contains("ws.unrecorded"), "\(types)")
        XCTAssertTrue(types.contains("ws.mismatch"), "\(types)")
        XCTAssertTrue(types.contains("ws.unused"), "the second recorded connection was never matched: \(types)")
        XCTAssertEqual(report.outcome, .notReproduced)
        let a = assessAttempt(report)
        XCTAssertEqual(a.status, .invalid)
        XCTAssertEqual(a.reasonCodes, ["interaction.mismatch", "interaction.missing", "interaction.unexpected"])
        let mismatch = report.divergences.first { $0.type == "ws.mismatch" }!
        XCTAssertTrue(mismatch.detail.contains("OTHER"), mismatch.detail)
    }

    func testBinaryFramesAreMetadataByDefaultAndCannotBeServed() async throws {
        let server = FakeWebSocketServer()
        server.reply = { _, _ in [.data(Data(repeating: 7, count: 512))] }
        let log = SeenLog()
        BugCapsule.registerAction("bin.open") { [self] _ in
            let s = socket(URL(string: "wss://bin.example.com/s")!, server)
            s.resume()
            Task {
                try await s.send(.data(Data([1, 2, 3])))
                log.add("got \(messageText(try await s.receive()))")
                BugCapsule.fail("binary_seen")
            }
        }
        startCapture()
        BugCapsule.recordAction("bin.open")
        _ = ActionRegistry.shared.invoke("bin.open", payload: nil)
        await expectEventually { log.lines.contains("got <512 bytes>") }
        let capsule = try await capsule()
        let send = try XCTUnwrap(capsule.events(ofType: "ws.send").first)
        XCTAssertEqual(send.data["payload"], ["mode": "metadata", "replayable": false, "bytes": 3, "kind": "binary"])
        let message = try XCTUnwrap(capsule.events(ofType: "ws.message").first)
        XCTAssertEqual(message.data["payload"], ["mode": "metadata", "replayable": false, "bytes": 512, "kind": "binary"])
        let dep = try XCTUnwrap(capsule.manifest.dependency("ws"))
        XCTAssertEqual(dep.coverage, .partial)
        XCTAssertEqual(dep.gaps.first?.code, DependencyGaps.payloadBinaryMetadata)
        XCTAssertEqual(dep.gaps.first?.count, 2)
        XCTAssertTrue(capsule.manifest.eligibility.missing.contains { $0.dependency == "dependency.ws" })

        let reportValue = await replay(capsule, settleMs: 300)
        let report = try XCTUnwrap(reportValue)
        let types = report.divergences.map(\.type)
        XCTAssertTrue(types.contains("ws.noPayload"), "\(types)")
        XCTAssertFalse(types.contains("ws.mismatch"), "metadata sends compare by size and kind")
        XCTAssertEqual(assessAttempt(report).reasonCodes.first, "interaction.incomplete")
    }

    func testCaptureBinaryOptInKeepsFramesAndReplaysThem() async throws {
        let server = FakeWebSocketServer()
        server.reply = { _, _ in [.data(Data([0, 1, 2, 255]))] }
        let log = SeenLog()
        BugCapsule.registerAction("bin.open") { [self] _ in
            let s = socket(URL(string: "wss://bin.example.com/s")!, server)
            s.resume()
            Task {
                try await s.send(.data(Data([9])))
                let m = try await s.receive()
                if case .data(let d) = m { log.add("got \(Array(d))") }
            }
        }
        startCapture(BugCapsuleWebSockets(captureBinary: true))
        BugCapsule.recordAction("bin.open")
        _ = ActionRegistry.shared.invoke("bin.open", payload: nil)
        await expectEventually { log.lines.contains("got [0, 1, 2, 255]") }
        let capsule = try await capsule()
        XCTAssertEqual(
            capsule.events(ofType: "ws.message").first?.data["payload"]?["value"], ["$t": "bytes", "b64": "AAEC/w=="])
        let replayLog = SeenLog()
        BugCapsule.registerAction("bin.open") { [self] _ in
            let s = socket(URL(string: "wss://bin.example.com/s")!, server)
            s.resume()
            Task {
                try await s.send(.data(Data([9])))
                if case .data(let d) = try await s.receive() { replayLog.add("got \(Array(d))") }
            }
        }
        let reportValue = await replay(capsule, integrations: [BugCapsuleWebSockets(captureBinary: true)], settleMs: 300)
        let report = try XCTUnwrap(reportValue)
        await expectEventually { replayLog.lines.contains("got [0, 1, 2, 255]") }
        XCTAssertEqual(report.divergences.filter(DivergencePolicy.isMaterial), [])
    }

    func testRemoteKillSwitchDisablesTheAdapterButNotHTTP() async throws {
        let server = quotesServer()
        let log = SeenLog()
        quotesApp(server, log)
        FakeServerProtocol.reset()
        FakeServerProtocol.routes["/api/quote"] = .init(chunks: [Data(#"{"ok":true}"#.utf8)])
        let net = BugCapsuleURLSession()
        startCapture(extra: [net])
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeServerProtocol.self]
        BugCapsule.instrument(c)
        let http = URLSession(configuration: c)
        let session = BugCapsuleSession.current!

        // Traffic before the switch is buffered, then purged with it.
        _ = ActionRegistry.shared.invoke("quotes.open", payload: nil)
        await expectEventually { log.lines.contains("done") }
        _ = try await http.data(from: URL(string: "https://shop.test/api/quote")!)
        let window = { session.recorderForTesting!.window().events }
        await expectEventually { window().contains { $0.type == "http" } }
        XCTAssertTrue(window().contains { $0.type.hasPrefix("ws.") })

        session.applyRemote(nil, RemoteCaptureConfig(fetchedAtMs: epochMs(), disabledAdapters: [BugCapsuleWebSockets.adapterId]))
        XCTAssertFalse(window().contains { $0.type.hasPrefix("ws.") }, "buffered WebSocket events are dropped")
        XCTAssertEqual(window().filter { $0.type == "http" }.count, 1, "HTTP capture is unaffected")

        // Later sockets work but are not recorded; HTTP still is.
        let after = SeenLog()
        quotesApp(server, after)
        _ = ActionRegistry.shared.invoke("quotes.open", payload: nil)
        await expectEventually { after.lines.contains("done") }
        _ = try await http.data(from: URL(string: "https://shop.test/api/quote")!)
        await expectEventually { window().filter { $0.type == "http" }.count == 2 }
        XCTAssertFalse(window().contains { $0.type.hasPrefix("ws.") })
        let capsule = try await capsule()
        XCTAssertEqual(CapsuleCodec.writeVersion(capsule), 1, "no dependency: written as v1")
        XCTAssertTrue(capsule.manifest.dependencies.isEmpty)

        // The switch round-trips through the config JSON.
        let parsed = try RemoteCaptureConfig(json: ["disabledAdapters": ["bugcapsule-ios.urlsession-websocket"]])
        XCTAssertEqual(parsed.disabledAdapters, ["bugcapsule-ios.urlsession-websocket"])
        XCTAssertEqual(try RemoteCaptureConfig(json: parsed.json.objectValue!).disabledAdapters, parsed.disabledAdapters)
        XCTAssertThrowsError(try RemoteCaptureConfig(json: ["disabledAdapters": "all"]))
    }

    func testReplayWithoutTheIntegrationNeverGoesLive() async throws {
        let server = FakeWebSocketServer()
        let session = BugCapsuleSession(
            config: BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa), integrations: [],
            overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory()))
        let engine = try XCTUnwrap(session.startReplayForTesting(capsule: makeCapsule(), settings: ReplaySettings()))
        let s = BugCapsuleWebSocket(session: .shared, url: quotesURL, protocols: [], integration: nil, live: server.factory())
        s.resume()
        let failed = SeenLog()
        do { _ = try await s.receive() } catch { failed.add("\(error)") }
        XCTAssertEqual(server.connectionCount, 0)
        XCTAssertTrue(failed.lines.first?.hasPrefix("bugcapsule.unrecorded") == true, "\(failed.lines)")
        XCTAssertTrue(engine.buildReport().divergences.contains { $0.type == "ws.unrecorded" })
    }

    func testPreflightMissingAdapterIsIncompatible() async throws {
        // A Flutter capsule needs bug_capsule.web_socket_channel.
        let doc = try loadJSON(TestPaths.fixtures.appendingPathComponent("capsule-v2/valid/websocket.json"))["document"]!
        let flutter = try CapsuleCodec.fromJSON(doc.objectValue!)
        let box = LastReportBox()
        let session = BugCapsuleSession(
            config: BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa), integrations: [BugCapsuleWebSockets()],
            overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory()))
        XCTAssertNil(session.startReplayForTesting(capsule: flutter, settings: ReplaySettings()) { box.report = $0 })
        let report = try XCTUnwrap(box.report)
        XCTAssertEqual(report.outcome, .incompatible)
        XCTAssertTrue(report.message!.hasPrefix("dependency.unsupported"), report.message!)
        XCTAssertTrue(report.message!.contains("bug_capsule.web_socket_channel"))
        XCTAssertFalse(session.isReplaying)
        let run = evaluateRun(.verify, requestedAttempts: 1, reports: [report])
        XCTAssertEqual(run.verdict, .incompatible)
        XCTAssertEqual(run.reasonCodes, ["dependency.unsupported"])

        // Same capsule, adapter not installed at all.
        let none = BugCapsuleSession(
            config: BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa), integrations: [],
            overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory()))
        XCTAssertNil(none.startReplayForTesting(capsule: flutter, settings: ReplaySettings()) { box.report = $0 })
        XCTAssertTrue(box.report!.message!.hasPrefix("dependency.unsupported"))

        // An iOS capsule with a schema this adapter cannot replay.
        var ios = flutter
        ios.manifest.dependencies[0].adapter = BugCapsuleWebSockets.adapterId
        ios.manifest.dependencies[0].schema = 2
        let s3 = BugCapsuleSession(
            config: BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa), integrations: [BugCapsuleWebSockets()],
            overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory()))
        XCTAssertNil(s3.startReplayForTesting(capsule: ios, settings: ReplaySettings()) { box.report = $0 })
        XCTAssertTrue(box.report!.message!.hasPrefix("dependency.schema"), box.report!.message!)

        // A periodic checkpoint with a connection open cannot be restored.
        ios.manifest.dependencies[0].schema = 1
        ios.checkpoint = Checkpoint(
            kind: .periodic, t: 50, wallClockMs: ios.checkpoint.wallClockMs, afterSeq: 1,
            data: ["interactions": ["open": [["dep": "ws", "type": "ws", "id": "ws1", "restorable": false]]]])
        XCTAssertNil(validateCapsuleDocument(CapsuleCodec.toJSON(ios)))
        let s4 = BugCapsuleSession(
            config: BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa), integrations: [BugCapsuleWebSockets()],
            overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory()))
        XCTAssertNil(s4.startReplayForTesting(capsule: ios, settings: ReplaySettings()) { box.report = $0 })
        XCTAssertTrue(box.report!.message!.hasPrefix("dependency.unrestorable"), box.report!.message!)
        XCTAssertEqual(assessAttempt(box.report!).reasonCodes, ["dependency.unsupported"])
    }

    func testOpenConnectionsAreListedInPeriodicCheckpointsAndBlockEligibility() async throws {
        let server = FakeWebSocketServer()
        startCapture()
        let s = socket(URL(string: "wss://feed.example.com/live")!, server)
        s.resume()
        await expectEventually { server.connectionCount == 1 }
        let session = BugCapsuleSession.current!
        let data = session.snapshot(.periodic)
        XCTAssertEqual(data["interactions"], ["open": [["dep": "ws", "type": "ws", "id": "ws1", "restorable": false]]])
        XCTAssertNil(session.snapshot(.launch)["interactions"])
        let eligibility = EligibilityBuilder()
        let periodic = Checkpoint(kind: .periodic, t: 0, wallClockMs: 0, afterSeq: 0, data: data)
        let deps = session.interactions.manifestDependencies(
            events: session.recorderForTesting!.window().events, checkpoint: periodic, eligibility: eligibility)
        XCTAssertEqual(deps.map(\.id), ["ws"])
        let built = eligibility.build()
        XCTAssertEqual(built.status, .ineligible)
        XCTAssertTrue(built.missing.contains { $0.dependency == "interactions.restore" && $0.blocking })
        s.cancel(with: .normalClosure, reason: nil)
        await expectEventually("closed connections leave the list") { session.interactions.checkpointData() == nil }
    }

    func testDueDeliveryBoundsIdleSkipAndIdleSocketDoesNotHoldReplay() async throws {
        // Recorded: the app connected at launch (t=50) and the quote came
        // 850 ms later. In the replayed build the connect moved behind the
        // `open` action (t=1000), so the quote is due at ~1850 on the replay
        // clock, inside a stretch the recording shows as idle (until 7000).
        let ws = BugCapsuleWebSockets()
        let key = ws.matchURL(quotesURL, redactor: Redactor()).key
        let fail = FailureRecord.assertion("late_quote", message: "", t: 7100)
        let capsule = makeWebSocketCapsule(
            events: [
                BugCapsuleEvent(seq: 1, t: 50, type: "ws.connect", data: ["dep": "ws", "conn": "ws1", "key": .string(key), "occurrence": 0]),
                BugCapsuleEvent(seq: 2, t: 80, type: "ws.open", data: ["dep": "ws", "conn": "ws1"]),
                BugCapsuleEvent(
                    seq: 3, t: 900, type: "ws.message",
                    data: ["dep": "ws", "conn": "ws1", "index": 0, "payload": ["mode": "full", "replayable": true, "value": "q1", "kind": "text"]]),
                BugCapsuleEvent(seq: 4, t: 1000, type: "action", data: ["id": "open"]),
                BugCapsuleEvent(seq: 5, t: 7000, type: "action", data: ["id": "check"]),
                BugCapsuleEvent(seq: 6, t: 7100, type: "failure", data: fail.json.objectValue!),
            ], failure: fail)
        let seen = SeenLog()
        let server = FakeWebSocketServer()
        BugCapsule.registerAction("open") { [self] _ in
            let s = socket(quotesURL, server)
            s.resume()
            Task {
                let m = try await s.receive()
                let at = BugCapsuleSession.current?.engine?.interactions?.now() ?? -1
                seen.add("\(messageText(m)) \(at)")
            }
        }
        BugCapsule.registerAction("check") { _ in
            seen.add("check")
            if seen.lines.first?.hasPrefix("q1") == true { BugCapsule.fail("late_quote") }
        }
        let started = Date()
        let reportValue = await replay(capsule, integrations: [ws], settleMs: 500)
        let report = try XCTUnwrap(reportValue)
        let real = Date().timeIntervalSince(started)
        XCTAssertEqual(report.outcome, .reproduced, "\(report.divergences) \(seen.lines)")
        XCTAssertEqual(seen.lines.count, 2, "\(seen.lines)")
        // Matched at ~1000 (+ the restore-to-run offset), due 850 ms later.
        let deliveredAt = Int(seen.lines[0].split(separator: " ")[1])!
        XCTAssertGreaterThanOrEqual(deliveredAt, 1840, "the quote is not skipped past: \(seen.lines)")
        XCTAssertLessThan(deliveredAt, 2600, "nor held back: \(seen.lines)")
        XCTAssertGreaterThan(report.compressedMs, 3500, "the idle open socket did not hold replay busy")
        XCTAssertLessThan(real, 5, "idle time was compressed")
        XCTAssertEqual(report.divergences.filter(DivergencePolicy.isMaterial), [])
    }
}

final class LastReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _report: ReplayReport?
    var report: ReplayReport? {
        get { lock.locked { _report } }
        set { lock.locked { _report = newValue } }
    }
}

func makeWebSocketCapsule(events: [BugCapsuleEvent], failure: FailureRecord?) -> Capsule {
    var c = makeCapsule(events: events, failure: failure)
    c.manifest.integrations = ["websocket"]
    c.manifest.dependencies = [
        CapsuleDependency(
            id: "ws", kind: DependencyKinds.websocket, adapter: BugCapsuleWebSockets.adapterId, adapterVersion: sdkVersion,
            schema: 1, required: true, coverage: .complete)
    ]
    return c
}

/// The live path through a real `URLSessionWebSocketTask` (loopback
/// server): the task delegate reports open and close, frames are recorded.
@MainActor
final class URLSessionWebSocketLoopbackTests: XCTestCase {
    override func setUp() async throws { await BugCapsule.resetForTesting() }
    override func tearDown() async throws { await BugCapsule.resetForTesting() }

    func testRealTaskIsRecordedAndReplayed() async throws {
        let server = try LoopbackWebSocketServer()
        defer { server.stop() }
        XCTAssertNotEqual(server.port, 0)
        let log = SeenLog()
        let session = URLSession(configuration: .ephemeral)
        BugCapsule.registerAction("chat.open") { _ in
            let s = BugCapsuleWebSocket(session: session, url: server.url)
            s.onOpen = { _ in log.add("open") }
            s.onClose = { code, _ in log.add("close \(code.rawValue)") }
            s.resume()
            Task {
                do {
                    try await s.send(.string("hi"))
                    log.add("got \(messageText(try await s.receive()))")
                    try await s.send(.string("bye"))
                    _ = try await s.receive()
                } catch {
                    log.add("ended")
                    if s.closeCode.rawValue == 4000 { BugCapsule.fail("closed_by_server") }
                }
            }
        }
        BugCapsule.start(
            BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa), integrations: [BugCapsuleWebSockets()],
            overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory(), captureSettleDelay: 0.05))
        BugCapsuleSession.current!.setAnchorForTesting(BugCapsuleSession.current!.now())
        BugCapsule.recordAction("chat.open")
        _ = ActionRegistry.shared.invoke("chat.open", payload: nil)
        await expectEventually("\(log.lines)") { log.lines.contains("ended") }
        let window = { BugCapsuleSession.current!.recorderForTesting!.window().events }
        await expectEventually { window().contains { $0.type == "ws.close" && $0.data["initiator"] == "server" } }
        let result = await BugCapsule.capture()
        let capsule = try CapsuleCodec.decode(Data(contentsOf: try XCTUnwrap(result).file))
        let types = capsule.events.map(\.type).filter { $0.hasPrefix("ws.") }
        // The app sends before the handshake completed (URLSession queues it).
        XCTAssertEqual(Set(types.prefix(3)), ["ws.connect", "ws.send", "ws.open"], "\(types)")
        XCTAssertEqual(Array(types.suffix(4)), ["ws.message", "ws.send", "ws.error", "ws.close"], "\(types)")
        XCTAssertEqual(capsule.events(ofType: "ws.close").first { $0.data["initiator"] == "server" }?.data["code"], 4000)
        XCTAssertEqual(capsule.events(ofType: "ws.message").first?.data["payload"]?["value"], "echo:hi")
        XCTAssertEqual(capsule.events(ofType: "ws.connect").first?.data["url"]?.stringValue?.contains("s3cr3t"), false)
        XCTAssertTrue(log.lines.contains("open"))
        XCTAssertTrue(log.lines.contains("close 4000"), "\(log.lines)")

        // Replay with the server gone: served from the capsule.
        server.stop()
        let replayLog = SeenLog()
        BugCapsule.registerAction("chat.open") { _ in
            let s = BugCapsuleWebSocket(session: session, url: server.url)
            s.onOpen = { _ in replayLog.add("open") }
            s.onClose = { code, _ in replayLog.add("close \(code.rawValue)") }
            s.resume()
            Task {
                do {
                    try await s.send(.string("hi"))
                    replayLog.add("got \(messageText(try await s.receive()))")
                    try await s.send(.string("bye"))
                    _ = try await s.receive()
                } catch {
                    replayLog.add("ended")
                    if s.closeCode.rawValue == 4000 { BugCapsule.fail("closed_by_server") }
                }
            }
        }
        await BugCapsule.resetForTesting()
        let replaySession = BugCapsuleSession(
            config: BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa), integrations: [BugCapsuleWebSockets()],
            overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory()))
        let engine = try XCTUnwrap(replaySession.startReplayForTesting(capsule: capsule, settings: ReplaySettings(settleTimeoutMs: 1500)))
        let report = await engine.run()
        XCTAssertEqual(report.outcome, .reproduced, "\(report.divergences) \(replayLog.lines)")
        XCTAssertEqual(report.divergences.filter(DivergencePolicy.isMaterial), [])
        // Reproduced only if the replayed socket reported the server's 4000.
        XCTAssertTrue(replayLog.lines.contains("got echo:hi"), "\(replayLog.lines)")
        XCTAssertTrue(replayLog.lines.contains("open"), "\(replayLog.lines)")
    }
}
