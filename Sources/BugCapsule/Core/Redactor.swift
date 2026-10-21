import Foundation

/// On-device redaction applied before anything is recorded (port of the
/// Dart reference `redaction.dart`; conformance: `redaction.json`).
///
/// * by name: JSON keys, header names, query/fragment parameter names and
///   tracked-text ids that look sensitive;
/// * by shape: `scrubText` finds credentials inside free text;
/// * by app rules: extra keys, headers and patterns from the config.
///
/// Word boundaries are ASCII (`[A-Za-z0-9_]`) lookarounds, as in Dart.
public final class Redactor: @unchecked Sendable {
    public static let placeholder = "[REDACTED]"

    static let defaultHeaders: Set<String> = [
        "authorization", "cookie", "set-cookie", "proxy-authorization", "x-api-key", "x-auth-token",
    ]
    static let exactKeys: Set<String> = ["pin", "pan", "otp", "ssn", "cvv", "cvc", "passcode", "iban"]
    static let substringKeys: [String] = [
        "password", "passwd", "token", "secret", "apikey", "authorization", "cookie", "cardnumber", "creditcard",
        "privatekey", "sessionid",
    ]
    static let exactQueryKeys: Set<String> = ["code", "sig", "key", "auth", "sid", "session"]
    static let substringQueryKeys: [String] = ["signature", "credential"]

    /// Keys and headers the app added (config and remote config), as given.
    public let extraKeys: [String]
    public let extraHeaders: [String]
    private let normalizedExtraKeys: Set<String>
    private let headers: Set<String>
    private let patterns: [NSRegularExpression]

    public init(extraKeys: [String] = [], extraHeaders: [String] = [], patterns: [NSRegularExpression] = []) {
        self.extraKeys = Self.dedupe(extraKeys)
        self.extraHeaders = Self.dedupe(extraHeaders)
        normalizedExtraKeys = Set(extraKeys.map(Self.normalize))
        headers = Self.defaultHeaders.union(extraHeaders.map { $0.lowercased() })
        self.patterns = patterns
    }

