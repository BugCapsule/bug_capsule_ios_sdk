import Foundation

/// The crash journal of this process (crash-capsules §1): what the flight
/// recorder holds, mirrored to `journal/<pid>/` so the next launch can build
/// a capsule when a native crash, a watchdog kill or another death leaves
/// no time to write one.
///
/// * `header.json`: the manifest fields known while running (`anchorT` and
///   `wallClockAtStartMs` place the session clock on the anchor).
/// * `checkpoints/<afterSeq>.json`: the launch checkpoint while nothing was
///   evicted, plus the newest periodic one.
/// * `events/<afterSeq + 1>.jsonl`: one file per checkpoint, one event per
///   line, `t` on the recorder's session clock.
///
/// Callers hand items over under their own lock (order is kept) and return;
/// a serial queue batches them into one write per file at least every
/// 250 ms, and at once on a checkpoint, a failure and going to the
/// background. Files are protected until first unlock, like saved capsules.
final class CrashJournal: @unchecked Sendable {
    static let flushInterval: TimeInterval = 0.25

    let directory: URL
    var eventsDirectory: URL { directory.appendingPathComponent("events", isDirectory: true) }
    var checkpointsDirectory: URL { directory.appendingPathComponent("checkpoints", isDirectory: true) }
    var headerFile: URL { directory.appendingPathComponent("header.json") }

    private enum Item {
        case event(BugCapsuleEvent)
        /// A periodic checkpoint was taken after this seq: later events go to a new file.
        case boundary(Int)
        case checkpoint(Checkpoint)
        /// The recorder evicted its first event: the launch checkpoint goes
        /// once a periodic one covers what is left.
        case evicted
        case header(JSONObject)
        case reset(header: JSONObject, launch: Checkpoint?, launchCovers: Bool, periodic: Checkpoint?, events: [BugCapsuleEvent])
    }

    private let queue = DispatchQueue(label: "com.bugcapsule.journal", qos: .utility)
    private let lock = NSLock()
    private var pending: [Item] = []
    private var flushScheduled = false
    private var stopped = false
    private var lastHeader: JSONObject?
    private var _maxBytes: Int

    // Writer state (queue only).
    private var currentStart = 1
    private var handle: FileHandle?
    private var handleStart: Int?
    private var files: [Int: Int] = [:]
    private var launchBytes: Int?
    private var periodic: (afterSeq: Int, bytes: Int)?
    private var headerBytes = 0
    private var evicted = false
    private var lastSeq = 0

    /// Starts the journal with the header and the launch checkpoint.
    init(directory: URL, maxBytes: Int, header: JSONObject, launch: Checkpoint) {
        self.directory = directory
        _maxBytes = max(maxBytes, 0)
        lastHeader = header
        pending = [.header(header), .checkpoint(launch)]
        queue.async { self.drain() }
    }

    /// At most `2 × maxCapsuleBytes` on disk.
    var maxBytes: Int {
        get { lock.locked { _maxBytes } }
        set { lock.locked { _maxBytes = max(newValue, 0) } }
    }

    func append(_ event: BugCapsuleEvent) { enqueue(.event(event), now: false) }

    /// Call where the recorder's `lastSeq` is read for a periodic checkpoint.
    func boundary(afterSeq: Int) { enqueue(.boundary(afterSeq), now: false) }

    func checkpoint(_ checkpoint: Checkpoint) { enqueue(.checkpoint(checkpoint), now: true) }

    func recorderEvicted() { enqueue(.evicted, now: false) }

    /// Rewrites `header.json` when [header] changed.
    func updateHeader(_ header: JSONObject) {
        let changed = lock.locked { () -> Bool in
            guard header != lastHeader else { return false }
            lastHeader = header
            return true
        }
        if changed { enqueue(.header(header), now: true) }
    }

    /// Replaces everything (the recorder rewrote its buffer: new redaction rules).
    /// [launch] is dropped when [launchCovers] is false and a periodic checkpoint exists.
    func reset(header: JSONObject, launch: Checkpoint, launchCovers: Bool, periodic: Checkpoint?, events: [BugCapsuleEvent]) {
        lock.locked { lastHeader = header }
        let keepLaunch = launchCovers || periodic == nil
        enqueue(
            .reset(header: header, launch: keepLaunch ? launch : nil, launchCovers: launchCovers, periodic: periodic, events: events),
            now: true)
    }

    /// Writes what is pending now (a failure, going to the background).
    func flush() {
        let go = lock.locked { !stopped && !pending.isEmpty }
        if go { queue.async { self.drain() } }
    }

    /// Writes what is pending before returning.
    func flushSynchronously() { queue.sync { drain() } }

    /// Stops journaling and keeps the files (the process ends).
    func close() {
        queue.sync {
            drain()
            lock.locked { stopped = true }
            closeHandle()
        }
    }

