import Foundation
import XCTest

@testable import BugCapsule

/// Crash capture (phase 0): the release of recovered runs, all threads in
/// native reports and hangs, the arm64 leaf frame, MetricKit and the
/// embedding crash bridge.
@MainActor
final class CrashReportingTests: XCTestCase {
    var dir: URL!

    override func setUp() async throws {
        await BugCapsule.resetForTesting()
        BugCapsuleCrashBridge.resetForTesting()
        StubBackend.reset()
        dir = tempDirectory()
    }

    override func tearDown() async throws {
        await BugCapsule.resetForTesting()
        BugCapsuleCrashBridge.resetForTesting()
    }

    func start(_ monitoring: BugCapsuleMonitoringOptions, directory: URL? = nil) async {
        let config = BugCapsuleConfig(
            appVersion: "1.4.0", appBuild: "52", appId: "com.shop.app", mode: .production, backend: stubBackend,
            gitSha: "abc123", gitDirty: false, productionSampleRate: 0, monitoring: monitoring)
        BugCapsule.start(
            config,
            overrides: BugCapsuleTestOverrides(
                storageDirectory: directory ?? dir, transport: stubTransport(), random: { 0.5 }, captureSettleDelay: 0.05))
        await BugCapsule.refreshRemoteConfig()
    }

    func flushUntil(_ timeout: TimeInterval = 5, _ cond: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            await BugCapsule.flush(timeout: 2)
            if cond() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < end
    }

    var monitoring: Monitoring { BugCapsuleSession.current!.monitoring! }

    // MARK: 1. release of recovered sessions and crashes

    func testRecoveredSessionKeepsTheReleaseThatRanIt() throws {
        let file = dir.appendingPathComponent("session.json")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let old = ReleaseHealth(
            file: file, release: "com.shop.app@1.3.0+48", environment: "qa", timeout: 30, did: { "d" }, emit: { _ in })
        old.start(at: t0)
        // The app was updated, then launched again.
        let next = ReleaseHealth(
            file: file, release: "com.shop.app@1.4.0+52", environment: "production", timeout: 30, did: { "d" },
            emit: { _ in })
        let abnormal = try XCTUnwrap(next.recoverPrevious(crashedAt: nil))
        XCTAssertEqual(abnormal["status"], "abnormal")
        XCTAssertEqual(abnormal["release"], "com.shop.app@1.3.0+48")
        XCTAssertEqual(abnormal["environment"], "qa")

        old.start(at: t0)
        let crashed = try XCTUnwrap(next.recoverPrevious(crashedAt: t0.addingTimeInterval(5)))
        XCTAssertEqual(crashed["status"], "crashed")
        XCTAssertEqual(crashed["release"], "com.shop.app@1.3.0+48")
    }

    func testSessionStateWithoutReleaseFallsBackToTheCurrentRelease() throws {
        let file = dir.appendingPathComponent("session.json")
        let legacy = #"{"sid":"5c1d0000-0000-4000-8000-000000000000","did":"d","seq":1,"initSent":true,"started":"2026-10-25T10:00:00.000Z","status":"ok","errors":0,"foreground":true,"updated":"2026-10-25T10:01:00.000Z"}"#
        try Data(legacy.utf8).write(to: file)
        let next = ReleaseHealth(
            file: file, release: "com.shop.app@1.4.0+52", environment: "production", timeout: 30, did: { "d" },
            emit: { _ in })
        let previous = try XCTUnwrap(next.recoverPrevious(crashedAt: nil))
        XCTAssertEqual(previous["sid"], "5c1d0000-0000-4000-8000-000000000000")
        XCTAssertEqual(previous["release"], "com.shop.app@1.4.0+52")
        XCTAssertEqual(previous["environment"], "production")
    }

