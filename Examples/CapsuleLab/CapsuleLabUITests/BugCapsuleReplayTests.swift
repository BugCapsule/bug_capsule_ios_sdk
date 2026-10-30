import BugCapsuleXCTest
import XCTest

/// The replay runner the `bugcapsule` CLI invokes. Skipped when not started by the CLI.
final class BugCapsuleReplayTests: BugCapsuleReplayTestCase {
    @MainActor
    func testReplay() throws {
        try runBugCapsuleReplay()
    }
}
