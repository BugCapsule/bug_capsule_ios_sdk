#if os(iOS)
import Foundation

/// Signed channel metadata as delivered, kept as the exact received bytes.
public struct SignedChannel: Sendable {
    public let document: Data
    public let signature: Data
    public let etag: String?
    /// The current keyring, applied first so a rotated signer verifies.
    public let keyringDocument: Data?
    public let keyringSignature: Data?

    public init(document: Data, signature: Data, etag: String? = nil, keyringDocument: Data? = nil, keyringSignature: Data? = nil) {
        self.keyringDocument = keyringDocument
        self.keyringSignature = keyringSignature
        self.document = document
        self.signature = signature
        self.etag = etag
    }
}

/// How an app reaches its delivery endpoint. TLS, tokens and retries live
/// here; the runtime treats everything that comes back as untrusted.
public protocol PatchTransport: Sendable {
    /// Nil means nothing changed since `etag`.
    func fetchChannel(etag: String?) async throws -> SignedChannel?
    func fetchArtifact(digest: String) async throws -> Data
    func postReceipts(_ batch: Data) async throws
}

public enum PatchUpdateState: Sendable {
    case upToDate, restartRequired, notInCohort, quarantined, failed
}

public struct PatchUpdateResult: Sendable {
    public let state: PatchUpdateState
    public let artifactDigest: String?
    public let reason: String?

    init(_ state: PatchUpdateState, artifactDigest: String? = nil, reason: String? = nil) {
        self.state = state
        self.artifactDigest = artifactDigest
        self.reason = reason
    }
}

/// Check, download, verify, stage. Never restarts the app and never changes
/// the running generation. Failures are returned, not thrown, and leave the
/// next launch as it was. The actor serializes concurrent checks.
public actor PatchUpdater {
    private let patch: BugCapsulePatch
    private let transport: any PatchTransport
    private var etag: String?

    public init(patch: BugCapsulePatch, transport: any PatchTransport) {
        self.patch = patch
        self.transport = transport
    }

    public func checkForUpdate() async -> PatchUpdateResult {
        do {
            guard let channel = try await transport.fetchChannel(etag: etag) else { return PatchUpdateResult(.upToDate) }
            if let k = channel.keyringDocument, let s = channel.keyringSignature { try patch.applyKeyring(k, signature: s) }
            let result = try await act(patch.applyChannel(channel.document, signature: channel.signature))
            // Only after the download and staging worked: a 304 must not end retries.
            etag = channel.etag
            return result
        } catch let e as PatchError {
            return PatchUpdateResult(.failed, reason: e.code)
        } catch let e as PatchHTTPError {
            return PatchUpdateResult(.failed, reason: e.reason)
        } catch {
            return PatchUpdateResult(.failed, reason: "transport: \(error)")
        }
    }

    private func act(_ d: [String: Any]) async throws -> PatchUpdateResult {
        let digest = d["artifactDigest"] as? String
        switch d["action"] as? String {
        case "download":
            let staged = try await patch.stage(transport.fetchArtifact(digest: digest ?? ""))
            return PatchUpdateResult(.restartRequired, artifactDigest: staged["artifactDigest"] as? String)
        case "restart_required":
            let target = d["target"] as? String
            return PatchUpdateResult(.restartRequired, artifactDigest: target == "base" ? nil : target)
        default:
            switch d["reason"] as? String {
            case "not_in_cohort": return PatchUpdateResult(.notInCohort)
            case "quarantined": return PatchUpdateResult(.quarantined, artifactDigest: digest)
            default: return PatchUpdateResult(.upToDate)
            }
        }
    }

    /// Uploads local receipts, acknowledging them only after the server took them.
    public func flushReceipts() async throws -> Int {
        var batch = try patch.receipts()
        let items = batch["receipts"] as? [[String: Any]] ?? []
        guard let last = items.last?["seq"] as? UInt64 ?? (items.last?["seq"] as? Int).map(UInt64.init) else { return 0 }
        batch["status"] = try patch.status()
        try await transport.postReceipts(JSONSerialization.data(withJSONObject: batch))
        try patch.ackReceipts(upTo: last)
        return items.count
    }
}

#endif