    func testNativeCrashIsAttributedToTheReleaseThatCrashed() async throws {
        var old = testMonitoringOptions(nativeCrashes: true)
        old.release = "com.shop.app@1.3.0+48"
        old.environment = "qa"
        await start(old)
        await flushUntil { !StubBackend.items("session").isEmpty }
        let sid = try XCTUnwrap(StubBackend.items("session").first?["sid"]?.stringValue)
        XCTAssertTrue(NativeCrashHandler.writeTestReport(signal: SIGSEGV))
        await BugCapsule.resetForTesting()

        StubBackend.reset()
        await start(testMonitoringOptions(nativeCrashes: true))
        await flushUntil { !StubBackend.items("event").isEmpty && StubBackend.items("session").count >= 2 }
        let crash = try XCTUnwrap(StubBackend.items("event").first)
        XCTAssertEqual(crash["release"], "com.shop.app@1.3.0+48")
        XCTAssertEqual(crash["environment"], "qa")
        let session = try XCTUnwrap(StubBackend.items("session").first { $0["sid"]?.stringValue == sid })
        XCTAssertEqual(session["status"], "crashed")
        XCTAssertEqual(session["release"], "com.shop.app@1.3.0+48")
        let current = try XCTUnwrap(StubBackend.items("session").first { $0["sid"]?.stringValue != sid })
        XCTAssertEqual(current["release"], "com.shop.app@1.4.0+52")
    }

    func testReportReleaseIsUsedWhenTheContextIsMissing() throws {
        let text = """
            BCCRASH 1
            kind signal
            signal 6
            time 1792592590
            frame 0x1045a0c3c
            release 21
            com.shop.app@1.3.0+48
            environment 2
            qa
            end

            """
        let r = try XCTUnwrap(NativeCrashReport.parse(Data(text.utf8)))
        XCTAssertNil(r.context)
        XCTAssertEqual(r.release, "com.shop.app@1.3.0+48")
        let draft = CrashEvents.draft(from: r, stack: StackBuilder(options: BugCapsuleMonitoringOptions()))
        XCTAssertEqual(draft.template?["release"], "com.shop.app@1.3.0+48")
        XCTAssertEqual(draft.template?["environment"], "qa")
    }

    // MARK: 2. all threads

    func testSyntheticMultiThreadReportIsParsedIntoThreads() throws {
        let images = #"[{"type":"macho","debugId":"6a1b0c6e-0000-4000-8000-000000000001","codeFile":"/x/Shop.app/Shop","imageAddr":"0x104578000","imageSize":4096000,"imageVmAddr":"0x100000000","arch":"arm64"},{"type":"macho","debugId":"1e4a0c6e-0000-4000-8000-0000000000a1","codeFile":"/usr/lib/system/libsystem_kernel.dylib","imageAddr":"0x1e8000000","imageSize":65536,"imageVmAddr":"0x1e8000000","arch":"arm64e"}]"#
        let text = """
            BCCRASH 1
            kind mach
            exception 1
            exceptionCode 0x1
            exceptionSubcode 0x10
            time 1792592590
            frame 0x1045a0c3c
            frame 0x1045a0d00
            thread 0 0 0 1
            tframe 0x1e8001234
            tframe 0x1045a0e00
            thread 3 1 1 0
            threadname com.shop.sync
            tframe 0x1045a0c3c
            tframe 0x1045a0d00
            thread 7 0 0 0
            threadname com.apple.uikit.eventfetch-thread
            tframe 0x1e8001000
            images \(images.utf8.count)
            \(images)
            end

            """
        let r = try XCTUnwrap(NativeCrashReport.parse(Data(text.utf8)))
        XCTAssertEqual(r.threads.count, 3)
        XCTAssertEqual(r.threads[1], ThreadSample(index: 3, name: "com.shop.sync", crashed: true, current: true, isMain: false, frames: [0x1045a0c3c, 0x1045a0d00]))

        let draft = CrashEvents.draft(from: r, stack: StackBuilder(options: BugCapsuleMonitoringOptions()))
        let threads = try XCTUnwrap(draft.threads)
        XCTAssertEqual(threads.map { $0["id"]?.intValue }, [0, 3, 7])
        XCTAssertEqual(threads[0]["name"], "main", "unnamed main thread")
        XCTAssertEqual(threads[0]["crashed"], false)
        XCTAssertEqual(threads[0]["current"], false)
        XCTAssertEqual(threads[1]["name"], "com.shop.sync")
        XCTAssertEqual(threads[1]["crashed"], true)
        XCTAssertEqual(threads[1]["current"], true)
        XCTAssertEqual(threads[2]["name"], "com.apple.uikit.eventfetch-thread")
        let main = try XCTUnwrap(threads[0]["stacktrace"]?["frames"]?.arrayValue)
        XCTAssertEqual(main.map { $0["instructionAddr"] }, ["0x1045a0dff", "0x1e8001234"], "oldest first, callers - 1")
        XCTAssertEqual(main[0]["package"], "/x/Shop.app/Shop")
        XCTAssertEqual(main[1]["package"], "/usr/lib/system/libsystem_kernel.dylib")
        let crashed = try XCTUnwrap(threads[1]["stacktrace"]?["frames"]?.arrayValue)
        XCTAssertEqual(crashed.last?["instructionAddr"], "0x1045a0c3c", "the pc is exact")
        XCTAssertEqual(
            Set(draft.images.map(\.debugId)), ["6a1b0c6e-0000-4000-8000-000000000001", "1e4a0c6e-0000-4000-8000-0000000000a1"])
        XCTAssertEqual(draft.exceptionValues?.first?["mechanism"]?["type"], "mach_exception")
    }

