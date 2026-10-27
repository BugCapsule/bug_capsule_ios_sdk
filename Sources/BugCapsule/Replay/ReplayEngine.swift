import Foundation

/// Drives a replay inside the real app (port of `replay_engine.dart`):
/// dispatches recorded semantic actions, tracked text and lifecycle at the
/// recorded times, watches for the original failure and reports.
///
/// iOS specifics:
/// * Pointer replay is not implemented (`input.pointer.replay:
///   unsupported`): the strategy is always semantic, and a capsule that
///   needs pointer input (only pointers recorded, or `--strategy pointer`)
///   gets the material `pointer.unsupported` divergence.
/// * Lifecycle is replayed by posting the matching `UIApplication`
///   notifications (`lifecycle.replay: partial`).
/// * With idle compression, long idle gaps are skipped; the virtual clock
///   (`BugCapsule.now()`) runs ahead of real time by the skipped amount.
/// * Interaction dependencies (capsule-v2: WebSockets, native adapters) are
///   served by `interactions` on the same clock: a delivery that is due
///   limits a skip to its deadline; an idle open connection does not keep
///   replay busy.
/// * Crash capsules (crash-capsules §4): the death of the process is judged
///   by `BugCapsuleXCTest` from the crash report. In the app, an
///   `ApplicationNotResponding` capsule is reproduced when the main thread
///   stays blocked past 2 s (reported from a background thread), and an
///   uncaught NSException reproduces only a crash of the same type
///   (otherwise `inconclusive`, `failure.different`). A replay that ends
///   with the app alive is `not_reproduced` as usual.
public final class ReplayEngine: ReplayContext, @unchecked Sendable {
    public let capsule: Capsule
    public let settings: ReplaySettings
    public let fixtures: FixtureStore
    let buildGitSha: String?
    let channel: ReplayChannel?
    weak var session: BugCapsuleSession?

    private let lock = NSLock()
    private var divergences: [Divergence] = []
    private var otherFailures: [FailureRecord] = []
    private var reproduced: FailureRecord?
    /// A crash capsule's replay died of another failure (`failure.different`).
    private var differentCrash: FailureRecord?
    private var fixturesServedCount = 0
    private var dispatched = 0
    private var expected = 0
    private let idle: IdleCompressor
    private var skippedMs = 0
    private var gapsCompressed = 0
    private var work = 0
    private var lastActivityMs = 0
    private var strategy: ReplayStrategy = .semantic
    private var runStart: TimeInterval?
    private let restoreStart = uptime()
    private var finished = false
    private var firstInput = false
    private var finishHooks: [@Sendable (ReplayEngine) -> Void] = []
    /// Called with the final report (tests).
    var onReport: (@Sendable (ReplayReport) -> Void)?
    /// Recorded interaction dependencies (empty when the capsule has none:
    /// adapters still fail unrecorded operations instead of going live).
    private(set) var interactions: InteractionReplay?

    init(capsule: Capsule, settings: ReplaySettings, buildGitSha: String?, channel: ReplayChannel?, session: BugCapsuleSession?) {
        self.capsule = capsule
        self.settings = settings
        self.buildGitSha = buildGitSha
        self.channel = channel
        self.session = session
        fixtures = FixtureStore(events: capsule.events)
        idle = IdleCompressor(events: capsule.events)
        interactions = InteractionReplay(
            capsule: capsule, clock: { [weak self] in self?.interactionClock() ?? 0 },
            base: capsule.checkpoint.kind == .launch ? 0 : capsule.checkpoint.t,
            diverge: { [weak self] type, detail in self?.diverge(type, detail) },
            activity: { [weak self] in self?.activity() })
    }

    // MARK: clocks

    private var base: Int { capsule.checkpoint.kind == .launch ? 0 : capsule.checkpoint.t }

    /// Real milliseconds since `run` started (0 before).
    private func clockMs() -> Int {
        guard let runStart = lock.locked({ self.runStart }) else { return 0 }
        return Int(((uptime() - runStart) * 1000).rounded(.down))
    }

    /// Replay clock in recorded milliseconds since run start.
    func elapsed() -> Int { clockMs() + lock.locked { skippedMs } }

