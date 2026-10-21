import Foundation

/// Per-endpoint normalization applied before a request key is computed.
///
/// ```swift
/// EndpointRule("POST", "/payments", ignoreBodyFields: ["timestamp", "nonce"], matchBodyFields: ["cart_id", "amount"])
/// ```
///
/// `path` matches the URL path exactly, `:name` matches one segment and a
/// trailing `*` any remainder. `method` may be `*`.
public struct EndpointRule: Sendable {
    public let method: String
    public let path: String
    public let ignoreQuery: Set<String>
    /// A plain name is removed at any depth; a dotted path (`meta.ts`) only there.
    public let ignoreBodyFields: Set<String>
    /// When set, only these top-level body fields take part in the key.
    public let matchBodyFields: [String]?
    private let pattern: String

    public init(
        _ method: String, _ path: String, ignoreQuery: Set<String> = [], ignoreBodyFields: Set<String> = [],
        matchBodyFields: [String]? = nil
    ) {
        self.method = method.uppercased()
        self.path = path
        self.ignoreQuery = ignoreQuery
        self.ignoreBodyFields = ignoreBodyFields
        self.matchBodyFields = matchBodyFields
        let wildcard = path.hasSuffix("*")
        let body = wildcard ? String(path.dropLast()) : path
        let segments = body.components(separatedBy: "/").map { segment in
            segment.hasPrefix(":") ? "[^/]+" : NSRegularExpression.escapedPattern(for: segment)
        }
        pattern = "^" + segments.joined(separator: "/") + (wildcard ? ".*" : "/?$")
    }

    public func matches(method requestMethod: String, path requestPath: String) -> Bool {
        guard method == "*" || method == requestMethod.uppercased() else { return false }
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        let ns = requestPath as NSString
        return re.firstMatch(in: requestPath, range: NSRange(location: 0, length: ns.length)) != nil
    }
}

/// Builds the stable key used to match a replayed request to a recording
/// (capsule v1 "Network matching"; conformance: `request-keys.json`).
public struct RequestKeyBuilder: Sendable {
    public static let defaultIgnoreQuery: Set<String> = ["_", "ts", "timestamp", "nonce", "cachebust"]
    public static let maxKeyLength = 8000

    public var rules: [EndpointRule]
    public var globalIgnoreQuery: Set<String>
    public var globalIgnoreBodyFields: Set<String>

    public init(
        rules: [EndpointRule] = [], globalIgnoreQuery: Set<String> = RequestKeyBuilder.defaultIgnoreQuery,
        globalIgnoreBodyFields: Set<String> = []
    ) {
        self.rules = rules
        self.globalIgnoreQuery = globalIgnoreQuery
        self.globalIgnoreBodyFields = globalIgnoreBodyFields
    }

    func rule(method: String, path: String) -> EndpointRule? {
        rules.first { $0.matches(method: method, path: path) }
    }

    /// The body of a key: `nil` (no body), a JSON value, or raw text that
    /// is parsed as JSON when it is valid JSON.
    public enum Body: Sendable {
        case json(JSONValue)
        case text(String)
    }

    /// `METHOD host/path?sortedQuery#bodyHash`. The URL and body must already
    /// be redacted, so capture and replay compute the same key.
    public func key(method: String, url: String, body: Body?) -> String {
        key(method: method, uri: DartURI.parse(url), body: body)
    }

    func key(method: String, uri: DartURI, body: Body?) -> String {
        let m = method.uppercased()
        let rule = rule(method: m, path: uri.path)
        let ignoreQuery = globalIgnoreQuery.union(rule?.ignoreQuery ?? [])
        var query: [String] = []
        let params = (try? uri.queryParametersAll()) ?? []
        for (name, values) in params.sorted(by: { utf16Less($0.name, $1.name) }) {
            if ignoreQuery.contains(name) { continue }
            for v in values { query.append("\(name)=\(v)") }
        }
        var key = "\(m) \(uri.host ?? "")\(uri.path.isEmpty ? "/" : uri.path)"
        if !query.isEmpty { key += "?" + query.joined(separator: "&") }
        if let normalized = normalizeBody(body, rule: rule) {
            key += "#" + Self.hash(Self.canonicalJSON(normalized))
        }
        if key.dartLength <= Self.maxKeyLength { return key }
        return key.dartPrefix(Self.maxKeyLength - 20) + "~" + Self.hash(key)
    }