    func testWrittenReportHasEveryThread() throws {
        final class Gate: @unchecked Sendable {
            let parked = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
        }
        let gate = Gate()
        let worker = Thread {
            gate.parked.signal()
            gate.release.wait()
        }
        worker.name = "bc-test-worker"
        worker.start()
        gate.parked.wait()
        defer { gate.release.signal() }

        XCTAssertTrue(NativeCrashHandler.install(directory: dir, mach: false))
        defer { NativeCrashHandler.uninstallForTesting() }
        NativeCrashHandler.setRelease("com.shop.app@1.4.0+52", environment: "production")
        XCTAssertTrue(NativeCrashHandler.writeTestReport(signal: SIGSEGV))
        let r = try XCTUnwrap(NativeCrashReport.parse(Data(contentsOf: NativeCrashHandler.reportFile(in: dir))))
        XCTAssertEqual(r.release, "com.shop.app@1.4.0+52")
        XCTAssertEqual(r.environment, "production")
        XCTAssertGreaterThanOrEqual(r.threads.count, 2)
        XCTAssertLessThanOrEqual(r.threads.count, CrashEvents.maxThreads)
        XCTAssertEqual(r.threads.filter(\.crashed).count, 1)
        XCTAssertTrue(r.threads.allSatisfy { $0.frames.count <= CrashEvents.maxThreadFrames })
        let parked = try XCTUnwrap(r.threads.first { $0.name == "bc-test-worker" })
        XCTAssertFalse(parked.crashed)
        XCTAssertGreaterThan(parked.frames.count, 1, "the parked thread was walked")
        XCTAssertNotNil(DebugImageCache.shared.image(containing: parked.frames[0]))
        XCTAssertEqual(r.threads.filter(\.isMain).count, 1)
    }

    func testThreadsAreKeptUnderTheSizeLimit() {
        let frame: JSONValue = [
            "instructionAddr": "0x1045a0c3c", "imageAddr": "0x104578000", "inApp": false,
            "package": .string("/System/Library/PrivateFrameworks/" + String(repeating: "x", count: 120)),
            "function": .string(String(repeating: "f", count: 120)),
        ]
        let threads: [JSONValue] = (0..<100).map { i in
            [
                "id": .int(i), "crashed": .bool(i == 42), "current": .bool(i == 42),
                "stacktrace": ["frames": .array(Array(repeating: frame, count: 100))],
            ]
        }
        XCTAssertGreaterThan(JSON.encodeData(.array(threads)).count, CrashEvents.maxThreadsBytes)
        let fitted = CrashEvents.fit(threads)
        XCTAssertLessThanOrEqual(JSON.encodeData(.array(fitted)).count, CrashEvents.maxThreadsBytes)
        let crashed = fitted.first { $0["crashed"] == true }
        XCTAssertEqual(crashed?["stacktrace"]?["frames"]?.arrayValue?.count, 100, "the crashed thread is kept whole")
        XCTAssertGreaterThan(fitted.count, 10)
    }

