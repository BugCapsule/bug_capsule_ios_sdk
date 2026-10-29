import Foundation
import XCTest

@testable import BugCapsule

/// Opt-in check against a real backend with emergency recovery set up:
///
///     BUGCAPSULE_EMERGENCY_E2E_URL=https://api.example.com \
///     BUGCAPSULE_EMERGENCY_E2E_KEY=bci_… \
///     BUGCAPSULE_EMERGENCY_E2E_ANCHOR=bcek.v1.… \
///     BUGCAPSULE_EMERGENCY_E2E_ENV=production \
///     BUGCAPSULE_EMERGENCY_E2E_FEATURE=checkout.confirm_order \
///     BUGCAPSULE_EMERGENCY_E2E_EXPECT_ACTION=BLOCK \
///     swift test --filter EmergencyE2ETests
///
/// Skipped unless BUGCAPSULE_EMERGENCY_E2E_URL is set.
final class EmergencyE2ETests: XCTestCase {
    func testFetchesVerifiesAndEvaluatesARealDocument() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["BUGCAPSULE_EMERGENCY_E2E_URL"], !url.isEmpty else {
            throw XCTSkip("set BUGCAPSULE_EMERGENCY_E2E_URL (and _KEY, _ANCHOR, _ENV, _FEATURE, _EXPECT_ACTION) to run")
        }
        func required(_ name: String) throws -> String {
            guard let v = env["BUGCAPSULE_EMERGENCY_E2E_\(name)"], !v.isEmpty else {
                throw XCTSkip("BUGCAPSULE_EMERGENCY_E2E_\(name) is not set")
            }
            return v
        }
        let key = try required("KEY")
        let anchor = try required("ANCHOR")
        let environment = env["BUGCAPSULE_EMERGENCY_E2E_ENV"].flatMap { $0.isEmpty ? nil : $0 } ?? "production"
        let feature = try required("FEATURE")
        let expected = try XCTUnwrap(
            EmergencyAction(rawValue: try required("EXPECT_ACTION")), "EXPECT_ACTION must be one of \(EmergencyAction.allCases.map(\.rawValue))")

        let dir = tempDirectory()
        var config = EmergencyConfiguration(
            trustAnchor: anchor, environment: environment, backend: BugCapsuleBackendConfig(url: url, ingestKey: key))
        config.testHooks = EmergencyTestHooks(storageDirectory: dir, autoSchedule: false, observeLifecycle: false)
        let runtime = EmergencyRuntime(configuration: config) { _ in }
        defer { runtime.dispose() }

        await runtime.refresh(.manual)
        let status = runtime.status()
        XCTAssertNil(status.lastError, "fetch failed: \(status.lastError.map(String.init(describing:)) ?? "")")
        XCTAssertFalse(status.credentialRejected)
        XCTAssertEqual(status.state, .usable)
        XCTAssertNotNil(status.revision)

        let decision = runtime.evaluate(featureKey: feature, subject: nil).0
        XCTAssertEqual(decision.action, expected, "decision: \(decision)")
        XCTAssertEqual(decision.source, .policy)
        XCTAssertEqual(decision.documentRevision, status.revision)

        // The second fetch revalidates with the stored ETag; the document stays.
        await runtime.refresh(.manual)
        XCTAssertNil(runtime.status().lastError)
        XCTAssertEqual(runtime.status().revision, status.revision)

        // A new instance starts from the verified cache without the network.
        var offline = config
        offline.backend = BugCapsuleBackendConfig(url: "http://127.0.0.1:9", ingestKey: key)
        let cached = EmergencyRuntime(configuration: offline) { _ in }
        defer { cached.dispose() }
        XCTAssertEqual(cached.status().revision, status.revision)
        XCTAssertEqual(cached.evaluate(featureKey: feature, subject: nil).0.action, expected)
    }
}
