import Foundation

/// A JSON value that keeps integers and decimals apart (`1` is `.int`,
/// `1.0` is `.double`) and objects in insertion order, so capsules,
/// request-key hashes and re-encoded bodies match the Dart reference
/// byte for byte.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    public var isNull: Bool { if case .null = self { return true } else { return false } }
    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var intValue: Int? { if case .int(let i) = self { return i } else { return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var objectValue: JSONObject? { if case .object(let o) = self { return o } else { return nil } }

    /// Numbers of either kind as a `Double`.
    public var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    public var isNumber: Bool { doubleValue != nil }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// Converts Foundation / app values (`[String: Any]`, `NSNumber`, ...).
    /// Dictionary keys are sorted (Swift dictionaries have no order).
    public init(any value: Any?) {
        guard let value else { self = .null; return }
        switch value {
        case let v as JSONValue: self = v
        case is NSNull: self = .null
        case let s as String: self = .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else if CFNumberIsFloatType(n) {
                self = .double(n.doubleValue)
            } else {
                self = .int(n.intValue)
            }
        case let b as Bool: self = .bool(b)
        case let i as Int: self = .int(i)
        case let d as Double: self = .double(d)
        case let date as Date: self = .int(Int((date.timeIntervalSince1970 * 1000).rounded()))
        case let data as Data: self = .string(data.base64EncodedString())
        case let o as JSONObject: self = .object(o)
        case let d as [String: Any]:
            var o = JSONObject()
            for k in d.keys.sorted(by: utf16Less) { o[k] = JSONValue(any: d[k]) }
            self = .object(o)
        case let a as [Any]: self = .array(a.map { JSONValue(any: $0) })
        case let a as [Any?]: self = .array(a.map { JSONValue(any: $0) })
        default: self = .string(String(describing: value))
        }
    }

    /// Foundation representation (`[String: Any]`, `[Any]`, `NSNull`, ...).
    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { $0.anyValue }
        case .object(let o):
            var d: [String: Any] = [:]
            for (k, v) in o { d[k] = v.anyValue }
            return d
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var o = JSONObject()
        for (k, v) in elements { o[k] = v }
        self = .object(o)
    }
    public init(nilLiteral: ()) { self = .null }
}

/// A JSON object that remembers key insertion order (like Dart maps).
/// Equality ignores order.
public struct JSONObject: Sendable, Equatable, Sequence, ExpressibleByDictionaryLiteral {
    public private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    public init() {}
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        for (k, v) in elements { self[k] = v }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    /// Setting `nil` removes the key; setting `.null` stores a JSON null.
    public subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public func contains(_ key: String) -> Bool { storage[key] != nil }

    public func makeIterator() -> AnyIterator<(key: String, value: JSONValue)> {
        var i = 0
        let keys = self.keys
        let storage = self.storage
        return AnyIterator {
            guard i < keys.count else { return nil }
            defer { i += 1 }
            return (keys[i], storage[keys[i]]!)
        }
    }

    public static func == (a: JSONObject, b: JSONObject) -> Bool { a.storage == b.storage }
}

/// UTF-16 code unit order, as Dart's `String.compareTo`.
@inline(__always)
func utf16Less(_ a: String, _ b: String) -> Bool {
    a.utf16.lexicographicallyPrecedes(b.utf16)
}

extension String {
    /// Length in UTF-16 code units (Dart's `String.length`).
    var dartLength: Int { utf16.count }

    /// The first [max] UTF-16 code units (Dart's `substring(0, max)`),
    /// without splitting a surrogate pair.
    func dartPrefix(_ max: Int) -> String {
        if utf16.count <= max { return self }
        var end = utf16.index(utf16.startIndex, offsetBy: max)
        while end > utf16.startIndex, String.Index(end, within: self) == nil {
            end = utf16.index(before: end)
        }
        return String(self[..<end])
    }
}

// MARK: - Parsing

public struct JSONParseError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public let offset: Int
    public var description: String { "\(message) at offset \(offset)" }
}

