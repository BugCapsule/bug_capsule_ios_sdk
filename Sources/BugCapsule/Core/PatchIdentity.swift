import Foundation

/// The dependency a capsule captured with a patch loaded must require, so a
/// replayer that knows nothing of patches refuses it instead of running the
/// bare base and reporting a false fix (capsule-v2 §10).
public let patchRuntimeDependencyKind = "patch.runtime"
public let patchRuntimeAdapter = "bugcapsule.patch_runtime"
/// The adapter name the Flutter SDK writes; capsules cross runtimes in tools.
public let patchRuntimeAdapterFlutter = "bug_capsule.patch_runtime"
public let patchRuntimeSchema = 1

/// `manifest.patch` (capsule-v2 §10): what actually ran. A nil `patchSetDigest`
/// is the bare base build.
public struct PatchIdentity: Sendable, Equatable {
    public var baseBuildId: String
    public var patchSetDigest: String?
    public var engineAbi: Int
    public var hostAbiHash: String
    public var artifactDigest: String?

    public init(baseBuildId: String, patchSetDigest: String?, engineAbi: Int, hostAbiHash: String, artifactDigest: String? = nil) {
        self.baseBuildId = baseBuildId
        self.patchSetDigest = patchSetDigest
        self.engineAbi = engineAbi
        self.hostAbiHash = hostAbiHash
        self.artifactDigest = artifactDigest
    }

    public init?(json j: JSONObject) {
        guard let base = j["baseBuildId"]?.stringValue, let abi = j["engineAbi"]?.intValue, let hash = j["hostAbiHash"]?.stringValue else { return nil }
        self.init(baseBuildId: base, patchSetDigest: j["patchSetDigest"]?.stringValue, engineAbi: abi, hostAbiHash: hash, artifactDigest: j["artifactDigest"]?.stringValue)
    }

    public var json: JSONValue {
        var o: JSONObject = [
            "baseBuildId": .string(baseBuildId),
            "patchSetDigest": patchSetDigest.map { .string($0) } ?? .null,
            "engineAbi": .int(engineAbi),
            "hostAbiHash": .string(hostAbiHash),
        ]
        if let artifactDigest { o["artifactDigest"] = .string(artifactDigest) }
        return .object(o)
    }

    /// The required dependency of a capsule captured with a patch loaded.
    var dependency: CapsuleDependency {
        CapsuleDependency(id: patchRuntimeDependencyKind, kind: patchRuntimeDependencyKind, adapter: patchRuntimeAdapter, adapterVersion: "1", schema: patchRuntimeSchema, required: true, coverage: .complete)
    }
}

/// Connects the patch runtime to capture and replay. `BugCapsulePatch`
/// implements this; set it as `BugCapsuleConfig.patchBinding`.
public protocol PatchBinding: Sendable {
    /// What this process runs. Capsules record it.
    var identity: PatchIdentity? { get }

    /// Replay: load exactly `bundle`, or the bare base when nil, offline and
    /// without the device store or live channel. A bundle signed by a delegated
    /// key comes with the archived keyring and its signature. Throws when that
    /// is impossible: running anything else would make the attempt meaningless.
    func pinForReplay(bundle: Data?, keyring: Data?, keyringSignature: Data?) throws -> PatchIdentity?
}

/// Why a capsule can't replay with this patch setup, or nil. A wrong or
/// missing patch is `incompatible`, never a run of something else.
public func patchPreflight(manifest: CapsuleManifest, settings: ReplaySettings, hasBinding: Bool, running: PatchIdentity?) -> String? {
    let captured = manifest.patch
    let required = manifest.dependencies.filter { $0.required && $0.kind == patchRuntimeDependencyKind }
    for d in required {
        if d.adapter != patchRuntimeAdapter && d.adapter != patchRuntimeAdapterFlutter {
            return "dependency.unsupported: \(d.adapter) (dependency \(d.id)) is not a known patch runtime"
        }
        if d.schema != patchRuntimeSchema { return "dependency.schema: \(d.adapter) cannot replay schema \(d.schema); update the SDK" }
        if captured == nil { return "patch.identity_missing: the capsule requires a patch runtime but records no identity" }
    }
    let needsRuntime = captured?.patchSetDigest != nil || !required.isEmpty
    guard hasBinding else {
        return needsRuntime || settings.patchArtifact
            ? "dependency.unsupported: \(patchRuntimeAdapter) is not set up in this build; set patchBinding on BugCapsuleConfig" : nil
    }
    guard let running else { return "patch.unavailable: the patch runtime reported no identity" }
    if let captured {
        if captured.baseBuildId != running.baseBuildId {
            return "patch.base: captured on base \(captured.baseBuildId), this build is \(running.baseBuildId)"
        }
        if captured.engineAbi != running.engineAbi || captured.hostAbiHash != running.hostAbiHash {
            return "patch.abi: captured on engine ABI \(captured.engineAbi), this build has \(running.engineAbi)"
        }
        if !settings.patchArtifact, let digest = captured.patchSetDigest {
            return "patch.artifact_missing: captured with \(digest); pass its archived artifact with --patch-artifact"
        }
    }
    if settings.patchArtifact, running.patchSetDigest != settings.expectedPatchSetDigest {
        return "patch.mismatch: loaded \(running.patchSetDigest ?? "base"), expected \(settings.expectedPatchSetDigest ?? "none")"
    }
    // A baseline reproduces what was captured; only a verify run may try a candidate.
    if settings.kind != "verify", running.patchSetDigest != captured?.patchSetDigest {
        return "patch.mismatch: a baseline must run the captured \(captured?.patchSetDigest ?? "base"), this attempt loaded \(running.patchSetDigest ?? "base")"
    }
    return nil
}