    /// Stops journaling and deletes the journal (its capsule was written,
    /// or the session stopped recording).
    func delete() {
        lock.locked {
            stopped = true
            pending = []
        }
        queue.sync {
            closeHandle()
            FileIO.deleteQuietly(directory)
        }
    }

    private func enqueue(_ item: Item, now: Bool) {
        let schedule: TimeInterval? = lock.locked {
            if stopped { return nil }
            pending.append(item)
            if now { return 0 }
            if flushScheduled { return nil }
            flushScheduled = true
            return Self.flushInterval
        }
        guard let schedule else { return }
        if schedule == 0 {
            queue.async { self.drain() }
        } else {
            queue.asyncAfter(deadline: .now() + schedule) { self.drain() }
        }
    }

    // MARK: writer (queue)

    private func drain() {
        let (items, limit) = lock.locked { () -> ([Item], Int) in
            let p = pending
            pending = []
            flushScheduled = false
            return (stopped ? [] : p, _maxBytes)
        }
        if items.isEmpty { return }
        guard (try? Self.ensureDirectory(eventsDirectory)) != nil, (try? Self.ensureDirectory(checkpointsDirectory)) != nil else {
            return
        }
        var buffers: [Int: Data] = [:]
        func writeBuffers() {
            for start in buffers.keys.sorted() { append(buffers[start]!, toFile: start) }
            buffers = [:]
        }
        for item in items {
            switch item {
            case .event(let e):
                lastSeq = max(lastSeq, e.seq)
                buffers[currentStart, default: Data()].append(JSON.encodeData(e.json) + Data([0x0A]))
            case .boundary(let afterSeq):
                writeBuffers()
                closeHandle()
                currentStart = max(afterSeq + 1, 1)
            case .checkpoint(let c):
                writeBuffers()
                write(checkpoint: c)
            case .evicted:
                evicted = true
                dropBeforePeriodic()
            case .header(let h):
                write(header: h)
            case .reset(let header, let launch, let launchCovers, let periodic, let events):
                writeBuffers()
                rewrite(header: header, launch: launch, launchCovers: launchCovers, periodic: periodic, events: events)
            }
        }
        writeBuffers()
        enforce(limit)
    }

    private func write(header: JSONObject) {
        var h = header
        h["writtenAt"] = .string(ISODate.format(Date()))
        let data = JSON.encodeData(.object(h))
        if (try? Self.writeAtomically(data, to: headerFile)) != nil { headerBytes = data.count }
    }

    private func write(checkpoint c: Checkpoint) {
        // A periodic checkpoint before any event adds nothing to the launch one.
        if c.kind == .periodic && launchBytes != nil && c.afterSeq == 0 { return }
        let data = JSON.encodeData(c.json)
        guard (try? Self.writeAtomically(data, to: checkpointFile(c.afterSeq))) != nil else { return }
        if c.kind == .launch {
            launchBytes = data.count
            return
        }
        if let p = periodic, p.afterSeq != c.afterSeq { FileIO.deleteQuietly(checkpointFile(p.afterSeq)) }
        periodic = (c.afterSeq, data.count)
        dropBeforePeriodic()
    }

    /// Once the recorder evicted events, the newest periodic checkpoint is
    /// where a capsule starts: the launch checkpoint and the event files
    /// before it go.
    private func dropBeforePeriodic() {
        guard evicted, let p = periodic else { return }
        dropLaunch()
        for start in files.keys where start <= p.afterSeq { deleteEvents(start) }
    }

    private func dropLaunch() {
        guard launchBytes != nil else { return }
        FileIO.deleteQuietly(checkpointFile(0))
        launchBytes = nil
    }

    /// [launch]: the launch checkpoint while it covers [events] or is the
    /// only checkpoint; [newPeriodic]: the newest periodic one.
    private func rewrite(
        header: JSONObject, launch: Checkpoint?, launchCovers: Bool, periodic newPeriodic: Checkpoint?, events: [BugCapsuleEvent]
    ) {
        closeHandle()
        FileIO.deleteQuietly(eventsDirectory)
        FileIO.deleteQuietly(checkpointsDirectory)
        files = [:]
        launchBytes = nil
        periodic = nil
        evicted = !launchCovers
        guard (try? Self.ensureDirectory(eventsDirectory)) != nil, (try? Self.ensureDirectory(checkpointsDirectory)) != nil else {
            return
        }
        write(header: header)
        if let launch { write(checkpoint: launch) }
        if let newPeriodic { write(checkpoint: newPeriodic) }
        let from = launch?.afterSeq ?? newPeriodic?.afterSeq ?? 0
        let kept = events.filter { $0.seq > from }
        // Events the launch checkpoint no longer covers start a file named
        // after the first of them: the missing `1.jsonl` marks the gap.
        let first = launch != nil && !launchCovers ? (kept.first?.seq ?? from + 1) : from + 1
        var boundaries = [first]
        if let newPeriodic, newPeriodic.afterSeq + 1 > first { boundaries.append(newPeriodic.afterSeq + 1) }
        for (i, start) in boundaries.enumerated() {
            let end = i + 1 < boundaries.count ? boundaries[i + 1] : Int.max
            var data = Data()
            for e in kept where e.seq >= start && e.seq < end {
                lastSeq = max(lastSeq, e.seq)
                data.append(JSON.encodeData(e.json) + Data([0x0A]))
            }
            currentStart = start
            if !data.isEmpty { append(data, toFile: start) }
        }
    }