public enum JSON {
    /// Nesting beyond this is rejected while parsing (bounded stack use).
    public static let maxParseDepth = 512

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Array(text.utf8))
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try parse([UInt8](data))
    }

    public static func parse(_ bytes: [UInt8]) throws -> JSONValue {
        var p = Parser(bytes: bytes)
        p.skipWhitespace()
        let v = try p.parseValue(depth: 0)
        p.skipWhitespace()
        if p.i != bytes.count { throw p.error("unexpected trailing characters") }
        return v
    }

    /// `jsonEncode` of the Dart SDK: no whitespace, same escapes and number
    /// formatting.
    public static func encode(_ value: JSONValue) -> String {
        var out = ""
        out.reserveCapacity(256)
        write(value, into: &out)
        return out
    }

    public static func encodeData(_ value: JSONValue) -> Data { Data(encode(value).utf8) }

    static func write(_ value: JSONValue, into out: inout String) {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d): out += formatDouble(d)
        case .string(let s): writeString(s, into: &out)
        case .array(let a):
            out += "["
            var first = true
            for v in a {
                if !first { out += "," }
                first = false
                write(v, into: &out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            var first = true
            for (k, v) in o {
                if !first { out += "," }
                first = false
                writeString(k, into: &out)
                out += ":"
                write(v, into: &out)
            }
            out += "}"
        }
    }

    static func writeString(_ s: String, into out: inout String) {
        out += "\""
        var needsEscape = false
        for u in s.utf16 where u < 0x20 || u == 0x22 || u == 0x5C {
            needsEscape = true
            break
        }
        if !needsEscape {
            out += s
        } else {
            for scalar in s.unicodeScalars {
                switch scalar.value {
                case 0x22: out += "\\\""
                case 0x5C: out += "\\\\"
                case 0x08: out += "\\b"
                case 0x09: out += "\\t"
                case 0x0A: out += "\\n"
                case 0x0C: out += "\\f"
                case 0x0D: out += "\\r"
                case let v where v < 0x20:
                    let hex = Array("0123456789abcdef")
                    out += "\\u00"
                    out.append(hex[Int(v >> 4)])
                    out.append(hex[Int(v & 0xF)])
                default: out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    /// Dart's `double.toString()` (ECMAScript shortest form, `.0` appended
    /// to integral values). Non-finite values encode as `null`.
    public static func formatDouble(_ d: Double) -> String {
        guard d.isFinite else { return "null" }
        if d == 0 { return d.sign == .minus ? "-0.0" : "0.0" }
        // Swift's description is the shortest round-trip representation;
        // only the layout differs from ECMAScript.
        var desc = "\(abs(d))"
        var exp10 = 0
        if let e = desc.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exp10 = Int(desc[desc.index(after: e)...]) ?? 0
            desc = String(desc[..<e])
        }
        var intPart = desc
        var fracPart = ""
        if let dot = desc.firstIndex(of: ".") {
            intPart = String(desc[..<dot])
            fracPart = String(desc[desc.index(after: dot)...])
        }
        var digits = intPart + fracPart
        var pointPos = intPart.count + exp10 // decimal point after `pointPos` digits
        // Strip leading zeros.
        while digits.count > 1 && digits.hasPrefix("0") {
            digits.removeFirst()
            pointPos -= 1
        }
        // Strip trailing zeros.
        while digits.count > 1 && digits.hasSuffix("0") { digits.removeLast() }
        let k = digits.count
        let n = pointPos
        var s: String
        if k <= n && n <= 21 {
            s = digits + String(repeating: "0", count: n - k) + ".0"
        } else if 0 < n && n <= 21 {
            let idx = digits.index(digits.startIndex, offsetBy: n)
            s = String(digits[..<idx]) + "." + String(digits[idx...])
        } else if -6 < n && n <= 0 {
            s = "0." + String(repeating: "0", count: -n) + digits
        } else {
            let e = n - 1
            let sign = e < 0 ? "-" : "+"
            if k == 1 {
                s = digits + "e" + sign + String(abs(e))
            } else {
                s = String(digits.first!) + "." + digits.dropFirst() + "e" + sign + String(abs(e))
            }
        }
        return d < 0 ? "-" + s : s
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        func error(_ m: String) -> JSONParseError { JSONParseError(message: m, offset: i) }

        mutating func skipWhitespace() {
            while i < bytes.count {
                let c = bytes[i]
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1 } else { break }
            }
        }

        mutating func parseValue(depth: Int) throws -> JSONValue {
            guard i < bytes.count else { throw error("unexpected end of input") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth + 1)
            case UInt8(ascii: "["): return try parseArray(depth: depth + 1)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try parseNumber()
            }
        }

        mutating func literal(_ word: String) throws {
            let w = Array(word.utf8)
            guard i + w.count <= bytes.count, Array(bytes[i..<i + w.count]) == w else {
                throw error("unexpected character")
            }
            i += w.count
        }

        mutating func parseObject(depth: Int) throws -> JSONValue {
            if depth > JSON.maxParseDepth { throw error("nesting too deep") }
            i += 1
            var o = JSONObject()
            skipWhitespace()
            if i < bytes.count && bytes[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
            while true {
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw error("expected a string key") }
                let key = try parseString()
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw error("expected ':'") }
                i += 1
                skipWhitespace()
                o[key] = try parseValue(depth: depth)
                skipWhitespace()
                guard i < bytes.count else { throw error("unexpected end of input") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
                throw error("expected ',' or '}'")
            }
        }

        mutating func parseArray(depth: Int) throws -> JSONValue {
            if depth > JSON.maxParseDepth { throw error("nesting too deep") }
            i += 1
            var a: [JSONValue] = []
            skipWhitespace()
            if i < bytes.count && bytes[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
            while true {
                skipWhitespace()
                a.append(try parseValue(depth: depth))
                skipWhitespace()
                guard i < bytes.count else { throw error("unexpected end of input") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                throw error("expected ',' or ']'")
            }
        }

        mutating func parseString() throws -> String {
            i += 1
            let start = i
            // Fast path: no escapes.
            while i < bytes.count {
                let c = bytes[i]
                if c == UInt8(ascii: "\"") {
                    guard let s = String(bytes: bytes[start..<i], encoding: .utf8) else {
                        throw error("invalid UTF-8 in string")
                    }
                    i += 1
                    return s
                }
                if c == UInt8(ascii: "\\") { break }
                if c < 0x20 { throw error("control character in string") }
                i += 1
            }
            var buf = [UInt8](bytes[start..<i])
            while i < bytes.count {
                let c = bytes[i]
                if c == UInt8(ascii: "\"") {
                    i += 1
                    guard let s = String(bytes: buf, encoding: .utf8) else { throw error("invalid UTF-8 in string") }
                    return s
                }
                if c < 0x20 { throw error("control character in string") }
                if c != UInt8(ascii: "\\") { buf.append(c); i += 1; continue }
                i += 1
                guard i < bytes.count else { break }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): buf.append(0x22)
                case UInt8(ascii: "\\"): buf.append(0x5C)
                case UInt8(ascii: "/"): buf.append(0x2F)
                case UInt8(ascii: "b"): buf.append(0x08)
                case UInt8(ascii: "f"): buf.append(0x0C)
                case UInt8(ascii: "n"): buf.append(0x0A)
                case UInt8(ascii: "r"): buf.append(0x0D)
                case UInt8(ascii: "t"): buf.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code), i + 1 < bytes.count,
                        bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u")
                    {
                        let save = i
                        i += 2
                        let low = try hex4()
                        if (0xDC00...0xDFFF).contains(low) {
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            i = save
                        }
                    }
                    let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                    buf.append(contentsOf: Array(String(scalar).utf8))
                default: throw error("invalid escape")
                }
            }
            throw error("unterminated string")
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count else { throw error("invalid \\u escape") }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let c = bytes[i]
                let d: UInt32
                switch c {
                case 0x30...0x39: d = UInt32(c - 0x30)
                case 0x41...0x46: d = UInt32(c - 0x41 + 10)
                case 0x61...0x66: d = UInt32(c - 0x61 + 10)
                default: throw error("invalid \\u escape")
                }
                v = v * 16 + d
                i += 1
            }
            return v
        }

        mutating func parseNumber() throws -> JSONValue {
            let start = i
            if i < bytes.count && bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard i < bytes.count, (0x30...0x39).contains(bytes[i]) else { throw error("unexpected character") }
            if bytes[i] == 0x30 {
                i += 1
            } else {
                while i < bytes.count && (0x30...0x39).contains(bytes[i]) { i += 1 }
            }
            var isDouble = false
            if i < bytes.count && bytes[i] == UInt8(ascii: ".") {
                isDouble = true
                i += 1
                guard i < bytes.count, (0x30...0x39).contains(bytes[i]) else { throw error("invalid number") }
                while i < bytes.count && (0x30...0x39).contains(bytes[i]) { i += 1 }
            }
            if i < bytes.count && (bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E")) {
                isDouble = true
                i += 1
                if i < bytes.count && (bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-")) { i += 1 }
                guard i < bytes.count, (0x30...0x39).contains(bytes[i]) else { throw error("invalid number") }
                while i < bytes.count && (0x30...0x39).contains(bytes[i]) { i += 1 }
            }
            let text = String(decoding: bytes[start..<i], as: UTF8.self)
            if !isDouble, let v = Int(text) { return .int(v) }
            guard let d = Double(text) else { throw error("invalid number") }
            return .double(d)
        }
    }
}
