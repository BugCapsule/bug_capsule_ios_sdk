#if canImport(XCTest)
    import Foundation
    import XCTest

    /// Runs one BugCapsule replay attempt from the app's UI test target.
    ///
    /// The `bugcapsule` CLI runs
    /// `xcodebuild test-without-building -only-testing:<Target>/<Class>/<method>`
    /// with `TEST_RUNNER_BUGCAPSULE_REPLAY_URL=<armed URL>`; xcodebuild strips
    /// the prefix, so this test runner sees `BUGCAPSULE_REPLAY_URL`. The helper
    /// launches the app with that URL in `launchEnvironment` plus the
    /// `-BugCapsuleReplay` argument (the SDK arms replay only with both, and
    /// only in DEBUG builds), waits until the in-app engine publishes its
    /// report, and prints it as `BUGCAPSULE_RESULT::{json}` so the CLI finds
    /// it in the xcodebuild output. The app also POSTs the report to the CLI
    /// directly; the printed line is the fallback channel.
    ///
    /// ```swift
    /// import BugCapsuleXCTest
    ///
    /// final class BugCapsuleReplayTests: BugCapsuleReplayTestCase {
    ///     func testReplay() throws { try runBugCapsuleReplay() }
    /// }
    /// ```
    open class BugCapsuleReplayTestCase: XCTestCase {
        public static let replayURLKey = "BUGCAPSULE_REPLAY_URL"
        public static let launchArgument = "-BugCapsuleReplay"
        public static let resultIdentifier = "bugcapsule.replay.result"
        public static let resultPrefix = "BUGCAPSULE_RESULT::"

        /// The app under test; override to customise (bundle id, extra environment).
        @MainActor open func makeApplication() -> XCUIApplication { XCUIApplication() }

        /// Launches the app in replay mode and waits for its report.
        /// Skips when the test was not started by `bugcapsule`.
        @MainActor
        public func runBugCapsuleReplay(timeout: TimeInterval = 900) throws {
            let env = ProcessInfo.processInfo.environment
            guard let url = env[Self.replayURLKey], !url.isEmpty else {
                throw XCTSkip("not started by `bugcapsule run|verify` (no \(Self.replayURLKey))")
            }
            continueAfterFailure = true
            let app = makeApplication()
            app.launchEnvironment[Self.replayURLKey] = url
            app.launchArguments += [Self.launchArgument]
            print("[bugcapsule] launching app in replay mode")
            app.launch()
            let marker = app.descendants(matching: .any).matching(identifier: Self.resultIdentifier).firstMatch
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if marker.exists {
                    let value = (marker.value as? String) ?? ""
                    if !value.isEmpty {
                        print(Self.resultPrefix + value)
                        return
                    }
                }
                switch app.state {
                case .notRunning, .unknown:
                    // A crash (e.g. the reproduced NSException): the engine
                    // posted its report synchronously before terminating.
                    print("[bugcapsule] app terminated during replay; its report was posted to the CLI over HTTP")
                    return
                default:
                    break
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            XCTFail("no BugCapsule replay result within \(Int(timeout))s")
        }
    }
#endif
