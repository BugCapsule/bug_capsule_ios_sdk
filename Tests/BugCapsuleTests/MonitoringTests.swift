import Foundation
import XCTest

@testable import BugCapsule

/// monitoring-v1 against a stubbed backend (URLProtocol).
@MainActor
final class MonitoringTests: XCTestCase {
    var dir: URL!

    override func setUp() async throws {
        await BugCapsule.resetForTesting()
        StubBackend.reset()
        FakeServerProtocol.reset()
        dir = tempDirectory()
    }

    override func tearDown() async throws { await BugCapsule.resetForTesting() }

    /// Production with capsule sampling at 0 isolates monitoring; `qa` records.
    func start(
        mode: CaptureMode = .production, monitoring: BugCapsuleMonitoringOptions = testMonitoringOptions(),
        integrations: [BugCapsuleIntegration] = [], directory: URL? = nil
    ) async {
        let config = BugCapsuleConfig(
            appVersion: "1.4.0", appBuild: "52", appId: "com.shop.app", mode: mode, backend: stubBackend,
            gitSha: "abc123", gitDirty: false, productionSampleRate: 0, monitoring: monitoring)
        BugCapsule.start(
            config, integrations: integrations,
            overrides: BugCapsuleTestOverrides(
                storageDirectory: directory ?? dir, transport: stubTransport(), random: { 0.5 }, captureSettleDelay: 0.05))
        await BugCapsule.refreshRemoteConfig()
    }

    var monitoring: Monitoring { BugCapsuleSession.current!.monitoring! }

    func waitUntil(_ timeout: TimeInterval = 5, _ cond: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func flushUntil(_ timeout: TimeInterval = 5, _ cond: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            await BugCapsule.flush(timeout: 2)
            if cond() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < end
    }

    // MARK: errors

    func testExceptionIsSentAsRedactedGzippedEnvelope() async throws {
        await start()
        XCTAssertFalse(BugCapsule.isRecording, "capsules sampled out: monitoring alone")
        BugCapsule.setUser(BugCapsuleUser(id: "u_123", segment: "pro"))
        BugCapsule.setTag("screen", "checkout")
        BugCapsule.setTag("bad key!", "ignored")
        BugCapsule.log("user typed password=hunter2")
        BugCapsule.recordAction("cart.checkout")
        let id = BugCapsule.captureException(
            DemoError(id: 42), options: CaptureOptions(tags: ["flow": "pay"], extra: ["cartSize": 3]))
        XCTAssertNotNil(id)
        XCTAssertEqual(BugCapsule.lastEventId(), id)
        await flushUntil { !StubBackend.items("event").isEmpty }

        let req = try XCTUnwrap(
            StubBackend.requests("/v1/envelope").first {
                $0.json?["items"]?.arrayValue?.contains { $0["type"] == "event" } ?? false
            })
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.header("Authorization"), "Bearer bci_test_key_1234567890")
        XCTAssertEqual(req.header("Content-Type"), "application/json")
        XCTAssertEqual(req.header("Content-Encoding"), "gzip", "bodies over 1 KiB are gzipped")
        let envelope = try XCTUnwrap(req.json)
        XCTAssertNotNil(envelope["sentAt"]?.stringValue.flatMap(ISODate.parse))
        XCTAssertEqual(envelope["sdk"]?["name"], "bugcapsule-ios")
        XCTAssertEqual(envelope["sdk"]?["version"], "0.4.1-beta.5")

        let e = try XCTUnwrap(StubBackend.items("event").first)
        XCTAssertEqual(e["eventId"]?.stringValue, id)
        XCTAssertEqual(e["level"], "error")
        XCTAssertEqual(e["runtime"], "ios")
        XCTAssertEqual(e["release"], "com.shop.app@1.4.0+52")
        XCTAssertEqual(e["environment"], "production")
        let value = try XCTUnwrap(e["exception"]?["values"]?.arrayValue?.last)
        XCTAssertEqual(value["type"], "DemoError")
        XCTAssertEqual(value["value"], "checkout failed for order 42 token=[REDACTED]")
        XCTAssertEqual(value["mechanism"]?["type"], "manual")
        XCTAssertEqual(value["mechanism"]?["handled"], true)
        let frames = try XCTUnwrap(value["stacktrace"]?["frames"]?.arrayValue)
        XCTAssertFalse(frames.isEmpty)
        for f in frames { XCTAssertTrue(f["instructionAddr"]?.stringValue?.hasPrefix("0x") ?? false) }
        XCTAssertTrue(frames.contains { $0["function"]?.stringValue != nil }, "system frames named on device (dladdr)")
        let images = try XCTUnwrap(e["debugImages"]?.arrayValue)
        XCTAssertFalse(images.isEmpty)
        for image in images {
            XCTAssertEqual(image["type"], "macho")
            XCTAssertNotNil(UUID(uuidString: image["debugId"]?.stringValue ?? ""))
            XCTAssertTrue(image["imageAddr"]?.stringValue?.hasPrefix("0x") ?? false)
            XCTAssertGreaterThan(image["imageSize"]?.intValue ?? 0, 0)
        }
        // Every frame with an image points into one of the sent images.
        let ranges = images.compactMap { i -> ClosedRange<UInt64>? in
            guard let a = parseHex(i["imageAddr"]?.stringValue), let s = i["imageSize"]?.intValue else { return nil }
            return a...(a + UInt64(s))
        }
        for f in frames where f["package"] != nil {
            let a = try XCTUnwrap(parseHex(f["instructionAddr"]?.stringValue))
            XCTAssertTrue(ranges.contains { $0.contains(a) })
        }
        XCTAssertEqual(e["tags"]?["screen"], "checkout")
        XCTAssertEqual(e["tags"]?["flow"], "pay")
        XCTAssertNil(e["tags"]?["bad key!"])
        XCTAssertEqual(e["user"]?["id"], "u_123")
        XCTAssertNil(e["user"]?["ipAddress"], "sendDefaultPii is off")
        XCTAssertEqual(e["extra"]?["cartSize"], 3)
        XCTAssertEqual(e["contexts"]?["device"]?["manufacturer"], "Apple")
        XCTAssertNotNil(e["contexts"]?["os"]?["version"]?.stringValue)
        XCTAssertEqual(e["contexts"]?["app"]?["appId"], "com.shop.app")
        XCTAssertEqual(e["contexts"]?["trace"]?["traceId"]?.stringValue?.count, 32)
        let crumbs = try XCTUnwrap(e["breadcrumbs"]?.arrayValue)
        XCTAssertTrue(crumbs.contains { $0["category"] == "log" && $0["message"] == "user typed password=[REDACTED]" })
        XCTAssertTrue(crumbs.contains { $0["type"] == "user" && $0["message"] == "cart.checkout" })
        // Nothing sensitive reached the wire.
        let raw = String(decoding: try Gzip.decompress(req.body, maxBytes: 10_000_000), as: UTF8.self)
        XCTAssertFalse(raw.contains("hunter2"))
        XCTAssertFalse(raw.contains("abcdef123456"))
    }

