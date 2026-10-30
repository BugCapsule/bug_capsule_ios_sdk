import XCTest

@testable import BugCapsule

final class PatchIdentityTests: XCTestCase {
    private let hostHash = "sha256:" + String(repeating: "a", count: 64)
    private let digest = "sha256:" + String(repeating: "b", count: 64)

    private func id(base: String = "build-1", patch: String? = nil, abi: Int = 1) -> PatchIdentity {
        PatchIdentity(baseBuildId: base, patchSetDigest: patch, engineAbi: abi, hostAbiHash: hostHash)
    }

    private func manifest(_ patch: PatchIdentity?) -> CapsuleManifest {
        var m = CapsuleManifest(json: [
            "capsuleId": .string("c"), "createdAt": .string("2026-01-01T00:00:00.000Z"), "mode": .string("qa"),
            "app": .object(["version": .string("1"), "build": .string("1")]), "source": .object([:]),
            "sdk": .object(["name": .string("s"), "version": .string("1")]), "stateSchemaVersion": .int(1),
            "platform": .object(["os": .string("ios"), "screen": .object([:])]),
            "session": .object(["id": .string("s"), "startedAt": .string("2026-01-01T00:00:00.000Z"), "wallClockAtAnchorMs": .int(0), "seed": .int(1), "durationMs": .int(0)]),
            "eligibility": .object(["status": .string("eligible")]), "integrations": .array([]),
            "stats": .object(["eventCount": .int(0), "droppedEvents": .int(0), "checkpointKind": .string("launch")]),
        ], specVersion: 2)
        m.patch = patch
        if let p = patch, p.patchSetDigest != nil { m.dependencies = [p.dependency] }
        return m
    }

    private func check(_ captured: PatchIdentity?, _ running: PatchIdentity?, artifact: Bool = false, expected: String? = nil, binding: Bool = true, kind: String = "replay", deps: [CapsuleDependency]? = nil) -> String? {
        var s = ReplaySettings()
        s.kind = kind
        s.patchArtifact = artifact
        s.expectedPatchSetDigest = expected
        var m = manifest(captured)
        if let deps { m.dependencies = deps }
        return patchPreflight(manifest: m, settings: s, hasBinding: binding, running: running)
    }

    func testIdentityRoundTrips() {
        let i = PatchIdentity(baseBuildId: "b", patchSetDigest: digest, engineAbi: 1, hostAbiHash: hostHash, artifactDigest: digest)
        guard case .object(let o) = i.json else { return XCTFail("object") }
        XCTAssertEqual(PatchIdentity(json: o), i)
    }

    func testAPatchedCapsuleRequiresTheRuntime() {
        XCTAssertEqual(manifest(id(patch: digest)).dependencies.first?.kind, patchRuntimeDependencyKind)
        XCTAssertTrue(manifest(id()).dependencies.isEmpty)
    }

    func testPreexistingCapsulesStillReplay() {
        XCTAssertNil(check(nil, nil, binding: false))
        XCTAssertNil(check(nil, id()))
    }

    func testAReplayerWithoutARuntimeRefusesAPatchedCapsule() {
        XCTAssertEqual(check(id(patch: digest), nil, binding: false)?.hasPrefix("dependency.unsupported"), true)
    }

    func testAMissingArchivedArtifactIsNeverABaseRun() {
        XCTAssertEqual(check(id(patch: digest), id())?.hasPrefix("patch.artifact_missing"), true)
    }

    func testWrongBaseAbiOrDigestIsIncompatible() {
        XCTAssertEqual(check(id(), id(base: "x"))?.hasPrefix("patch.base"), true)
        XCTAssertEqual(check(id(), id(abi: 2))?.hasPrefix("patch.abi"), true)
        XCTAssertEqual(check(id(), id(patch: hostHash), artifact: true, expected: digest, kind: "verify")?.hasPrefix("patch.mismatch"), true)
    }

    func testAFixRunOfTheExactDigestPasses() {
        XCTAssertNil(check(id(), id(patch: digest), artifact: true, expected: digest, kind: "verify"))
        XCTAssertNil(check(id(patch: digest), id(patch: digest), artifact: true, expected: digest))
    }