    /// Clock of the interaction scheduler: runs from engine creation (apps
    /// connect before the anchor) and includes skipped idle time.
    func interactionClock() -> Int { Int(((uptime() - restoreStart) * 1000).rounded(.down)) + lock.locked { skippedMs } }

    /// Virtual wall clock: checkpoint time + elapsed since restore + skipped idle time.
    func virtualNow() -> Date {
        let ms = capsule.checkpoint.wallClockMs + Int((uptime() - restoreStart) * 1000) + lock.locked { skippedMs }
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }

    // MARK: ReplayContext

    public func diverge(_ type: String, _ detail: String) {
        let t: Int? = lock.locked { runStart } == nil ? nil : elapsed()
        lock.locked {
            if divergences.count < 200 { divergences.append(Divergence(type, detail, t: t)) }
        }
    }

    public func fixtureServed() { lock.locked { fixturesServedCount += 1 } }

    public func beginWork() -> @Sendable () -> Void {
        lock.locked { work += 1 }
        activity()
        let ended = Flag()
        return { [weak self] in
            guard ended.set() else { return }
            self?.lock.locked { self?.work -= 1 }
            self?.activity()
        }
    }

    public func activity() {
        let now = clockMs()
        lock.locked { lastActivityMs = now }
    }

    public var hasDispatchedInput: Bool { lock.locked { firstInput } }

    /// Runs `hook` right before the report is built (e.g. `restore.missing`).
    func onFinish(_ hook: @escaping @Sendable (ReplayEngine) -> Void) { lock.locked { finishHooks.append(hook) } }

    private var quietMs: Int { clockMs() - lock.locked { lastActivityMs } }
    private var busy: Int { lock.locked { work } }

    func onFailure(_ failure: FailureRecord) {
        let expected = capsule.manifest.failure
        if let expected, failure.signature == expected.signature {
            lock.locked { if reproduced == nil { reproduced = failure } }
        } else {
            lock.locked { otherFailures.append(failure) }
            diverge("failure.other", failure.signature)
        }
    }

    private var isReproduced: Bool { lock.locked { reproduced != nil } }
    private var isFinished: Bool { lock.locked { finished } }

    /// The capsule replays a crash (failure kind `crash`).
    var expectsCrash: Bool { capsule.manifest.failure?.kind == .crash }

    static let anrType = CrashVerdict.anrType
    /// iOS's app hang threshold for ANR crash capsules (crash-capsules §4).
    static let hangThreshold: TimeInterval = 2

    /// Uncaught NSException: reports synchronously before the process
    /// terminates. For a crash capsule it reproduces only a crash of the
    /// same type (`crash:<exception name>`).
    func uncaught(_ failure: FailureRecord, reason: String) {
        if expectsCrash, let expected = capsule.manifest.failure {
            let observed = FailureRecord.crash(
                type: failure.type, message: failure.message, stack: failure.stack, crash: ["mechanism": "nsexception"],
                t: lock.locked { runStart } == nil ? 0 : elapsed())
            lock.locked {
                if observed.signature == expected.signature {
                    if reproduced == nil { reproduced = observed }
                } else if reproduced == nil {
                    differentCrash = observed
                }
            }
        } else {
            onFailure(failure)
        }
        finishSynchronously(reason: reason)
    }

    /// ANR capsules: a watchdog thread pings the main thread; no answer
    /// within [threshold] is the reproduction, reported from that thread
    /// (the main thread may never come back).
    private func watchMainThread(threshold: TimeInterval) {
        let thread = Thread { [weak self] in
            while let engine = self, !engine.isFinished {
                let answered = Flag()
                let sent = uptime()
                DispatchQueue.main.async { _ = answered.set() }
                while !answered.isSet && uptime() - sent < threshold && !engine.isFinished { usleep(20_000) }
                if engine.isFinished { return }
                if !answered.isSet {
                    engine.mainThreadHung(for: uptime() - sent)
                    return
                }
                usleep(100_000)
            }
        }
        thread.name = "BugCapsule replay hang watch"
        thread.start()
    }