    func testCapsuleAndEventPointAtEachOther() async throws {
        await start(mode: .qa)
        XCTAssertTrue(BugCapsule.isRecording)
        let id = BugCapsule.captureException(DemoError(id: 7))
        await waitUntil { !StubBackend.requests("/v1/capsules").isEmpty }
        await flushUntil { !StubBackend.items("event").isEmpty }
        let capsule = try CapsuleCodec.decode(try XCTUnwrap(StubBackend.requests("/v1/capsules").first?.body))
        let event = try XCTUnwrap(StubBackend.items("event").first)
        XCTAssertEqual(event["eventId"]?.stringValue, id)
        XCTAssertEqual(event["capsuleId"]?.stringValue, capsule.manifest.capsuleId)
        XCTAssertEqual(event["environment"], "qa")
        let link = try XCTUnwrap(capsule.manifest.monitoring)
        XCTAssertEqual(link.eventId, id)
        XCTAssertEqual(link.release, "com.shop.app@1.4.0+52")
        XCTAssertEqual(link.environment, "qa")
        XCTAssertNil(validateCapsuleDocument(CapsuleCodec.toJSON(capsule)), "manifest.monitoring keeps the capsule valid")
        XCTAssertEqual(capsule.manifest.json["monitoring"]?["eventId"]?.stringValue, id)
    }

    func testAssertionFailureAndMessageEvents() async throws {
        await start()
        BugCapsule.fail("cart.total_negative", "total was -3")
        let messageId = BugCapsule.captureMessage("Checkout slow", level: .warning)
        await flushUntil { StubBackend.items("event").count >= 2 }
        let events = StubBackend.items("event")
        let assertion = try XCTUnwrap(events.first { $0["exception"] != nil })
        let value = assertion["exception"]?["values"]?.arrayValue?.last
        XCTAssertEqual(value?["type"], "cart.total_negative")
        XCTAssertEqual(value?["value"], "total was -3")
        XCTAssertEqual(value?["mechanism"]?["type"], "assertion")
        let message = try XCTUnwrap(events.first { $0["eventId"]?.stringValue == messageId })
        XCTAssertEqual(message["level"], "warning")
        XCTAssertEqual(message["message"]?["formatted"], "Checkout slow")
        XCTAssertNotNil(message["threads"]?.arrayValue?.first?["stacktrace"], "attachStacktrace")
    }

    func testScopeBeforeSendSamplingAndFingerprint() async throws {
        await start(
            monitoring: testMonitoringOptions(beforeSend: { event, _ in
                if event.message?.contains("drop") == true { return nil }
                var e = event
                e.tags["checked"] = "yes"
                return e
            }))
        BugCapsule.setFingerprint(["checkout", "{{ default }}"])
        let inside = BugCapsule.withScope { scope -> String? in
            scope.setTag("temp", "1")
            scope.setLevel(.debug)
            return BugCapsule.captureMessage("in scope")
        }
        let outside = BugCapsule.captureMessage("after")
        XCTAssertNil(BugCapsule.captureMessage("drop me"))
        XCTAssertEqual(BugCapsule.lastEventId(), outside)
        await flushUntil { StubBackend.items("event").count >= 2 }
        let events = StubBackend.items("event")
        XCTAssertEqual(events.count, 2)
        let a = try XCTUnwrap(events.first { $0["eventId"]?.stringValue == inside })
        let b = try XCTUnwrap(events.first { $0["eventId"]?.stringValue == outside })
        XCTAssertEqual(a["tags"]?["temp"], "1")
        XCTAssertEqual(a["level"], "debug")
        XCTAssertNil(b["tags"]?["temp"], "the temporary scope ended")
        XCTAssertEqual(b["level"], "info")
        XCTAssertEqual(b["tags"]?["checked"], "yes")
        XCTAssertEqual(b["fingerprint"], ["checkout", "{{ default }}"])
    }