    private func normalizeBody(_ body: Body?, rule: EndpointRule?) -> JSONValue? {
        guard var body else { return nil }
        // Dart passes decoded JSON strings as strings, which are parsed again.
        if case .json(.string(let s)) = body { body = .text(s) }
        var value: JSONValue
        switch body {
        case .json(let v):
            if v.isNull { return nil }
            value = v
        case .text(let s):
            if s.isEmpty { return nil }
            guard let parsed = try? JSON.parse(s) else { return .string(s) }
            value = parsed
        }
        let ignore = globalIgnoreBodyFields.union(rule?.ignoreBodyFields ?? [])
        if let match = rule?.matchBodyFields, case .object(let o) = value {
            var picked = JSONObject()
            for k in match where o.contains(k) { picked[k] = o[k] }
            value = .object(picked)
        }
        return ignore.isEmpty ? value : strip(value, ignore, "")
    }

    private func strip(_ value: JSONValue, _ ignore: Set<String>, _ path: String) -> JSONValue {
        switch value {
        case .object(let o):
            var out = JSONObject()
            for (k, v) in o {
                let p = path.isEmpty ? k : "\(path).\(k)"
                if ignore.contains(k) || ignore.contains(p) { continue }
                out[k] = strip(v, ignore, p)
            }
            return .object(out)
        case .array(let a):
            return .array(a.map { strip($0, ignore, path) })
        default:
            return value
        }
    }

    static func canonicalJSON(_ value: JSONValue) -> String {
        switch value {
        case .object(let o):
            let keys = o.keys.sorted(by: utf16Less)
            var parts: [String] = []
            for k in keys {
                var s = ""
                JSON.writeString(k, into: &s)
                parts.append(s + ":" + canonicalJSON(o[k]!))
            }
            return "{" + parts.joined(separator: ",") + "}"
        case .array(let a):
            return "[" + a.map(canonicalJSON).joined(separator: ",") + "]"
        default:
            return JSON.encode(value)
        }
    }

    /// Two 32-bit FNV-1a passes with different offsets; 16 hex chars.
    static func hash(_ input: String) -> String {
        let bytes = Array(input.utf8)
        func fnv(_ offset: UInt32) -> UInt32 {
            var h = offset
            for b in bytes {
                h ^= UInt32(b)
                h = h &* 0x0100_0193
            }
            return h
        }
        return String(format: "%08x%08x", fnv(0x811C_9DC5), fnv(0x050C_5D1F))
    }
}

/// One recorded HTTP exchange, as stored in an `http` event.
public struct HttpFixture: Sendable {
    public let event: BugCapsuleEvent
    public init(_ event: BugCapsuleEvent) { self.event = event }

    public var data: JSONObject { event.data }
    public var key: String { data["key"]?.stringValue ?? "" }
    public var occurrence: Int { data["occurrence"]?.intValue ?? 0 }
    public var status: Int { data["status"]?.intValue ?? 0 }
    public var durationMs: Int { data["durationMs"]?.intValue ?? 0 }
    public var responseBody: JSONValue { data["responseBody"] ?? .null }
    public var bodyEncoding: String { data["bodyEncoding"]?.stringValue ?? "omitted" }
    public var responseHeaders: [(String, String)] {
        (data["responseHeaders"]?.objectValue ?? JSONObject()).compactMap { k, v in v.stringValue.map { (k, $0) } }
    }
    public var error: JSONObject? { data["error"]?.objectValue }
    public var hasBody: Bool { bodyEncoding != "omitted" && bodyEncoding != "truncated" }
    /// iOS extension (ignored by other readers): the exchange had not
    /// completed when the capsule was written.
    public var isPending: Bool { data["pending"] == .bool(true) }
}

public struct FixtureLookup: Sendable {
    public let fixture: HttpFixture
    /// The request happened more often than recorded; the last response was served again.
    public let reused: Bool
}

/// Serves recorded responses in occurrence order per request key.
public final class FixtureStore: @unchecked Sendable {
    private var byKey: [String: [HttpFixture]] = [:]
    private var keyOrder: [String] = []
    private var served: [String: Int] = [:]
    private let lock = NSLock()

    public init(events: [BugCapsuleEvent]) {
        for e in events where e.type == EventTypes.http {
            let f = HttpFixture(e)
            if byKey[f.key] == nil { keyOrder.append(f.key) }
            byKey[f.key, default: []].append(f)
        }
        for k in byKey.keys {
            byKey[k]!.sort { $0.occurrence < $1.occurrence }
        }
    }

    public var keyCount: Int { byKey.count }

    public func take(_ key: String) -> FixtureLookup? {
        lock.lock()
        defer { lock.unlock() }
        guard let list = byKey[key], !list.isEmpty else { return nil }
        let n = served[key] ?? 0
        served[key] = n + 1
        return n < list.count ? FixtureLookup(fixture: list[n], reused: false) : FixtureLookup(fixture: list.last!, reused: true)
    }

    /// Keys that were recorded but never requested during replay.
    public func unusedKeys() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return keyOrder.filter { served[$0] == nil }
    }
}
