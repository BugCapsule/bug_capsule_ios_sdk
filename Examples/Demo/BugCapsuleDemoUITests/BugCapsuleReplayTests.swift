import BugCapsuleXCTest
import XCTest

/// The replay runner the `bugcapsule` CLI invokes:
/// `-only-testing:BugCapsuleDemoUITests/BugCapsuleReplayTests/testReplay`.
/// Skipped when not started by the CLI.
final class BugCapsuleReplayTests: BugCapsuleReplayTestCase {
    @MainActor
    func testReplay() throws {
        try runBugCapsuleReplay()
    }
}
