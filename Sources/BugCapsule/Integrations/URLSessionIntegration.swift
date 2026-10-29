import Foundation

/// URLSession capture and replay through an explicit `URLProtocol`
/// (no swizzling).
///
/// ```swift
/// let config = URLSessionConfiguration.default
/// BugCapsule.instrument(config)              // inserts the SDK's URL protocol first
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

    // MARK: downstream sessions

    private static let downstreamLock = NSLock()
    // By the protocol class `instrument(_:)` put in the configuration; the
    // base class (shared session, global registry) maps to `.default`.
    nonisolated(unsafe) private static var downstreams: [ObjectIdentifier: DownstreamSession] = [:]
    nonisolated(unsafe) private static var protocolClassCount = 0

    /// `BugCapsuleURLProtocol` or one of the subclasses `instrument(_:)` creates.
    static func isSDKProtocol(_ c: AnyClass) -> Bool {
        (c as? NSObject.Type)?.isSubclass(of: BugCapsuleURLProtocol.self) ?? false
    }

    /// A new `BugCapsuleURLProtocol` subclass whose requests are re-issued on
    /// a session built from [config] (its own headers, cookie storage, cache
    /// policy, TLS and proxy settings, and protocol classes), so nothing of one
    /// configuration reaches another session's requests.
    static func registerDownstream(from config: URLSessionConfiguration) -> AnyClass {
        downstreamLock.locked {
            let downstream = DownstreamSession(downstreamConfiguration(config))
            for _ in 0..<8 {
                protocolClassCount += 1
                let name = "BugCapsuleURLProtocol_\(protocolClassCount)_\(UInt32.random(in: 0...UInt32.max))"
                guard let c = objc_allocateClassPair(BugCapsuleURLProtocol.self, name, 0) else { continue }
                objc_registerClassPair(c)
                downstreams[ObjectIdentifier(c)] = downstream
                return c
            }
            // Not expected (the names are unique): fall back to what the
            // shared session uses rather than to another session's configuration.
            BugCapsuleLog.warn("could not tag an instrumented URLSessionConfiguration; its requests use URLSessionConfiguration.default")
            return BugCapsuleURLProtocol.self
        }
    }

    /// The downstream session for requests intercepted by [protocolClass].
    static func downstream(for protocolClass: AnyClass) -> DownstreamSession {
        downstreamLock.locked {
            if let d = downstreams[ObjectIdentifier(protocolClass)] { return d }
            // Not set up by `instrument(_:)` (`instrumentSharedSession()`, or the
            // class added by hand): what `URLSession.shared` uses.
            let key = ObjectIdentifier(BugCapsuleURLProtocol.self)
            if let d = downstreams[key] { return d }
            let d = DownstreamSession(downstreamConfiguration(.default))
            downstreams[key] = d
            return d
        }
    }

    /// A copy of [config] minus the SDK's protocol, keeping its own protocol
    /// classes first and the system's after them.
    private static func downstreamConfiguration(_ config: URLSessionConfiguration) -> URLSessionConfiguration {
        let copy = config.copy() as! URLSessionConfiguration
        let protocols = (copy.protocolClasses ?? []).filter { !isSDKProtocol($0) }
        let system = URLSessionConfiguration.default.protocolClasses ?? []
        copy.protocolClasses = protocols + system.filter { s in !protocols.contains { $0 == s } && !isSDKProtocol(s) }
        return copy
    }
}

/// The session that performs real requests below the SDK's protocol for one
/// instrumented configuration. Created on demand and invalidated after
/// `idleTimeout` without tasks, so configurations instrumented once and no
/// longer used don't keep a session open.
final class DownstreamSession: @unchecked Sendable {
    /// Changed by tests only.
    nonisolated(unsafe) static var idleTimeout: TimeInterval = 60

    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var session: URLSession?
    private var running = 0
    private var generation = 0

    init(_ configuration: URLSessionConfiguration) { self.configuration = configuration }

    /// A task on this configuration's session; `taskEnded()` once it completes.
    func dataTask(with request: URLRequest) -> URLSessionDataTask {
        lock.locked {
            running += 1
            generation += 1
            let s = session ?? URLSession(
                configuration: configuration, delegate: DownstreamDelegate.shared, delegateQueue: DownstreamDelegate.shared.queue)
            session = s
            return s.dataTask(with: request)
        }
    }

    func taskEnded() {
        let idle: Int? = lock.locked {
            running -= 1
            return running == 0 ? generation : nil
        }
        guard let idle else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + DownstreamSession.idleTimeout) { [self] in
            let s: URLSession? = lock.locked {
                guard running == 0, generation == idle else { return nil }
                defer { session = nil }
                return session
            }
            s?.finishTasksAndInvalidate()
        }
    }
}

extension BugCapsule {
    /// Inserts the SDK's URL protocol (a `BugCapsuleURLProtocol` subclass
    /// for this configuration) as the first protocol of [configuration]
    /// (create your `URLSession` with it afterwards). Requests are re-issued
    /// with a copy of the configuration as it is now: its headers, cookie
    /// storage, cache policy and TLS settings apply to its own requests only.
    /// Protocol classes already in the configuration keep running below the SDK's.
    public static func instrument(_ configuration: URLSessionConfiguration) {
        var protocols = configuration.protocolClasses ?? []
        protocols.removeAll { BugCapsuleURLSession.isSDKProtocol($0) }
        let original = configuration.copy() as! URLSessionConfiguration
        original.protocolClasses = protocols
        let tagged: AnyClass = BugCapsuleURLSession.registerDownstream(from: original)
        configuration.protocolClasses = [tagged] + protocols
        BugCapsuleURLSession.protocolInstalled = true
    }

    /// Opt-in for `URLSession.shared` (and other sessions using the global
    /// protocol registry): `URLProtocol.registerClass(BugCapsuleURLProtocol.self)`.
    /// Their requests are re-issued with `URLSessionConfiguration.default`
    /// (shared cookie storage, cache and credentials), as `URLSession.shared` does.
    public static func instrumentSharedSession() {
        URLProtocol.registerClass(BugCapsuleURLProtocol.self)
        BugCapsuleURLSession.protocolInstalled = true
    }
}
