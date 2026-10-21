import Foundation
import XCTest

@testable import BugCapsule

enum TestPaths {
    /// Repository root (`bug_capsule_ios_sdk/`).
    static let repo: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixtures = repo.appendingPathComponent("spec-fixtures")
    /// The source of truth when the Flutter SDK is checked out next to this repo.
    static let upstreamFixtures = repo.deletingLastPathComponent()
        .appendingPathComponent("bug_capsule_flutter_sdk/spec/fixtures")
}

func loadJSON(_ url: URL) throws -> JSONValue {
    try JSON.parse(Data(contentsOf: url))
}

func fixtureFiles(_ sub: String) throws -> [URL] {
    let dir = TestPaths.fixtures.appendingPathComponent(sub)
    return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

func tempDirectory(_ name: String = UUID().uuidString) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("bugcapsule-tests/\(name)")
    try? FileManager.default.removeItem(at: url)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A minimal valid capsule for tests.
func makeCapsule(
    events: [BugCapsuleEvent] = [], failure: FailureRecord? = nil, checkpointData: JSONObject = JSONObject(),
    checkpointKind: CheckpointKind = .launch, capabilities: [(String, String)] = [], screen: (Double, Double) = (402, 874),
    gitSha: String? = nil, stateSchemaVersion: Int = 1
) -> Capsule {
    Capsule(
        manifest: CapsuleManifest(
            capsuleId: UUID().uuidString.lowercased(), createdAt: Date(), mode: .qa,
            app: AppInfo(id: "com.example", version: "1.0", build: "1"), gitSha: gitSha, dirty: false,
            sdkName: "bugcapsule-ios", sdkVersion: "0.3.0", stateSchemaVersion: stateSchemaVersion,
            platform: PlatformInfo(
                os: "ios", osVersion: "27.0", locale: "en_US", screenWidth: screen.0, screenHeight: screen.1,
                pixelRatio: 3),
            session: SessionInfo(id: "s1", startedAt: Date(), wallClockAtAnchorMs: 1_700_000_000_000, seed: 42, durationMs: 1000),
            failure: failure, eligibility: Eligibility(status: .eligible, missing: []),
            integrations: ["urlsession"], eventCount: events.count, droppedEvents: 0, checkpointKind: checkpointKind,
            runtime: RuntimeInfo(name: "ios", version: "27.0", language: "swift", frameworks: ["uikit"]),
            capabilities: capabilities),
        checkpoint: Checkpoint(kind: checkpointKind, t: 0, wallClockMs: 1_700_000_000_000, afterSeq: 0, data: checkpointData),
        events: events)
}

func httpEvent(
    seq: Int, t: Int, key: String, occurrence: Int = 0, status: Int = 200, body: JSONValue = ["ok": true],
    durationMs: Int = 50, error: JSONValue = .null, encoding: String = "json"
) -> BugCapsuleEvent {
    BugCapsuleEvent(
        seq: seq, t: t, type: EventTypes.http,
        data: [
            "id": .int(seq), "key": .string(key), "occurrence": .int(occurrence), "method": "GET",
            "url": "https://shop.example.com/x", "status": .int(status),
            "responseHeaders": ["content-type": "application/json"], "responseBody": body,
            "bodyEncoding": .string(encoding), "durationMs": .int(durationMs), "error": error,
        ])
}
