import Foundation

/// Who installed the process-wide crash handlers (signals, Mach exceptions,
/// hang watchdog, MetricKit): the SDK's monitoring or
/// `BugCapsuleCrashBridge`. The first to claim them keeps them, so they are
/// never installed twice.
enum CrashOwnership {
    enum Owner: Sendable { case sdk, bridge }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var owner: Owner?

    static var current: Owner? { lock.locked { owner } }

    /// True when the handlers are free or already [who]'s.
    static func claim(_ who: Owner) -> Bool {
        lock.locked {
            if let owner, owner != who { return false }
            owner = who
            return true
        }
    }

    static func release(_ who: Owner) {
        lock.locked { if owner == who { owner = nil } }
    }
}
