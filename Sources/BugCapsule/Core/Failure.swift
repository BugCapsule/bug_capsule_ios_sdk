import Foundation

public enum FailureKind: String, Sendable {
    case exception, assertion, manual
}

/// A machine-checkable failure: what replay and verify compare against.
public struct FailureRecord: Sendable, Equatable {
    public var kind: FailureKind
    public var signature: String
    public var type: String
    public var message: String
    public var stack: String?
    public var assertionId: String?
    public var t: Int

    public init(
        kind: FailureKind, signature: String, type: String, message: String, stack: String? = nil,
        assertionId: String? = nil, t: Int
    ) {
        self.kind = kind
        self.signature = signature
        self.type = type
        self.message = message
        self.stack = stack
        self.assertionId = assertionId
        self.t = t
    }

    /// From a type name and message (runtimes-v1 §5: `String(describing:
    /// type(of: error))` / `String(describing: error)`, or the NSException
    /// name / reason). [scrub] removes credentials before anything is derived,
    /// so capture and replay compute the same signature.
    public static func exception(
        type: String, message rawMessage: String, stack: String?, t: Int, scrub: (String) -> String = { $0 }
    ) -> FailureRecord {
        let message = scrub(rawMessage)
        return FailureRecord(
            kind: .exception,
            signature: FailureSignature.compute(.exception, type, message),
            type: type,
            message: truncate(message, 2000),
            stack: stack.map { scrub(truncate($0, 8000)) },
            t: t)
    }

    /// `BugCapsule.fail(id, message)`: the id, not the message, identifies it.
    public static func assertion(_ assertionId: String, message: String, t: Int, scrub: (String) -> String = { $0 })
        -> FailureRecord
    {
        FailureRecord(
            kind: .assertion,
            signature: FailureSignature.compute(.assertion, assertionId, ""),
            type: assertionId,
            message: truncate(scrub(message), 2000),
            assertionId: assertionId,
            t: t)
    }

    init(json: JSONObject) {
        kind = FailureKind(rawValue: json["kind"]?.stringValue ?? "") ?? .exception
        signature = json["signature"]?.stringValue ?? ""
        type = json["type"]?.stringValue ?? ""
        message = json["message"]?.stringValue ?? ""
        stack = json["stack"]?.stringValue
        assertionId = json["assertionId"]?.stringValue
        t = json["t"]?.intValue ?? 0
    }

    public func shifted(_ offset: Int) -> FailureRecord {
        var f = self
        f.t = t - offset
        return f
    }

    public var json: JSONValue {
        [
            "kind": .string(kind.rawValue),
            "signature": .string(signature),
            "type": .string(type),
            "message": .string(message),
            "stack": stack.map { .string($0) } ?? .null,
            "assertionId": assertionId.map { .string($0) } ?? .null,
            "t": .int(t),
        ]
    }

    static func truncate(_ s: String, _ max: Int) -> String {
        s.dartLength <= max ? s : s.dartPrefix(max) + "…"
    }
}

public enum FailureSignature {
    private static let hex = try! NSRegularExpression(
        pattern: "(?<![A-Za-z0-9_])(0x)?[0-9a-fA-F]{8,}(?![A-Za-z0-9_])")
    private static let digits = try! NSRegularExpression(pattern: "[0-9]+")
    private static let space = try! NSRegularExpression(pattern: "\\s+")

    /// `<kind>:<type>:<normalized first line of the message>` (capsule v1).
    public static func compute(_ kind: FailureKind, _ type: String, _ message: String) -> String {
        let firstLine = message.components(separatedBy: "\n").first ?? ""
        var normalized = Regex.replaceAll(hex, in: firstLine, with: "#")
        normalized = Regex.replaceAll(digits, in: normalized, with: "#")
        normalized = Regex.replaceAll(space, in: normalized, with: " ")
        normalized = dartTrim(normalized)
        if normalized.dartLength > 200 { normalized = normalized.dartPrefix(200) }
        return "\(kind.rawValue):\(type):\(normalized)"
    }
}

/// Dart's `String.trim()` whitespace set.
func isDartWhitespace(_ u: UInt16) -> Bool {
    switch u {
    case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
        return true
    default:
        return false
    }
}

func dartTrim(_ s: String) -> String {
    let u = Array(s.utf16)
    var a = 0
    var b = u.count
    while a < b && isDartWhitespace(u[a]) { a += 1 }
    while b > a && isDartWhitespace(u[b - 1]) { b -= 1 }
    if a == 0 && b == u.count { return s }
    return String(utf16CodeUnits: Array(u[a..<b]), count: b - a)
}

func dartTrimLeft(_ s: String) -> String {
    let u = Array(s.utf16)
    var a = 0
    while a < u.count && isDartWhitespace(u[a]) { a += 1 }
    if a == 0 { return s }
    return String(utf16CodeUnits: Array(u[a...]), count: u.count - a)
}

/// NSRegularExpression helpers working on UTF-16 offsets (like Dart).
enum Regex {
    static func replaceAll(_ re: NSRegularExpression, in s: String, with replacement: String) -> String {
        replaceAll(re, in: s) { _ in replacement }
    }

    /// Replaces every non-overlapping match, left to right, with
    /// `transform(groups)`; `groups[0]` is the whole match, missing groups
    /// are `nil`.
    static func replaceAll(_ re: NSRegularExpression, in s: String, transform: ([String?]) -> String) -> String {
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return s }
        var out = ""
        var last = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var groups: [String?] = []
            for g in 0..<m.numberOfRanges {
                let r = m.range(at: g)
                groups.append(r.location == NSNotFound ? nil : ns.substring(with: r))
            }
            out += transform(groups)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}
