#if os(iOS)
import Foundation

/// Refusal from the delivery endpoint, or a response outside its bounds.
public struct PatchHTTPError: Error, Sendable, Equatable {
    public let reason: String
    public let status: Int?

    public init(_ reason: String, status: Int? = nil) {
        self.reason = reason
        self.status = status
    }
}

/// One bounded request. Bytes accumulate only up to the limit, redirects stop
/// at the delegate, an unwanted body is cancelled unread, and the session's
/// resource timeout is an absolute deadline that a trickled body can't extend.
private final class BoundedRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let max: Int
    private let wanted: Set<Int>
    private let lock = NSLock()
    private var body = Data()
    private var failure: PatchHTTPError?
    private var status = 0
    private var etag: String?
    /// The body isn't needed: the status alone is the answer.
    private var bodySkipped = false
    private var continuation: CheckedContinuation<(Int, Data, String?), Error>?

    init(max: Int, wanted: Set<Int>) {
        self.max = max
        self.wanted = wanted
    }

    func run(_ request: URLRequest, timeout: TimeInterval) async throws -> (Int, Data, String?) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withCheckedThrowingContinuation { c in
            lock.withLock { continuation = c }
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse, newRequest: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // The bearer token must not follow a redirect.
        completionHandler(nil)
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let disposition: URLSession.ResponseDisposition = lock.withLock {
            status = http?.statusCode ?? 0
            etag = http?.value(forHTTPHeaderField: "ETag")
            if !wanted.contains(status) {
                bodySkipped = true
                return .cancel
            }
            if response.expectedContentLength > Int64(max) {
                failure = PatchHTTPError("response_too_large", status: status)
                return .cancel
            }
            return .allow
        }
        completionHandler(disposition)
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let over: Bool = lock.withLock {
            if body.count + data.count > max {
                failure = PatchHTTPError("response_too_large", status: status)
                return true
            }
            body.append(data)
            return false
        }
        if over { dataTask.cancel() }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (c, result): (CheckedContinuation<(Int, Data, String?), Error>?, Result<(Int, Data, String?), Error>) = lock.withLock {
            defer { continuation = nil }
            if let failure { return (continuation, .failure(failure)) }
            if bodySkipped { return (continuation, .success((status, Data(), etag))) }
            // A body that ended early is a failure, never a short success.
            if let error {
                let timedOut = (error as? URLError)?.code == .timedOut
                return (continuation, .failure(timedOut ? PatchHTTPError("timed_out") : error))
            }
            return (continuation, .success((status, body, etag)))
        }
        c?.resume(with: result)
    }
}

/// `PatchTransport` over the BugCapsule delivery API (`/v1/apps/:id/patches`).
/// Sizes are bounded while reading. TLS is required except for loopback.
public struct HttpPatchTransport: PatchTransport {
    public static let maxArtifactBytes = 10 << 20
    /// Two 16 KiB documents with signatures, in base64, inside JSON.
    public static let maxChannelBytes = 64 << 10
    public static let maxReceipts = 100
    /// An event outside this list stays local: one unknown name would refuse the whole batch.
    private static let receiptEvents: Set<String> = ["staged", "activated", "healthy", "fault", "quarantined", "rolled_back", "rollback_requested", "invalidated"]

    private let baseURL: String
    private let deliveryToken: String
    private let applicationId: String
    private let platform: String
    private let distributionProfile: String
    private let baseBuildId: String
    private let installationId: String
    /// Absolute limit of a channel or receipt request, reading included.
    private let timeout: TimeInterval
    /// Absolute limit of an artifact download, reading included.
    private let artifactTimeout: TimeInterval

    public init(
        baseURL: String, deliveryToken: String, applicationId: String, platform: String, distributionProfile: String,
        baseBuildId: String, installationId: String, timeout: TimeInterval = 30, artifactTimeout: TimeInterval = 120
    ) throws {
        guard let u = URL(string: baseURL), u.scheme == "https" || ["localhost", "127.0.0.1", "::1"].contains(u.host ?? "") else {
            throw PatchHTTPError("https_required")
        }
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.deliveryToken = deliveryToken
        self.applicationId = applicationId
        self.platform = platform
        self.distributionProfile = distributionProfile
        self.baseBuildId = baseBuildId
        self.installationId = installationId
        self.timeout = timeout
        self.artifactTimeout = artifactTimeout
    }

