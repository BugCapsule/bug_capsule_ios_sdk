import Foundation

/// Runs a native adapter through a scripted session, offline: capture →
/// capsule (encoded, decoded and validated like a real one) → replay with a
/// fresh adapter whose dependency must not be called. Use it in your
/// adapter's tests:
///
/// ```swift
/// func testMyAdapterReplays() async throws {
///     let report = try await BugCapsuleAdapterConformance.run(
///         makeAdapter: { replaying in MyAdapter(sdk: replaying ? FailingSDK() : FakeSDK()) }
///     ) { adapter, log in
///         let a = adapter as! MyAdapter
///         log.append("get: \(try await a.get("carts/1"))")
///     }
///     XCTAssertTrue(report.isClean, report.problems.joined(separator: "\n"))
/// }
/// ```
///
/// The script runs twice (capture, replay) and logs what the app saw; a
/// conformant adapter replays the same log with no divergence. Operations
/// the adapter does not support show up in `report.gaps`
/// (`operation.unsupported`) and, when the script uses them, as
/// `native.unrecorded` in replay.
public enum BugCapsuleAdapterConformance {
    public struct Report: Sendable {
        /// The recorded capsule (spec v2 when anything was recorded).
        public let capsule: Capsule
        /// `manifest.dependencies` entry of the adapter (nil: nothing recorded).
        public let dependency: CapsuleDependency?
        /// What the script logged while capturing and while replaying.
        public let captureLog: [String]
        public let replayLog: [String]
        /// Divergences of the replay (capsule-v2 §5), unused interactions included.
        public let divergences: [Divergence]
        /// The preflight refusal (`dependency.unsupported`, ...), if any.
        public let incompatible: String?
        /// Errors the script threw (`capture: ...`, `replay: ...`).
        public let scriptErrors: [String]

        public var gaps: [DependencyGap] { dependency?.gaps ?? [] }

        /// Everything that makes the adapter non-conformant for this script.
        public var problems: [String] {
            var out: [String] = []
            if let incompatible { out.append("preflight: \(incompatible)") }
            out += scriptErrors
            out += divergences.map { "divergence \($0.type): \($0.detail)" }
            if captureLog != replayLog {
                out.append("replay log differs from capture:\n  capture: \(captureLog)\n  replay:  \(replayLog)")
            }
            return out
        }

        /// Replay reproduced the capture exactly, without divergences.
        public var isClean: Bool { problems.isEmpty }
    }