    func testRemoteConfigTurnsMonitoringOffAndSamplesErrors() async throws {
        StubBackend.config = ["enabled": true, "monitoringEnabled": false]
        await start()
        XCTAssertNil(BugCapsule.captureException(DemoError(id: 1)))
        await BugCapsule.flush()
        XCTAssertTrue(StubBackend.requests("/v1/envelope").isEmpty, "monitoringEnabled: false sends nothing")
        await BugCapsule.resetForTesting()

        StubBackend.config = ["enabled": true, "errorSampleRate": 0, "maxBreadcrumbs": 2]
        await start(mode: .qa)
        XCTAssertNil(BugCapsule.captureMessage("sampled out"))
        BugCapsule.log("1")
        BugCapsule.log("2")
        BugCapsule.log("3")
        let linked = BugCapsule.captureException(DemoError(id: 2))
        XCTAssertNotNil(linked, "events linked to a capsule are always sent")
        await flushUntil { !StubBackend.items("event").isEmpty }
        let e = try XCTUnwrap(StubBackend.items("event").first)
        XCTAssertEqual(e["eventId"]?.stringValue, linked)
        XCTAssertEqual(e["breadcrumbs"]?.arrayValue?.count, 2, "remote maxBreadcrumbs")
    }

    // MARK: sessions

    func testSessionUpdatesAndErroredExit() async throws {
        await start()
        _ = BugCapsule.captureException(DemoError(id: 3))
        BugCapsule.endSession()
        await flushUntil { StubBackend.items("session").count >= 3 }
        let sessions = StubBackend.items("session")
        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(sessions.map { $0["seq"]?.intValue ?? 0 }, [1, 2, 3])
        XCTAssertEqual(Set(sessions.compactMap { $0["sid"]?.stringValue }).count, 1)
        XCTAssertEqual(sessions[0]["init"], true)
        XCTAssertEqual(sessions[0]["status"], "ok")
        XCTAssertEqual(sessions[1]["errors"], 1)
        XCTAssertEqual(sessions[2]["status"], "exited")
        XCTAssertEqual(sessions[2]["errors"], 1, "exited with errors: an errored session")
        XCTAssertEqual(sessions[0]["did"]?.stringValue, monitoring.installId)
        XCTAssertEqual(sessions[0]["release"], "com.shop.app@1.4.0+52")
        XCTAssertNotNil(sessions[2]["duration"]?.doubleValue)
    }

    func testUnfinishedRunIsAbnormalAndNativeCrashIsFatalOnNextLaunch() async throws {
        // Launch 1 dies in the foreground without a report (OOM / watchdog).
        await start(monitoring: testMonitoringOptions(nativeCrashes: true))
        await flushUntil { !StubBackend.items("session").isEmpty }
        let first = try XCTUnwrap(StubBackend.items("session").first?["sid"]?.stringValue)
        await BugCapsule.resetForTesting()

        // Launch 2 reports it, then "crashes" with a signal.
        StubBackend.reset()
        await start(monitoring: testMonitoringOptions(nativeCrashes: true))
        XCTAssertTrue(NativeCrashHandler.isInstalled)
        await flushUntil { StubBackend.items("session").count >= 2 }
        let recovered = try XCTUnwrap(StubBackend.items("session").first { $0["sid"]?.stringValue == first })
        XCTAssertEqual(recovered["status"], "abnormal")
        let second = try XCTUnwrap(StubBackend.items("session").first { $0["init"] == true }?["sid"]?.stringValue)
        BugCapsule.setTag("screen", "cart")
        BugCapsule.addBreadcrumb(Breadcrumb(category: "test", message: "before the crash"))
        monitoring.syncCrashContext()
        XCTAssertTrue(NativeCrashHandler.writeTestReport(signal: SIGSEGV))
        await BugCapsule.resetForTesting()

        // Launch 3 sends the fatal event and closes the session as crashed.
        StubBackend.reset()
        await start(monitoring: testMonitoringOptions(nativeCrashes: true))
        await flushUntil { !StubBackend.items("event").isEmpty && StubBackend.items("session").count >= 2 }
        let crash = try XCTUnwrap(StubBackend.items("event").first)
        XCTAssertEqual(crash["level"], "fatal")
        let value = try XCTUnwrap(crash["exception"]?["values"]?.arrayValue?.last)
        XCTAssertEqual(value["type"], "SIGSEGV")
        XCTAssertEqual(value["mechanism"]?["type"], "signal")
        XCTAssertEqual(value["mechanism"]?["handled"], false)
        XCTAssertEqual(value["mechanism"]?["data"]?["signal"]?.intValue, Int(SIGSEGV))
        let frames = try XCTUnwrap(value["stacktrace"]?["frames"]?.arrayValue)
        XCTAssertGreaterThan(frames.count, 2)
        XCTAssertFalse(crash["debugImages"]?.arrayValue?.isEmpty ?? true)
        XCTAssertEqual(crash["tags"]?["screen"], "cart", "scope of the crashed run")
        XCTAssertTrue(crash["breadcrumbs"]?.arrayValue?.contains { $0["message"] == "before the crash" } ?? false)
        XCTAssertEqual(crash["release"], "com.shop.app@1.4.0+52")
        let crashed = try XCTUnwrap(StubBackend.items("session").first { $0["sid"]?.stringValue == second })
        XCTAssertEqual(crashed["status"], "crashed")
    }