    private func append(_ data: Data, toFile start: Int) {
        let url = eventsFile(start)
        if handleStart != start {
            closeHandle()
            if !FileIO.fm.fileExists(atPath: url.path) {
                guard FileIO.fm.createFile(atPath: url.path, contents: nil, attributes: Self.protection) else { return }
            }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            _ = try? h.seekToEnd()
            handle = h
            handleStart = start
        }
        do {
            try handle?.write(contentsOf: data)
            files[start, default: 0] += data.count
        } catch {
            closeHandle()
        }
        if start != currentStart { closeHandle() }
    }

    /// Past the size limit the oldest events file goes, and the launch
    /// checkpoint with it.
    private func enforce(_ limit: Int) {
        func total() -> Int { headerBytes + (launchBytes ?? 0) + (periodic?.bytes ?? 0) + files.values.reduce(0, +) }
        while total() > limit, let oldest = files.keys.min() {
            deleteEvents(oldest)
            dropLaunch()
            if oldest == currentStart { currentStart = lastSeq + 1 }
        }
    }

    private func deleteEvents(_ start: Int) {
        if handleStart == start { closeHandle() }
        FileIO.deleteQuietly(eventsFile(start))
        files[start] = nil
    }

    private func closeHandle() {
        try? handle?.close()
        handle = nil
        handleStart = nil
    }

    private func eventsFile(_ start: Int) -> URL { eventsDirectory.appendingPathComponent("\(start).jsonl") }
    private func checkpointFile(_ afterSeq: Int) -> URL { checkpointsDirectory.appendingPathComponent("\(afterSeq).json") }

    // MARK: files

    static var protection: [FileAttributeKey: Any]? {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            return [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
            return nil
        #endif
    }

    static func ensureDirectory(_ url: URL) throws {
        try FileIO.fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: protection)
    }

    /// Temp file + rename.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
            try data.write(to: url, options: [.atomic])
        #endif
    }
}

/// A journal left by an earlier process, read back on a later launch.
struct CrashJournalContents {
    let directory: URL
    let header: JSONObject
    let launch: Checkpoint?
    /// The newest periodic checkpoint.
    let periodic: Checkpoint?
    /// Every journaled event, by seq.
    let events: [BugCapsuleEvent]
    /// First seqs of the event files present.
    let fileStarts: Set<Int>
    /// Kept for a MetricKit diagnostic that may still arrive.
    let claimedAt: Date?

    static func claimFile(_ dir: URL) -> URL { dir.appendingPathComponent("claim.json") }

