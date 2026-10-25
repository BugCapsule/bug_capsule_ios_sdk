import Foundation

/// URLSession capture and replay through an explicit `URLProtocol`
/// (no swizzling).
///
/// ```swift
/// let config = URLSessionConfiguration.default
/// BugCapsule.instrument(config)              // inserts BugCapsuleURLProtocol first
/// let session = URLSession(configuration: config)
/// // URLSession.shared: BugCapsule.instrumentSharedSession() (URLProtocol.registerClass)
/// ```
///
/// Capture streams every chunk to the app as it arrives and keeps only a
/// bounded prefix (`maxBodyBytes`, 256 KiB text / `maxBinaryBytes` 64 KiB
/// binary); a larger body, or one still streaming after `maxBodyWait`, is
/// recorded as `truncated`. Request bodies set with `httpBody` are hashed
/// into the key when ≤ `maxKeyBodyBytes` (64 KiB); `httpBodyStream` bodies
/// (one-shot) are keyed without a hash and recorded as `omitted`.
///
/// Replay serves the fixture with the same key and occurrence after the
/// recorded latency; unrecorded requests fail with
/// `URLError(.cannotConnectToHost)` and `network.unrecorded` (strict) and
/// never reach the network unless `--lenient-network`.
///
/// Alamofire works the same way: pass an instrumented configuration to
/// `Session(configuration:)`.
public final class BugCapsuleURLSession: BugCapsuleIntegration, @unchecked Sendable {
    public let name = "urlsession"
    public var capabilities: [(String, String)] { [("network.urlsession", "supported")] }

    public let keys: RequestKeyBuilder
    public let maxBinaryBytes: Int
    public let maxKeyBodyBytes: Int
    public let maxBodyWait: TimeInterval
    /// Requests recorded with method, redacted URL, status and timing only.
    public let exclude: (@Sendable (URLRequest) -> Bool)?

    private let lock = NSLock()
    private var occurrences: [String: Int] = [:]
    private var nextId = 0
    private(set) var session: BugCapsuleSession?

    private static let activeLock = NSLock()
    nonisolated(unsafe) private static var _active: BugCapsuleURLSession?
    static var active: BugCapsuleURLSession? { activeLock.locked { _active } }

    nonisolated(unsafe) private static var _protocolInstalled = false
    /// `BugCapsuleURLProtocol` was installed (`instrument`, `instrumentSharedSession`)
    /// or has seen an app request (`BugCapsule.status`).
    static var protocolInstalled: Bool {
        get { activeLock.locked { _protocolInstalled } }
        set { activeLock.locked { _protocolInstalled = newValue } }
    }

    public init(
        rules: [EndpointRule] = [], ignoreQuery: Set<String> = RequestKeyBuilder.defaultIgnoreQuery,
        ignoreBodyFields: Set<String> = [], maxBinaryBytes: Int = 64 * 1024, maxKeyBodyBytes: Int = 64 * 1024,
        maxBodyWait: TimeInterval = 30, exclude: (@Sendable (URLRequest) -> Bool)? = nil
    ) {
        keys = RequestKeyBuilder(rules: rules, globalIgnoreQuery: ignoreQuery, globalIgnoreBodyFields: ignoreBodyFields)
        self.maxBinaryBytes = maxBinaryBytes
        self.maxKeyBodyBytes = maxKeyBodyBytes
        self.maxBodyWait = maxBodyWait
        self.exclude = exclude
    }

    public func setUp(_ session: BugCapsuleSession) {
        lock.locked { self.session = session }
        Self.activeLock.locked { Self._active = self }
    }

    public func describeEligibility(_ eligibility: EligibilityBuilder, window: RecordedWindow) {
        let missing = window.events.filter { e in
            e.type == EventTypes.http && (e.data["error"]?.isNull ?? true)
                && (e.data["bodyEncoding"] == .string("omitted") || e.data["bodyEncoding"] == .string("truncated"))
        }
        if !missing.isEmpty {
            eligibility.missing(
                "network.bodies",
                "\(missing.count) recorded responses have no body (capture disabled, excluded or too large)")
        }
    }