    private func mainThreadHung(for seconds: TimeInterval) {
        let observed = FailureRecord.crash(
            type: Self.anrType, message: "the main thread was blocked for \(Int(seconds * 1000)) ms during replay",
            stack: nil, crash: ["mechanism": "app_hang"], t: elapsed())
        let report: ReplayReport? = lock.locked {
            guard !finished, reproduced == nil else { return nil }
            reproduced = observed
            // Built here: finish hooks and fixtures may need the main thread.
            return ReplayReport(
                outcome: .reproduced, attempt: settings.attempt,
                durationMs: runStart.map { Int((uptime() - $0) * 1000) } ?? 0, strategy: strategy,
                expectedSignature: capsule.manifest.failure?.signature, observed: observed, otherFailures: otherFailures,
                divergences: divergences, eventsDispatched: dispatched, eventsExpected: expected,
                fixturesServed: fixturesServedCount, compressedMs: skippedMs, gapsCompressed: gapsCompressed,
                buildGitSha: buildGitSha, message: "app hang past \(Int(Self.hangThreshold)) s", attemptId: settings.attemptId,
                runtime: "ios")
        }
        if let report { complete(report) }
    }

    func precheck() {
        let m = capsule.manifest
        if let sha = m.gitSha, let build = buildGitSha, sha != build {
            diverge("build.gitSha", "capsule \(sha) vs build \(build)")
        }
    }

    func chooseStrategy() -> ReplayStrategy {
        let pointers = capsule.events.filter { $0.type == EventTypes.pointer }.count
        let hasActions = capsule.events.contains { $0.type == EventTypes.action }
        switch settings.strategy {
        case .pointer:
            diverge("pointer.unsupported", "pointer replay is not supported on iOS; replaying semantic actions instead")
        case .semantic:
            break
        case .auto:
            if pointers > 0 && !hasActions {
                diverge(
                    "pointer.unsupported",
                    "the capsule has only pointer input (\(pointers) events) and iOS replays semantic actions only")
            }
        }
        return .semantic
    }

    private func shouldDispatch(_ type: String) -> Bool {
        switch type {
        case EventTypes.lifecycle, EventTypes.text: return true
        case EventTypes.action: return strategy == .semantic
        default: return false
        }
    }

    // MARK: run

    /// Starts the replay at the anchor (main thread).
    @MainActor
    func start() {
        Task { @MainActor in
            let report = await self.run()
            self.complete(report)
        }
    }

    @MainActor
    func run() async -> ReplayReport {
        lock.locked { runStart = uptime() }
        interactions?.runStarted(at: interactionClock())
        strategy = chooseStrategy()
        let expectedFailure = capsule.manifest.failure
        if expectedFailure?.kind == .crash && expectedFailure?.type == Self.anrType {
            watchMainThread(threshold: Self.hangThreshold)
        }
        let base = self.base
        let toDispatch = capsule.events.filter { shouldDispatch($0.type) && $0.t >= base }
        lock.locked { expected = toDispatch.count }

        var lastT = 0
        var previous = base
        for event in toDispatch {
            if isReproduced { break }
            let due = event.t - base
            lastT = due
            let idleSince = settings.idleCompression ? idle.idleSince(from: previous, to: event.t) : nil
            previous = event.t
            while !isReproduced {
                interactions?.pump()
                let wait = due - elapsed()
                if wait <= 0 { break }
                if let idleSince, idle.maySkip(now: elapsed() + base, idleSince: idleSince, busy: busy, quietMs: quietMs) {
                    // A recorded delivery due before the input bounds the
                    // jump (capsule-v2 §5): it arrives at its time, then the
                    // gap is re-checked.
                    let untilDue = interactions?.nextDueAt.map { $0 - interactionClock() } ?? wait
                    if untilDue <= 0 {
                        try? await Task.sleep(nanoseconds: 2_000_000)
                        continue
                    }
                    let skip = min(untilDue, wait)
                    lock.locked {
                        skippedMs += skip
                        if skip == wait { gapsCompressed += 1 }
                    }
                    interactions?.clockJumped()
                    if skip == wait { break }
                    continue
                }
                // Inside a compressible gap re-check idleness every 50 ms;
                // otherwise wake at least every 50 ms to notice the failure.
                try? await Task.sleep(nanoseconds: UInt64(min(wait, 50)) * 1_000_000)
            }
            if isReproduced { break }
            dispatch(event)
        }

        if !isReproduced {
            let failureDue = expectedFailure.map { $0.t - base } ?? 0
            let deadline = max(failureDue, lastT) + (expectedFailure == nil ? 1500 : settings.settleTimeoutMs)
            while !isReproduced && elapsed() < deadline {
                interactions?.pump()
                try? await Task.sleep(nanoseconds: UInt64(max(min(deadline - elapsed(), 50), 1)) * 1_000_000)
            }
        }
        return buildReport()
    }

