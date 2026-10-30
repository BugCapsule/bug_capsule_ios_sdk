import Foundation

/// Talks to the CLI's replay server: `GET <base>/settings`, `GET
/// <base>/capsule`, `POST <base>/result` (protocol v1.1). Also writes the
/// `BUGCAPSULE_RESULT::{json}` fallback line and exposes the report to the
/// UI test (accessibility element) so the XCUITest output carries it.
final class ReplayChannel: @unchecked Sendable {
    let baseURL: String
    private let session: URLSession
    /// What this attempt runs, attached to every report.
    nonisolated(unsafe) var patch: PatchIdentity?

    enum DeliveryStatus: Equatable, Sendable {
        case accepted
        /// 409 (wrong attemptId) or 410 (attempt closed): stop, never retry.
        case stale(Int)
        case failed(String)
    }

    init(baseURL: String) {
        var b = baseURL
        while b.hasSuffix("/") { b.removeLast() }
        self.baseURL = b
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = []
        c.timeoutIntervalForRequest = 15
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: c)
    }

    private func request(_ path: String) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else { throw CapsuleFormatError("bad replay URL \(baseURL)") }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        BugCapsuleURLProtocol.markInternal(&req)
        return req
    }

    struct HTTPError: Error, CustomStringConvertible {
        let description: String
    }

    private func syncData(_ req: URLRequest, timeout: TimeInterval) throws -> (Data, Int) {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<(Data, Int), Error> = .failure(HTTPError(description: "timed out"))
        let task = session.dataTask(with: req) { data, response, error in
            if let error {
                result = .failure(error)
            } else {
                result = .success((data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
            }
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            throw HTTPError(description: "replay server did not answer within \(Int(timeout))s")
        }
        return try result.get()
    }

    /// A file of this attempt's patch archive. Throws when it can't be loaded.
    func fetchPatchFileSync(_ path: String, timeout: TimeInterval = 20) throws -> Data {
        let (data, status) = try syncData(try request(path), timeout: timeout)
        guard status == 200 else { throw HTTPError(description: "\(path) download failed: HTTP \(status)") }
        return data
    }

    /// Blocking fetch, called from `BugCapsule.start` so that checkpoint
    /// data is restored before app code runs (loopback, DEBUG builds only).
    func fetchSync(timeout: TimeInterval = 20) throws -> (Capsule, ReplaySettings) {
        let (settingsData, s1) = try syncData(try request(ReplayProtocol.settingsPath), timeout: timeout)
        guard s1 == 200, case .object(let settingsJSON) = try JSON.parse(settingsData) else {
            throw HTTPError(description: "settings download failed: HTTP \(s1)")
        }
        let (capsuleData, s2) = try syncData(try request(ReplayProtocol.capsulePath), timeout: timeout)
        guard s2 == 200 else { throw HTTPError(description: "capsule download failed: HTTP \(s2)") }
        return (try CapsuleCodec.decode(capsuleData), ReplaySettings(json: settingsJSON))
    }

    static func status(for code: Int) -> DeliveryStatus {
        switch code {
        case 200...299: return .accepted
        case 409, 410: return .stale(code)
        default: return .failed("HTTP \(code)")
        }
    }

    /// Posts the report (blocking up to `timeout`), prints the fallback
    /// line and, on iOS, shows the report to the UI test. Safe from any thread.
    @discardableResult
    func deliver(_ report: ReplayReport, attemptId: String?, timeout: TimeInterval = 5) -> DeliveryStatus {
        var r = report
        if r.attemptId == nil { r.attemptId = attemptId }
        r.patch = patch
        let json = JSON.encode(r.json)
        let line = ReplayProtocol.stdoutPrefix + json + "\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        ReplayResultMarker.publish(json)
        do {
            var req = try request(ReplayProtocol.resultPath)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(json.utf8)
            let (_, code) = try syncData(req, timeout: timeout)
            let status = Self.status(for: code)
            if case .stale(let c) = status {
                BugCapsuleLog.warn("replay attempt is stale (HTTP \(c)); the CLI closed it, not retrying")
            }
            return status
        } catch {
            BugCapsuleLog.warn("could not post replay result: \(error)")
            return .failed("\(error)")
        }
    }
}