    private func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET") throws -> URLRequest {
        let app = applicationId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? applicationId
        guard var c = URLComponents(string: "\(baseURL)/v1/apps/\(app)/patches\(path)") else { throw PatchHTTPError("bad_url") }
        if !query.isEmpty { c.queryItems = query }
        guard let url = c.url else { throw PatchHTTPError("bad_url") }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer \(deliveryToken)", forHTTPHeaderField: "Authorization")
        return r
    }

    private func refused(_ status: Int) -> PatchHTTPError {
        switch status {
        case 301, 302, 303, 307, 308: return PatchHTTPError("redirect_refused", status: status)
        case 401, 403: return PatchHTTPError("unauthorized", status: status)
        case 404: return PatchHTTPError("not_found", status: status)
        case 410: return PatchHTTPError("gone", status: status)
        case 429: return PatchHTTPError("rate_limited", status: status)
        default: return PatchHTTPError("http_error", status: status)
        }
    }

    public func fetchChannel(etag: String?) async throws -> SignedChannel? {
        var r = try request("/channel", query: [
            URLQueryItem(name: "platform", value: platform),
            URLQueryItem(name: "distributionProfile", value: distributionProfile),
            URLQueryItem(name: "baseBuildId", value: baseBuildId),
        ])
        if let etag { r.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (status, body, tag) = try await BoundedRequest(max: Self.maxChannelBytes, wanted: [200]).run(r, timeout: timeout)
        if status == 204 || status == 304 { return nil }
        guard status == 200 else { throw refused(status) }
        guard let j = try JSONSerialization.jsonObject(with: body) as? [String: Any],
            let channel = j["channel"] as? [String: Any],
            let document = (channel["document"] as? String).flatMap({ Data(base64Encoded: $0) }),
            let signature = (channel["signature"] as? String).flatMap({ Data(base64Encoded: $0) })
        else { throw PatchHTTPError("malformed_response") }
        let keyring = j["keyring"] as? [String: Any]
        return SignedChannel(
            document: document, signature: signature, etag: tag,
            keyringDocument: (keyring?["document"] as? String).flatMap { Data(base64Encoded: $0) },
            keyringSignature: (keyring?["signature"] as? String).flatMap { Data(base64Encoded: $0) })
    }

    public func fetchArtifact(digest: String) async throws -> Data {
        guard digest.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil else { throw PatchHTTPError("bad_digest") }
        let (status, body, _) = try await BoundedRequest(max: Self.maxArtifactBytes, wanted: [200]).run(try request("/artifacts/\(digest)"), timeout: artifactTimeout)
        guard status == 200 else { throw refused(status) }
        return body
    }

    public func postReceipts(_ batch: Data) async throws {
        guard let b = try JSONSerialization.jsonObject(with: batch) as? [String: Any] else { throw PatchHTTPError("malformed_batch") }
        let status = b["status"] as? [String: Any] ?? [:]
        let pending = (status["pending"] as? String).flatMap { $0.hasPrefix("sha256:") ? $0 : nil }
        let receipts = (b["receipts"] as? [[String: Any]] ?? []).prefix(Self.maxReceipts).filter { Self.receiptEvents.contains($0["event"] as? String ?? "") }
        let body: [String: Any] = [
            "platform": platform, "baseBuildId": baseBuildId, "installationId": installationId,
            "activeDigest": status["activeDigest"] ?? NSNull(), "stagedDigest": pending ?? NSNull(),
            "channelRevision": status["channelRevision"] ?? NSNull(),
            "receipts": receipts.map { r in ["seq": r["seq"] ?? 0, "event": r["event"] ?? "", "digest": r["digest"] ?? NSNull(), "reason": r["reason"] ?? NSNull(), "at": r["at"] ?? 0] },
        ]
        var r = try request("/receipts", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (code, _, _) = try await BoundedRequest(max: 0, wanted: []).run(r, timeout: timeout)
        guard code == 202 else { throw refused(code) }
    }
}

#endif