    func buildReport(message: String? = nil) -> ReplayReport {
        let hooks = lock.locked { finishHooks }
        for hook in hooks { hook(self) }
        for key in fixtures.unusedKeys() { diverge("network.unused", key) }
        let expectedFailure = capsule.manifest.failure
        for (type, detail) in interactions?.finish(failureT: expectedFailure?.t) ?? [] { diverge(type, detail) }
        let (reproducedFailure, different) = lock.locked { (reproduced, differentCrash) }
        var observed = reproducedFailure
        var outcome: ReplayOutcome =
            expectedFailure == nil ? .noAssertion : observed != nil ? .reproduced : .notReproduced
        var codes: [String] = []
        if observed == nil, let different {
            outcome = .inconclusive
            observed = different
            codes = ["failure.different"]
        }
        return lock.locked {
            ReplayReport(
                outcome: outcome, attempt: settings.attempt, durationMs: runStart.map { Int((uptime() - $0) * 1000) } ?? 0,
                strategy: strategy, expectedSignature: expectedFailure?.signature, observed: observed,
                otherFailures: otherFailures, divergences: divergences, eventsDispatched: dispatched,
                eventsExpected: expected, fixturesServed: fixturesServedCount, compressedMs: skippedMs,
                gapsCompressed: gapsCompressed, buildGitSha: buildGitSha, message: message,
                attemptId: settings.attemptId, runtime: "ios", reasonCodes: codes)
        }
    }

    /// Delivers the report once (POST + fallback line + UI test marker).
    func complete(_ report: ReplayReport) {
        let first = lock.locked { () -> Bool in
            if finished { return false }
            finished = true
            return true
        }
        guard first else { return }
        onReport?(report)
        guard let channel else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            channel.deliver(report, attemptId: self.settings.attemptId)
        }
    }

    /// Uncaught exception during replay: report synchronously before the
    /// process terminates.
    func finishSynchronously(reason: String) {
        let first = lock.locked { () -> Bool in
            if finished { return false }
            finished = true
            return true
        }
        guard first else { return }
        let report = buildReport(message: reason)
        onReport?(report)
        channel?.deliver(report, attemptId: settings.attemptId, timeout: 3)
    }

    func finishIncompatible(_ message: String) {
        lock.locked { finished = true }
        let report = ReplayReport(
            outcome: .incompatible, attempt: settings.attempt, durationMs: 0, strategy: settings.strategy,
            expectedSignature: capsule.manifest.failure?.signature, message: message, attemptId: settings.attemptId,
            runtime: "ios")
        onReport?(report)
        if let channel {
            DispatchQueue.global().async { channel.deliver(report, attemptId: self.settings.attemptId) }
        }
    }

    // MARK: dispatch

    @MainActor
    func dispatch(_ event: BugCapsuleEvent) {
        lock.locked { firstInput = true }
        switch event.type {
        case EventTypes.action:
            let id = event.data["id"]?.stringValue ?? ""
            if !ActionRegistry.shared.invoke(id, payload: event.data["payload"]?.objectValue) {
                diverge("action.unregistered", id)
                return
            }
        case EventTypes.text:
            let id = event.data["id"]?.stringValue ?? ""
            let value = event.data["value"]?.stringValue ?? ""
            if value.contains(Redactor.placeholder) { diverge("text.redacted", id) }
            if !ActionRegistry.shared.setText(id, value) {
                diverge("text.untracked", id)
                return
            }
        case EventTypes.lifecycle:
            let state = event.data["state"]?.stringValue ?? ""
            if !LifecycleReplayer.post(state) {
                diverge("lifecycle.unsupported", state)
                return
            }
        default:
            return
        }
        lock.locked { dispatched += 1 }
        activity()
    }
}

/// Set-once flag.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.locked { value } }
    /// True the first time.
    func set() -> Bool {
        lock.locked {
            if value { return false }
            value = true
            return true
        }
    }
}