    func testUncaughtNSExceptionIsWrittenSynchronously() async throws {
        await start(monitoring: testMonitoringOptions(nativeCrashes: true))
        await flushUntil { !StubBackend.items("session").isEmpty }
        let sid = StubBackend.items("session").first?["sid"]?.stringValue
        let exception = NSException(name: .invalidArgumentException, reason: "bad cart token=abcdef123456", userInfo: nil)
        BugCapsuleSession.current!.handleUncaughtException(exception)
        // The process would now abort: the SIGABRT report only marks the crash.
        XCTAssertTrue(NativeCrashHandler.writeTestReport(signal: SIGABRT))
        let queued = UploadOutbox.entries(in: dir.appendingPathComponent("envelopes"), fileExtension: "envelope")
        XCTAssertFalse(queued.isEmpty, "written before the handler returned")
        let report = try XCTUnwrap(
            NativeCrashReport.parse(Data(contentsOf: NativeCrashHandler.reportFile(in: dir.appendingPathComponent("monitoring")))))
        XCTAssertTrue(report.suppressed)
        await BugCapsule.resetForTesting()

        StubBackend.reset()
        await start(monitoring: testMonitoringOptions(nativeCrashes: true))
        await flushUntil { !StubBackend.items("event").isEmpty }
        let events = StubBackend.items("event")
        XCTAssertEqual(events.count, 1, "no second event for the SIGABRT that followed")
        let value = events[0]["exception"]?["values"]?.arrayValue?.last
        XCTAssertEqual(events[0]["level"], "fatal")
        XCTAssertEqual(value?["type"], "NSInvalidArgumentException")
        XCTAssertEqual(value?["value"], "bad cart token=[REDACTED]")
        XCTAssertEqual(value?["mechanism"]?["type"], "nsexception")
        XCTAssertEqual(value?["mechanism"]?["handled"], false)
        XCTAssertEqual(StubBackend.items("session").first { $0["sid"]?.stringValue == sid }?["status"], "crashed")
    }

    // MARK: tracing

    func testTracePropagationAndHTTPSpans() async throws {
        let net = BugCapsuleURLSession()
        await start(
            mode: .qa, monitoring: testMonitoringOptions(tracesSampleRate: 1, targets: ["shop.test/api/cart"]),
            integrations: [net])
        FakeServerProtocol.routes["/api/cart"] = .init()
        FakeServerProtocol.routes["/api/other"] = .init()
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeServerProtocol.self]
        BugCapsule.instrument(c)
        let urlSession = URLSession(configuration: c)

        let t = try XCTUnwrap(BugCapsule.startTransaction(name: "checkout", op: "task", bindToScope: true))
        var req = URLRequest(url: URL(string: "https://shop.test/api/cart")!)
        req.setValue("vendor=1", forHTTPHeaderField: "baggage")
        _ = try await urlSession.data(for: req)
        _ = try await urlSession.data(from: URL(string: "https://shop.test/api/other")!)
        t.finish()