    // Exchanges still in flight (capture), so a capsule written meanwhile
    // (e.g. by the crash handler) records them as `pending`.
    private final class WeakProtocol: @unchecked Sendable {
        weak var value: BugCapsuleURLProtocol?
        init(_ v: BugCapsuleURLProtocol) { value = v }
    }
    private var inFlight: [ObjectIdentifier: WeakProtocol] = [:]

    func began(_ p: BugCapsuleURLProtocol) { lock.locked { inFlight[ObjectIdentifier(p)] = WeakProtocol(p) } }
    func ended(_ p: BugCapsuleURLProtocol) { lock.locked { _ = inFlight.removeValue(forKey: ObjectIdentifier(p)) } }

    /// `http` event data for exchanges that have not completed yet: replay
    /// keeps such requests open (the app never saw their response).
    func pendingExchanges() -> [JSONObject] {
        let live = lock.locked { inFlight.values.compactMap(\.value) }
        return live.compactMap { $0.pendingSnapshot() }.sorted { ($0["id"]?.intValue ?? 0) < ($1["id"]?.intValue ?? 0) }
    }

    func nextOccurrence(_ key: String) -> (occurrence: Int, id: Int) {
        lock.locked {
            let n = occurrences[key, default: -1] + 1
            occurrences[key] = n
            let id = nextId
            nextId += 1
            return (n, id)
        }
    }

    // MARK: bodies

    static func isMultipart(_ contentType: String?) -> Bool {
        (contentType ?? "").lowercased().hasPrefix("multipart/")
    }

    static func isText(_ type: String) -> Bool {
        type.contains("json") || type.hasPrefix("text/") || type.contains("xml") || type.contains("x-www-form-urlencoded")
            || type.isEmpty
    }

    /// Decodes a complete body for keying and storage: redacted JSON, form
    /// fields, scrubbed text, or small binary as base64.
    func decode(_ bytes: Data, contentType: String?, redactor: Redactor) -> (JSONValue, String) {
        if bytes.isEmpty { return (.null, "json") }
        let type = (contentType ?? "").lowercased()
        if Self.isText(type) {
            guard let text = String(data: bytes, encoding: .utf8) else { return binary(bytes) }
            if type.contains("json") || type.isEmpty {
                if let v = try? JSON.parse(text) { return (redactor.redactJSON(v), "json") }
                return (.string(redactor.scrubText(text)), "text")
            }
            if type.contains("x-www-form-urlencoded") {
                if let form = Self.splitQueryString(text) { return (redactor.redactJSON(.object(form)), "form") }
                return (.string(redactor.scrubText(text)), "text")
            }
            return (.string(redactor.scrubText(text)), "text")
        }
        return binary(bytes)
    }

    private func binary(_ bytes: Data) -> (JSONValue, String) {
        bytes.count > maxBinaryBytes ? (.null, "truncated") : (.string(bytes.base64EncodedString()), "base64")
    }

    /// Dart's `Uri.splitQueryString` (later values win).
    static func splitQueryString(_ s: String) -> JSONObject? {
        var out = JSONObject()
        for part in s.split(separator: "&", omittingEmptySubsequences: true) {
            do {
                if let eq = part.firstIndex(of: "=") {
                    out[try DartURI.decodeComponent(part[..<eq])] = .string(try DartURI.decodeComponent(part[part.index(after: eq)...]))
                } else {
                    out[try DartURI.decodeComponent(part)] = ""
                }
            } catch {
                return nil
            }
        }
        return out
    }