    private static func dedupe(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    /// A redactor with these rules plus [keys], [headers] and [patterns].
    public func extend(keys: [String] = [], headers: [String] = [], patterns: [NSRegularExpression] = []) -> Redactor {
        Redactor(extraKeys: extraKeys + keys, extraHeaders: extraHeaders + headers, patterns: self.patterns + patterns)
    }

    private static let normalizeChars = try! NSRegularExpression(pattern: "[_\\-\\s.]")

    static func normalize(_ key: String) -> String {
        Regex.replaceAll(normalizeChars, in: key.lowercased(), with: "")
    }

    public func isSensitiveKey(_ key: String) -> Bool {
        let n = Self.normalize(key)
        if Self.exactKeys.contains(n) || normalizedExtraKeys.contains(n) { return true }
        return Self.substringKeys.contains { n.contains($0) }
    }

    /// Like `isSensitiveKey`, plus names that are only secret inside URLs.
    public func isSensitiveQueryKey(_ key: String) -> Bool {
        if isSensitiveKey(key) { return true }
        let n = Self.normalize(key)
        if Self.exactQueryKeys.contains(n) { return true }
        return Self.substringQueryKeys.contains { n.contains($0) }
    }

    public func isSensitiveHeader(_ name: String) -> Bool {
        headers.contains(name.lowercased()) || isSensitiveKey(name)
    }

    // MARK: JSON

    static let maxDepth = 64
    static let maxEmbeddedJSON = 64 * 1024

    /// Deep copy: values under sensitive keys replaced, strings scrubbed,
    /// strings holding a JSON object/array redacted recursively.
    public func redactJSON(_ value: JSONValue) -> JSONValue { redact(value, depth: 0).0 }

    private func redact(_ value: JSONValue, depth: Int) -> (JSONValue, Bool) {
        if depth > Self.maxDepth { return (.string(Self.placeholder), true) }
        switch value {
        case .string(let s): return redactString(s, depth: depth)
        case .object(let o):
            var changed = false
            var out = JSONObject()
            for (k, v) in o {
                if !v.isNull && isSensitiveKey(k) {
                    out[k] = .string(Self.placeholder)
                    changed = true
                } else {
                    let (r, c) = redact(v, depth: depth + 1)
                    out[k] = r
                    changed = changed || c
                }
            }
            return (.object(out), changed)
        case .array(let a):
            var changed = false
            var out: [JSONValue] = []
            out.reserveCapacity(a.count)
            for v in a {
                let (r, c) = redact(v, depth: depth + 1)
                out.append(r)
                changed = changed || c
            }
            return (.array(out), changed)
        default:
            return (value, false)
        }
    }

    private func redactString(_ value: String, depth: Int) -> (JSONValue, Bool) {
        let trimmed = dartTrimLeft(value)
        if trimmed.dartLength >= 2 && value.dartLength <= Self.maxEmbeddedJSON
            && (trimmed.hasPrefix("{") || trimmed.hasPrefix("["))
        {
            if let decoded = try? JSON.parse(value) {
                switch decoded {
                case .object, .array:
                    let (r, changed) = redact(decoded, depth: depth + 1)
                    return changed ? (.string(JSON.encode(r)), true) : (.string(value), false)
                default: break
                }
            }
        }
        let scrubbed = scrubText(value)
        return (.string(scrubbed), scrubbed != value)
    }

    // MARK: free text

    static let authScheme = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])(Bearer|Basic|Token|Digest)\s+[A-Za-z0-9\-._~+/]{6,}=*"#,
        options: [.caseInsensitive])
    static let jwt = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*"#)
    static let knownKeys = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])(?:(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{8,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{30,}|bc[is]_[A-Za-z0-9_-]{20,})"#
    )
    static let quotedPair = try! NSRegularExpression(
        pattern: #"(["'])([^"'\\]{1,100})\1(\s*[:=]\s*)(["'])((?:[^"'\\]|\\.)*)\4"#)
    static let equalsPair = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_\-.\[\]])([A-Za-z0-9_\-.\[\]]{1,100})=([^&\s"'#;,)<>]+)"#)
    static let colonPair = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_\-.])([A-Za-z0-9_\-.]{2,100})(\s*:\s*)([^,\s}{\]\[]+)"#)
    static let cardDigits = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])[2-6][0-9](?:[ -]?[0-9]){11,17}(?![A-Za-z0-9_])"#)

    /// Removes credentials from free text; returns the input unchanged when
    /// nothing matched.
    public func scrubText(_ text: String) -> String {
        if text.dartLength < 5 { return text }
        let p = Self.placeholder
        var out = text
        out = Regex.replaceAll(Self.authScheme, in: out) { g in "\(g[1]!) \(p)" }
        out = Regex.replaceAll(Self.jwt, in: out, with: p)
        out = Regex.replaceAll(Self.knownKeys, in: out, with: p)
        out = Regex.replaceAll(Self.quotedPair, in: out) { g in
            if !self.isSensitiveQueryKey(g[2]!) || g[5] == p { return g[0]! }
            return "\(g[1]!)\(g[2]!)\(g[1]!)\(g[3]!)\(g[4]!)\(p)\(g[4]!)"
        }
        out = Regex.replaceAll(Self.equalsPair, in: out) { g in
            if !self.isSensitiveQueryKey(g[1]!) || g[2] == p { return g[0]! }
            return "\(g[1]!)=\(p)"
        }
        out = Regex.replaceAll(Self.colonPair, in: out) { g in
            let value = g[3]!
            if value.hasPrefix("//") || !self.isSensitiveKey(g[1]!) || value.contains(p) { return g[0]! }
            return "\(g[1]!)\(g[2]!)\(p)"
        }
        out = Regex.replaceAll(Self.cardDigits, in: out) { g in Self.luhn(g[0]!) ? p : g[0]! }
        for pattern in patterns {
            out = Regex.replaceAll(pattern, in: out, with: p)
        }
        return out == text ? text : out
    }

    static func luhn(_ candidate: String) -> Bool {
        let digits = candidate.utf8.filter { $0 != 0x20 && $0 != 0x2D }
        if digits.count < 13 || digits.count > 19 { return false }
        var sum = 0
        var alt = false
        for c in digits.reversed() {
            var d = Int(c) - 48
            if alt {
                d *= 2
                if d > 9 { d -= 9 }
            }
            sum += d
            alt.toggle()
        }
        return sum % 10 == 0
    }

    // MARK: headers and URLs

    /// Lower-cased names; sensitive values replaced, others scrubbed.
    public func redactHeaders(_ headers: [(String, String)]) -> JSONObject {
        var out = JSONObject()
        for (name, value) in headers {
            out[name.lowercased()] = .string(isSensitiveHeader(name) ? Self.placeholder : scrubText(value))
        }
        return out
    }

    /// `redactHeaders` for a JSON object of header values (strings or lists).
    public func redactHeaders(_ headers: JSONObject) -> JSONObject {
        redactHeaders(
            headers.map { k, v -> (String, String) in
                switch v {
                case .string(let s): return (k, s)
                case .array(let a): return (k, a.map { $0.stringValue ?? JSON.encode($0) }.joined(separator: ", "))
                default: return (k, v.stringValue ?? JSON.encode(v))
                }
            })
    }

    /// Redacts user info, sensitive query parameters and sensitive
    /// `key=value` pairs in the fragment. The path is kept.
    func redactURI(_ uri: DartURI) -> DartURI {
        do {
            return try redactURIOrThrow(uri)
        } catch {
            // Malformed escapes make the query unreadable: drop it.
            return DartURI(scheme: uri.scheme, userInfo: nil, host: uri.host, port: uri.port, path: uri.path, query: nil, fragment: nil)
        }
    }

    private func redactURIOrThrow(_ uri: DartURI) throws -> DartURI {
        var result = uri
        if let info = uri.userInfo, !info.isEmpty { result.userInfo = "REDACTED" }
        if uri.query != nil {
            var changed = false
            var params: [(String, [String])] = []
            for (key, values) in try uri.queryParametersAll() {
                if isSensitiveQueryKey(key) {
                    changed = true
                    params.append((key, [Self.placeholder]))
                } else {
                    let scrubbed = values.map { scrubText($0) }
                    if scrubbed != values { changed = true }
                    params.append((key, scrubbed))
                }
            }
            if changed {
                var parts: [String] = []
                for (k, vs) in params {
                    for v in vs {
                        let ek = DartURI.encodeQueryComponent(k)
                        parts.append(v.isEmpty ? ek : ek + "=" + DartURI.encodeQueryComponent(v))
                    }
                }
                result.query = parts.joined(separator: "&")
            }
        }
        if let fragment = uri.fragment, fragment.contains("=") {
            let scrubbed = Regex.replaceAll(Self.equalsPair, in: fragment) { g in
                self.isSensitiveQueryKey(g[1]!) ? "\(g[1]!)=\(Self.placeholder)" : g[0]!
            }
            if scrubbed != fragment { result.fragment = DartURI.normalize(scrubbed, allowed: DartURI.queryChars) }
        }
        return result
    }

    /// Redacts a URL string; unchanged URLs are returned as given.
    public func redactURL(_ url: String) -> String {
        let uri = DartURI.parse(url)
        let redacted = redactURI(uri)
        return redacted == uri ? url : redacted.string
    }

    /// Tracked text: the whole value when the id looks sensitive or the
    /// field is marked sensitive (secure entry), otherwise scrubbed.
    public func redactText(fieldId: String, value: String, sensitive: Bool = false) -> String {
        sensitive || isSensitiveKey(fieldId) ? Self.placeholder : scrubText(value)
    }
}
