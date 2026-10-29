import Foundation

/// Result of one `GET …/emergency/policies` (§3).
enum EmergencyFetchResult: Sendable {
    /// 200: the parsed body (not yet verified) and its ETag.
    case envelope(JSONValue, etag: String?)
    /// 200 whose body is not JSON.
    case unparseable
    /// 304: the cached envelope is current.
    case notModified
    /// 401, 403 or 404: the credential is refused.
    case refused(status: Int, reason: String?)
    /// Anything else (409 `emergency_not_configured`, 429, 5xx, other 4xx,
    /// network error, timeout, oversized body).
    case failed(code: String, message: String, status: Int?, retryAfter: TimeInterval?)
}

/// URLSession client for the emergency endpoints. Requests are marked so the
/// SDK's own URLProtocol never records them.
final class EmergencyHTTPTransport: @unchecked Sendable {
    static let maxBodyBytes = 1 << 20
    let backend: BugCapsuleBackendConfig
    private let session: URLSession

    init(backend: BugCapsuleBackendConfig) {
        self.backend = backend
        let c = URLSessionConfiguration.ephemeral
        // URLSession has no separate connect timeout: 5 s without progress
        // fails the request, 10 s bounds the whole request (§3).
        c.timeoutIntervalForRequest = 5
        c.timeoutIntervalForResource = 10
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpCookieStorage = nil
        session = URLSession(configuration: c)
    }

    deinit { session.finishTasksAndInvalidate() }

    private func url(applicationId: String, path: String, query: [URLQueryItem] = []) -> URL? {
        var base = backend.url
        while base.hasSuffix("/") { base.removeLast() }
        let app = applicationId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? applicationId
        guard var components = URLComponents(string: "\(base)/v1/apps/\(app)/emergency/\(path)") else { return nil }
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }

    /// Diagnostic version strings the backend accepts (1–64 characters).
    static func diagnosticVersion(_ v: String?) -> String? {
        guard let v, !v.isEmpty, v.count <= 64 else { return nil }
        return v
    }

    func fetchPolicies(
        applicationId: String, environment: String, appVersion: String?, etag: String?
    ) async -> EmergencyFetchResult {
        var query = [
            URLQueryItem(name: "environment", value: environment),
            URLQueryItem(name: "platform", value: EmergencyContract.platform),
        ]
        if let v = Self.diagnosticVersion(appVersion) { query.append(URLQueryItem(name: "app_version", value: v)) }
        query.append(URLQueryItem(name: "sdk_version", value: sdkVersion))
        guard let url = url(applicationId: applicationId, path: "policies", query: query) else {
            return .failed(code: "invalid_backend_url", message: "the backend URL is not valid", status: nil, retryAfter: nil)
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        req.setValue("Bearer \(backend.ingestKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        BugCapsuleURLProtocol.markInternal(&req)
        do {
            let (bytes, response) = try await session.bytes(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failed(code: "network_error", message: "not an HTTP response", status: nil, retryAfter: nil)
            }
            if http.expectedContentLength > Int64(Self.maxBodyBytes) {
                bytes.task.cancel()
                return .failed(code: "body_too_large", message: "the policy response is larger than 1 MiB", status: http.statusCode, retryAfter: nil)
            }
            var body = Data()
            for try await b in bytes {
                body.append(b)
                if body.count > Self.maxBodyBytes {
                    bytes.task.cancel()
                    return .failed(
                        code: "body_too_large", message: "the policy response is larger than 1 MiB", status: http.statusCode, retryAfter: nil)
                }
            }
            switch http.statusCode {
            case 200:
                guard let json = try? JSON.parse(body) else { return .unparseable }
                return .envelope(json, etag: http.value(forHTTPHeaderField: "ETag"))
            case 304:
                return .notModified
            case 401, 403, 404:
                let reason = (try? JSON.parse(body))?["reason"]?.stringValue.map { String($0.prefix(100)) }
                return .refused(status: http.statusCode, reason: reason)
            default:
                let problem = try? JSON.parse(body)
                let reason = problem?["reason"]?.stringValue ?? problem?["extra"]?["reason"]?.stringValue
                let code = reason == "emergency_not_configured" ? "emergency_not_configured" : "http_error"
                let message =
                    code == "emergency_not_configured"
                    ? "emergency recovery is not set up for this project (no signing key)" : "HTTP \(http.statusCode)"
                return .failed(
                    code: code, message: message, status: http.statusCode, retryAfter: BugCapsuleBackendClient.retryAfter(http))
            }
        } catch {
            return .failed(code: "network_error", message: error.localizedDescription, status: nil, retryAfter: nil)
        }
    }

    /// `POST …/emergency/receipts`; true on 2xx. Never retried.
    func sendReceipt(applicationId: String, body: JSONObject) async -> Result<Void, EmergencyStatus.Failure> {
        guard let url = url(applicationId: applicationId, path: "receipts") else {
            return .failure(.init(code: "invalid_backend_url", message: "the backend URL is not valid"))
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("Bearer \(backend.ingestKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        BugCapsuleURLProtocol.markInternal(&req)
        do {
            let (_, response) = try await session.upload(for: req, from: JSON.encodeData(.object(body)))
            guard let http = response as? HTTPURLResponse else {
                return .failure(.init(code: "network_error", message: "not an HTTP response"))
            }
            if (200..<300).contains(http.statusCode) { return .success(()) }
            return .failure(.init(code: "http_error", message: "HTTP \(http.statusCode)", httpStatus: http.statusCode))
        } catch {
            return .failure(.init(code: "network_error", message: error.localizedDescription))
        }
    }
}