    /// Nil when there is no readable header. A line cut short by the crash is skipped.
    static func load(_ dir: URL) -> CrashJournalContents? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("header.json")),
            let header = (try? JSON.parse(data))?.objectValue
        else { return nil }
        var launch: Checkpoint?
        var periodic: Checkpoint?
        let cpDir = dir.appendingPathComponent("checkpoints", isDirectory: true)
        for url in (try? FileIO.fm.contentsOfDirectory(at: cpDir, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "json" {
            guard let o = (try? Data(contentsOf: url)).flatMap({ try? JSON.parse($0) })?.objectValue,
                o["kind"]?.stringValue != nil
            else { continue }
            let c = Checkpoint(json: o)
            if c.kind == .launch {
                launch = c
            } else if c.afterSeq >= (periodic?.afterSeq ?? -1) {
                periodic = c
            }
        }
        var bySeq: [Int: BugCapsuleEvent] = [:]
        var starts = Set<Int>()
        let evDir = dir.appendingPathComponent("events", isDirectory: true)
        for url in (try? FileIO.fm.contentsOfDirectory(at: evDir, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "jsonl" {
            guard let start = Int(url.deletingPathExtension().lastPathComponent),
                let bytes = try? Data(contentsOf: url)
            else { continue }
            starts.insert(start)
            for line in bytes.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard let o = (try? JSON.parse(Data(line)))?.objectValue, o["seq"]?.intValue != nil,
                    o["type"]?.stringValue != nil
                else { continue }
                let e = BugCapsuleEvent(json: o)
                bySeq[e.seq] = e
            }
        }
        let claimed = (try? Data(contentsOf: claimFile(dir))).flatMap { try? JSON.parse($0) }?["claimedAt"]?.intValue
        return CrashJournalContents(
            directory: dir, header: header, launch: launch, periodic: periodic,
            events: bySeq.keys.sorted().map { bySeq[$0]! }, fileStarts: starts,
            claimedAt: claimed.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) })
    }

    var pid: Int? { header["pid"]?.intValue }
    var writtenAt: Date? { header["writtenAt"]?.stringValue.flatMap(ISODate.parse) }

    /// crash-capsules §2: the launch checkpoint when every event after it is
    /// still here, else the newest periodic one ([periodicOnly]: the smaller
    /// capsule). `hasGap`: events between the checkpoint and the first
    /// journaled one were lost.
    func window(periodicOnly: Bool = false) -> (checkpoint: Checkpoint, events: [BugCapsuleEvent], hasGap: Bool)? {
        if !periodicOnly, let launch, events.isEmpty || fileStarts.contains(launch.afterSeq + 1) {
            return (launch, events.filter { $0.seq > launch.afterSeq }, false)
        }
        if let periodic {
            let after = events.filter { $0.seq > periodic.afterSeq }
            return (periodic, after, !after.isEmpty && !fileStarts.contains(periodic.afterSeq + 1))
        }
        if !periodicOnly, let launch { return (launch, events.filter { $0.seq > launch.afterSeq }, true) }
        return nil
    }

    /// The process was in the foreground when it ended (its last lifecycle
    /// event is not a move to the background).
    var endedInForeground: Bool {
        let last = events.last { $0.type == EventTypes.lifecycle }?.data["state"]?.stringValue
        return last != "paused" && last != "detached"
    }
}

/// The `journal/` directory: one journal per process, cleaned up on launch.
final class CrashJournals: @unchecked Sendable {
    static let maxAge: TimeInterval = 7 * 24 * 3600

    let root: URL
    let pid = Int(getpid())

    init(root: URL) {
        self.root = root
    }

    /// `journal/<pid>` of this process.
    var currentDirectory: URL { root.appendingPathComponent("\(pid)", isDirectory: true) }

    /// A journal already under this process's id (an earlier process with
    /// the same pid) is moved to `<pid>.<random>`, so this process starts a
    /// fresh one and the old one can still be claimed.
    func setAsideCurrent() {
        let dir = currentDirectory
        guard FileIO.fm.fileExists(atPath: dir.path) else { return }
        let aside = root.appendingPathComponent("\(pid).\(uuidV4().prefix(8))", isDirectory: true)
        if (try? FileIO.fm.moveItem(at: dir, to: aside)) == nil { FileIO.deleteQuietly(dir) }
    }

    /// Journals of earlier processes, newest first.
    func earlier() -> [URL] {
        let items = (try? FileIO.fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return items.filter { $0.standardizedFileURL != currentDirectory.standardizedFileURL && Self.pid(of: $0) != nil }
            .sorted { FileIO.modified($0) > FileIO.modified($1) }
    }

    /// The pid a journal directory is named after (`<pid>` or `<pid>.<suffix>`).
    static func pid(of dir: URL) -> Int? {
        Int(dir.lastPathComponent.split(separator: ".", maxSplits: 1).first ?? "")
    }

    /// The newest journal of an earlier process [pid].
    func find(pid: Int) -> URL? {
        earlier().first { Self.pid(of: $0) == pid && FileIO.fm.fileExists(atPath: $0.appendingPathComponent("header.json").path) }
    }

    func claim(_ dir: URL, at date: Date = Date()) {
        let data = JSON.encodeData(["claimedAt": .int(Int(date.timeIntervalSince1970 * 1000))])
        try? CrashJournal.writeAtomically(data, to: CrashJournalContents.claimFile(dir))
    }

    /// Deletes every earlier journal no fatal event claimed, and any older
    /// than 7 days. With [claimForMetricKit], a journal of a process that
    /// ended in the foreground without a crash report is claimed instead: a
    /// MetricKit diagnostic (watchdog, memory, a crash the handler missed)
    /// may arrive for it later.
    func cleanup(claimForMetricKit: Bool, now: Date = Date()) {
        for dir in earlier() {
            guard let contents = CrashJournalContents.load(dir) else {
                FileIO.deleteQuietly(dir)
                continue
            }
            let since = contents.claimedAt ?? contents.writtenAt ?? FileIO.modified(dir)
            if now.timeIntervalSince(since) > Self.maxAge {
                FileIO.deleteQuietly(dir)
            } else if contents.claimedAt != nil {
                continue
            } else if claimForMetricKit && contents.endedInForeground {
                claim(dir, at: now)
            } else {
                FileIO.deleteQuietly(dir)
            }
        }
    }
}
