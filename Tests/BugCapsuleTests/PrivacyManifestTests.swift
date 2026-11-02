import Foundation
import XCTest

@testable import BugCapsule

/// The privacy manifest ships in the module bundle so Xcode's privacy report
/// for a consumer app picks it up (BC-ENT-039).
final class PrivacyManifestTests: XCTestCase {
    private func manifest() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
                                "PrivacyInfo.xcprivacy is missing from the BugCapsule bundle")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    func testManifestDeclaresNoTracking() throws {
        let m = try manifest()
        XCTAssertEqual(m["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((m["NSPrivacyTrackingDomains"] as? [String])?.count, 0)
    }

    func testManifestDeclaresEachRequiredReasonAPIWithAReason() throws {
        let types = try XCTUnwrap(manifest()["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: [String]] = [:]
        for t in types {
            let category = try XCTUnwrap(t["NSPrivacyAccessedAPIType"] as? String)
            reasons[category] = t["NSPrivacyAccessedAPITypeReasons"] as? [String]
        }
        XCTAssertEqual(reasons, [
            "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
            "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
            "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"],
        ])
    }

    func testCollectedDataIsNeitherLinkedNorTracking() throws {
        let collected = try XCTUnwrap(manifest()["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let kinds = Set(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String })
        XCTAssertTrue(kinds.isSuperset(of: [
            "NSPrivacyCollectedDataTypeCrashData",
            "NSPrivacyCollectedDataTypePerformanceData",
            "NSPrivacyCollectedDataTypeOtherDiagnosticData",
        ]))
        for entry in collected {
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, false)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
            XCTAssertFalse((entry["NSPrivacyCollectedDataTypePurposes"] as? [String] ?? []).isEmpty)
        }
    }
}