        func header(_ i: Int, _ name: String) -> String? {
            FakeServerProtocol.headers[i].first { $0.key.lowercased() == name }?.value
        }
        let traceparent = try XCTUnwrap(header(0, "traceparent"))
        let parts = traceparent.split(separator: "-").map(String.init)
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts[0], "00")
        XCTAssertEqual(parts[1], t.traceId)
        XCTAssertEqual(parts[3], "01")
        let baggage = try XCTUnwrap(header(0, "baggage"))
        XCTAssertTrue(baggage.hasPrefix("vendor=1,"), "existing baggage kept")
        XCTAssertTrue(baggage.contains("bugcapsule-trace_id=\(t.traceId)"))
        XCTAssertTrue(baggage.contains("bugcapsule-release=com.shop.app@1.4.0+52"))
        XCTAssertTrue(baggage.contains("bugcapsule-environment=qa"))
        XCTAssertTrue(baggage.contains("bugcapsule-sampled=true"))
        XCTAssertTrue(baggage.contains("bugcapsule-sample_rate=1"))
        XCTAssertNil(header(1, "traceparent"), "not a propagation target")

        // Capsule data is untouched: the key and recorded headers ignore trace headers.
        let http = BugCapsuleSession.current!.recorderForTesting!.window().events.filter { $0.type == EventTypes.http }
        XCTAssertEqual(http.first?.data["key"], "GET shop.test/api/cart")
        XCTAssertNil(http.first?.data["requestHeaders"]?["traceparent"])

        await flushUntil { !StubBackend.items("transaction").isEmpty }
        let tx = try XCTUnwrap(StubBackend.items("transaction").first)
        XCTAssertEqual(tx["traceId"]?.stringValue, t.traceId)
        XCTAssertEqual(tx["name"], "checkout")
        XCTAssertEqual(tx["op"], "task")
        XCTAssertEqual(tx["release"], "com.shop.app@1.4.0+52")
        let spans = try XCTUnwrap(tx["spans"]?.arrayValue)
        let cart = try XCTUnwrap(spans.first { $0["description"] == "GET https://shop.test/api/cart" })
        XCTAssertEqual(cart["op"], "http.client")
        XCTAssertEqual(cart["spanId"]?.stringValue, parts[2], "traceparent carries the http.client span")
        XCTAssertEqual(cart["parentSpanId"]?.stringValue, t.spanId)
        XCTAssertEqual(cart["status"], "ok")
        XCTAssertEqual(cart["data"]?["http.response.status_code"], 200)
        XCTAssertEqual(spans.count, 2)
    }

    func testHTTPBreadcrumbsAndSpansWithoutRecording() async throws {
        let net = BugCapsuleURLSession()
        await start(monitoring: testMonitoringOptions(tracesSampleRate: 1), integrations: [net])
        XCTAssertFalse(BugCapsule.isRecording)
        FakeServerProtocol.routes["/api/cart"] = .init(status: 503)
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeServerProtocol.self]
        BugCapsule.instrument(c)
        let urlSession = URLSession(configuration: c)
        let result: Int = try await BugCapsule.startSpan(name: "load cart", op: "task") { _ in
            let (_, r) = try await urlSession.data(from: URL(string: "https://shop.test/api/cart?token=secret")!)
            return (r as? HTTPURLResponse)?.statusCode ?? 0
        }
        XCTAssertEqual(result, 503)
        XCTAssertNil(FakeServerProtocol.headers[0]["traceparent"], "no targets on mobile by default")
        _ = BugCapsule.captureMessage("after request")
        await flushUntil { !StubBackend.items("event").isEmpty && !StubBackend.items("transaction").isEmpty }
        let crumbs = StubBackend.items("event").first?["breadcrumbs"]?.arrayValue ?? []
        let http = try XCTUnwrap(crumbs.first { $0["type"] == "http" })
        XCTAssertEqual(http["data"]?["status_code"], 503)
        XCTAssertEqual(http["data"]?["url"], "https://shop.test/api/cart?token=[REDACTED]")
        XCTAssertEqual(http["level"], "warning")
        let tx = try XCTUnwrap(StubBackend.items("transaction").first)
        XCTAssertEqual(tx["name"], "load cart")
        let span = try XCTUnwrap(tx["spans"]?.arrayValue?.first)
        XCTAssertEqual(span["status"], "unavailable")
        XCTAssertEqual(span["data"]?["url"], "https://shop.test/api/cart?token=[REDACTED]")
    }

    func testSamplingAndContinueTrace() async throws {
        await start(monitoring: testMonitoringOptions(tracesSampleRate: 0))
        let unsampled = try XCTUnwrap(BugCapsule.startTransaction(name: "a", op: "task"))
        XCTAssertFalse(unsampled.sampled)
        unsampled.finish()
        let incoming = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
        BugCapsule.continueTrace(traceparent: incoming, baggage: "bugcapsule-sampled=true")
        let t = try XCTUnwrap(BugCapsule.startTransaction(name: "b", op: "task", bindToScope: true))
        XCTAssertEqual(t.traceId, "4bf92f3577b34da6a3ce929d0e0e4736")
        XCTAssertEqual(t.parentSpanId, "00f067aa0ba902b7")
        XCTAssertTrue(t.sampled, "the incoming decision is propagated")
        XCTAssertTrue(BugCapsule.getTraceparent()?.hasPrefix("00-4bf92f3577b34da6a3ce929d0e0e4736-\(t.spanId)-01") ?? false)
        _ = BugCapsule.captureMessage("in trace")
        t.finish()
        await flushUntil { !StubBackend.items("transaction").isEmpty && !StubBackend.items("event").isEmpty }
        XCTAssertEqual(StubBackend.items("transaction").map { $0["name"] }, ["b"], "unsampled transactions are not sent")
        XCTAssertEqual(StubBackend.items("event").first?["contexts"]?["trace"]?["spanId"]?.stringValue, t.spanId)
    }

    func testScreenAndAppStartTransactions() async throws {
        await start(monitoring: testMonitoringOptions(tracesSampleRate: 1))
        monitoring.idleTimeout = 0.1
        monitoring.screenWillAppear("/product/42")
        let processStart = try XCTUnwrap(DeviceInfo.processStart)
        monitoring.appStartEnded(at: processStart.addingTimeInterval(1.5))
        await flushUntil { StubBackend.items("transaction").count >= 2 }
        let txs = StubBackend.items("transaction")
        let screen = try XCTUnwrap(txs.first { $0["op"] == "ui.load" })
        XCTAssertEqual(screen["name"], "/product/:id", "no ids in transaction names")
        XCTAssertNotNil(screen["measurements"]?["time_to_initial_display"]?["value"]?.doubleValue)
        XCTAssertTrue(screen["spans"]?.arrayValue?.contains { $0["op"] == "ui.load.initial_display" } ?? false)
        let appStart = try XCTUnwrap(txs.first { $0["op"]?.stringValue?.hasPrefix("app.start.") ?? false })
        XCTAssertEqual(appStart["op"], "app.start.cold")
        let ms = try XCTUnwrap(appStart["measurements"]?["app_start_cold"]?["value"]?.doubleValue)
        XCTAssertEqual(ms, 1500, accuracy: 1)
        XCTAssertEqual(appStart["measurements"]?["app_start_cold"]?["unit"], "millisecond")
    }

    // MARK: feedback, hangs

    func testFeedbackLinksToEvent() async throws {
        await start()
        let eventId = BugCapsule.captureMessage("Checkout broken")
        XCTAssertNil(BugCapsule.captureFeedback(message: "   "))
        let id = BugCapsule.captureFeedback(
            message: "Checkout button did nothing", name: "Ana", email: "ana@example.com", associatedEventId: eventId)
        XCTAssertNotNil(id)
        await flushUntil { !StubBackend.items("feedback").isEmpty }
        let f = try XCTUnwrap(StubBackend.items("feedback").first)
        XCTAssertEqual(f["feedbackId"]?.stringValue, id)
        XCTAssertEqual(f["eventId"]?.stringValue, eventId)
        XCTAssertEqual(f["message"], "Checkout button did nothing")
        XCTAssertEqual(f["name"], "Ana")
        XCTAssertEqual(f["email"], "ana@example.com")
        XCTAssertEqual(f["runtime"], "ios")
        XCTAssertEqual(f["contexts"]?["trace"]?["traceId"]?.stringValue?.count, 32)
    }

    func testSubmitFeedbackInQAWritesLinkedCapsule() async throws {
        await start(mode: .qa)
        BugCapsule.fail("checkout.stuck")
        let id = await BugCapsule.submitFeedback(message: "Stuck on checkout")
        XCTAssertNotNil(id)
        await flushUntil { !StubBackend.items("feedback").isEmpty }
        let f = try XCTUnwrap(StubBackend.items("feedback").first)
        let capsuleId = try XCTUnwrap(f["capsuleId"]?.stringValue)
        XCTAssertTrue(BugCapsule.savedCaptures().contains { $0.lastPathComponent == "\(capsuleId).bugcapsule" })
        XCTAssertEqual(f["eventId"]?.stringValue, BugCapsule.lastEventId())
    }

    func testAppHangIsReportedOnce() async throws {
        var options = testMonitoringOptions()
        options.enableAppHangTracking = true
        options.appHangTimeout = 0.2
        await start(monitoring: options)
        if NativeCrashHandler.debuggerAttached { throw XCTSkip("the watchdog is off under a debugger") }
        try await Task.sleep(nanoseconds: 300_000_000)
        blockCurrentThread(0.9)  // the main thread
        await flushUntil { !StubBackend.items("event").isEmpty }
        let hangs = StubBackend.items("event").filter {
            $0["exception"]?["values"]?.arrayValue?.last?["type"] == "App Hanging"
        }
        XCTAssertEqual(hangs.count, 1)
        let value = hangs[0]["exception"]?["values"]?.arrayValue?.last
        XCTAssertEqual(value?["mechanism"]?["type"], "app_hang")
        XCTAssertEqual(value?["value"], "App hanging for at least 200 ms.")
        let main = try XCTUnwrap(hangs[0]["threads"]?.arrayValue?.first)
        XCTAssertEqual(main["name"], "main")
        XCTAssertFalse(main["stacktrace"]?["frames"]?.arrayValue?.isEmpty ?? true, "main thread sampled")
    }

    func testMonitoringIsOffInReplayAndWhenDisabled() async throws {
        let session = BugCapsuleSession(
            config: BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .debug), integrations: [], overrides: nil)
        _ = session.startReplayForTesting(capsule: makeCapsule(), settings: ReplaySettings())
        XCTAssertNil(session.monitoring)
        XCTAssertFalse(session.isObserving)
        await session.dispose()

        await start(monitoring: .disabled)
        XCTAssertNil(BugCapsuleSession.current?.monitoring)
        XCTAssertNil(BugCapsule.captureMessage("x"))
    }
}

