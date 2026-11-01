#if os(iOS)
import BugCapsule
import Foundation

/// Opens the runtime for BugCapsule: normally from the device store, and in a
/// replay attempt pinned to one exact artifact. Set it as
/// `BugCapsuleConfig.patchBinding`, then use `patch`.
public final class BugCapsulePatchBinding: PatchBinding, @unchecked Sendable {
    private let config: PatchConfig
    private let modules: [PatchContract]
    private let surfaces: [PatchSurfaceContract]
    private let lock = NSLock()
    private var opened: BugCapsulePatch?

    public init(config: PatchConfig, modules: [PatchContract], surfaces: [PatchSurfaceContract] = []) {
        self.config = config
        self.modules = modules
        self.surfaces = surfaces
    }

    /// The runtime of this process.
    public var patch: BugCapsulePatch {
        lock.lock()
        defer { lock.unlock() }
        if let opened { return opened }
        let p = BugCapsulePatch.open(config: config, modules: modules, surfaces: surfaces)
        opened = p
        return p
    }

    public var identity: PatchIdentity? { identity(of: patch) }

    private func identity(of p: BugCapsulePatch) -> PatchIdentity? {
        guard p.available, let s = try? p.status(), let base = s["baseBuildId"] as? String,
            let abi = s["engineAbi"] as? Int, let hash = s["hostAbiHash"] as? String
        else { return nil }
        let running = s["running"] as? [String: Any]
        return PatchIdentity(
            baseBuildId: base, patchSetDigest: running?["patchSetDigest"] as? String, engineAbi: abi, hostAbiHash: hash,
            artifactDigest: running?["artifactDigest"] as? String)
    }

    public func pinForReplay(bundle: Data?, keyring: Data?, keyringSignature: Data?) throws -> PatchIdentity? {
        guard (keyring == nil) == (keyringSignature == nil) else { throw PatchError(code: "bad_input", message: "a keyring needs its signature") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bcpatch-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The runtime loads the archive at open; nothing reads these afterwards.
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ name: String, _ data: Data?) throws -> String? {
            guard let data else { return nil }
            let url = dir.appendingPathComponent(name)
            try data.write(to: url)
            return url.path
        }
        let replay = PatchReplay(
            bundlePath: try write("artifact.bcpatch", bundle), keyringPath: try write("keyring.json", keyring),
            keyringSignaturePath: try write("keyring.sig", keyringSignature))
        let p = BugCapsulePatch.open(config: config, modules: modules, surfaces: surfaces, replay: replay)
        guard p.available else { throw PatchError(code: p.unavailableReason ?? "unavailable", message: "the pinned artifact was refused") }
        lock.lock()
        let handle = opened ?? p
        if handle !== p { handle.adoptReplay(p) }
        opened = handle
        lock.unlock()
        return identity(of: handle)
    }
}

#endif
