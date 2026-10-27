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
        XCTAssertEqual(threads.map { $0["id"]?.intValue }, [3, 0, 7], "crashed first, then main")
        XCTAssertEqual(threads[0]["name"], "com.shop.sync")
        XCTAssertEqual(threads[0]["crashed"], true)
        XCTAssertEqual(threads[0]["current"], true)
        XCTAssertEqual(threads[1]["name"], "main", "unnamed main thread")
        XCTAssertEqual(threads[1]["crashed"], false)
        XCTAssertEqual(threads[1]["current"], false)
        XCTAssertEqual(threads[2]["name"], "com.apple.uikit.eventfetch-thread")
        let main = try XCTUnwrap(threads[1]["stacktrace"]?["frames"]?.arrayValue)
        XCTAssertEqual(main.map { $0["instructionAddr"] }, ["0x1045a0dff", "0x1e8001234"], "oldest first, callers - 1")
        XCTAssertEqual(main[0]["package"], "/x/Shop.app/Shop")
        XCTAssertEqual(main[1]["package"], "/usr/lib/system/libsystem_kernel.dylib")
        let crashed = try XCTUnwrap(threads[0]["stacktrace"]?["frames"]?.arrayValue)
        XCTAssertEqual(crashed.last?["instructionAddr"], "0x1045a0c3c", "the pc is exact")
        XCTAssertEqual(
            Set(draft.images.map(\.debugId)), ["6a1b0c6e-0000-4000-8000-000000000001", "1e4a0c6e-0000-4000-8000-0000000000a1"])
        XCTAssertEqual(draft.exceptionValues?.first?["mechanism"]?["type"], "mach_exception")
        assertFramesCarryTheirImage(draft)
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
        XCTAssertTrue(r.threads.allSatisfy { $0.frames.count <= 100 }, "the writer's per-thread buffer")
        let parked = try XCTUnwrap(r.threads.first { $0.name == "bc-test-worker" })
        XCTAssertFalse(parked.crashed)
        XCTAssertGreaterThan(parked.frames.count, 1, "the parked thread was walked")
        XCTAssertNotNil(DebugImageCache.shared.image(containing: parked.frames[0]))
        XCTAssertEqual(r.threads.filter(\.isMain).count, 1)
    }

    func testThreadsAreKeptWithinTheServerLimits() {
        let frame: JSONValue = [
            "instructionAddr": "0x1045a0c3c", "imageAddr": "0x104578000", "inApp": false,
            "package": .string("/System/Library/PrivateFrameworks/" + String(repeating: "x", count: 600)),
            "function": .string(String(repeating: "f", count: 600)),
        ]
        func frames(_ n: Int, mark: String) -> JSONValue {
            var list = Array(repeating: frame, count: n)
            list[n - 1] = ["instructionAddr": .string(mark)]  // the newest frame
            return ["frames": .array(list)]
        }
        let threads: [JSONValue] = (0..<120).map { i in
            [
                "id": .int(i), "crashed": .bool(i == 42), "current": .bool(i == 42),
                "stacktrace": frames(i == 42 ? 300 : 100, mark: "0x\(i)"),
            ]
        }
        let fitted = CrashEvents.fit(threads)
        XCTAssertLessThanOrEqual(fitted.count, CrashEvents.maxThreads)
        XCTAssertLessThanOrEqual(JSON.encodeData(.array(fitted)).count, CrashEvents.maxThreadsBytes)
        let counts = fitted.map { $0["stacktrace"]?["frames"]?.arrayValue?.count ?? 0 }
        XCTAssertLessThanOrEqual(counts.reduce(0, +), CrashEvents.maxTotalFrames)
        let crashed = try? XCTUnwrap(fitted.first { $0["crashed"] == true })
        XCTAssertEqual(crashed?["stacktrace"]?["frames"]?.arrayValue?.count, 250, "the crashed thread is served first")
        XCTAssertEqual(crashed?["stacktrace"]?["frames"]?.arrayValue?.last?["instructionAddr"], "0x42", "newest frames kept")
        for t in fitted where t["crashed"] != true {
            let f = t["stacktrace"]?["frames"]?.arrayValue ?? []
            XCTAssertLessThanOrEqual(f.count, 40)
            if let last = f.last { XCTAssertEqual(last["instructionAddr"], .string("0x\(t["id"]!.intValue!)")) }
        }
        XCTAssertEqual(fitted.first?["id"], 0, "threads are dropped from the end")
    }

    func testThreadsListTheCrashedThreadThenMain() {
        let samples = [
            ThreadSample(index: 0, name: nil, crashed: false, current: false, isMain: true, frames: [0x10, 0x20]),
            ThreadSample(index: 1, name: "a", crashed: false, current: false, isMain: false, frames: [0x10]),
            ThreadSample(index: 5, name: "b", crashed: true, current: true, isMain: false, frames: Array(repeating: 0x10, count: 300)),
        ]
        let (threads, _) = CrashEvents.threads(
            samples, stack: StackBuilder(options: BugCapsuleMonitoringOptions()), resolve: { _ in nil })
        XCTAssertEqual(threads.map { $0["id"]?.intValue }, [5, 0, 1])
        XCTAssertEqual(threads[0]["stacktrace"]?["frames"]?.arrayValue?.count, 250)
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
        XCTAssertEqual(threads[0]["crashed"], true, "the hung thread")
        XCTAssertTrue(threads.allSatisfy { $0["current"] == false }, "the watchdog sampled them")
        XCTAssertTrue(threads.dropFirst().allSatisfy { $0["crashed"] == false })
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
        XCTAssertEqual(value["mechanism"]?["data"]?["source"], "metrickit")
        XCTAssertEqual(crash.pid, 3021)
        assertFramesCarryTheirImage(crash.draft)
        let frames = try XCTUnwrap(value["stacktrace"]?["frames"]?.arrayValue)
        XCTAssertEqual(frames.map { $0["instructionAddr"] }, ["0x18a000fff", "0x1046a0cff", "0x1046a0c3c"])
        XCTAssertEqual(frames.map { $0["inApp"] }, [false, true, true])
        XCTAssertEqual(frames[2]["imageAddr"], "0x104678000")
        let threads = try XCTUnwrap(crash.draft.threads)
        XCTAssertEqual(threads.count, 2)
        XCTAssertEqual(threads.map { $0["crashed"] }, [true, false], "crashed first")
        XCTAssertEqual(threads[1]["stacktrace"]?["frames"]?.arrayValue?.map { $0["instructionAddr"] }, ["0x1f0001fff", "0x1e8001234"])
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
        XCTAssertEqual(hangValue["mechanism"]?["data"]?["source"], "metrickit")
    }

    func testMetricKitCallTreesAreCapped() throws {
        func chain(_ depth: Int) -> JSONValue {
            var frame: JSONValue = [
                "binaryUUID": "6A1B0C6E-0000-4000-8000-000000000001", "offsetIntoBinaryTextSegment": 4096,
                "binaryName": "ShopApp", "address": 4_369_026_108,
            ]
            for _ in 1..<depth {
                frame = [
                    "binaryUUID": "6A1B0C6E-0000-4000-8000-000000000001", "offsetIntoBinaryTextSegment": 4096,
                    "binaryName": "ShopApp", "address": 4_369_026_108, "subFrames": [frame],
                ]
            }
            return frame
        }
        let stacks: [JSONValue] = (0..<120).map { i in
            ["threadAttributed": .bool(i == 3), "callStackRootFrames": [chain(i == 3 ? 300 : 60)]]
        }
        let payload: JSONValue = [
            "timeStampEnd": "2026-10-25 10:00:00",
            "crashDiagnostics": [["diagnosticMetaData": ["signal": 11], "callStackTree": ["callStacks": .array(stacks)]]],
        ]
        let d = try XCTUnwrap(
            MetricKitConverter.diagnostics(fromPayload: payload, stack: StackBuilder(options: BugCapsuleMonitoringOptions())).first)
        XCTAssertEqual(d.draft.exceptionValues?.first?["stacktrace"]?["frames"]?.arrayValue?.count, 250)
        let threads = try XCTUnwrap(d.draft.threads)
        XCTAssertLessThanOrEqual(threads.count, 100)
        XCTAssertEqual(threads[0]["crashed"], true)
        XCTAssertEqual(threads[0]["stacktrace"]?["frames"]?.arrayValue?.count, 250)
        XCTAssertTrue(threads.dropFirst().allSatisfy { ($0["stacktrace"]?["frames"]?.arrayValue?.count ?? 0) <= 40 })
        XCTAssertLessThanOrEqual(
            threads.map { $0["stacktrace"]?["frames"]?.arrayValue?.count ?? 0 }.reduce(0, +), CrashEvents.maxTotalFrames)
    }

    /// Every resolved frame names its image by `imageAddr`, and every image has a size.
    func assertFramesCarryTheirImage(_ d: EventDraft, file: StaticString = #filePath, line: UInt = #line) {
        let images = Dictionary(d.images.map { (hex($0.loadAddress), $0) }, uniquingKeysWith: { a, _ in a })
        let frames =
            (d.exceptionValues ?? []).flatMap { $0["stacktrace"]?["frames"]?.arrayValue ?? [] }
            + (d.threads ?? []).flatMap { $0["stacktrace"]?["frames"]?.arrayValue ?? [] }
        XCTAssertFalse(frames.isEmpty, file: file, line: line)
        for f in frames where f["package"] != nil {
            let image = f["imageAddr"]?.stringValue.flatMap { images[$0] }
            XCTAssertNotNil(image, "frame \(f) has no image", file: file, line: line)
            if let image, let addr = parseHex(f["instructionAddr"]?.stringValue) {
                XCTAssertTrue(image.contains(addr), file: file, line: line)
            }
        }
        XCTAssertTrue(d.images.allSatisfy { $0.json["imageSize"]?.intValue ?? 0 > 0 }, file: file, line: line)
    }

    func mechanisms() -> [String] {
        StubBackend.items("event").compactMap {
            $0["exception"]?["values"]?.arrayValue?.last?["mechanism"]?["type"]?.stringValue
        }.sorted()
    }

    func testMetricKitDiagnosticsBugCapsuleReportedAreDropped() async throws {
        let payload = try metricKitPayload()
        let crashTime = try XCTUnwrap(MetricKitConverter.parseTime("2026-10-25 10:00:00"))
        await start(testMonitoringOptions())
        // The native handler reported a crash 30 s apart, and the watchdog this hang.
        monitoring.ledger.record(.crash, at: crashTime.addingTimeInterval(30), pid: nil)
        monitoring.ledger.record(.hang, at: crashTime.addingTimeInterval(-20), pid: nil)
        monitoring.receiveMetricKit(payload, end: nil)
        await BugCapsule.flush(timeout: 2)
        XCTAssertEqual(StubBackend.items("event").count, 0, "both already reported")

        // 2 minutes apart: another crash and hang, sent.
        await BugCapsule.resetForTesting()
        StubBackend.reset()
        await start(testMonitoringOptions(), directory: tempDirectory())
        monitoring.ledger.record(.crash, at: crashTime.addingTimeInterval(120), pid: nil)
        monitoring.receiveMetricKit(payload, end: nil)
        await flushUntil { StubBackend.items("event").count >= 2 }
        XCTAssertEqual(mechanisms(), ["app_hang", "metrickit"])
        let crash = try XCTUnwrap(StubBackend.items("event").first { $0["level"] == "fatal" })
        XCTAssertEqual(crash["release"], "com.shop.app@1.3.0+48", "the build that crashed")
        XCTAssertNil(crash["contexts"]?["app"], "not this launch's app context")
        XCTAssertNotNil(crash["contexts"]?["device"])
        XCTAssertFalse(crash["debugImages"]?.arrayValue?.isEmpty ?? true)
        XCTAssertEqual(crash["threads"]?.arrayValue?.count, 2)
    }

    func testMetricKitEventsAreInTheOutboxBeforeReturning() async throws {
        await start(testMonitoringOptions())
        StubBackend.envelopeResponses = []
        monitoring.receiveMetricKit(try metricKitPayload(), end: nil)
        let queued = UploadOutbox.entries(in: dir.appendingPathComponent("envelopes"), fileExtension: "envelope")
        XCTAssertFalse(queued.isEmpty, "written synchronously")
    }

    func testCrashLedgerMatchesByProcessThenTime() {
        let file = dir.appendingPathComponent("crash_times.json")
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        CrashLedger(file: file).record(.crash, at: t, pid: 3021)
        CrashLedger(file: file).record(.hang, at: t, pid: nil)
        let next = CrashLedger(file: file)
        // Same process, anywhere in the payload's window.
        XCTAssertTrue(next.contains(.crash, pid: 3021, from: t.addingTimeInterval(-3600), to: t.addingTimeInterval(3600)))
        // Another process at the same time is another crash.
        XCTAssertFalse(next.contains(.crash, pid: 4000, from: t, to: t))
        // No pid: 60 s around the diagnostic.
        XCTAssertTrue(next.contains(.crash, pid: nil, from: t, to: t.addingTimeInterval(59)))
        XCTAssertFalse(next.contains(.crash, pid: nil, from: t, to: t.addingTimeInterval(61)))
        XCTAssertTrue(next.contains(.hang, pid: 1, from: t, to: t.addingTimeInterval(30)))
        XCTAssertFalse(next.contains(.hang, pid: nil, from: t, to: t.addingTimeInterval(300)))
    }

    // MARK: 5. crash bridge

    let noWatchers = BugCapsuleCrashBridge.Options(appHangs: nil, metricKit: false)

    func install(_ release: String = "r", environment: String = "production", directory: URL? = nil) -> Bool {
        BugCapsuleCrashBridge.installForTesting(
            directory: directory ?? dir, release: release, environment: environment, options: noWatchers)
    }

    func pending() -> [JSONValue] {
        BugCapsuleCrashBridge.takePendingEvents().compactMap { try? JSON.parse(Data($0.utf8)) }
    }

    func testBridgeTakePendingEventsReturnsEachCrashOnce() throws {
        XCTAssertTrue(install("com.shop.app@1.3.0+48", environment: "qa"))
        XCTAssertEqual(CrashOwnership.current, .bridge)
        XCTAssertTrue(BugCapsuleCrashBridge.nativeCrashHandlerInstalled)
        XCTAssertFalse(BugCapsuleCrashBridge.lastRunCrashed)
        XCTAssertEqual(BugCapsuleCrashBridge.takePendingEvents(), [])
        BugCapsuleCrashBridge.updateScope(
            json: #"{"tags":{"screen":"cart"},"user":{"id":"u1"},"breadcrumbs":[{"type":"default","category":"test","message":"before the crash","timestamp":"2026-10-25T10:00:00.000Z"}],"ignored":1}"#)
        XCTAssertTrue(NativeCrashHandler.writeTestReport(signal: SIGSEGV))
        // The process ends; the next one (after an update) installs again.
        BugCapsuleCrashBridge.resetForTesting()
        XCTAssertTrue(install("com.shop.app@1.4.0+52"))
        XCTAssertTrue(BugCapsuleCrashBridge.lastRunCrashed)

        let events = pending()
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertNotNil(UUID(uuidString: event["eventId"]?.stringValue ?? ""))
        XCTAssertEqual(event["level"], "fatal")
        XCTAssertEqual(event["runtime"], "ios")
        XCTAssertEqual(event["release"], "com.shop.app@1.3.0+48")
        XCTAssertEqual(event["environment"], "qa")
        XCTAssertEqual(event["tags"]?["screen"], "cart")
        XCTAssertEqual(event["user"]?["id"], "u1")
        XCTAssertNil(event["ignored"])
        XCTAssertNil(event["pid"], "process id stays in the scope mirror")
        XCTAssertEqual(event["breadcrumbs"]?.arrayValue?.first?["message"], "before the crash")
        XCTAssertEqual(event["exception"]?["values"]?.arrayValue?.last?["mechanism"]?["type"], "signal")
        XCTAssertNil(event["contexts"]?["device"], "the embedding SDK adds device contexts")
        let threads = try XCTUnwrap(event["threads"]?.arrayValue)
        XCTAssertGreaterThan(threads.count, 1)
        XCTAssertEqual(threads.first?["crashed"], true)
        XCTAssertEqual(threads.filter { $0["crashed"] == true }.count, 1)
        XCTAssertFalse(event["debugImages"]?.arrayValue?.isEmpty ?? true)

        XCTAssertEqual(BugCapsuleCrashBridge.takePendingEvents(), [], "deleted once returned")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("events").path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("reports").path), [])
    }

    func testBridgeUsesTheReportScopeOnlyForItsOwnProcess() throws {
        func report(contextPid: Int, pid: Int) -> String {
            let context = #"{"pid":\#(contextPid),"release":"old@1","environment":"qa","tags":{"screen":"cart"}}"#
            return """
                BCCRASH 1
                kind signal
                signal 11
                time 1792592590
                pid \(pid)
                frame 0x1045a0c3c
                context \(context.utf8.count)
                \(context)
                end

                """
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(report(contextPid: 41, pid: 41).utf8).write(to: NativeCrashHandler.reportFile(in: dir))
        XCTAssertTrue(install())
        var event = try XCTUnwrap(pending().first)
        XCTAssertEqual(event["tags"]?["screen"], "cart")
        XCTAssertEqual(event["release"], "old@1")

        BugCapsuleCrashBridge.resetForTesting()
        try Data(report(contextPid: 7, pid: 41).utf8).write(to: NativeCrashHandler.reportFile(in: dir))
        BugCapsuleCrashBridge.updateScope(json: #"{"tags":{"screen":"now"}}"#)
        XCTAssertTrue(install())
        BugCapsuleCrashBridge.updateScope(json: #"{"tags":{"screen":"now"}}"#)
        event = try XCTUnwrap(pending().first)
        XCTAssertNil(event["tags"], "another process's scope: none, never this one's")
    }

    func testBridgeKeepsAReportUntilItsEventIsStored() throws {
        XCTAssertTrue(install())
        XCTAssertTrue(NativeCrashHandler.writeTestReport(signal: SIGSEGV))
        BugCapsuleCrashBridge.resetForTesting()
        // The events folder can't be written (a crash-on-launch loop, a full disk).
        let events = dir.appendingPathComponent("events")
        try FileManager.default.removeItem(at: events)
        try Data().write(to: events)
        XCTAssertTrue(install())
        XCTAssertEqual(BugCapsuleCrashBridge.takePendingEvents(), [])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("reports").path).count, 1,
            "kept for the next launch")

        BugCapsuleCrashBridge.resetForTesting()
        try FileManager.default.removeItem(at: events)
        XCTAssertTrue(install())
        XCTAssertTrue(BugCapsuleCrashBridge.lastRunCrashed)
        XCTAssertEqual(pending().count, 1)
    }

    func testBridgeUncaughtExceptionIsPendingOnce() throws {
        XCTAssertTrue(install())
        BugCapsuleCrashBridge.updateScope(json: #"{"tags":{"screen":"cart"}}"#)
        let exception = NSException(name: .invalidArgumentException, reason: "bad cart", userInfo: nil)
        CrashBridgeRuntime.shared.recordUncaught(exception)
        // abort() follows: its report only marks the run crashed.
        XCTAssertTrue(NativeCrashHandler.writeTestReport(signal: SIGABRT))
        BugCapsuleCrashBridge.resetForTesting()
        XCTAssertTrue(install())
        XCTAssertTrue(BugCapsuleCrashBridge.lastRunCrashed)
        let events = pending()
        XCTAssertEqual(events.count, 1)
        let value = events.first?["exception"]?["values"]?.arrayValue?.last
        XCTAssertEqual(value?["type"], "NSInvalidArgumentException")
        XCTAssertEqual(value?["value"], "bad cart")
        XCTAssertEqual(value?["mechanism"]?["type"], "nsexception")
        XCTAssertEqual(events.first?["tags"]?["screen"], "cart")
        let threads = try XCTUnwrap(events.first?["threads"]?.arrayValue)
        XCTAssertEqual(threads.first?["crashed"], true)
        XCTAssertEqual(threads.filter { $0["crashed"] == true }.count, 1)
        XCTAssertGreaterThan(threads.count, 1)
    }

    func testBridgeHangsReachTheListenerAndThePendingEvents() async throws {
        XCTAssertTrue(install())
        final class Sink: @unchecked Sendable {
            let lock = NSLock()
            var events: [String] = []
        }
        let sink = Sink()
        BugCapsuleCrashBridge.setListener { json in sink.lock.locked { sink.events.append(json) } }
        // Sampled off the main thread, as the watchdog does.
        let samples = await Task.detached { NativeCrashHandler.sampleThreads() }.value
        CrashBridgeRuntime.shared.recordHang(samples, threshold: 2)
        let end = Date().addingTimeInterval(5)
        while sink.lock.locked({ sink.events.isEmpty }) && Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
        let heard = try XCTUnwrap(sink.lock.locked { sink.events.first })
        let events = BugCapsuleCrashBridge.takePendingEvents()
        XCTAssertEqual(events, [heard])
        let hang = try JSON.parse(Data(heard.utf8))
        XCTAssertEqual(hang["level"], "error")
        XCTAssertEqual(hang["exception"]?["values"]?.arrayValue?.last?["mechanism"]?["type"], "app_hang")
        XCTAssertEqual(hang["threads"]?.arrayValue?.first?["name"], "main")
        // A later MetricKit hang diagnostic of this process is the same hang.
        var payload = try metricKitPayload().objectValue!
        payload["crashDiagnostics"] = .array([])
        let now = ISODate.format(Date())
        payload["timeStampBegin"] = .string(now)
        payload["timeStampEnd"] = .string(now)
        CrashBridgeRuntime.shared.receiveMetricKit(.object(payload), end: nil)
        XCTAssertEqual(BugCapsuleCrashBridge.takePendingEvents(), [])
    }

    func testBridgeMetricKitDiagnosticsArePendingDeduplicatedAndScopedByProcess() throws {
        // The process MetricKit describes (pid 3021) mirrored its scope to disk.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"pid":3021,"release":"com.shop.app@1.3.0+48","environment":"qa","tags":{"screen":"cart"}}"#.utf8)
            .write(to: dir.appendingPathComponent("scope.json"))
        XCTAssertTrue(install())
        let payload = try metricKitPayload()
        CrashBridgeRuntime.shared.receiveMetricKit(payload, end: nil)
        var events = pending()
        XCTAssertEqual(events.compactMap { $0["level"]?.stringValue }.sorted(), ["error", "fatal"])
        let crash = try XCTUnwrap(events.first { $0["level"] == "fatal" })
        XCTAssertEqual(crash["tags"]?["screen"], "cart", "scope of pid 3021")
        XCTAssertEqual(crash["environment"], "qa")
        let hang = try XCTUnwrap(events.first { $0["level"] == "error" })
        XCTAssertNil(hang["tags"], "no pid on the hang diagnostic: no scope")

        // The handlers reported that crash themselves: only the hang.
        BugCapsuleCrashBridge.resetForTesting()
        CrashLedger(file: dir.appendingPathComponent("crash_times.json"))
            .record(.crash, at: try XCTUnwrap(MetricKitConverter.parseTime("2026-10-25 09:59:30")), pid: 3021)
        XCTAssertTrue(install())
        CrashBridgeRuntime.shared.receiveMetricKit(payload, end: nil)
        events = pending()
        XCTAssertEqual(events.compactMap { $0["level"]?.stringValue }, ["error"])
    }

    func testBridgeScopeIsMirroredToDiskWithItsProcess() async throws {
        XCTAssertTrue(install("com.shop.app@1.4.0+52"))
        BugCapsuleCrashBridge.updateScope(json: #"{"tags":{"screen":"a"}}"#)
        BugCapsuleCrashBridge.updateScope(json: #"{"tags":{"screen":"b"}}"#)
        let file = dir.appendingPathComponent("scope.json")
        let end = Date().addingTimeInterval(5)
        while (try? loadJSON(file))?["tags"]?["screen"] != "b" && Date() < end {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let scope = try loadJSON(file)
        XCTAssertEqual(scope["pid"]?.intValue, Int(getpid()))
        XCTAssertEqual(scope["release"], "com.shop.app@1.4.0+52")
        XCTAssertEqual(scope["tags"]?["screen"], "b")
    }

    func testBridgeInstallsOnceAndNeverNextToTheSDK() async throws {
        XCTAssertTrue(install("first"))
        XCTAssertTrue(install("second"), "idempotent")
        XCTAssertTrue(NativeCrashHandler.writeTestReport(signal: SIGSEGV))
        BugCapsuleCrashBridge.resetForTesting()
        XCTAssertTrue(install())
        XCTAssertEqual(pending().first?["release"], "first", "the first settings are kept")
        BugCapsuleCrashBridge.resetForTesting()

        // The SDK running (even without monitoring): the bridge stays out.
        await start(.disabled)
        XCTAssertFalse(install(directory: tempDirectory()))
        XCTAssertFalse(BugCapsuleCrashBridge.nativeCrashHandlerInstalled)
        XCTAssertEqual(BugCapsuleCrashBridge.takePendingEvents(), [])
        await BugCapsule.resetForTesting()
        await start(testMonitoringOptions(nativeCrashes: true))
        XCTAssertEqual(CrashOwnership.current, .sdk)
        XCTAssertFalse(install(directory: tempDirectory()))
        await BugCapsule.resetForTesting()
        XCTAssertNil(CrashOwnership.current)

        // The bridge first: the SDK's monitoring skips the handlers and leaves them installed.
        XCTAssertTrue(install())
        await start(testMonitoringOptions(nativeCrashes: true), directory: tempDirectory())
        XCTAssertEqual(CrashOwnership.current, .bridge)
        await BugCapsule.resetForTesting()
        XCTAssertTrue(NativeCrashHandler.isInstalled, "still the bridge's")
        XCTAssertEqual(CrashOwnership.current, .bridge)
    }
}