    func testABaselineMustRunTheCapturedDigest() {
        XCTAssertEqual(check(id(patch: digest), id(patch: hostHash), artifact: true, expected: hostHash)?.hasPrefix("patch.mismatch"), true)
        XCTAssertEqual(check(id(), id(patch: digest), artifact: true, expected: digest)?.hasPrefix("patch.mismatch"), true)
        XCTAssertEqual(check(nil, id(patch: digest), artifact: true, expected: digest)?.hasPrefix("patch.mismatch"), true)
        XCTAssertNil(check(id(patch: digest), id(patch: hostHash), artifact: true, expected: hostHash, kind: "verify"))
    }

    func testARequiredRuntimeIsValidatedNotSkipped() {
        var bad = id(patch: digest).dependency
        bad.adapter = "x.y"
        XCTAssertEqual(check(id(patch: digest), id(patch: digest), artifact: true, expected: digest, deps: [bad])?.hasPrefix("dependency.unsupported"), true)
        var schema = id(patch: digest).dependency
        schema.schema = 2
        XCTAssertEqual(check(id(patch: digest), id(patch: digest), artifact: true, expected: digest, deps: [schema])?.hasPrefix("dependency.schema"), true)
        XCTAssertEqual(check(nil, id(), deps: [id(patch: digest).dependency])?.hasPrefix("patch.identity_missing"), true)
    }
}

private struct FakeBinding: PatchBinding {
    let identity: PatchIdentity?
    func pinForReplay(bundle: Data?, keyring: Data?, keyringSignature: Data?) throws -> PatchIdentity? { identity }
}

/// A real capture through the session, not a hand-built manifest.
@MainActor
final class PatchCaptureTests: XCTestCase {
    private var dir: URL!
    private let hostHash = "sha256:" + String(repeating: "a", count: 64)
    private let digest = "sha256:" + String(repeating: "b", count: 64)

    override func setUp() async throws {
        await BugCapsule.resetForTesting()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await BugCapsule.resetForTesting()
        try? FileManager.default.removeItem(at: dir)
    }

    private func capture(_ binding: (any PatchBinding)?) async throws -> Capsule {
        var config = BugCapsuleConfig(appVersion: "1.0", appBuild: "1", mode: .qa, gitSha: "abc", gitDirty: false, autoCaptureOnFailure: false)
        config.patchBinding = binding
        BugCapsule.start(config, overrides: BugCapsuleTestOverrides(storageDirectory: dir, captureSettleDelay: 0))
        let result = await BugCapsule.capture()
        return try CapsuleCodec.decode(Data(contentsOf: try XCTUnwrap(result?.file)))
    }

    func testACaptureOnAPatchRecordsItAndRequiresTheRuntime() async throws {
        let c = try await capture(FakeBinding(identity: PatchIdentity(baseBuildId: "build-1", patchSetDigest: digest, engineAbi: 1, hostAbiHash: hostHash, artifactDigest: hostHash)))
        XCTAssertEqual(c.manifest.patch?.patchSetDigest, digest)
        XCTAssertEqual(c.manifest.patch?.artifactDigest, hostHash)
        XCTAssertEqual(c.manifest.dependencies.filter { $0.required }.map(\.kind), [patchRuntimeDependencyKind])
        XCTAssertTrue(c.manifest.isV2)
    }

    func testACaptureOnTheBareBaseNeedsNoRuntime() async throws {
        let c = try await capture(FakeBinding(identity: PatchIdentity(baseBuildId: "build-1", patchSetDigest: nil, engineAbi: 1, hostAbiHash: hostHash)))
        XCTAssertEqual(c.manifest.patch?.baseBuildId, "build-1")
        XCTAssertNil(c.manifest.patch?.patchSetDigest)
        XCTAssertTrue(c.manifest.dependencies.isEmpty)
    }

    func testWithoutABindingACaptureIsUnchanged() async throws {
        let c = try await capture(nil)
        XCTAssertNil(c.manifest.patch)
    }
}