    /// What the script reports it saw (results, events, errors).
    public final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        public init() {}
        public func append(_ line: String) { lock.locked { _lines.append(line) } }
        public var lines: [String] { lock.locked { _lines } }
    }

    /// - Parameters:
    ///   - makeAdapter: a new adapter; `replaying` is true for the replay
    ///     run (give it a dependency that fails when called).
    ///   - redactor: the capture redaction rules (default rules).
    ///   - settle: how long to keep delivering recorded events after the
    ///     replay script returned.
    ///   - timeout: per run.
    ///   - script: the app's use of the adapter; runs once per phase.
    public static func run(
        makeAdapter: @Sendable (_ replaying: Bool) -> BugCapsuleNativeAdapter, redactor: Redactor = Redactor(),
        settle: TimeInterval = 0.3, timeout: TimeInterval = 10,
        script: @escaping @Sendable (_ adapter: BugCapsuleNativeAdapter, _ log: Log) async throws -> Void
    ) async throws -> Report {
        var errors: [String] = []

        // Capture.
        let recorded = EventSink()
        let start = uptime()
        let elapsed: @Sendable () -> Int = { Int(((uptime() - start) * 1000).rounded(.down)) }
        let capture = InteractionRuntime(
            record: { type, data in recorded.add(t: elapsed(), type: type, data: data) }, now: elapsed,
            redactor: { redactor }, recording: { true })
        let adapter = makeAdapter(false)
        capture.install(adapter.descriptor)
        adapter.attach(BugCapsuleNativeBridge(descriptor: adapter.descriptor, runtime: capture, adapter: adapter))
        let captureLog = Log()
        if let e = await runScript(script, adapter, captureLog, timeout) { errors.append("capture: \(e)") }
        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        adapter.dispose()

        let capsule = try buildCapsule(recorded.events, capture: capture, redactor: redactor)
        let dependency = capsule.manifest.dependencies.first { $0.adapter == adapter.descriptor.adapter }

        // Replay.
        let divergences = DivergenceSink()
        let replayStart = uptime()
        let replayClock: @Sendable () -> Int = { Int(((uptime() - replayStart) * 1000).rounded(.down)) }
        let replayRuntime = InteractionRuntime(
            record: { _, _ in }, now: replayClock, redactor: { redactor }, recording: { false })
        let replay = InteractionReplay(
            capsule: capsule, clock: replayClock, base: 0, diverge: { divergences.add($0, $1, t: replayClock()) })
        replayRuntime.replay = replay
        let replayAdapter = makeAdapter(true)
        replayRuntime.install(replayAdapter.descriptor)
        let incompatible = replayRuntime.preflight(capsule)
        let replayLog = Log()
        if incompatible == nil {
            replayAdapter.attach(
                BugCapsuleNativeBridge(descriptor: replayAdapter.descriptor, runtime: replayRuntime, adapter: replayAdapter))
            replay.runStarted(at: 0)
            if let e = await runScript(script, replayAdapter, replayLog, timeout) { errors.append("replay: \(e)") }
            // Deliver what is still due, then settle.
            let deadline = uptime() + timeout
            while let next = replay.nextDueAt, uptime() < deadline {
                let wait = max(next - replayClock(), 1)
                try? await Task.sleep(nanoseconds: UInt64(min(wait, 50)) * 1_000_000)
                replay.pump()
            }
            try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
            replay.pump()
            for (type, detail) in replay.finish(failureT: nil) { divergences.add(type, detail, t: replayClock()) }
        }
        replayAdapter.dispose()
        return Report(
            capsule: capsule, dependency: dependency, captureLog: captureLog.lines, replayLog: replayLog.lines,
            divergences: divergences.all, incompatible: incompatible, scriptErrors: errors)
    }

    private static func runScript(
        _ script: @escaping @Sendable (BugCapsuleNativeAdapter, Log) async throws -> Void,
        _ adapter: BugCapsuleNativeAdapter, _ log: Log, _ timeout: TimeInterval
    ) async -> String? {
        let box = SendableBox(adapter)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await script(box.value as! BugCapsuleNativeAdapter, log) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw BugCapsuleReplayError(code: "bugcapsule.timeout", message: "the script did not finish in \(timeout)s")
                }
                try await group.next()
                group.cancelAll()
            }
            return nil
        } catch {
            return "\(error)"
        }
    }

    static func buildCapsule(_ events: [BugCapsuleEvent], capture: InteractionRuntime, redactor: Redactor) throws -> Capsule {
        let launch = Checkpoint(kind: .launch, t: 0, wallClockMs: epochMs(), afterSeq: 0)
        let eligibility = EligibilityBuilder()
        let deps = capture.manifestDependencies(events: events, checkpoint: launch, eligibility: eligibility)
        let manifest = CapsuleManifest(
            capsuleId: uuidV4(), createdAt: Date(), mode: .debug,
            app: AppInfo(id: "adapter.conformance", version: "1", build: "1"), gitSha: nil, dirty: nil, sdkName: sdkName,
            sdkVersion: sdkVersion, stateSchemaVersion: 1,
            platform: PlatformInfo(os: "ios", osVersion: "", locale: "en_US", screenWidth: 0, screenHeight: 0, pixelRatio: 1),
            session: SessionInfo(
                id: uuidV4(), startedAt: Date(), wallClockAtAnchorMs: launch.wallClockMs, seed: 1,
                durationMs: events.last?.t ?? 0),
            failure: nil, eligibility: eligibility.build(), integrations: [], eventCount: events.count, droppedEvents: 0,
            checkpointKind: .launch, redactionKeys: redactor.extraKeys, redactionHeaders: redactor.extraHeaders,
            runtime: RuntimeInfo(name: "ios", language: "swift"), dependencies: deps)
        // Through the real codec: the capsule must validate as spec v2.
        return try CapsuleCodec.decode(CapsuleCodec.encode(Capsule(manifest: manifest, checkpoint: launch, events: events)))
    }
}

/// In-memory event recorder of the conformance harness.
final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [BugCapsuleEvent] = []

    func add(t: Int, type: String, data: JSONObject) {
        lock.locked { _events.append(BugCapsuleEvent(seq: _events.count + 1, t: t, type: type, data: data)) }
    }

    var events: [BugCapsuleEvent] { lock.locked { _events } }
}

final class DivergenceSink: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Divergence] = []
    func add(_ type: String, _ detail: String, t: Int) { lock.locked { list.append(Divergence(type, detail, t: t)) } }
    var all: [Divergence] { lock.locked { list } }
}
