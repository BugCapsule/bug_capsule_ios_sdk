import Foundation
import XCTest

@testable import BugCapsule

/// Crash capsules (crash-capsules.md): the journal, capsules built from it
/// on the next launch, and how replay judges a crash.
@MainActor
final class CrashCapsuleTests: XCTestCase {
    var dir: URL!

    override func setUp() async throws {
        await BugCapsule.resetForTesting()
        StubBackend.reset()
        dir = tempDirectory()
    }

    override func tearDown() async throws {
        await BugCapsule.resetForTesting()
        NativeCrashHandler.uninstallForTesting()
    }

    // MARK: helpers

    static let wallAtStart = 1_800_000_000_000

    func header(pid: Int = 4242, anchorT: Int? = 100, gitSha: String? = "abc123") -> JSONObject {
        [
            "mode": "qa",
            "app": AppInfo(id: "com.shop.app", version: "1.4.0", build: "52").json,
            "source": ["gitSha": gitSha.map { .string($0) } ?? .null, "dirty": false],
            "sdk": ["name": "bugcapsule-ios", "version": "0.4.1-beta.2"],
            "stateSchemaVersion": 1,
            "platform": PlatformInfo(os: "ios", osVersion: "27.0", locale: "en_US", screenWidth: 402, screenHeight: 874, pixelRatio: 3).json,
            "session": [
                "id": "s1", "startedAt": .string(ISODate.format(Date(timeIntervalSince1970: Double(Self.wallAtStart) / 1000))),
                "wallClockAtAnchorMs": .int(Self.wallAtStart + (anchorT ?? 0)), "seed": 7,
            ],
            "integrations": ["urlsession"],
            "labels": ["team": "checkout"],
            "dependencies": [],
            "runtime": RuntimeInfo(name: "ios", version: "27.0", language: "swift", frameworks: ["uikit"]).json,
            "capabilities": ["crash.native": "partial"],
            "pid": .int(pid),
            "release": "com.shop.app@1.4.0+52",
            "environment": "qa",
            "anchorT": anchorT.map { .int($0) } ?? .null,
            "wallClockAtStartMs": .int(Self.wallAtStart),
        ]
    }

    func launch() -> Checkpoint { Checkpoint(kind: .launch, t: 20, wallClockMs: Self.wallAtStart + 20, afterSeq: 0, data: ["state": ["cart": 0]]) }

    func action(_ seq: Int, t: Int, id: String = "tap", pad: Int = 0) -> BugCapsuleEvent {
        var payload: JSONObject = [:]
        if pad > 0 { payload["pad"] = .string(String(repeating: "x", count: pad)) }
        return BugCapsuleEvent(seq: seq, t: t, type: EventTypes.action, data: ["id": .string(id), "payload": .object(payload)])
    }

    func journal(_ name: String = "4242", maxBytes: Int = 10_000_000, header h: JSONObject? = nil) -> CrashJournal {
        CrashJournal(directory: dir.appendingPathComponent("journal/\(name)"), maxBytes: maxBytes, header: h ?? header(), launch: launch())
    }

