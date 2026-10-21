import Foundation

/// Chained `NSSetUncaughtExceptionHandler`.
///
/// Captured: uncaught Objective-C `NSException`s (raised by UIKit/Foundation
/// or with `NSException.raise()`), best effort. The capsule is built and
/// written synchronously to the outbox and uploaded on the next launch; the
/// previously installed handler (e.g. a crash reporter) is always called
/// afterwards.
///
/// Not captured: Swift runtime traps (`fatalError`, force unwraps of nil,
/// array index out of range, integer overflow, `precondition`), POSIX
/// signals (SIGSEGV, SIGABRT from `abort()`), out-of-memory (jetsam)
/// terminations and watchdog kills. Those never run Objective-C exception
/// handlers, and handling signals safely is out of scope; report such
/// conditions yourself with `BugCapsule.check` / `BugCapsule.report(error:)`
/// before they trap.
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
