import Foundation
import Security

/// On-device state of the emergency module under `<SDK root>/emergency`:
///
/// * `policies.<environment>.json`: the accepted envelope exactly as
///   received, its ETag, when it was received and the highest revision ever
///   accepted for that application and environment (§5), in one file
///   written atomically;
/// * `installation-id`: the random installation id (§7.3), kept apart from
///   the policy cache.
final class EmergencyStore: @unchecked Sendable {
    let directory: URL

    struct Cached: Equatable {
        var applicationId: String
        var environment: String
        /// The envelope as received (verified again on every load).
        var envelope: JSONValue?
        var etag: String?
        var receivedAtMs: Int64?
        var highestRevision: Int?
    }

    init(directory: URL) {
        self.directory = directory
    }

    static func defaultDirectory() throws -> URL {
        try CapsuleStore.defaultRoot().appendingPathComponent("emergency", isDirectory: true)
    }

    private func ensureDirectory() throws {
        try FileIO.ensureDirectory(directory)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var d = directory
        try? d.setResourceValues(values)
    }

    func policyFile(environment: String) -> URL {
        directory.appendingPathComponent("policies.\(environment).json")
    }

    var installationIdFile: URL { directory.appendingPathComponent("installation-id") }

    // MARK: policy cache

    func readPolicies(environment: String) -> Cached? {
        let url = policyFile(environment: environment)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let json = try? JSON.parse(data), case .object(let o) = json, o["v"]?.intValue == 1,
            let app = o["application_id"]?.stringValue, let env = o["environment"]?.stringValue
        else {
            BugCapsuleLog.warn("emergency: the policy cache is unreadable; discarding it")
            FileIO.deleteQuietly(url)
            return nil
        }
        let envelope = o["envelope"].flatMap { $0.isNull ? nil : $0 }
        return Cached(
            applicationId: app, environment: env, envelope: envelope, etag: o["etag"]?.stringValue,
            receivedAtMs: o["received_at_ms"]?.intValue.map(Int64.init), highestRevision: o["highest_revision"]?.intValue)
    }

    func writePolicies(_ c: Cached) throws {
        try ensureDirectory()
        var o: JSONObject = [
            "v": 1, "application_id": .string(c.applicationId), "environment": .string(c.environment),
            "envelope": c.envelope ?? .null,
        ]
        o["etag"] = c.etag.map { .string($0) } ?? .null
        o["received_at_ms"] = c.receivedAtMs.map { .int(Int($0)) } ?? .null
        o["highest_revision"] = c.highestRevision.map { .int($0) } ?? .null
        try FileIO.writeAtomically(JSON.encodeData(.object(o)), to: policyFile(environment: c.environment))
    }

    // MARK: installation id

    /// The persisted installation id, created on first use: 16 random bytes
    /// in base64url (22 characters). If it cannot be stored, the id lives
    /// for this process only.
    func installationId() -> String {
        if let data = try? Data(contentsOf: installationIdFile) {
            let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isInstallationId(s) { return s }
        }
        let id = Self.newInstallationId()
        do {
            try ensureDirectory()
            try FileIO.writeAtomically(Data(id.utf8), to: installationIdFile)
        } catch {
            BugCapsuleLog.warn("emergency: could not store the installation id (\(error.localizedDescription)); using one for this run")
        }
        return id
    }

    static func isInstallationId(_ s: String) -> Bool {
        s.utf8.count == 22
            && s.utf8.allSatisfy { b in
                (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z")) || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
                    || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9")) || b == UInt8(ascii: "-") || b == UInt8(ascii: "_")
            }
    }

    static func newInstallationId() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var g = SystemRandomNumberGenerator()
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &g) }
        }
        return Base64URL.encode(Data(bytes))
    }
}