    func files(_ j: CrashJournal, _ sub: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: j.directory.appendingPathComponent(sub).path)) ?? []).sorted()
    }

    static let segvReport = """
        BCCRASH 1
        kind signal
        signal 11
        code 1
        addr 0x0
        time 1800000005
        timems 1800000005000
        pid 4242
        frame 0x1045a0c3c
        end

        """

    func segvDraft(_ text: String = segvReport) throws -> EventDraft {
        let r = try XCTUnwrap(NativeCrashReport.parse(Data(text.utf8)))
        return CrashEvents.draft(from: r, stack: StackBuilder(options: BugCapsuleMonitoringOptions()))
    }

    func bareSession(maxCapsulesPerSession: Int = 5) -> BugCapsuleSession {
        var config = BugCapsuleConfig(appVersion: "1.4.0", appBuild: "52", appId: "com.shop.app", mode: .qa)
        config.maxCapsulesPerSession = maxCapsulesPerSession
        return BugCapsuleSession(config: config, integrations: [], overrides: BugCapsuleTestOverrides(storageDirectory: dir))
    }

    let link = CapsuleMonitoringLink(eventId: "0f0e0d0c0b0a49088706050403020100", release: "com.shop.app@1.4.0+52", environment: "qa")

    // MARK: 1. journal

    func testJournalWritesHeaderLaunchCheckpointAndEvents() throws {
        let j = journal()
        for i in 1...3 { j.append(action(i, t: 100 + i)) }
        j.flushSynchronously()
        let c = try XCTUnwrap(CrashJournalContents.load(j.directory))
        XCTAssertEqual(c.pid, 4242)
        XCTAssertNotNil(c.writtenAt)
        XCTAssertEqual(c.header["anchorT"], 100)
        XCTAssertEqual(c.launch?.afterSeq, 0)
        XCTAssertEqual(c.events.map(\.seq), [1, 2, 3])
        XCTAssertEqual(files(j, "events"), ["1.jsonl"])
        XCTAssertEqual(files(j, "checkpoints"), ["0.json"])
        let w = try XCTUnwrap(c.window())
        XCTAssertEqual(w.checkpoint.kind, .launch)
        XCTAssertFalse(w.hasGap)
        // One line per event, exactly the capsule's event JSON.
        let lines = try String(contentsOf: j.directory.appendingPathComponent("events/1.jsonl"), encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(try JSON.parse(Data(lines[0].utf8)), action(1, t: 101).json)
    }

    func testJournalFlushesWithoutBeingAskedWithin250ms() throws {
        let j = journal()
        j.append(action(1, t: 101))
        let deadline = Date().addingTimeInterval(1)
        var events: [BugCapsuleEvent] = []
        while Date() < deadline {
            events = CrashJournalContents.load(j.directory)?.events ?? []
            if !events.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(events.map(\.seq), [1])
    }

    func testJournalRotatesAtEachCheckpoint() throws {
        let j = journal()
        j.append(action(1, t: 101))
        j.append(action(2, t: 102))
        j.boundary(afterSeq: 2)
        j.append(action(3, t: 103))
        j.checkpoint(Checkpoint(kind: .periodic, t: 102, wallClockMs: Self.wallAtStart + 102, afterSeq: 2, data: ["state": ["cart": 2]]))
        j.append(action(4, t: 104))
        j.flushSynchronously()
        XCTAssertEqual(files(j, "events"), ["1.jsonl", "3.jsonl"])
        XCTAssertEqual(files(j, "checkpoints"), ["0.json", "2.json"])
        let c = try XCTUnwrap(CrashJournalContents.load(j.directory))
        XCTAssertEqual(c.window()?.checkpoint.kind, .launch, "nothing evicted: the launch checkpoint")
        XCTAssertEqual(c.window()?.events.map(\.seq), [1, 2, 3, 4])
        XCTAssertEqual(c.window(periodicOnly: true)?.checkpoint.afterSeq, 2)
        XCTAssertEqual(c.window(periodicOnly: true)?.events.map(\.seq), [3, 4])

        // A newer periodic checkpoint replaces the older one.
        j.boundary(afterSeq: 4)
        j.checkpoint(Checkpoint(kind: .periodic, t: 104, wallClockMs: Self.wallAtStart + 104, afterSeq: 4))
        j.flushSynchronously()
        XCTAssertEqual(files(j, "checkpoints"), ["0.json", "4.json"])
    }

    func testJournalEvictsWhatTheRecorderEvicted() throws {
        let j = journal()
        j.append(action(1, t: 101))
        j.append(action(2, t: 102))
        j.boundary(afterSeq: 2)
        j.append(action(3, t: 103))
        j.recorderEvicted()
        j.flushSynchronously()
        XCTAssertEqual(files(j, "checkpoints"), ["0.json"], "kept until a periodic checkpoint covers what is left")
        j.checkpoint(Checkpoint(kind: .periodic, t: 102, wallClockMs: Self.wallAtStart + 102, afterSeq: 2))
        j.flushSynchronously()
        XCTAssertEqual(files(j, "checkpoints"), ["2.json"])
        XCTAssertEqual(files(j, "events"), ["3.jsonl"])
        let w = try XCTUnwrap(CrashJournalContents.load(j.directory)?.window())
        XCTAssertEqual(w.checkpoint.kind, .periodic)
        XCTAssertEqual(w.events.map(\.seq), [3])
        XCTAssertFalse(w.hasGap)
    }

    func testJournalSizeCapDropsTheOldestFileAndTheLaunchCheckpoint() throws {
        let j = journal(maxBytes: 6_000)
        for i in 1...4 { j.append(action(i, t: 100 + i, pad: 900)) }
        j.boundary(afterSeq: 4)
        j.checkpoint(Checkpoint(kind: .periodic, t: 104, wallClockMs: Self.wallAtStart + 104, afterSeq: 4))
        j.flushSynchronously()
        XCTAssertEqual(files(j, "events"), ["1.jsonl"])
        for i in 5...7 { j.append(action(i, t: 100 + i, pad: 900)) }
        j.flushSynchronously()
        XCTAssertEqual(files(j, "events"), ["5.jsonl"], "past 6,000 bytes the oldest file goes")
        XCTAssertEqual(files(j, "checkpoints"), ["4.json"], "and the launch checkpoint with it")
        let size = try FileManager.default.subpathsOfDirectory(atPath: j.directory.path).reduce(0) { sum, p in
            sum + FileIO.size(j.directory.appendingPathComponent(p))
        }
        XCTAssertLessThanOrEqual(size, 6_000)
        let w = try XCTUnwrap(CrashJournalContents.load(j.directory)?.window())
        XCTAssertEqual(w.checkpoint.afterSeq, 4)
        XCTAssertEqual(w.events.map(\.seq), [5, 6, 7])
    }

    func testJournalCutShortByTheCrashKeepsEveryCompleteLine() throws {
        let j = journal()
        j.append(action(1, t: 101))
        j.flushSynchronously()
        let file = j.directory.appendingPathComponent("events/1.jsonl")
        let h = try FileHandle(forWritingTo: file)
        try h.seekToEnd()
        try h.write(contentsOf: Data(#"{"seq":2,"t":10"#.utf8))
        try h.close()
        XCTAssertEqual(CrashJournalContents.load(j.directory)?.events.map(\.seq), [1])
    }

    func testJournalResetRewritesFromTheRecorder() throws {
        let j = journal()
        for i in 1...3 { j.append(action(i, t: 100 + i)) }
        j.flushSynchronously()
        var h = header()
        h["labels"] = ["team": "payments"]
        j.reset(header: h, launch: launch(), launchCovers: true, periodic: nil, events: [action(1, t: 101), action(3, t: 103)])
        j.flushSynchronously()
        let c = try XCTUnwrap(CrashJournalContents.load(j.directory))
        XCTAssertEqual(c.events.map(\.seq), [1, 3])
        XCTAssertEqual(c.header["labels"]?["team"], "payments")
        XCTAssertEqual(c.window()?.checkpoint.kind, .launch)
    }

    func testJournalDeleteRemovesTheDirectory() {
        let j = journal()
        j.append(action(1, t: 101))
        j.flushSynchronously()
        j.delete()
        j.append(action(2, t: 102))
        XCTAssertFalse(FileManager.default.fileExists(atPath: j.directory.path))
    }

    func testCleanupDeletesUnclaimedAndOldJournalsAndClaimsForMetricKit() throws {
        let root = dir.appendingPathComponent("journal")
        let journals = CrashJournals(root: root)
        func make(_ name: String, background: Bool) -> URL {
            let j = journal(name)
            j.append(BugCapsuleEvent(seq: 1, t: 101, type: EventTypes.lifecycle, data: ["state": "resumed"]))
            if background { j.append(BugCapsuleEvent(seq: 2, t: 102, type: EventTypes.lifecycle, data: ["state": "paused"])) }
            j.close()
            return j.directory
        }
        let background = make("100", background: true)
        let foreground = make("101", background: false)
        let old = make("102", background: false)
        journals.claim(old, at: Date().addingTimeInterval(-8 * 24 * 3600))
        let broken = root.appendingPathComponent("103")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        let mine = journals.currentDirectory
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)

        journals.cleanup(claimForMetricKit: true)
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: background.path), "ended in the background: nothing will claim it")
        XCTAssertTrue(fm.fileExists(atPath: CrashJournalContents.claimFile(foreground).path), "kept for MetricKit")
        XCTAssertFalse(fm.fileExists(atPath: old.path), "claimed more than 7 days ago")
        XCTAssertFalse(fm.fileExists(atPath: broken.path))
        XCTAssertTrue(fm.fileExists(atPath: mine.path), "this process's journal is never cleaned up")
        XCTAssertEqual(journals.find(pid: 101)?.resolvingSymlinksInPath().path, foreground.resolvingSymlinksInPath().path)

        journals.cleanup(claimForMetricKit: false)
        XCTAssertTrue(fm.fileExists(atPath: foreground.path), "a claim holds until 7 days")
    }

    func testCurrentPidJournalIsSetAsideNotOverwritten() throws {
        let journals = CrashJournals(root: dir.appendingPathComponent("journal"))
        let j = CrashJournal(
            directory: journals.currentDirectory, maxBytes: 1_000_000, header: header(pid: journals.pid), launch: launch())
        j.append(action(1, t: 101))
        j.close()
        journals.setAsideCurrent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: journals.currentDirectory.path))
        let found = try XCTUnwrap(journals.find(pid: journals.pid))
        XCTAssertTrue(found.lastPathComponent.hasPrefix("\(journals.pid)."))
    }

    func testRecordingSessionJournalsWhatItRecords() async throws {
        BugCapsule.start(
            BugCapsuleConfig(
                appVersion: "1.4.0", appBuild: "52", appId: "com.shop.app", mode: .qa, labels: ["team": "checkout"],
                monitoring: testMonitoringOptions()),
            overrides: BugCapsuleTestOverrides(storageDirectory: dir))
        let session = try XCTUnwrap(BugCapsuleSession.current)
        session.setAnchorForTesting(session.now())
        session.refreshJournalHeader()
        session.record(EventTypes.action, ["id": "add_to_cart"])
        session.periodicCheckpoint()
        session.record(EventTypes.action, ["id": "checkout"])
        let journal = try XCTUnwrap(session.journalForTesting)
        journal.flushSynchronously()
        let c = try XCTUnwrap(CrashJournalContents.load(journal.directory))
        XCTAssertEqual(journal.directory.lastPathComponent, "\(getpid())")
        XCTAssertEqual(c.events.map { $0.data["id"] }, ["add_to_cart", "checkout"])
        XCTAssertEqual(c.events.map(\.seq), session.recorderForTesting!.window().events.map(\.seq))
        XCTAssertNotNil(c.launch)
        XCTAssertEqual(c.periodic?.afterSeq, 1)
        XCTAssertEqual(c.header["labels"]?["team"], "checkout")
        XCTAssertEqual(c.header["pid"], .int(Int(getpid())))
        XCTAssertNotNil(c.header["anchorT"]?.intValue)
        XCTAssertEqual(c.header["session"]?["id"], .string(session.sessionId))

        // Ending normally keeps it; the next launch deletes it (no fatal event).
        await BugCapsule.resetForTesting()
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.directory.path))
        BugCapsule.start(
            BugCapsuleConfig(appVersion: "1.4.0", appBuild: "52", mode: .qa, monitoring: testMonitoringOptions()),
            overrides: BugCapsuleTestOverrides(storageDirectory: dir))
        let next = try XCTUnwrap(BugCapsuleSession.current)
        await waitForQueue(next)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("journal").path)
        XCTAssertEqual(left, ["\(getpid())"], "only the new process's journal")
    }

    func testNotRecordingKeepsNoJournal() async throws {
        BugCapsule.start(
            BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .production, productionSampleRate: 0, monitoring: testMonitoringOptions()),
            overrides: BugCapsuleTestOverrides(storageDirectory: dir, random: { 0.5 }))
        let session = try XCTUnwrap(BugCapsuleSession.current)
        XCTAssertFalse(session.isRecording)
        XCTAssertNil(session.journalForTesting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("journal/\(getpid())").path))
    }

    func testUncaughtExceptionCapsuleDeletesTheJournal() async throws {
        BugCapsule.start(
            BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa, monitoring: testMonitoringOptions()),
            overrides: BugCapsuleTestOverrides(storageDirectory: dir))
        let session = try XCTUnwrap(BugCapsuleSession.current)
        session.record(EventTypes.action, ["id": "pay"])
        let journal = try XCTUnwrap(session.journalForTesting)
        journal.flushSynchronously()
        session.handleUncaughtException(NSException(name: .invalidArgumentException, reason: "boom"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.directory.path))
        XCTAssertNil(session.journalForTesting)
        XCTAssertEqual(session.store?.savedCaptures().count, 1, "the synchronous capsule replaces the journal")
    }

    func waitForQueue(_ session: BugCapsuleSession) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in session.queue.async { c.resume() } }
    }

    // MARK: 2. capsule from the journal

    func testCrashCapsuleFromTheLaunchCheckpoint() throws {
        let j = journal()
        for i in 1...3 { j.append(action(i, t: 1000 * i)) }
        j.close()
        let c = try XCTUnwrap(CrashJournalContents.load(j.directory))
        let session = bareSession()
        let crashAt = Date(timeIntervalSince1970: Double(Self.wallAtStart + 3_400) / 1000)
        let (capsule, bytes) = try XCTUnwrap(
            session.buildCrashCapsule(c, draft: try segvDraft(), crashTime: crashAt, link: link, capsuleId: "cap-1", maxBytes: 5_000_000))
        let m = capsule.manifest
        XCTAssertEqual(m.capsuleId, "cap-1")
        XCTAssertEqual(capsule.checkpoint.kind, .launch)
        XCTAssertEqual(capsule.checkpoint.t, 20 - 100, "shifted to the anchor")
        XCTAssertEqual(capsule.events.map(\.t), [900, 1900, 2900])
        let f = try XCTUnwrap(m.failure)
        XCTAssertEqual(f.kind, .crash)
        XCTAssertEqual(f.signature, "crash:SIGSEGV")
        XCTAssertEqual(f.type, "SIGSEGV")
        XCTAssertEqual(f.crash?["mechanism"], "signal")
        XCTAssertEqual(f.crash?["signal"], 11)
        XCTAssertEqual(f.t, 3_400 - 100)
        XCTAssertEqual(m.journalGapMs, 400, "crash time minus the last journaled event")
        XCTAssertEqual(m.monitoring, link)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: m.labels)["source"], "crash_journal")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: m.labels)["crash.mechanism"], "signal")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: m.labels)["team"], "checkout")
        XCTAssertEqual(m.eligibility.status, .partial)
        XCTAssertEqual(m.eligibility.missing.map(\.dependency), ["crash.native"])
        XCTAssertFalse(m.eligibility.missing[0].blocking)
        XCTAssertEqual(m.session.id, "s1")
        XCTAssertEqual(m.session.wallClockAtAnchorMs, Self.wallAtStart + 100)
        XCTAssertEqual(m.app.version, "1.4.0")

        // Always format v2, readable and valid.
        let json = CapsuleCodec.toJSON(capsule)
        XCTAssertEqual(json["specVersion"], 2)
        XCTAssertEqual(json["manifest"]?["dependencies"], .array([]))
        XCTAssertEqual(json["manifest"]?["stats"]?["journalGapMs"], 400)
        XCTAssertNil(validateCapsuleDocument(json))
        let decoded = try CapsuleCodec.decode(bytes)
        XCTAssertEqual(decoded.manifest.failure, f)
        XCTAssertEqual(decoded.manifest.journalGapMs, 400)
    }

    func testCrashCapsuleFromThePeriodicCheckpointAfterEviction() throws {
        let j = journal()
        for i in 1...3 { j.append(action(i, t: 1000 * i)) }
        j.boundary(afterSeq: 3)
        j.recorderEvicted()
        j.checkpoint(Checkpoint(kind: .periodic, t: 3_000, wallClockMs: Self.wallAtStart + 3_000, afterSeq: 3, data: ["state": ["cart": 3]]))
        j.append(action(4, t: 4_000))
        j.close()
        let c = try XCTUnwrap(CrashJournalContents.load(j.directory))
        let (capsule, _) = try XCTUnwrap(
            bareSession().buildCrashCapsule(c, draft: try segvDraft(), crashTime: nil, link: link, capsuleId: "cap-2", maxBytes: 5_000_000))
        XCTAssertEqual(capsule.checkpoint.kind, .periodic)
        XCTAssertEqual(capsule.manifest.checkpointKind, .periodic)
        XCTAssertEqual(capsule.checkpoint.afterSeq, 3)
        XCTAssertEqual(capsule.events.map(\.seq), [4])
        XCTAssertNil(capsule.manifest.journalGapMs, "crash time unknown")
        XCTAssertEqual(capsule.manifest.failure?.t, 4_000 - 100, "the last journaled event stands in")
    }

    func testCrashCapsuleReportsTheGapWhenTheFileAfterItsCheckpointIsGone() throws {
        let j = journal(maxBytes: 4_000)
        j.boundary(afterSeq: 0)
        for i in 1...6 { j.append(action(i, t: 100 * i, pad: 900)) }
        j.close()
        let c = try XCTUnwrap(CrashJournalContents.load(j.directory))
        XCTAssertNil(c.launch, "the cap took the launch checkpoint with the first file")
        XCTAssertNil(c.window(), "nothing to start from")

        let k = journal("4343", maxBytes: 5_000)
        k.boundary(afterSeq: 2)
        k.checkpoint(Checkpoint(kind: .periodic, t: 200, wallClockMs: Self.wallAtStart + 200, afterSeq: 2))
        for i in 3...8 { k.append(action(i, t: 100 * i, pad: 900)) }
        k.flushSynchronously()
        for i in 9...10 { k.append(action(i, t: 100 * i, pad: 900)) }
        k.close()
        let d = try XCTUnwrap(CrashJournalContents.load(k.directory))
        let w = try XCTUnwrap(d.window())
        XCTAssertEqual(w.checkpoint.afterSeq, 2)
        XCTAssertTrue(w.hasGap)
        let (capsule, _) = try XCTUnwrap(
            bareSession().buildCrashCapsule(d, draft: try segvDraft(), crashTime: nil, link: link, capsuleId: "cap-3", maxBytes: 5_000_000))
        XCTAssertTrue(capsule.manifest.eligibility.missing.contains { $0.dependency == "events.window" })
        XCTAssertTrue(capsule.manifest.eligibility.missing.contains { $0.dependency == "crash.native" })
    }

    func testOversizeCrashCapsuleUsesThePeriodicCheckpointThenNothing() throws {
        let j = journal()
        for i in 1...40 { j.append(action(i, t: 100 * i, pad: 2_000)) }
        j.boundary(afterSeq: 40)
        j.checkpoint(Checkpoint(kind: .periodic, t: 4_000, wallClockMs: Self.wallAtStart + 4_000, afterSeq: 40))
        j.append(action(41, t: 4_100))
        j.close()
        let c = try XCTUnwrap(CrashJournalContents.load(j.directory))
        let session = bareSession()
        let full = try XCTUnwrap(
            session.buildCrashCapsule(c, draft: try segvDraft(), crashTime: nil, link: link, capsuleId: "a", maxBytes: 5_000_000))
        XCTAssertEqual(full.0.checkpoint.kind, .launch)
        let limit = full.1.count - 1
        let smaller = try XCTUnwrap(
            session.buildCrashCapsule(c, draft: try segvDraft(), crashTime: nil, link: link, capsuleId: "b", maxBytes: limit))
        XCTAssertEqual(smaller.0.checkpoint.kind, .periodic)
        XCTAssertEqual(smaller.0.events.map(\.seq), [41])
        XCTAssertNil(
            session.buildCrashCapsule(c, draft: try segvDraft(), crashTime: nil, link: link, capsuleId: "c", maxBytes: 200),
            "still too big: no capsule")
    }

    func testCrashBeforeTheAnchorAndMachExceptions() throws {
        let j = journal(header: header(anchorT: nil))
        j.append(action(1, t: 50))
        j.close()
        let c = try XCTUnwrap(CrashJournalContents.load(j.directory))
        let mach = """
            BCCRASH 1
            kind mach
            signal 11
            exception 1
            exceptionCode 0x1
            exceptionSubcode 0x10
            time 1800000000
            pid 4242
            frame 0x1045a0c3c
            end

            """
        let (capsule, _) = try XCTUnwrap(
            bareSession().buildCrashCapsule(c, draft: try segvDraft(mach), crashTime: nil, link: link, capsuleId: "m", maxBytes: 5_000_000))
        XCTAssertEqual(capsule.events.map(\.t), [0], "no anchor: the last event stands in")
        XCTAssertEqual(capsule.manifest.session.wallClockAtAnchorMs, Self.wallAtStart + 50)
        XCTAssertEqual(capsule.manifest.failure?.signature, "crash:EXC_BAD_ACCESS")
        XCTAssertEqual(capsule.manifest.failure?.crash?["exception"], 1)
        XCTAssertEqual(capsule.manifest.failure?.crash?["mechanism"], "mach_exception")
        XCTAssertFalse(capsule.manifest.failure?.signature.contains("0x") ?? true, "no addresses in the signature")
    }

    func testMetricKitWatchdogKillIsAnApplicationNotRespondingCrash() throws {
        let value = StackBuilder.exceptionValue(
            type: "EXC_CRASH", value: "Namespace FRONTBOARD, Code 0x8badf00d", module: nil, mechanism: "metrickit", handled: false,
            frames: nil, data: ["source": "metrickit", "exception": 10, "signal": 9, "terminationReason": "Namespace FRONTBOARD, Code 0x8badf00d"])
        let f = try XCTUnwrap(CrashFailure.failure(from: EventDraft(level: .fatal, exceptionValues: [value]), t: 10))
        XCTAssertEqual(f.signature, "crash:ApplicationNotResponding")
        XCTAssertEqual(f.crash?["mechanism"], "metrickit")
        XCTAssertEqual(f.crash?["signal"], 9)
    }

    func testCrashFailureValidation() {
        var doc = CapsuleCodec.toJSON(makeCapsule(failure: FailureRecord.crash(
            type: "SIGABRT", message: "Abort", stack: nil, crash: ["mechanism": "signal", "signal": 6], t: 5)))
        XCTAssertNil(validateCapsuleDocument(doc))
        XCTAssertEqual(doc["specVersion"], 2)
        var v1 = doc.objectValue!
        v1["specVersion"] = 1
        XCTAssertEqual(validateCapsuleDocument(.object(v1))?.hasPrefix("$.manifest.failure.kind"), true, "a v2 kind")
        var manifest = doc["manifest"]!.objectValue!
        var failure = manifest["failure"]!.objectValue!
        failure["crash"] = ["signal": "eleven"]
        manifest["failure"] = .object(failure)
        doc = .object(["format": "bugcapsule.capsule", "specVersion": 2, "manifest": .object(manifest), "checkpoint": doc["checkpoint"]!, "events": []])
        XCTAssertEqual(validateCapsuleDocument(doc)?.hasPrefix("$.manifest.failure.crash.signal"), true)
    }

    // MARK: 3. next launch, end to end

    func start(_ dir: URL, maxCapsulesPerSession: Int = 5) async {
        var config = BugCapsuleConfig(
            appVersion: "1.4.0", appBuild: "52", appId: "com.shop.app", mode: .qa, backend: stubBackend, gitSha: "abc123",
            gitDirty: false, monitoring: testMonitoringOptions(nativeCrashes: true))
        config.maxCapsulesPerSession = maxCapsulesPerSession
        BugCapsule.start(
            config,
            overrides: BugCapsuleTestOverrides(storageDirectory: dir, transport: stubTransport(), random: { 0.5 }, captureSettleDelay: 0.05))
        await BugCapsule.refreshRemoteConfig()
    }

    func flushUntil(_ timeout: TimeInterval = 8, _ cond: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            await BugCapsule.flush(timeout: 2)
            await BugCapsule.flushUploads()
            if cond() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < end
    }

    func uploadedCapsules() -> [Capsule] {
        StubBackend.requests("/v1/capsules").compactMap { r in
            (try? CapsuleCodec.decode(r.body)) ?? (try? CapsuleCodec.decode(Gzip.compress(r.body)))
        }
    }

    func testNativeCrashWithAJournalGivesAnUploadedCapsuleAndAnEventWithItsId() async throws {
        await start(dir, maxCapsulesPerSession: 0)
        let first = try XCTUnwrap(BugCapsuleSession.current)
        first.setAnchorForTesting(first.now())
        first.refreshJournalHeader()
        first.record(EventTypes.action, ["id": "add_to_cart"])
        first.record(EventTypes.action, ["id": "checkout"])
        let journalDir = try XCTUnwrap(first.journalForTesting?.directory)
        XCTAssertTrue(NativeCrashHandler.writeTestReport(signal: SIGSEGV))
        await BugCapsule.resetForTesting()  // the process "dies": the journal stays
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalDir.path))

        StubBackend.reset()
        await start(dir, maxCapsulesPerSession: 0)
        await flushUntil { !self.uploadedCapsules().isEmpty && !StubBackend.items("event").isEmpty }
        let capsule = try XCTUnwrap(uploadedCapsules().first, "crash capsules do not count against maxCapsulesPerSession")
        let event = try XCTUnwrap(StubBackend.items("event").first { $0["level"] == "fatal" })
        XCTAssertEqual(event["capsuleId"], .string(capsule.manifest.capsuleId))
        XCTAssertEqual(capsule.manifest.monitoring?.eventId, event["eventId"]?.stringValue)
        XCTAssertEqual(capsule.manifest.monitoring?.release, event["release"]?.stringValue)
        XCTAssertEqual(capsule.manifest.failure?.signature, "crash:SIGSEGV")
        XCTAssertEqual(capsule.events.compactMap { $0.data["id"]?.stringValue }, ["add_to_cart", "checkout"])
        XCTAssertNotNil(capsule.manifest.journalGapMs)
        XCTAssertGreaterThanOrEqual(capsule.manifest.journalGapMs ?? -1, 0)
        XCTAssertTrue(capsule.manifest.eligibility.missing.contains { $0.dependency == "crash.native" })

        // The crashed process's journal is gone; this process keeps its own.
        let journals = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("journal").path)
        XCTAssertEqual(journals, ["\(getpid())"])
    }

    func testCrashWithoutAJournalGivesTheEventOnly() async throws {
        await start(dir)
        XCTAssertTrue(NativeCrashHandler.writeTestReport(signal: SIGSEGV))
        let first = try XCTUnwrap(BugCapsuleSession.current)
        first.journalForTesting?.delete()  // e.g. that run was not recording
        await BugCapsule.resetForTesting()

        StubBackend.reset()
        await start(dir)
        await flushUntil { !StubBackend.items("event").isEmpty }
        let event = try XCTUnwrap(StubBackend.items("event").first { $0["level"] == "fatal" })
        XCTAssertNil(event["capsuleId"])
        XCTAssertTrue(uploadedCapsules().isEmpty)
    }

    func testMetricKitCrashOfAClaimedJournalGetsItsCapsuleWhenItArrives() async throws {
        await start(dir)
        let session = try XCTUnwrap(BugCapsuleSession.current)
        let journals = try XCTUnwrap(session.crashJournals)
        // A process that died in the foreground without a crash report.
        let j = CrashJournal(
            directory: journals.root.appendingPathComponent("31337"), maxBytes: 1_000_000, header: header(pid: 31337),
            launch: launch())
        j.append(action(1, t: 500, id: "open_cart"))
        j.close()
        journals.claim(j.directory)
        let payload: JSONValue = [
            "timeStampBegin": "2026-10-25 09:00:00", "timeStampEnd": "2026-10-25 10:00:00",
            "crashDiagnostics": [[
                "diagnosticMetaData": [
                    "appVersion": "1.4.0", "appBuildVersion": "52", "bundleIdentifier": "com.shop.app", "pid": 31337,
                    "exceptionType": 1, "exceptionCode": 0, "signal": 11,
                ],
                "callStackTree": ["callStacks": [], "callStackPerThread": true],
            ]],
        ]
        session.monitoring?.receiveMetricKit(payload, end: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: j.directory.path), "used once")
        await flushUntil { !self.uploadedCapsules().isEmpty && !StubBackend.items("event").isEmpty }
        let capsule = try XCTUnwrap(uploadedCapsules().first)
        let event = try XCTUnwrap(StubBackend.items("event").first)
        XCTAssertEqual(event["capsuleId"], .string(capsule.manifest.capsuleId))
        XCTAssertEqual(capsule.manifest.failure?.signature, "crash:EXC_BAD_ACCESS")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: capsule.manifest.labels)["crash.mechanism"], "metrickit")
        XCTAssertNil(capsule.manifest.journalGapMs)
    }

    // MARK: 4. replay verdicts

    func ips(type: String, signal: String, symbol: String = "HomeViewController.crash()", termination: String? = nil, asi: String? = nil) -> Data {
        var body: JSONObject = [
            "pid": 999, "procName": "BugCapsuleDemo", "procPath": "/sim/7D3B/BugCapsuleDemo.app/BugCapsuleDemo",
            "exception": ["type": .string(type), "signal": .string(signal), "subtype": "KERN_INVALID_ADDRESS at 0x0"],
            "faultingThread": 0,
            "threads": [["triggered": true, "frames": [
                ["imageIndex": 1, "symbol": "objc_msgSend"],
                ["imageIndex": 0, "symbol": .string(symbol)],
            ]]],
            "usedImages": [["path": "/sim/7D3B/BugCapsuleDemo.app/BugCapsuleDemo"], ["path": "/usr/lib/libobjc.A.dylib"]],
        ]
        if let termination { body["termination"] = ["namespace": "FRONTBOARD", "code": .string(termination)] }
        if let asi { body["asi"] = ["CoreFoundation": [.string(asi)]] }
        let header: JSONValue = ["bug_type": "309", "name": "BugCapsuleDemo", "bundleID": "com.bugcapsule.demo"]
        return Data((JSON.encode(header) + "\n" + JSON.encode(.object(body))).utf8)
    }

    func expected(_ type: String, inAppFrame: String? = nil) -> FailureRecord {
        var crash: JSONObject = ["mechanism": "signal"]
        if let inAppFrame { crash["inAppFrame"] = .string(inAppFrame) }
        return FailureRecord.crash(type: type, message: "", stack: nil, crash: crash, t: 0)
    }

    func testCrashReportIsParsed() throws {
        let c = try XCTUnwrap(ObservedCrash.parseIPS(ips(type: "EXC_BAD_ACCESS", signal: "SIGSEGV")))
        XCTAssertEqual(c.pid, 999)
        XCTAssertEqual(c.bundleId, "com.bugcapsule.demo")
        XCTAssertEqual(c.type, "EXC_BAD_ACCESS")
        XCTAssertEqual(c.frames.map(\.inApp), [false, true])
        XCTAssertEqual(c.summary, "EXC_BAD_ACCESS (SIGSEGV): KERN_INVALID_ADDRESS at 0x0")
        XCTAssertNil(ObservedCrash.parseIPS(Data("{\"bug_type\":\"288\"}\n{}".utf8)), "not a crash")
    }

    func testDebugDylibFramesAreInApp() throws {
        var body = try XCTUnwrap(
            (try JSON.parse(Data(String(decoding: ips(type: "EXC_BAD_ACCESS", signal: "SIGSEGV"), as: UTF8.self)
                .split(separator: "\n", maxSplits: 1)[1].utf8))).objectValue)
        body["usedImages"] = [["path": "/sim/7D3B/BugCapsuleDemo.app/BugCapsuleDemo.debug.dylib"], ["path": "/usr/lib/libobjc.A.dylib"]]
        let data = Data((#"{"bug_type":"309"}"# + "\n" + JSON.encode(.object(body))).utf8)
        XCTAssertEqual(ObservedCrash.parseIPS(data)?.frames.map(\.inApp), [false, true])
        let main = try XCTUnwrap(DebugImageCache.mainExecutablePath)
        let stack = StackBuilder(options: BugCapsuleMonitoringOptions())
        XCTAssertTrue(stack.isInApp(main + ".debug.dylib"))
        XCTAssertFalse(stack.isInApp(main + ".other.dylib"))
    }

    func testSameCrashTypeIsReproduced() throws {
        let crash = try XCTUnwrap(ObservedCrash.parseIPS(ips(type: "EXC_BAD_ACCESS", signal: "SIGSEGV")))
        for type in ["SIGSEGV", "EXC_BAD_ACCESS"] {
            let (outcome, observed, codes) = CrashVerdict.judge(expected: expected(type), crash: crash)
            XCTAssertEqual(outcome, .reproduced, type)
            XCTAssertEqual(observed.signature, "crash:\(type)")
            XCTAssertEqual(codes, [])
        }
        // `kill -SEGV` from the host: EXC_CRASH (SIGSEGV).
        let killed = try XCTUnwrap(ObservedCrash.parseIPS(ips(type: "EXC_CRASH", signal: "SIGSEGV")))
        XCTAssertEqual(killed.type, "SIGSEGV")
        XCTAssertEqual(CrashVerdict.judge(expected: expected("SIGSEGV"), crash: killed).outcome, .reproduced)
    }

    func testDifferentCrashTypeIsInconclusive() throws {
        let crash = try XCTUnwrap(ObservedCrash.parseIPS(ips(type: "EXC_CRASH", signal: "SIGABRT")))
        let report = CrashVerdict.report(
            expected: expected("SIGSEGV"), crash: crash, settings: ReplaySettings(attempt: 2, attemptId: "att-1"), durationMs: 1200,
            source: "BugCapsuleDemo.ips")
        XCTAssertEqual(report.outcome, .inconclusive)
        XCTAssertEqual(report.reasonCodes, ["failure.different"])
        XCTAssertEqual(report.observed?.signature, "crash:SIGABRT")
        XCTAssertEqual(report.expectedSignature, "crash:SIGSEGV")
        XCTAssertEqual(report.attempt, 2)
        XCTAssertEqual(report.attemptId, "att-1")
        // What the CLI reads back.
        let json = report.json
        XCTAssertEqual(json["outcome"], "inconclusive")
        XCTAssertEqual(json["reasonCodes"], ["failure.different"])
        XCTAssertEqual(ReplayReport(json: json.objectValue!), report)
        let assessment = assessAttempt(report)
        XCTAssertEqual(assessment.status, .invalid)
        XCTAssertEqual(assessment.reasonCodes, ["failure.different"])
    }

    func testDifferentInAppFrameIsStillReproduced() throws {
        let crash = try XCTUnwrap(ObservedCrash.parseIPS(ips(type: "EXC_BAD_ACCESS", signal: "SIGSEGV", symbol: "CartView.pay()")))
        let same = CrashVerdict.judge(expected: expected("SIGSEGV", inAppFrame: "BugCapsuleDemo.CartView.pay() -> ()"), crash: crash)
        XCTAssertEqual(same.outcome, .reproduced)
        XCTAssertEqual(same.reasonCodes, [])
        XCTAssertTrue(CrashVerdict.sameFunction("static BugCapsuleDemo.AppDelegate.$main() -> ()", "static AppDelegate.$main()"))
        let other = CrashVerdict.judge(expected: expected("SIGSEGV", inAppFrame: "HomeViewController.crash()"), crash: crash)
        XCTAssertEqual(other.outcome, .reproduced)
        XCTAssertEqual(other.reasonCodes, ["failure.different_frame"])
        XCTAssertEqual(other.observed.crash?["inAppFrame"], "CartView.pay()")
    }

    func testWatchdogKillAndUncaughtExceptionTypes() throws {
        let watchdog = try XCTUnwrap(ObservedCrash.parseIPS(ips(type: "EXC_CRASH", signal: "SIGKILL", termination: "0x8badf00d")))
        XCTAssertEqual(CrashVerdict.judge(expected: expected("ApplicationNotResponding"), crash: watchdog).outcome, .reproduced)
        XCTAssertEqual(CrashVerdict.judge(expected: expected("SIGKILL"), crash: watchdog).outcome, .reproduced)
        let exception = try XCTUnwrap(ObservedCrash.parseIPS(ips(
            type: "EXC_CRASH", signal: "SIGABRT",
            asi: "*** Terminating app due to uncaught exception 'NSInvalidArgumentException', reason: 'boom'")))
        XCTAssertEqual(exception.type, "NSInvalidArgumentException")
        XCTAssertEqual(CrashVerdict.judge(expected: expected("NSInvalidArgumentException"), crash: exception).outcome, .reproduced)
        XCTAssertEqual(CrashVerdict.judge(expected: expected("SIGSEGV"), crash: exception).outcome, .inconclusive)
    }

    func crashCapsule(_ type: String, t: Int = 50) -> Capsule {
        var capsule = makeCapsule(failure: FailureRecord.crash(type: type, message: "", stack: nil, crash: ["mechanism": "signal"], t: t))
        capsule.manifest.integrations = []
        return capsule
    }

    func testCrashReplayEndingWithTheAppAliveIsNotReproduced() async throws {
        let engine = try XCTUnwrap(
            bareSession().startReplayForTesting(capsule: crashCapsule("SIGSEGV"), settings: ReplaySettings(settleTimeoutMs: 100)))
        let report = await engine.run()
        XCTAssertEqual(report.outcome, .notReproduced)
        XCTAssertEqual(report.expectedSignature, "crash:SIGSEGV")
        XCTAssertEqual(assessAttempt(report).status, .clean, "\(assessAttempt(report).reasons)")
    }

    func testAppHangPastTwoSecondsReproducesAnANRCapsule() async throws {
        let reports = CrashReportBox()
        let engine = try XCTUnwrap(
            bareSession().startReplayForTesting(
                capsule: crashCapsule("ApplicationNotResponding", t: 3_000), settings: ReplaySettings(settleTimeoutMs: 100),
                onReport: { reports.add($0) }))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Thread.sleep(forTimeInterval: 2.6) }
        let late = await engine.run()
        engine.complete(late)
        let report = try XCTUnwrap(reports.all.first)
        XCTAssertEqual(reports.all.count, 1, "reported once, from the watchdog")
        XCTAssertEqual(report.outcome, .reproduced)
        XCTAssertEqual(report.observed?.signature, "crash:ApplicationNotResponding")
        XCTAssertEqual(report.observed?.crash?["mechanism"], "app_hang")
    }

    func testShortStallDoesNotReproduceAnANRCapsule() async throws {
        let engine = try XCTUnwrap(
            bareSession().startReplayForTesting(
                capsule: crashCapsule("ApplicationNotResponding", t: 1_500), settings: ReplaySettings(settleTimeoutMs: 100)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Thread.sleep(forTimeInterval: 0.8) }
        let report = await engine.run()
        XCTAssertEqual(report.outcome, .notReproduced)
    }

    func testUncaughtExceptionDuringACrashReplay() throws {
        let failure = BugCapsuleSession.failure(
            for: NSException(name: .invalidArgumentException, reason: "boom"), t: 10, redactor: Redactor())
        let other = try XCTUnwrap(bareSession().startReplayForTesting(capsule: crashCapsule("SIGSEGV"), settings: ReplaySettings()))
        let reports = CrashReportBox()
        other.onReport = { reports.add($0) }
        other.uncaught(failure, reason: "uncaught exception")
        XCTAssertEqual(reports.all.first?.outcome, .inconclusive)
        XCTAssertEqual(reports.all.first?.reasonCodes, ["failure.different"])
        XCTAssertEqual(reports.all.first?.observed?.signature, "crash:NSInvalidArgumentException")

        let same = try XCTUnwrap(
            bareSession().startReplayForTesting(capsule: crashCapsule("NSInvalidArgumentException"), settings: ReplaySettings()))
        let sameReports = CrashReportBox()
        same.onReport = { sameReports.add($0) }
        same.uncaught(failure, reason: "uncaught exception")
        XCTAssertEqual(sameReports.all.first?.outcome, .reproduced)
    }
}

final class CrashReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [ReplayReport] = []
    func add(_ r: ReplayReport) { lock.locked { reports.append(r) } }
    var all: [ReplayReport] { lock.locked { reports } }
}
