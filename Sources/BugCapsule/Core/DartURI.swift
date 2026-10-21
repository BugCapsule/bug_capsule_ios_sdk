import Foundation

/// The parts of Dart's `Uri` the request-key and URL-redaction rules
/// depend on: RFC 3986 splitting, host lower-casing, dot-segment removal,
/// percent-escape normalization, `queryParametersAll` decoding (`+` is a
/// space) and `encodeQueryComponent` when a query is rebuilt.
struct DartURI: Equatable {
    var scheme: String?
    var userInfo: String?
    var host: String?
    var port: String?
    var path: String
    var query: String?
    var fragment: String?

    var hasAuthority: Bool { host != nil }

    struct DecodeError: Error {}

    static func parse(_ input: String) -> DartURI {
        let s = input
        var rest = Substring(s)
        var scheme: String?
        // scheme: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) ":"
        if let colon = rest.firstIndex(of: ":") {
            let candidate = rest[..<colon]
            if let first = candidate.first, first.isASCII, first.isLetter,
                candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") })
            {
                scheme = candidate.lowercased()
                rest = rest[rest.index(after: colon)...]
            }
        }
        var fragment: String?
        if let hash = rest.firstIndex(of: "#") {
            fragment = String(rest[rest.index(after: hash)...])
            rest = rest[..<hash]
        }
        var query: String?
        if let q = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: q)...])
            rest = rest[..<q]
        }
        var userInfo: String?
        var host: String?
        var port: String?
        var path = rest
        if rest.hasPrefix("//") {
            let afterSlashes = rest.index(rest.startIndex, offsetBy: 2)
            let authorityEnd = rest[afterSlashes...].firstIndex(of: "/") ?? rest.endIndex
            var authority = rest[afterSlashes..<authorityEnd]
            path = rest[authorityEnd...]
            if let at = authority.lastIndex(of: "@") {
                userInfo = String(authority[..<at])
                authority = authority[authority.index(after: at)...]
            }
            var hostPart = authority
            if authority.hasPrefix("[") {
                if let close = authority.firstIndex(of: "]") {
                    hostPart = authority[authority.index(after: authority.startIndex)..<close]
                    let after = authority[authority.index(after: close)...]
                    if after.hasPrefix(":") { port = String(after.dropFirst()) }
                }
            } else if let colon = authority.lastIndex(of: ":") {
                hostPart = authority[..<colon]
                port = String(authority[authority.index(after: colon)...])
            }
            host = hostPart.lowercased()
            if port?.isEmpty == true { port = nil }
            if let p = port, (scheme == "http" && p == "80") || (scheme == "https" && p == "443") { port = nil }
        }
        var normalizedPath = normalize(String(path), allowed: pathChars)
        if scheme != nil || host != nil { normalizedPath = removeDotSegments(normalizedPath) }
        return DartURI(
            scheme: scheme, userInfo: userInfo, host: host, port: port, path: normalizedPath,
            query: query.map { normalize($0, allowed: queryChars) },
            fragment: fragment.map { normalize($0, allowed: queryChars) })
    }

    /// Dart's `queryParametersAll`: names in first-seen order, values in order.
    func queryParametersAll() throws -> [(name: String, values: [String])] {
        guard let query else { return [] }
        var order: [String] = []
        var values: [String: [String]] = [:]
        for part in query.split(separator: "&", omittingEmptySubsequences: true) {
            let key: String
            let value: String
            if let eq = part.firstIndex(of: "=") {
                key = try Self.decodeComponent(part[..<eq])
                value = try Self.decodeComponent(part[part.index(after: eq)...])
            } else {
                key = try Self.decodeComponent(part)
                value = ""
            }
            if values[key] == nil { order.append(key) }
            values[key, default: []].append(value)
        }
        return order.map { ($0, values[$0]!) }
    }

    var string: String {
        var out = ""
        if let scheme { out += scheme + ":" }
        if let host {
            out += "//"
            if let userInfo { out += userInfo + "@" }
            out += host.contains(":") ? "[\(host)]" : host
            if let port { out += ":" + port }
        }
        out += path
        if let query { out += "?" + query }
        if let fragment { out += "#" + fragment }
        return out
    }

    /// `Uri.encodeQueryComponent`: unreserved characters kept, space as `+`,
    /// everything else percent-encoded (UTF-8, upper-case hex).
    static func encodeQueryComponent(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            if unreserved.contains(b) {
                out.unicodeScalars.append(Unicode.Scalar(b))
            } else if b == 0x20 {
                out += "+"
            } else {
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    static func decodeComponent<S: StringProtocol>(_ s: S) throws -> String {
        var bytes: [UInt8] = []
        let u = Array(s.utf8)
        var i = 0
        var simple = true
        while i < u.count {
            let c = u[i]
            if c == 0x25 {  // %
                guard i + 2 < u.count, let h = hexValue(u[i + 1]), let l = hexValue(u[i + 2]) else {
                    throw DecodeError()
                }
                bytes.append(h << 4 | l)
                i += 3
                simple = false
            } else if c == 0x2B {  // +
                bytes.append(0x20)
                i += 1
                simple = false
            } else {
                bytes.append(c)
                i += 1
            }
        }
        if simple { return String(s) }
        guard let decoded = String(bytes: bytes, encoding: .utf8) else { throw DecodeError() }
        return decoded
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x41 + 10
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
    }

    static let unreserved: Set<UInt8> = {
        var s = Set<UInt8>()
        for c in UInt8(ascii: "a")...UInt8(ascii: "z") { s.insert(c) }
        for c in UInt8(ascii: "A")...UInt8(ascii: "Z") { s.insert(c) }
        for c in UInt8(ascii: "0")...UInt8(ascii: "9") { s.insert(c) }
        for c in "-._~".utf8 { s.insert(c) }
        return s
    }()

    static let pathChars: Set<UInt8> = unreserved.union("!$&'()*+,;=:@/".utf8)
    static let queryChars: Set<UInt8> = unreserved.union("!$&'()*+,;=:@/?".utf8)

    /// Keeps allowed characters, normalizes existing escapes (decodes those
    /// of unreserved characters, upper-cases the rest) and percent-encodes
    /// everything else.
    static func normalize(_ s: String, allowed: Set<UInt8>) -> String {
        let u = Array(s.utf8)
        var needsWork = false
        for b in u where !allowed.contains(b) {
            needsWork = true
            break
        }
        if !needsWork { return s }
        var out = ""
        var i = 0
        while i < u.count {
            let b = u[i]
            if b == 0x25, i + 2 < u.count, let h = hexValue(u[i + 1]), let l = hexValue(u[i + 2]) {
                let v = h << 4 | l
                if unreserved.contains(v) {
                    out.unicodeScalars.append(Unicode.Scalar(v))
                } else {
                    out += String(format: "%%%02X", v)
                }
                i += 3
            } else if allowed.contains(b) {
                out.unicodeScalars.append(Unicode.Scalar(b))
                i += 1
            } else {
                out += String(format: "%%%02X", b)
                i += 1
            }
        }
        return out
    }

    /// RFC 3986 §5.2.4.
    static func removeDotSegments(_ path: String) -> String {
        if !path.contains(".") { return path }
        let absolute = path.hasPrefix("/")
        var output: [Substring] = []
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        var appendSlash = false
        for (i, seg) in segments.enumerated() {
            if i == 0 && absolute { continue }
            appendSlash = false
            if seg == ".." {
                if !output.isEmpty { output.removeLast() }
                appendSlash = true
            } else if seg == "." {
                appendSlash = true
            } else {
                output.append(seg)
            }
        }
        var result = output.joined(separator: "/")
        if appendSlash { result += "/" }
        return absolute ? "/" + result : result
    }
}