    static func encodeBody(_ body: JSONValue, encoding: String) -> Data {
        switch encoding {
        case "json": return body.isNull ? Data() : JSON.encodeData(body)
        case "text": return Data((body.stringValue ?? "").utf8)
        case "form":
            let pairs = (body.objectValue ?? JSONObject()).map { k, v -> String in
                let value = v.stringValue ?? JSON.encode(v)
                let ek = DartURI.encodeQueryComponent(k)
                return value.isEmpty ? ek : ek + "=" + DartURI.encodeQueryComponent(value)
            }
            return Data(pairs.joined(separator: "&").utf8)
        case "base64": return Data(base64Encoded: body.stringValue ?? "") ?? Data()
        default: return Data()
        }
    }

    /// The request key; capture and replay call this with the same inputs.
    func key(for request: URLRequest, body: Data?, redactor: Redactor) -> String {
        let uri = redactor.redactURI(DartURI.parse(request.url?.absoluteString ?? ""))
        let contentType = request.value(forHTTPHeaderField: "Content-Type")
        var keyBody: RequestKeyBuilder.Body?
        if let body, body.count <= maxKeyBodyBytes, !Self.isMultipart(contentType) {
            let (value, encoding) = decode(body, contentType: contentType, redactor: redactor)
            switch (value, encoding) {
            case (.null, _): keyBody = nil
            case (.string(let s), "text"), (.string(let s), "base64"): keyBody = .text(s)
            default: keyBody = .json(value)
            }
        }
        return keys.key(method: request.httpMethod ?? "GET", uri: uri, body: keyBody)
    }

    // MARK: downstream configuration

    private static let downstreamLock = NSLock()
    nonisolated(unsafe) private static var downstreamConfig: URLSessionConfiguration?
    nonisolated(unsafe) private static var downstreamSession: URLSession?
    nonisolated(unsafe) private static var downstreamProtocols: [AnyClass] = []

    static func registerDownstream(from config: URLSessionConfiguration) {
        downstreamLock.locked {
            let copy = config.copy() as! URLSessionConfiguration
            var protocols = downstreamProtocols
            for p in copy.protocolClasses ?? [] where p != BugCapsuleURLProtocol.self {
                if !protocols.contains(where: { $0 == p }) { protocols.append(p) }
            }
            downstreamProtocols = protocols
            let system = URLSessionConfiguration.default.protocolClasses ?? []
            copy.protocolClasses = protocols + system.filter { s in !protocols.contains { $0 == s } && s != BugCapsuleURLProtocol.self }
            downstreamConfig = copy
            downstreamSession = nil
        }
    }

    /// The session that performs real requests below the SDK's protocol
    /// (the instrumented configuration minus `BugCapsuleURLProtocol`, keeping
    /// app protocols registered after it).
    static func downstream() -> URLSession {
        downstreamLock.locked {
            if let s = downstreamSession { return s }
            let config = downstreamConfig ?? URLSessionConfiguration.default
            let s = URLSession(configuration: config, delegate: DownstreamDelegate.shared, delegateQueue: DownstreamDelegate.shared.queue)
            downstreamSession = s
            return s
        }
    }
}

extension BugCapsule {
    /// Inserts `BugCapsuleURLProtocol` as the first protocol of
    /// [configuration] (create your `URLSession` with it afterwards). Protocol
    /// classes already in the configuration keep running below the SDK's.
    public static func instrument(_ configuration: URLSessionConfiguration) {
        var protocols = configuration.protocolClasses ?? []
        protocols.removeAll { $0 == BugCapsuleURLProtocol.self }
        let original = configuration.copy() as! URLSessionConfiguration
        original.protocolClasses = protocols
        BugCapsuleURLSession.registerDownstream(from: original)
        configuration.protocolClasses = [BugCapsuleURLProtocol.self] + protocols
        BugCapsuleURLSession.protocolInstalled = true
    }

    /// Opt-in for `URLSession.shared` (and other sessions using the global
    /// protocol registry): `URLProtocol.registerClass(BugCapsuleURLProtocol.self)`.
    public static func instrumentSharedSession() {
        URLProtocol.registerClass(BugCapsuleURLProtocol.self)
        BugCapsuleURLSession.protocolInstalled = true
    }
}