    func testAppHangAttachesEveryThread() async throws {
        if NativeCrashHandler.debuggerAttached { throw XCTSkip("the watchdog is off under a debugger") }
        final class Gate: @unchecked Sendable { let release = DispatchSemaphore(value: 0) }
        let gate = Gate()
        let worker = Thread { gate.release.wait() }
        worker.name = "bc-hang-worker"
        worker.start()
        defer { gate.release.signal() }

        var options = testMonitoringOptions()
        options.enableAppHangTracking = true
        options.appHangTimeout = 0.2
        await start(options)
        try await Task.sleep(nanoseconds: 300_000_000)
        blockCurrentThread(0.9)
        await flushUntil { !StubBackend.items("event").isEmpty }
        let hang = try XCTUnwrap(
            StubBackend.items("event").first { $0["exception"]?["values"]?.arrayValue?.last?["type"] == "App Hanging" })
        let threads = try XCTUnwrap(hang["threads"]?.arrayValue)
        XCTAssertGreaterThan(threads.count, 1)
        XCTAssertEqual(threads[0]["name"], "main")
        XCTAssertEqual(threads[0]["current"], true)
        XCTAssertTrue(threads.dropFirst().allSatisfy { $0["current"] == false && $0["crashed"] == false })
        let other = try XCTUnwrap(threads.first { $0["name"] == "bc-hang-worker" })
        XCTAssertFalse(other["stacktrace"]?["frames"]?.arrayValue?.isEmpty ?? true)
    }

    // MARK: 3. arm64 leaf frame

    func testLinkRegisterIsTheFirstCallerOfALeafFunction() {
        let nop: UInt32 = 0xD503_201F
        let code = UnsafeMutablePointer<UInt32>.allocate(capacity: 64)
        defer { code.deallocate() }
        code.initialize(repeating: nop, count: 64)
        let base = UInt64(UInt(bitPattern: code))
        func at(_ i: Int) -> UInt64 { base + UInt64(i * 4) }
        func bl(from i: Int, to j: Int) -> UInt32 { 0x9400_0000 | (UInt32(bitPattern: Int32(j - i)) & 0x03FF_FFFF) }
        let outer: UInt64 = 0x1_0000_4000

        // A leaf at [32...] called from 4: lr = 5, the walk missed it.
        code[4] = bl(from: 4, to: 32)
        let pc = at(34)
        XCTAssertEqual(
            NativeCrashHandler.insertLinkRegister(pc: pc, lr: at(5), frames: [pc, outer]), [pc, at(5), outer])
        // Already the first return address.
        XCTAssertEqual(
            NativeCrashHandler.insertLinkRegister(pc: pc, lr: at(5), frames: [pc, at(5), outer]), [pc, at(5), outer])
        // Not after a call instruction: not a return address.
        XCTAssertEqual(NativeCrashHandler.insertLinkRegister(pc: pc, lr: at(9), frames: [pc, outer]), [pc, outer])
        // A call the crashing function made itself (lr between the call target and pc).
        code[18] = bl(from: 18, to: 16)
        let inner = at(24)
        XCTAssertEqual(NativeCrashHandler.insertLinkRegister(pc: inner, lr: at(19), frames: [inner, outer]), [inner, outer])
        // ... or to a function above pc.
        code[20] = bl(from: 20, to: 48)
        XCTAssertEqual(NativeCrashHandler.insertLinkRegister(pc: inner, lr: at(21), frames: [inner, outer]), [inner, outer])
        // Indirect calls (blr x8) count.
        code[40] = 0xD63F_0100
        XCTAssertEqual(
            NativeCrashHandler.insertLinkRegister(pc: pc, lr: at(41), frames: [pc, outer]), [pc, at(41), outer])
        // A full buffer drops its outermost frame.
        XCTAssertEqual(
            NativeCrashHandler.insertLinkRegister(pc: pc, lr: at(5), frames: [pc, outer, outer + 8], max: 3),
            [pc, at(5), outer])
    }

    // MARK: 4. MetricKit

    func metricKitPayload() throws -> JSONValue {
        try loadJSON(TestPaths.repo.appendingPathComponent("Tests/Fixtures/metrickit/diagnostic-payload.json"))
    }