func blockCurrentThread(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

/// Units below the session: transport, outbox, parsing, redaction, health.
final class MonitoringUnitTests: XCTestCase {
    override func setUp() { StubBackend.reset() }

    func testEnvelopeTransportStatuses() async throws {
        let client = stubTransport()
        let body = Data(#"{"items":[]}"#.utf8)
        StubBackend.envelopeResponses = [
            .init(status: 200, body: Data(#"{"accepted":1,"rejected":[{"index":1,"reason":"bad sid"}]}"#.utf8)),
            .init(status: 429, headers: ["Retry-After": "120"]),
            .init(status: 503, headers: ["Retry-After": "7"]),
            .init(status: 413, body: Data(#"{"code":"payload_too_large"}"#.utf8)),
            .init(status: 403, body: Data(#"{"code":"capture_disabled"}"#.utf8)),
        ]
        let ok = await client.sendEnvelope(body, gzipped: false)
        XCTAssertEqual(ok.status, .uploaded, "rejected items are never retried")
        let limited = await client.sendEnvelope(body, gzipped: false)
        XCTAssertEqual(limited.status, .retryLater)
        XCTAssertEqual(limited.retryAfter, 120)
        let unavailable = await client.sendEnvelope(body, gzipped: true)
        XCTAssertEqual(unavailable.status, .retryLater)
        XCTAssertEqual(unavailable.retryAfter, 7)
        let tooLarge = await client.sendEnvelope(body, gzipped: false)
        XCTAssertEqual(tooLarge.status, .rejected)
        let disabled = await client.sendEnvelope(body, gzipped: false)
        XCTAssertEqual(disabled.status, .rejected)
        XCTAssertEqual(disabled.message, "capture_disabled")
        let reqs = StubBackend.requests("/v1/envelope")
        XCTAssertNil(reqs[0].header("Content-Encoding"))
        XCTAssertEqual(reqs[2].header("Content-Encoding"), "gzip")
    }

    func testEnvelopeOutboxLimitsAndBackoff() async throws {
        let clock = TestClock()
        let dir = tempDirectory()
        let box = UploadOutbox(
            directory: dir, limits: OutboxLimits(maxCount: 30, maxBytes: 5 * 1024 * 1024), fileExtension: "envelope",
            now: { clock.now }, random: { 0.5 })
        for _ in 0..<35 {
            let ok = await box.enqueue(capsuleId: uuidV4(), bytes: try Gzip.compress(Data("{}".utf8)))
            XCTAssertTrue(ok)
            clock.advance(1)
        }
        let count = await box.entries().count
        XCTAssertEqual(count, 30, "30 envelopes by default")
        XCTAssertTrue(UploadOutbox.entries(in: dir).isEmpty, "capsule outbox entries are separate")
        _ = await box.flush(upload: { _ in UploadResult(.retryLater, retryAfter: 120) }, allowed: { true })
        let retryAt = await box.retryAt
        XCTAssertEqual(retryAt?.timeIntervalSince(clock.now) ?? 0, 120, accuracy: 0.01, "Retry-After honoured")
        let remaining = await box.entries().count
        XCTAssertEqual(remaining, 30)
    }

    func testPreparedEnvelopeHasSentAtAndGzipThreshold() throws {
        let small = try Gzip.compress(Data(#"{"sdk":{"name":"bugcapsule-ios"},"items":[]}"#.utf8))
        let (body, gz) = try XCTUnwrap(Monitoring.prepareForSending(small))
        XCTAssertFalse(gz)
        let doc = try JSON.parse(body)
        XCTAssertEqual(doc.objectValue?.keys.first, "sentAt")
        XCTAssertEqual(doc["sdk"]?["name"], "bugcapsule-ios")
        let big = try Gzip.compress(Data(#"{"items":[{"type":"event","payload":{"m":"\#(String(repeating: "x", count: 2000))"}}]}"#.utf8))
        let (body2, gz2) = try XCTUnwrap(Monitoring.prepareForSending(big))
        XCTAssertTrue(gz2)
        XCTAssertTrue(Gzip.isGzip(body2))
    }

    func testRemoteConfigMonitoringFields() throws {
        let c = try RemoteCaptureConfig(json: [
            "monitoringEnabled": false, "errorSampleRate": 0.25, "tracesSampleRate": 2, "sessionTracking": false,
            "maxBreadcrumbs": 50, "tracePropagationTargets": ["api.shop.com", "/^https://internal/"],
            "storeIpAddresses": true, "apdexThresholdMs": 300,
        ])
        XCTAssertFalse(c.monitoringEnabled)
        XCTAssertEqual(c.errorSampleRate, 0.25)
        XCTAssertEqual(c.tracesSampleRate, 1, "clamped")
        XCTAssertFalse(c.sessionTracking)
        XCTAssertEqual(c.maxBreadcrumbs, 50)
        XCTAssertEqual(c.tracePropagationTargets, ["api.shop.com", "/^https://internal/"])
        XCTAssertEqual(try RemoteCaptureConfig(json: c.json.objectValue!), c, "cache round trip")
        let defaults = try RemoteCaptureConfig(json: [:])
        XCTAssertTrue(defaults.monitoringEnabled)
        XCTAssertNil(defaults.errorSampleRate)
        XCTAssertNil(defaults.tracePropagationTargets, "null: the app's list applies")
        XCTAssertThrowsError(try RemoteCaptureConfig(json: ["tracePropagationTargets": "x"]))
        XCTAssertThrowsError(try RemoteCaptureConfig(json: ["monitoringEnabled": "no"]))
    }

    func testPropagationTargetsMatching() {
        XCTAssertTrue(Tracer.matches("https://api.shop.com/cart", targets: ["api.shop.com"]))
        XCTAssertTrue(Tracer.matches("https://internal.shop.com/x", targets: ["/^https://internal\\./"]))
        XCTAssertFalse(Tracer.matches("https://cdn.shop.com/x", targets: ["api.shop.com", "/^https://internal/"]))
        XCTAssertFalse(Tracer.matches("https://api.shop.com", targets: []))
        XCTAssertEqual(SpanStatus.fromHTTP(404), .notFound)
        XCTAssertEqual(SpanStatus.fromHTTP(429), .resourceExhausted)
        XCTAssertEqual(SpanStatus.fromHTTP(204), .ok)
        XCTAssertEqual(SpanStatus.fromHTTP(502), .internalError)
    }

    func testNativeReportParsing() throws {
        let context = #"{"release":"r@1+2","tags":{"screen":"cart"}}"#
        let images = #"[{"type":"macho","debugId":"6a1b0c6e-0000-4000-8000-000000000001","codeFile":"/x/Shop.app/Shop","imageAddr":"0x104578000","imageSize":4096000,"imageVmAddr":"0x100000000","arch":"arm64"}]"#
        let text = """
            BCCRASH 1
            kind mach
            signal 0
            code 0
            addr 0x10
            exception 1
            exceptionCode 0x1
            exceptionSubcode 0x10
            time 1792592590
            suppressed 0
            frame 0x1045a0c3c
            frame 0x1045a0d00
            context \(context.utf8.count)
            \(context)
            images \(images.utf8.count)
            \(images)
            end

            """
        let r = try XCTUnwrap(NativeCrashReport.parse(Data(text.utf8)))
        XCTAssertTrue(r.isMach)
        XCTAssertEqual(r.frames, [0x1045a0c3c, 0x1045a0d00])
        XCTAssertEqual(r.time, Date(timeIntervalSince1970: 1_792_592_590))
        XCTAssertEqual(r.context?["tags"]?["screen"], "cart")
        XCTAssertEqual(r.images.first?.debugId, "6a1b0c6e-0000-4000-8000-000000000001")
        XCTAssertEqual(r.description.type, "EXC_BAD_ACCESS")
        XCTAssertEqual(r.description.mechanism, "mach_exception")
        XCTAssertTrue(r.description.value.contains("0x10"))
        XCTAssertNil(NativeCrashReport.parse(Data("garbage".utf8)))

        let stack = StackBuilder(options: BugCapsuleMonitoringOptions())
        let (frames, used) = stack.frames(
            r.frames, firstIsPC: true, resolve: { a in r.images.first { $0.contains(a) } }, symbol: { _, _ in nil })
        XCTAssertEqual(frames.last?["instructionAddr"], "0x1045a0c3c", "crashing frame last, exact pc")
        XCTAssertEqual(frames.first?["instructionAddr"], "0x1045a0cff", "callers point into the call instruction")
        XCTAssertEqual(frames.first?["package"], "/x/Shop.app/Shop")
        XCTAssertEqual(used.map(\.debugId), ["6a1b0c6e-0000-4000-8000-000000000001"])
    }

    func testLiveDebugImagesAndSymbols() throws {
        let address = try XCTUnwrap(Thread.callStackReturnAddresses.first?.uint64Value)
        let image = try XCTUnwrap(DebugImageCache.shared.image(containing: address))
        XCTAssertTrue(image.contains(address))
        XCTAssertNotNil(UUID(uuidString: image.debugId))
        XCTAssertEqual(image.debugId, image.debugId.lowercased())
        XCTAssertGreaterThan(image.size, 0)
        let libsystem = try XCTUnwrap(DebugImageCache.shared.all.first { $0.path.contains("libsystem_c") })
        XCTAssertEqual(DebugImageCache.shared.image(debugId: libsystem.debugId)?.loadAddress, libsystem.loadAddress)
        let strlenAddress = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "strlen"))
        XCTAssertNotNil(Symbolicator.function(at: UInt64(UInt(bitPattern: strlenAddress))))
        XCTAssertTrue(Symbolicator.demangle("$s10BugCapsule7MonitorC").contains("BugCapsule"))
    }

    func testThreadBacktraceOfAnotherThread() throws {
        final class Box: @unchecked Sendable { var frames: [UInt64] = [] }
        let box = Box()
        let port = NativeCrashHandler.currentThreadPort
        let done = DispatchSemaphore(value: 0)
        Thread {
            box.frames = NativeCrashHandler.backtrace(ofThread: port)
            done.signal()
        }.start()
        done.wait()  // this thread is parked here while it is sampled
        let frames = box.frames
        XCTAssertGreaterThan(frames.count, 1)
        XCTAssertNotNil(DebugImageCache.shared.image(containing: frames[0]))
    }

    func testItemRedactionKeepsStructure() {
        let redactor = Redactor()
        let payload: JSONObject = [
            "eventId": "8f0e0000-0000-4000-8000-000000000000", "timestamp": "2026-10-21T14:03:10.982Z",
            "release": "com.shop.app@1.4.0+52",
            "message": ["formatted": "login with Bearer abcdefghijklmnop failed"],
            "extra": ["password": "hunter2", "note": "ok"],
            "exception": [
                "values": [
                    [
                        "type": "E", "value": "token=abcdef123456",
                        "stacktrace": ["frames": [["instructionAddr": "0x1045a0c3c", "function": "main"]]],
                    ]
                ]
            ],
            "contexts": ["trace": ["traceId": "4bf92f3577b34da6a3ce929d0e0e4736", "spanId": "00f067aa0ba902b7"]],
        ]
        let out = ItemRedaction.redact(payload, redactor: redactor)
        XCTAssertEqual(out["eventId"], payload["eventId"])
        XCTAssertEqual(out["release"], payload["release"])
        XCTAssertEqual(out["message"]?["formatted"], "login with Bearer [REDACTED] failed")
        XCTAssertEqual(out["extra"]?["password"], "[REDACTED]")
        XCTAssertEqual(out["extra"]?["note"], "ok")
        let value = out["exception"]?["values"]?.arrayValue?.first
        XCTAssertEqual(value?["value"], "token=[REDACTED]")
        XCTAssertEqual(value?["stacktrace"]?["frames"]?.arrayValue?.first?["instructionAddr"], "0x1045a0c3c")
        XCTAssertEqual(out["contexts"]?["trace"]?["traceId"], "4bf92f3577b34da6a3ce929d0e0e4736")
    }

    func testReleaseHealthForegroundRuns() throws {
        final class Sink: @unchecked Sendable {
            let lock = NSLock()
            var items: [JSONObject] = []
        }
        let sink = Sink()
        let file = tempDirectory().appendingPathComponent("session.json")
        let health = ReleaseHealth(
            file: file, release: "r", environment: "production", timeout: 30, did: { "install-1" },
            emit: { p in sink.lock.locked { sink.items.append(p) } })
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        health.start(at: t0)
        health.didEnterBackground(at: t0.addingTimeInterval(10))
        health.willEnterForeground(at: t0.addingTimeInterval(20))
        XCTAssertEqual(sink.items.count, 1, "10 s in the background: same session")
        health.didEnterBackground(at: t0.addingTimeInterval(30))
        health.willEnterForeground(at: t0.addingTimeInterval(70))
        XCTAssertEqual(sink.items.count, 3)
        XCTAssertEqual(sink.items[1]["status"], "exited")
        XCTAssertEqual(sink.items[1]["timestamp"]?.stringValue, ISODate.format(t0.addingTimeInterval(30)))
        XCTAssertEqual(sink.items[1]["duration"]?.doubleValue, 30)
        XCTAssertEqual(sink.items[2]["init"], true)
        XCTAssertNotEqual(sink.items[2]["sid"], sink.items[0]["sid"])

        // Killed in the background: exited when the app went there.
        health.didEnterBackground(at: t0.addingTimeInterval(80))
        let next = ReleaseHealth(file: file, release: "r", environment: "production", timeout: 30, did: { "x" }, emit: { _ in })
        let previous = try XCTUnwrap(next.recoverPrevious(crashedAt: nil))
        XCTAssertEqual(previous["status"], "exited")
        XCTAssertEqual(previous["sid"], sink.items[2]["sid"])
        XCTAssertEqual(previous["timestamp"]?.stringValue, ISODate.format(t0.addingTimeInterval(80)))
        XCTAssertEqual(previous["init"], false)
        XCTAssertNil(next.recoverPrevious(crashedAt: nil), "reported once")
    }

    func testDefaultReleaseAndEnvironment() {
        let c = BugCapsuleConfig(appVersion: "1.4.0", appBuild: "52", appId: "com.shop.app")
        XCTAssertEqual(Monitoring.defaultRelease(c), "com.shop.app@1.4.0+52")
        XCTAssertEqual(Monitoring.defaultEnvironment(.production), "production")
        XCTAssertEqual(Monitoring.defaultEnvironment(.qa), "qa")
        XCTAssertEqual(Monitoring.defaultEnvironment(.debug), "development")
        XCTAssertEqual(Monitoring.screenName("/order/123/item/6a1b0c6e-0000-4000-8000-000000000001"), "/order/:id/item/:id")
        XCTAssertEqual(Monitoring.screenName("CartViewController"), "CartViewController")
    }

    func testMachExceptionServerInstallsAndUninstalls() throws {
        if NativeCrashHandler.debuggerAttached { throw XCTSkip("not installed under a debugger") }
        let dir = tempDirectory()
        XCTAssertTrue(NativeCrashHandler.install(directory: dir, mach: true))
        XCTAssertTrue(NativeCrashHandler.isInstalled)
        XCTAssertTrue(NativeCrashHandler.machInstalled)
        NativeCrashHandler.uninstallForTesting()
        XCTAssertFalse(NativeCrashHandler.isInstalled)
        XCTAssertFalse(NativeCrashHandler.machInstalled)
    }
}
