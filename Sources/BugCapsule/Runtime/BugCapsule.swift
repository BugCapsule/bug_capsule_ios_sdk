import Foundation

/// Entry point of the BugCapsule SDK.
///
/// ```swift
/// func application(_ app: UIApplication, didFinishLaunchingWithOptions o: ...) -> Bool {
///     BugCapsule.start(BugCapsuleConfig(backend: .init(url: "https://bugcapsule.example.com", ingestKey: "bci_...")),
///                      integrations: [BugCapsuleURLSession(), BugCapsuleUserDefaults(keys: ["cart_cache"]),
///                                     BugCapsuleNavigation.shared, BugCapsuleStateIntegration.shared])
///     ...
/// }
/// ```
///
/// Call `start` first in `application(_:didFinishLaunchingWithOptions:)`
/// (or `App.init`), before app code reads `UserDefaults`: in replay it
/// restores the checkpoint there. The SDK never stops the app from
/// starting: if setup fails, the app runs without capture.
public enum BugCapsule {
    /// Starts capture (or, in a DEBUG build launched by the BugCapsule UI
    /// test, replay). Calling it twice is ignored.
    @MainActor
    public static func start(
        _ config: BugCapsuleConfig = BugCapsuleConfig(), integrations: [BugCapsuleIntegration] = [],
        overrides: BugCapsuleTestOverrides? = nil
    ) {
        if BugCapsuleSession.current != nil {
            BugCapsuleLog.warn("BugCapsule.start called twice; ignored")
            return
        }
        let session = BugCapsuleSession(config: config, integrations: integrations, overrides: overrides)
        session.start()
    }

    public static var isStarted: Bool { BugCapsuleSession.current != nil }
    public static var isRecording: Bool { BugCapsuleSession.current?.isRecording ?? false }
    public static var isReplaying: Bool { BugCapsuleSession.current?.isReplaying ?? false }
    public static var mode: CaptureMode? { BugCapsuleSession.current?.mode }
    public static var session: BugCapsuleSession? { BugCapsuleSession.current }

    private static let fallbackRandom = BugCapsuleRandom(seed: BugCapsuleRandom.newSeed())

    /// Seeded per session and re-seeded in replay: draw randomness that
    /// affects behaviour you want reproducible from here (`random.seeded: explicit`).
    public static var random: BugCapsuleRandom { BugCapsuleSession.current?.random ?? fallbackRandom }

    /// The wall clock: real time when capturing; the virtual replay clock
    /// (checkpoint time + elapsed + skipped idle time) in replay
    /// (`clock.virtual: explicit`).
    public static func now() -> Date { BugCapsuleSession.current?.wallClock() ?? Date() }

    /// Raises the named failure assertion [assertionId]; replay is judged against it.
    public static func fail(_ assertionId: String, _ message: String = "") {
        guard let s = BugCapsuleSession.current else { return }
        s.handleFailure(FailureRecord.assertion(assertionId, message: message, t: s.now(), scrub: s.redactor.scrubText))
    }

    /// Raises [assertionId] when [condition] is false.
    public static func check(_ assertionId: String, _ condition: Bool, _ message: @autoclosure () -> String = "") {
        if !condition { fail(assertionId, message()) }
    }

    /// Reports an error the app caught as a failure (deduplicated by signature):
    /// type `String(describing: type(of: error))`, message `String(describing: error)`.
    public static func report(error: Error) {
        BugCapsuleSession.current?.reportError(error)
    }

    /// Reports an `NSException` the app caught.
    public static func report(exception: NSException) {
        BugCapsuleSession.current?.reportException(exception)
    }

    public static func log(_ message: String, level: String = "info") {
        BugCapsuleSession.current?.record(EventTypes.log, ["level": .string(level), "message": .string(message)])
    }

    /// Writes a capsule now (QA "capture" button). The latest failure in the
    /// window is the assertion when there is one.
    @discardableResult
    public static func capture(note: String? = nil) async -> CaptureResult? {
        guard let s = BugCapsuleSession.current else { return nil }
        var labels: [String: String] = [:]
        if let note { labels["note"] = note }
        return await s.writeCapsule(failure: s.lastFailure, labels: labels)
    }

    /// Takes a periodic checkpoint now (otherwise every `checkpointInterval`):
    /// snapshots every integration (UserDefaults, state, navigation) so a
    /// later capsule can start from here once older events are evicted.
    @MainActor
    public static func checkpointNow() {
        BugCapsuleSession.current?.periodicCheckpoint()
    }

    /// Saved capsule files, newest first (at most 20).
    public static func savedCaptures() -> [URL] { BugCapsuleSession.current?.store?.savedCaptures() ?? [] }

    /// Fetches the remote capture config now (otherwise refreshed after its
    /// TTL and when the app becomes active).
    public static func refreshRemoteConfig() async {
        await BugCapsuleSession.current?.remote?.refresh()
    }

    /// Uploads queued capsules now, if the remote config allows it. Uploads
    /// only run while the app runs: no background upload is scheduled.
    public static func flushUploads() async {
        await BugCapsuleSession.current?.flushOutbox()
    }

    /// Stops the SDK and forgets the session (tests).
    public static func resetForTesting() async {
        await BugCapsuleSession.current?.dispose()
        BugCapsuleSession.current = nil
    }
}

