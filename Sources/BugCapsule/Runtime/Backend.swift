import Foundation

public enum UploadStatus: String, Sendable { case uploaded, rejected, retryLater }

public struct UploadResult: Sendable, Equatable {
    public var status: UploadStatus
    public var serverId: String?
    public var message: String?
    /// From a `Retry-After` header (seconds).
    public var retryAfter: TimeInterval?

    public init(_ status: UploadStatus, serverId: String? = nil, message: String? = nil, retryAfter: TimeInterval? = nil) {
        self.status = status
        self.serverId = serverId
        self.message = message
        self.retryAfter = retryAfter
    }
}

/// Result of one `GET /v1/sdk/config`.
public enum ConfigFetchResult: Sendable {
    case fetched(RemoteCaptureConfig)
    case failed(message: String, status: Int?, retryAfter: TimeInterval?)
}

/// How the SDK talks to the backend; tests substitute a fake.
public protocol BugCapsuleTransport: Sendable {
    func fetchConfig() async -> ConfigFetchResult
    func upload(_ bytes: Data) async -> UploadResult
    /// `POST /v1/envelope` (monitoring-v1 §1). [body] is the envelope JSON,
    /// gzip-compressed when [gzipped].
    func sendEnvelope(_ body: Data, gzipped: Bool) async -> UploadResult
}

extension BugCapsuleTransport {
    /// Transports written before monitoring drop envelopes.
    public func sendEnvelope(_ body: Data, gzipped: Bool) async -> UploadResult {
        UploadResult(.rejected, message: "this transport does not send monitoring envelopes")
    }
}

/// URLSession client for `GET /v1/sdk/config` and `POST /v1/capsules`.
/// Its requests are marked so the SDK's own URLProtocol never records them.
public final class BugCapsuleBackendClient: BugCapsuleTransport, @unchecked Sendable {
    public let config: BugCapsuleBackendConfig
    private let session: URLSession
    static let timeout: TimeInterval = 20

    public convenience init(config: BugCapsuleBackendConfig) {
        self.init(config: config, protocolClasses: [])
    }

    /// [protocolClasses]: stubs in tests; the app's protocols never see SDK traffic.
    init(config: BugCapsuleBackendConfig, protocolClasses: [AnyClass]) {
        self.config = config
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = Self.timeout
        c.waitsForConnectivity = false
        c.protocolClasses = protocolClasses
        session = URLSession(configuration: c)
    }

    private func url(_ path: String) -> URL? {
        var base = config.url
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path)
    }

    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
            let s = Int(raw.trimmingCharacters(in: .whitespaces))
        else { return nil }
        return TimeInterval(min(max(s, 0), 86400))
    }

    public func fetchConfig() async -> ConfigFetchResult {
        guard let url = url("/v1/sdk/config") else { return .failed(message: "bad backend URL", status: nil, retryAfter: nil) }
        var req = URLRequest(url: url, timeoutInterval: Self.timeout)
        req.setValue("Bearer \(config.ingestKey)", forHTTPHeaderField: "Authorization")
        BugCapsuleURLProtocol.markInternal(&req)
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failed(message: "not HTTP", status: nil, retryAfter: nil)
            }
            if http.statusCode != 200 {
                return .failed(message: "HTTP \(http.statusCode)", status: http.statusCode, retryAfter: Self.retryAfter(http))
            }
            guard case .object(let o) = try JSON.parse(data) else {
                return .failed(message: "config is not a JSON object", status: nil, retryAfter: nil)
            }
            return .fetched(try RemoteCaptureConfig(json: o, fetchedAtMs: Int(Date().timeIntervalSince1970 * 1000)))
        } catch {
            return .failed(message: "\(error.localizedDescription)", status: nil, retryAfter: nil)
        }
    }

    public func upload(_ bytes: Data) async -> UploadResult {
        guard let url = url("/v1/capsules") else { return UploadResult(.rejected, message: "bad backend URL") }
        // Room for a slow uplink: 20 s plus 1 s per 16 KB.
        var req = URLRequest(url: url, timeoutInterval: Self.timeout + TimeInterval(bytes.count / (16 * 1024)))
        req.httpMethod = "POST"
        req.setValue("Bearer \(config.ingestKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        BugCapsuleURLProtocol.markInternal(&req)
        do {
            let (data, response) = try await session.upload(for: req, from: bytes)
            guard let http = response as? HTTPURLResponse else { return UploadResult(.retryLater, message: "not HTTP") }
            let json = (try? JSON.parse(data))?.objectValue
            if http.statusCode == 200 || http.statusCode == 201 {
                return UploadResult(.uploaded, serverId: json?["id"]?.stringValue)
            }
            let code = json?["code"]?.stringValue ?? "HTTP \(http.statusCode)"
            // 4xx other than 401/408/429 will never succeed: drop.
            let retry = http.statusCode >= 500 || [401, 408, 429].contains(http.statusCode)
            return UploadResult(retry ? .retryLater : .rejected, message: code, retryAfter: Self.retryAfter(http))
        } catch {
            return UploadResult(.retryLater, message: error.localizedDescription)
        }
    }

    /// `200` with `{accepted, rejected}`: delivered (rejected items are
    /// never retried). 429/5xx/401/408: retry (honouring `Retry-After`);
    /// other 4xx (malformed, too large, `capture_disabled`): dropped.
    public func sendEnvelope(_ body: Data, gzipped: Bool) async -> UploadResult {
        guard let url = url("/v1/envelope") else { return UploadResult(.rejected, message: "bad backend URL") }
        var req = URLRequest(url: url, timeoutInterval: Self.timeout + TimeInterval(body.count / (16 * 1024)))
        req.httpMethod = "POST"
        req.setValue("Bearer \(config.ingestKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if gzipped { req.setValue("gzip", forHTTPHeaderField: "Content-Encoding") }
        BugCapsuleURLProtocol.markInternal(&req)
        do {
            let (data, response) = try await session.upload(for: req, from: body)
            guard let http = response as? HTTPURLResponse else { return UploadResult(.retryLater, message: "not HTTP") }
            let json = (try? JSON.parse(data))?.objectValue
            if http.statusCode == 200 || http.statusCode == 202 {
                let accepted = json?["accepted"]?.intValue ?? 0
                let rejected = json?["rejected"]?.arrayValue ?? []
                for r in rejected.prefix(5) {
                    BugCapsuleLog.warn("envelope item \(r["index"]?.intValue ?? -1) rejected: \(r["reason"]?.stringValue ?? "")")
                }
                return UploadResult(.uploaded, message: "accepted \(accepted), rejected \(rejected.count)")
            }
            let code = json?["code"]?.stringValue ?? "HTTP \(http.statusCode)"
            let retry = http.statusCode >= 500 || [401, 408, 429].contains(http.statusCode)
            return UploadResult(retry ? .retryLater : .rejected, message: code, retryAfter: Self.retryAfter(http))
        } catch {
            return UploadResult(.retryLater, message: error.localizedDescription)
        }
    }
}