    func testMetricKitPayloadConversion() throws {
        var options = BugCapsuleMonitoringOptions()
        options.inAppIncludes = ["ShopApp"]
        let diagnostics = MetricKitConverter.diagnostics(fromPayload: try metricKitPayload(), stack: StackBuilder(options: options))
        XCTAssertEqual(diagnostics.count, 2)

        let crash = diagnostics[0]
        XCTAssertTrue(crash.isCrash)
        XCTAssertEqual(crash.draft.level, .fatal)
        XCTAssertEqual(crash.draft.timestamp, MetricKitConverter.parseTime("2026-10-25 10:00:00"))
        let value = try XCTUnwrap(crash.draft.exceptionValues?.first)
        XCTAssertEqual(value["type"], "EXC_BAD_ACCESS")
        XCTAssertEqual(value["value"], "Namespace SIGNAL, Code 11 Segmentation fault: 11")
        XCTAssertEqual(value["mechanism"]?["type"], "metrickit")
        XCTAssertEqual(value["mechanism"]?["handled"], false)
        XCTAssertEqual(value["mechanism"]?["data"]?["signal"], 11)
        let frames = try XCTUnwrap(value["stacktrace"]?["frames"]?.arrayValue)
        XCTAssertEqual(frames.map { $0["instructionAddr"] }, ["0x18a000fff", "0x1046a0cff", "0x1046a0c3c"])
        XCTAssertEqual(frames.map { $0["inApp"] }, [false, true, true])
        XCTAssertEqual(frames[2]["imageAddr"], "0x104678000")
        let threads = try XCTUnwrap(crash.draft.threads)
        XCTAssertEqual(threads.count, 2)
        XCTAssertEqual(threads.map { $0["crashed"] }, [false, true])
        XCTAssertEqual(threads[0]["stacktrace"]?["frames"]?.arrayValue?.map { $0["instructionAddr"] }, ["0x1f0001fff", "0x1e8001234"])
        let images = crash.draft.images.map(\.json)
        XCTAssertEqual(images.count, 4, "ShopApp, UIKitCore, libsystem_kernel, libsystem_pthread")
        let app = try XCTUnwrap(images.first { $0["codeFile"] == "ShopApp" })
        XCTAssertEqual(app["type"], "macho")
        XCTAssertEqual(app["debugId"], "6a1b0c6e-0000-4000-8000-000000000001")
        XCTAssertEqual(app["imageAddr"], "0x104678000")
        XCTAssertGreaterThan(app["imageSize"]?.intValue ?? 0, 167168)
        XCTAssertEqual(
            MetricKitConverter.release(
                of: crash, current: "com.shop.app@1.4.0+52", appId: "com.shop.app", appVersion: "1.4.0", appBuild: "52",
                customRelease: false), "com.shop.app@1.3.0+48")
        XCTAssertEqual(
            MetricKitConverter.release(
                of: crash, current: "custom", appId: "com.shop.app", appVersion: "1.4.0", appBuild: "52",
                customRelease: true), "custom")

        let hang = diagnostics[1]
        XCTAssertFalse(hang.isCrash)
        XCTAssertEqual(hang.draft.level, .error)
        let hangValue = try XCTUnwrap(hang.draft.exceptionValues?.first)
        XCTAssertEqual(hangValue["type"], "App Hanging")
        XCTAssertEqual(hangValue["value"], "App hanging for 3.42 sec.")
        XCTAssertEqual(hangValue["mechanism"]?["type"], "app_hang")
    }

    func testMetricKitCrashIsDroppedWhenBugCapsuleReportedIt() async throws {
        await start(testMonitoringOptions())
        let payload = try metricKitPayload()
        let crashTime = try XCTUnwrap(MetricKitConverter.parseTime("2026-10-25 10:00:00"))
        // The native handler reported a crash 30 s apart: same crash.
        monitoring.ledger.record(crashTime.addingTimeInterval(30))
        monitoring.receiveMetricKit(payload, end: nil)
        await flushUntil { !StubBackend.items("event").isEmpty }
        var mechanisms = StubBackend.items("event").compactMap {
            $0["exception"]?["values"]?.arrayValue?.last?["mechanism"]?["type"]?.stringValue
        }
        XCTAssertEqual(mechanisms, ["app_hang"], "hang sent, crash deduplicated")

        // 2 minutes apart: another crash, sent.
        StubBackend.reset()
        let fresh = tempDirectory()
        await BugCapsule.resetForTesting()
        await start(testMonitoringOptions(), directory: fresh)
        monitoring.ledger.record(crashTime.addingTimeInterval(120))
        monitoring.receiveMetricKit(payload, end: nil)
        await flushUntil { StubBackend.items("event").count >= 2 }
        mechanisms = StubBackend.items("event").compactMap {
            $0["exception"]?["values"]?.arrayValue?.last?["mechanism"]?["type"]?.stringValue
        }
        XCTAssertEqual(Set(mechanisms), ["metrickit", "app_hang"])
        let crash = try XCTUnwrap(StubBackend.items("event").first { $0["level"] == "fatal" })
        XCTAssertEqual(crash["release"], "com.shop.app@1.3.0+48", "the build that crashed")
        XCTAssertFalse(crash["debugImages"]?.arrayValue?.isEmpty ?? true)
        XCTAssertEqual(crash["threads"]?.arrayValue?.count, 2)
    }

