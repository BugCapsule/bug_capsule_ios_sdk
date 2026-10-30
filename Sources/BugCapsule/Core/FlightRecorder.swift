import Foundation

/// The checkpoint plus the events that follow it — what a capsule replays.
public struct RecordedWindow: Sendable {
    public let checkpoint: Checkpoint
    public let events: [BugCapsuleEvent]
    /// Events evicted from the buffer over the whole session.
    public let droppedEvents: Int
    /// No retained checkpoint covers the oldest retained event.
    public let hasGap: Bool
}

/// Bounded event buffer with checkpoints (port of `flight_recorder.dart`).
///
/// While nothing has been evicted, the window is the launch checkpoint plus
/// every event. After eviction starts, the window starts at the earliest
/// periodic checkpoint taken after the last evicted event. Not thread-safe:
/// the runtime serializes access.
public final class FlightRecorder: @unchecked Sendable {
    public let maxEvents: Int
    public let windowMs: Int
    public let maxCheckpoints: Int

    private var launch: Checkpoint
    private var events: [BugCapsuleEvent] = []
    private var head = 0  // index of the first retained event in `events`
    private var periodic: [Checkpoint] = []
    private var seq = 0
    private var dropped = 0
    private var lastEvictedSeq = 0

    /// Events removed by `rewrite` over the session.
    public private(set) var rewriteDropped = 0

    public init(launch: Checkpoint, maxEvents: Int = 20000, windowMs: Int = 5 * 60 * 1000, maxCheckpoints: Int = 4) {
        precondition(launch.kind == .launch)
        self.launch = launch
        self.maxEvents = maxEvents
        self.windowMs = windowMs
        self.maxCheckpoints = maxCheckpoints
    }

    public var lastSeq: Int { seq }
    public var eventCount: Int { events.count - head }
    public var droppedEvents: Int { dropped }
    public var launchCoversWindow: Bool { dropped == 0 }

    @discardableResult
    public func add(t: Int, type: String, data: JSONObject = JSONObject()) -> BugCapsuleEvent {
        seq += 1
        let e = BugCapsuleEvent(seq: seq, t: t, type: type, data: data)
        events.append(e)
        evict(now: t)
        return e
    }

    public func addCheckpoint(_ checkpoint: Checkpoint) {
        precondition(checkpoint.kind == .periodic)
        periodic.append(checkpoint)
        prune()
    }

    /// Rewrites retained events and checkpoints in place (new redaction
    /// rules). Returning nil drops the event (counted in `rewriteDropped`).
    public func rewrite(event: ((BugCapsuleEvent) -> BugCapsuleEvent?)? = nil, checkpoint: ((Checkpoint) -> Checkpoint)? = nil) {
        if let event {
            var updated: [BugCapsuleEvent] = []
            for e in events[head...] {
                if let r = event(e) { updated.append(r) } else { rewriteDropped += 1 }
            }
            events = updated
            head = 0
        }
        if let checkpoint {
            launch = checkpoint(launch)
            periodic = periodic.map(checkpoint)
        }
    }

    public func checkpointNow(kind: CheckpointKind, t: Int, wallClockMs: Int, data: JSONObject) -> Checkpoint {
        Checkpoint(kind: kind, t: t, wallClockMs: wallClockMs, afterSeq: seq, data: data)
    }

    public func window() -> RecordedWindow {
        let retained = Array(events[head...])
        if launchCoversWindow {
            return RecordedWindow(checkpoint: launch, events: retained, droppedEvents: 0, hasGap: false)
        }
        var chosen = periodic.first { $0.afterSeq >= lastEvictedSeq }
        let hasGap = chosen == nil
        if chosen == nil { chosen = periodic.last ?? launch }
        let from = chosen!.afterSeq
        return RecordedWindow(
            checkpoint: chosen!, events: retained.filter { $0.seq > from }, droppedEvents: dropped, hasGap: hasGap)
    }

    /// What the crash journal mirrors (crash-capsules §1): the launch
    /// checkpoint (it covers the events while nothing was evicted), the
    /// newest periodic checkpoint and the retained events.
    func journalState() -> (launch: Checkpoint, launchCovers: Bool, periodic: Checkpoint?, events: [BugCapsuleEvent]) {
        (launch, launchCoversWindow, periodic.last, Array(events[head...]))
    }

    private func evict(now: Int) {
        while head < events.count && (events.count - head > maxEvents || events[head].t < now - windowMs) {
            lastEvictedSeq = events[head].seq
            head += 1
            dropped += 1
        }
        // Compact occasionally so memory stays bounded.
        if head > 4096 && head * 2 > events.count {
            events.removeFirst(head)
            head = 0
        }
        if dropped > 0 { prune() }
    }

    private func prune() {
        let firstValid = periodic.firstIndex { $0.afterSeq >= lastEvictedSeq }
        let keepFrom = firstValid ?? (periodic.count - 1)
        if keepFrom > 0 { periodic.removeFirst(keepFrom) }
        while periodic.count > maxCheckpoints { periodic.removeFirst() }
    }
}

/// Decides when replay may jump over an idle stretch before an input
/// (port of `idle_compression.dart`).
public struct IdleCompressor: Sendable {
    public let events: [BugCapsuleEvent]
    public let minGapMs: Int
    public let collapseToMs: Int

    public init(events: [BugCapsuleEvent], minGapMs: Int = 1500, collapseToMs: Int = 300) {
        self.events = events
        self.minGapMs = minGapMs
        self.collapseToMs = collapseToMs
    }

    /// Recorded time from which the recording is idle until the input at
    /// [to], given the previous input at [from]; nil when not longer than
    /// `minGapMs`. An HTTP exchange counts from request to response. Guard
    /// decisions aren't app activity: they are written again after every
    /// periodic checkpoint, and replay finds them by time wherever it jumps.
    public func idleSince(from: Int, to: Int) -> Int? {
        if to - from <= minGapMs { return nil }
        var since = from
        for e in events where e.type != EventTypes.emergencyDecision {
            let start = e.type == EventTypes.http ? e.t - (e.data["durationMs"]?.intValue ?? 0) : e.t
            if start >= to { continue }
            let end = e.t < to ? e.t : to
            if end > since { since = end }
        }
        return to - since > minGapMs ? since : nil
    }

    public func maySkip(now: Int, idleSince: Int, busy: Int, quietMs: Int) -> Bool {
        busy == 0 && quietMs >= collapseToMs && now >= idleSince + collapseToMs
    }
}
