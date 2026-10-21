import Foundation

/// Chained `NSSetUncaughtExceptionHandler`.
///
/// Captured: uncaught Objective-C `NSException`s (raised by UIKit/Foundation
/// or with `NSException.raise()`), best effort. The capsule (when
/// recording) and the `fatal` monitoring event are written synchronously to
/// their outboxes and uploaded on the next launch; the previously installed
/// handler (e.g. a crash reporter) is always called afterwards.
///
/// Swift runtime traps, POSIX signals and Mach exceptions never run this
/// handler: monitoring's native crash handler (BugCapsuleCrash) writes a
/// report for them that becomes a `fatal` event on the next launch, but no
/// capsule (building one is not async-signal-safe). Out-of-memory and
/// watchdog kills leave no report; release health marks such runs
/// `abnormal`.
enum CrashHandler {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed = false
    nonisolated(unsafe) private static var previous: (@convention(c) (NSException) -> Void)?

    static func install() {
        lock.lock()
        defer { lock.unlock() }
        if installed { return }
        installed = true
        previous = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            CrashHandler.handle(exception)
        }
    }

    static func handle(_ exception: NSException) {
        BugCapsuleSession.current?.handleUncaughtException(exception)
        previous?(exception)
    }
}