    func testCrashLedgerPersistsAcrossLaunches() {
        let file = dir.appendingPathComponent("crash_times.json")
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        CrashLedger(file: file).record(t)
        let next = CrashLedger(file: file)
        XCTAssertTrue(next.contains(near: t.addingTimeInterval(-59)))
        XCTAssertFalse(next.contains(near: t.addingTimeInterval(61)))
    }

    // MARK: 5. crash bridge

    func testBridgeTakePendingEventsReturnsEachCrashOnce() throws {
        XCTAssertTrue(
            BugCapsuleCrashBridge.installForTesting(
                directory: dir, release: "com.shop.app@1.3.0+48", environment: "qa",
                options: .init(appHangs: nil, metricKit: false)))
        XCTAssertEqual(CrashOwnership.current, .bridge)
        XCTAssertFalse(BugCapsuleCrashBridge.lastRunCrashed)
        XCTAssertEqual(BugCapsuleCrashBridge.takePendingEvents(), [])
        BugCapsuleCrashBridge.updateScope(
            json: #"{"tags":{"screen":"cart"},"user":{"id":"u1"},"breadcrumbs":[{"type":"default","category":"test","message":"before the crash","timestamp":"2026-10-25T10:00:00.000Z"}],"ignored":1}"#)
        XCTAssertTrue(NativeCrashHandler.writeTestReport(signal: SIGSEGV))
        // The process ends; the next one (after an update) installs again.
        BugCapsuleCrashBridge.resetForTesting()
        XCTAssertTrue(
            BugCapsuleCrashBridge.installForTesting(
                directory: dir, release: "com.shop.app@1.4.0+52", environment: "production",
                options: .init(appHangs: nil, metricKit: false)))
        XCTAssertTrue(BugCapsuleCrashBridge.lastRunCrashed)

        let events = BugCapsuleCrashBridge.takePendingEvents()
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(try JSON.parse(Data(events[0].utf8)).objectValue)
        XCTAssertNotNil(UUID(uuidString: event["eventId"]?.stringValue ?? ""))
        XCTAssertEqual(event["level"], "fatal")
        XCTAssertEqual(event["release"], "com.shop.app@1.3.0+48")
        XCTAssertEqual(event["environment"], "qa")
        XCTAssertEqual(event["tags"]?["screen"], "cart")
        XCTAssertEqual(event["user"]?["id"], "u1")
        XCTAssertNil(event["ignored"])
        XCTAssertEqual(event["breadcrumbs"]?.arrayValue?.first?["message"], "before the crash")
        XCTAssertEqual(event["exception"]?["values"]?.arrayValue?.last?["mechanism"]?["type"], "signal")
        XCTAssertNotNil(event["contexts"]?["device"])
        let threads = try XCTUnwrap(event["threads"]?.arrayValue)
        XCTAssertGreaterThan(threads.count, 1)
        XCTAssertEqual(threads.filter { $0["crashed"] == true }.count, 1)
        XCTAssertFalse(event["debugImages"]?.arrayValue?.isEmpty ?? true)

        XCTAssertEqual(BugCapsuleCrashBridge.takePendingEvents(), [], "deleted once returned")
        let pending = dir.appendingPathComponent("pending")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: pending.path), [])
    }

    func testBridgeUncaughtExceptionIsPendingOnce() throws {
        XCTAssertTrue(
            BugCapsuleCrashBridge.installForTesting(
                directory: dir, release: "r", environment: "production", options: .init(appHangs: nil, metricKit: false)))
        let exception = NSException(name: .invalidArgumentException, reason: "bad cart token=abcdef123456", userInfo: nil)
        CrashBridgeRuntime.shared.recordUncaught(exception)
        // abort() follows: its report only marks the run crashed.
        XCTAssertTrue(NativeCrashHandler.writeTestReport(signal: SIGABRT))
        BugCapsuleCrashBridge.resetForTesting()
        XCTAssertTrue(
            BugCapsuleCrashBridge.installForTesting(
                directory: dir, release: "r", environment: "production", options: .init(appHangs: nil, metricKit: false)))
        XCTAssertTrue(BugCapsuleCrashBridge.lastRunCrashed)
        let events = BugCapsuleCrashBridge.takePendingEvents().compactMap { try? JSON.parse(Data($0.utf8)) }
        XCTAssertEqual(events.count, 1)
        let value = events.first?["exception"]?["values"]?.arrayValue?.last
        XCTAssertEqual(value?["type"], "NSInvalidArgumentException")
        XCTAssertEqual(value?["value"], "bad cart token=[REDACTED]")
        XCTAssertEqual(value?["mechanism"]?["type"], "nsexception")
        let threads = try XCTUnwrap(events.first?["threads"]?.arrayValue)
        XCTAssertEqual(threads.filter { $0["crashed"] == true }.count, 1)
        XCTAssertGreaterThan(threads.count, 1)
    }

    func testBridgeMetricKitDiagnosticsArePendingAndDeduplicated() throws {
        XCTAssertTrue(
            BugCapsuleCrashBridge.installForTesting(
                directory: dir, release: "r", environment: "production", options: .init(appHangs: nil, metricKit: false)))
        let payload = try metricKitPayload()
        let crashTime = try XCTUnwrap(MetricKitConverter.parseTime("2026-10-25 10:00:00"))
        CrashBridgeRuntime.shared.receiveMetricKit(payload, end: nil)
        var events = BugCapsuleCrashBridge.takePendingEvents().compactMap { try? JSON.parse(Data($0.utf8)) }
        XCTAssertEqual(events.compactMap { $0["level"]?.stringValue }.sorted(), ["error", "fatal"])

        // A report the bridge handled at the same time: only the hang.
        BugCapsuleCrashBridge.resetForTesting()
        CrashLedger(file: dir.appendingPathComponent("crash_times.json")).record(crashTime)
        XCTAssertTrue(
            BugCapsuleCrashBridge.installForTesting(
                directory: dir, release: "r", environment: "production", options: .init(appHangs: nil, metricKit: false)))
        CrashBridgeRuntime.shared.receiveMetricKit(payload, end: nil)
        events = BugCapsuleCrashBridge.takePendingEvents().compactMap { try? JSON.parse(Data($0.utf8)) }
        XCTAssertEqual(events.compactMap { $0["level"]?.stringValue }, ["error"])
    }

    func testBridgeAndSDKNeverBothInstallTheHandlers() async throws {
        // The SDK first: the bridge stays out.
        await start(testMonitoringOptions(nativeCrashes: true))
        XCTAssertEqual(CrashOwnership.current, .sdk)
        XCTAssertFalse(
            BugCapsuleCrashBridge.installForTesting(
                directory: tempDirectory(), release: "r", environment: "e", options: .init(appHangs: nil, metricKit: false)))
        XCTAssertEqual(BugCapsuleCrashBridge.takePendingEvents(), [])
        await BugCapsule.resetForTesting()
        XCTAssertNil(CrashOwnership.current)

        // The bridge first: the SDK's monitoring skips them and leaves them installed.
        XCTAssertTrue(
            BugCapsuleCrashBridge.installForTesting(
                directory: dir, release: "r", environment: "e", options: .init(appHangs: nil, metricKit: false)))
        await start(testMonitoringOptions(nativeCrashes: true), directory: tempDirectory())
        XCTAssertEqual(CrashOwnership.current, .bridge)
        await BugCapsule.resetForTesting()
        XCTAssertTrue(NativeCrashHandler.isInstalled, "still the bridge's")
        XCTAssertEqual(CrashOwnership.current, .bridge)
    }
}
