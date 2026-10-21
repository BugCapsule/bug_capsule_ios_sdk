import Foundation

/// What a running replay exposes to integrations.
public protocol ReplayContext: AnyObject, Sendable {
    var capsule: Capsule { get }
    var settings: ReplaySettings { get }
    var fixtures: FixtureStore { get }
    /// Records a difference between the recording and this replay.
    func diverge(_ type: String, _ detail: String)
    /// Counts a network response served from the capsule.
    func fixtureServed()
    /// Marks work idle compression must not skip (e.g. a response waiting
    /// out its recorded latency). Call the returned function once it ends.
    func beginWork() -> @Sendable () -> Void
    /// Notes app activity, so idle compression waits for it to settle.
    func activity()
    /// True once the first recorded input was dispatched.
    var hasDispatchedInput: Bool { get }
}

/// Extension point for libraries and app state the SDK records and
/// restores (URLSession, UserDefaults, navigation, state objects, ...).
///
/// Capture: `setUp` → `snapshot` (launch, then periodic) →
/// `describeEligibility` when a capsule is written.
/// Replay: `setUp` (with `session.replay` set) → `restore` with this
/// integration's checkpoint data, inside `BugCapsule.start` before app code
/// runs. `snapshot` and `restore` run on the main thread.
public protocol BugCapsuleIntegration: AnyObject, Sendable {
    /// Key of this integration's data in checkpoints and `manifest.integrations`.
    var name: String { get }
    /// Capabilities this integration adds to `manifest.capabilities`.
    var capabilities: [(String, String)] { get }
    func setUp(_ session: BugCapsuleSession)
    @MainActor func snapshot(_ kind: CheckpointKind) -> JSONValue?
    @MainActor func restore(_ data: JSONValue?, session: BugCapsuleSession) throws
    func describeEligibility(_ eligibility: EligibilityBuilder, window: RecordedWindow)
}

extension BugCapsuleIntegration {
    public var capabilities: [(String, String)] { [] }
    public func setUp(_ session: BugCapsuleSession) {}
    @MainActor public func snapshot(_ kind: CheckpointKind) -> JSONValue? { nil }
    @MainActor public func restore(_ data: JSONValue?, session: BugCapsuleSession) throws {}
    public func describeEligibility(_ eligibility: EligibilityBuilder, window: RecordedWindow) {}
}

/// Runs [body] on the main thread synchronously (directly when already on it).
func onMainSync<T: Sendable>(_ body: @MainActor () throws -> T) rethrows -> T {
    if Thread.isMainThread {
        return try MainActor.assumeIsolated { try body() }
    }
    return try DispatchQueue.main.sync { try MainActor.assumeIsolated { try body() } }
}
