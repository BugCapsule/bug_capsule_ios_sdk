#if canImport(XCTest)
    import BugCapsule
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
    /// Crash capsules (failure kind `crash`, crash-capsules §4): when the app
    /// dies during the attempt, the helper reads the crash report the host
    /// wrote for it (simulator: `$SIMULATOR_HOST_HOME/Library/Logs/DiagnosticReports`)
    /// and prints the attempt's report itself:
    ///
    /// * `outcome: "reproduced"`: the same signal, Mach exception or uncaught
    ///   NSException (`reasonCodes: ["failure.different_frame"]` when the
    ///   in-app frame closest to the crash is another function);
    /// * `outcome: "inconclusive"`, `reasonCodes: ["failure.different"]`:
    ///   another crash type;
    /// * `observed`: the crash as a failure of kind `crash` (`type`,
    ///   `signature`, `crash.signal` / `crash.exception`, `crash.inAppFrame`);
    /// * `expectedSignature`, `attempt`, `attemptId`, `durationMs`,
    ///   `runtime: "ios"`, `message` (the report's summary).
    ///
    /// An app hang of an `ApplicationNotResponding` capsule and a replay that
    /// ends with the app alive are reported by the app (`reproduced`,
    /// `not_reproduced`).
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
        /// How long a crash report may take to appear after the app died.
        public static let crashReportWait: TimeInterval = 20

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
            // A crash capsule is judged here when the app dies.
            let crashAttempt = CrashAttempt.load(replayURL: url)
            let app = makeApplication()
            app.launchEnvironment[Self.replayURLKey] = url
            app.launchArguments += [Self.launchArgument]
            print("[bugcapsule] launching app in replay mode")
            let launchedAt = Date()
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
                    if let crashAttempt, let line = crashAttempt.judge(since: launchedAt, wait: Self.crashReportWait) {
                        print(Self.resultPrefix + line)
                        return
                    }
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

    /// The expected crash of the attempt, from the CLI's replay server.
    struct CrashAttempt {
        let expected: FailureRecord
        let settings: ReplaySettings

        /// Nil when the capsule is not a crash capsule or cannot be fetched.
        static func load(replayURL: String) -> CrashAttempt? {
            var base = replayURL
            while base.hasSuffix("/") { base.removeLast() }
            guard let settingsData = get(base + ReplayProtocol.settingsPath),
                let settingsJSON = (try? JSON.parse(settingsData))?.objectValue,
                let capsuleData = get(base + ReplayProtocol.capsulePath),
                let capsule = try? CapsuleCodec.decode(capsuleData),
                let failure = capsule.manifest.failure, failure.kind == .crash
            else { return nil }
            return CrashAttempt(expected: failure, settings: ReplaySettings(json: settingsJSON))
        }

        private static func get(_ url: String) -> Data? {
            guard let u = URL(string: url) else { return nil }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            let session = URLSession(configuration: config)
            defer { session.finishTasksAndInvalidate() }
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var out: Data?
            session.dataTask(with: u) { data, response, _ in
                if (response as? HTTPURLResponse)?.statusCode == 200 { out = data }
                done.signal()
            }.resume()
            _ = done.wait(timeout: .now() + 20)
            return out
        }

        /// The report line for the app's death, or nil when no crash report
        /// of it appeared (it exited, or the engine already reported).
        func judge(since: Date, wait: TimeInterval) -> String? {
            let until = Date().addingTimeInterval(wait)
            repeat {
                if let (crash, file) = CrashReports.newest(since: since) {
                    let report = CrashVerdict.report(
                        expected: expected, crash: crash, settings: settings,
                        durationMs: Int(Date().timeIntervalSince(since) * 1000), source: file.lastPathComponent)
                    return JSON.encode(report.json)
                }
                Thread.sleep(forTimeInterval: 0.5)
            } while Date() < until
            print("[bugcapsule] the app stopped but no crash report of it was found in \(CrashReports.directories.map(\.path))")
            return nil
        }
    }

    /// Crash reports the host writes for apps on this simulator.
    enum CrashReports {
        static var directories: [URL] {
            let env = ProcessInfo.processInfo.environment
            var dirs: [URL] = []
            if let home = env["SIMULATOR_HOST_HOME"] {
                dirs.append(URL(fileURLWithPath: home).appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true))
            }
            dirs.append(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true))
            return dirs
        }

        /// The newest crash of another process on this device since [since].
        static func newest(since: Date) -> (ObservedCrash, URL)? {
            let fm = FileManager.default
            let udid = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
            let me = ProcessInfo.processInfo.processIdentifier
            var best: (ObservedCrash, URL, Date)?
            for dir in directories {
                let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for url in items where url.pathExtension == "ips" {
                    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    guard modified >= since.addingTimeInterval(-1), modified > (best?.2 ?? .distantPast),
                        let data = try? Data(contentsOf: url), let crash = ObservedCrash.parseIPS(data), crash.pid != Int(me)
                    else { continue }
                    if let udid, let path = crash.processPath, !path.contains(udid) { continue }
                    best = (crash, url, modified)
                }
            }
            return best.map { ($0.0, $0.1) }
        }
    }
#endif
