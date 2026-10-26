import Foundation

/// Serves recorded interaction dependencies during a replay (capsule-v2 §5):
/// a thread-safe wrapper around `InteractionScript` on the replay engine's
/// clock, with its own timer so deliveries happen when they are due.
///
/// Adapters match outbound operations (`take`, `takeNext`) and `bind` a
/// handler to receive inbound events. Handlers run synchronously while the
/// scheduler is locked (a close may unbind the scope for later deliveries
/// of the same batch), so they must not block: they hand values to waiting
/// callers and return.
final class InteractionReplay: @unchecked Sendable {
    let script: InteractionScript
    /// Recorded events by seq (for adapters that look ahead).
    let events: [BugCapsuleEvent]
    let dependencies: [CapsuleDependency]
    private let lock = NSRecursiveLock()
    private let clock: @Sendable () -> Int
    private let onDiverge: @Sendable (String, String) -> Void
    private let onActivity: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.bugcapsule.interactions.replay", qos: .userInitiated)
    private var wakeAt: Int?
    private var finished = false

    init(
        capsule: Capsule, clock: @escaping @Sendable () -> Int, base: Int,
        diverge: @escaping @Sendable (String, String) -> Void, activity: @escaping @Sendable () -> Void = {},
        maxHandlerWaitMs: Int = 5000
    ) {
        let deps = Set(capsule.manifest.dependencies.filter(\.required).map(\.id))
        events = capsule.events
        dependencies = capsule.manifest.dependencies
        script = InteractionScript(
            events: capsule.events, dependencies: deps, clock: clock, base: base, maxHandlerWaitMs: maxHandlerWaitMs)
        self.clock = clock
        onDiverge = diverge
        onActivity = activity
    }

    var isEmpty: Bool { script.isEmpty }

    /// The capsule's dependency id recorded by [adapter].
    func dependencyId(adapter: String) -> String? { dependencies.first { $0.adapter == adapter }?.id }

    func diverge(_ type: String, _ detail: String) { onDiverge(type, detail) }

    func now() -> Int { clock() }

    // MARK: matching

    func take(dep: String, type: String, key: String) -> RecordedInteraction? {
        let r = lock.locked { script.take(dep: dep, type: type, key: key) }
        kick()
        return r
    }

    func takeNext(scope: String, types: Set<String>) -> RecordedInteraction? {
        let r = lock.locked { script.takeNext(scope: scope, types: types) }
        kick()
        return r
    }

    func hasUnconsumed(dep: String, type: String, prefix: String) -> Bool {
        lock.locked { script.hasUnconsumed(dep: dep, type: type, prefix: prefix) }
    }

    /// The recorded inbound events of [scope] after [seq] up to the next
    /// outbound one (what the dependency answered to that operation).
    func answers(scope: String, after seq: Int) -> [RecordedInteraction] {
        lock.locked {
            var out: [RecordedInteraction] = []
            for r in script.all where r.scope == scope && r.event.seq > seq {
                if r.outbound { break }
                out.append(r)
            }
            return out
        }
    }

    // MARK: delivery

    func bind(_ scope: String, _ handler: @escaping (RecordedInteraction) -> Void) {
        lock.locked {
            script.bind(scope) { [weak self] r in
                handler(r)
                self?.onActivity()
            }
        }
        kick()
    }

    func unbind(_ scope: String) { lock.locked { script.unbind(scope) } }

    func runStarted(at: Int) {
        lock.locked { script.runStarted(at: at) }
        kick()
    }

    /// Earliest due delivery with a handler (idle compression must not skip
    /// past it); nil: nothing due, an idle open connection keeps nothing busy.
    var nextDueAt: Int? { lock.locked { script.nextDueAt } }

    @discardableResult
    func pump() -> Int {
        let n: Int = lock.locked {
            if finished { return 0 }
            let n = script.pump()
            for (type, detail) in script.takeDivergences() { onDiverge(type, detail) }
            return n
        }
        kick()
        return n
    }

    /// The replay clock jumped (idle compression): deliver what is due now.
    func clockJumped() { pump() }

    /// Schedules a wake-up for the next due delivery (and re-checks events
    /// waiting for a handler every 250 ms, so a missing one times out).
    func kick() {
        let delay: Int? = lock.locked {
            guard !finished else { return nil }
            let now = clock()
            var next = script.nextDueAt
            if script.hasWaiting { next = min(next ?? now + 250, now + 250) }
            guard let next else { return nil }
            if let w = wakeAt, w <= next, w >= now { return nil }
            wakeAt = next
            return max(next - now, 0)
        }
        guard let delay else { return }
        queue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
            guard let self else { return }
            self.lock.locked { self.wakeAt = nil }
            self.pump()
        }
    }

    /// Ends serving: pending deliveries are dropped; returns the
    /// `<family>.unused` / `unusedAfterFailure` divergences.
    func finish(failureT: Int?) -> [(String, String)] {
        lock.locked {
            if finished { return [] }
            _ = script.pump()
            var out = script.takeDivergences()
            out += script.unused(failureT: failureT)
            finished = true
            return out
        }
    }
}
