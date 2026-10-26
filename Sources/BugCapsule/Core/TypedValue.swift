import Foundation

/// A map whose keys are not all strings (or one of them is `$t`), in
/// insertion order: what a `{"$t": "map"}` typed value decodes to, so it
/// re-encodes with the same entry order. Swift dictionaries have no order;
/// pass a `TypedMap` when the order matters to the dependency.
public struct TypedMap: @unchecked Sendable {
    public var entries: [(key: Any?, value: Any?)]

    public init(_ entries: [(key: Any?, value: Any?)] = []) { self.entries = entries }

    /// The value of the first entry whose key encodes like [key].
    public subscript(key: Any?) -> Any? {
        let wanted = RequestKeyBuilder.canonicalJSON(TypedValue.encode(key))
        return entries.first { RequestKeyBuilder.canonicalJSON(TypedValue.encode($0.key)) == wanted }?.value ?? nil
    }
}

/// Lossless JSON for the values WebSockets and native SDKs exchange
/// (capsule-v2 §3.1, port of `typed_value.dart`; conformance:
/// `interactions.json` `typedValues`): integers vs doubles, byte and
/// numeric arrays, and maps with non-string keys survive a round trip, so
/// replay hands the app the same value it saw when capturing.
///
/// Swift mapping:
///
/// | Swift value | Encoding |
/// |---|---|
/// | `nil`, `NSNull`, `Bool`, `String` | as JSON |
/// | integer types, \|n\| ≤ 2^53 − 1 | JSON integer |
/// | other integers (`Int64`, `UInt64`) | `{"$t": "int", "v": "<decimal>"}` |
/// | `Double`/`Float` with a fraction | JSON number |
/// | `Double` without a fraction, NaN, ±infinity, -0.0 | `{"$t": "double", "v": "80.0"}` |
/// | `Data`, `[UInt8]` | `{"$t": "bytes", "b64": …}` |
/// | `[Int32]`, `[Int64]`, `[Float]`, `[Double]` | `{"$t": "i32" / "i64" / "f32" / "f64", "v": […]}` |
/// | arrays | JSON arrays |
/// | `[String: Any]` (no `$t` key) | JSON object (keys sorted: Swift dictionaries have no order) |
/// | `TypedMap`, `[AnyHashable: Any]` with other keys | `{"$t": "map", "e": [[k, v], …]}` |
/// | anything else | `{"$t": "unsupported", "type": "<type>"}` (not replayable) |
///
/// `decode` returns `Data`, `[Int32]`, `[Int64]`, `[Float]`, `[Double]`,
/// `Int`, `Double`, `String`, `Bool`, `[Any?]`, `[String: Any?]`,
/// `TypedMap`, or nil.
public enum TypedValue {
    public static let tag = "$t"
    static let maxSafeInt = 9_007_199_254_740_991

    // MARK: encode

    /// Encodes [value] as typed-value JSON. Values this encoder cannot
    /// represent become an `unsupported` tag; `isReplayable` reports them.
    public static func encode(_ value: Any?) -> JSONValue {
        guard let value = unwrap(value) else { return .null }
        switch value {
        case let v as JSONValue: return encodeJSON(v)
        case is NSNull: return .null
        default: break
        }
        let t = type(of: value)
        // Exact native types first (NSNumber bridging would blur them).
        if t == Bool.self { return .bool(value as! Bool) }
        if t == String.self { return .string(value as! String) }
        if t == Substring.self { return .string(String(value as! Substring)) }
        if t == Int.self { return int(Int64(value as! Int)) }
        if t == Int8.self { return int(Int64(value as! Int8)) }
        if t == Int16.self { return int(Int64(value as! Int16)) }
        if t == Int32.self { return int(Int64(value as! Int32)) }
        if t == Int64.self { return int(value as! Int64) }
        if t == UInt.self { return uint(UInt64(value as! UInt)) }
        if t == UInt8.self { return int(Int64(value as! UInt8)) }
        if t == UInt16.self { return int(Int64(value as! UInt16)) }
        if t == UInt32.self { return int(Int64(value as! UInt32)) }
        if t == UInt64.self { return uint(value as! UInt64) }
        if t == Double.self { return double(value as! Double) }
        if t == Float.self { return double(Double(value as! Float)) }
        if t == [UInt8].self { return bytes(Data(value as! [UInt8])) }
        if t == [Int32].self { return .object([tag: "i32", "v": .array((value as! [Int32]).map { .int(Int($0)) })]) }
        if t == [Int64].self { return .object([tag: "i64", "v": .array((value as! [Int64]).map { .string(String($0)) })]) }
        if t == [Float].self { return .object([tag: "f32", "v": .array((value as! [Float]).map { floatItem(Double($0)) })]) }
        if t == [Double].self { return .object([tag: "f64", "v": .array((value as! [Double]).map(floatItem))]) }
        switch value {
        case let v as TypedMap: return encodeMap(v.entries)
        case let d as Data: return bytes(d)
        case let s as String: return .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            if CFNumberIsFloatType(n) { return double(n.doubleValue) }
            if n.int64Value < 0 { return int(n.int64Value) }
            return uint(n.uint64Value)
        case let d as [String: Any?]:
            if d.keys.contains(tag) { return encodeMap(d.map { (key: $0.key, value: $0.value) }, sorted: true) }
            var o = JSONObject()
            for k in d.keys.sorted(by: utf16Less) { o[k] = encode(d[k]!) }
            return .object(o)
        case let d as [AnyHashable: Any?]:
            if d.keys.allSatisfy({ ($0.base as? String).map { $0 != tag } ?? false }) {
                var o = JSONObject()
                for k in d.keys.map({ $0.base as! String }).sorted(by: utf16Less) { o[k] = encode(d[AnyHashable(k)]!) }
                return .object(o)
            }
            return encodeMap(d.map { (key: $0.key.base, value: $0.value) }, sorted: true)
        case let a as [Any?]: return .array(a.map(encode))
        case let a as NSArray: return .array(a.map(encode))
        case let d as NSDictionary:
            var entries: [(key: Any?, value: Any?)] = []
            for (k, v) in d { entries.append((key: k, value: v)) }
            if entries.allSatisfy({ ($0.key as? String).map { $0 != tag } ?? false }) {
                var o = JSONObject()
                for (k, v) in entries.sorted(by: { utf16Less($0.key as! String, $1.key as! String) }) {
                    o[k as! String] = encode(v)
                }
                return .object(o)
            }
            return encodeMap(entries, sorted: true)
        default:
            return .object([tag: "unsupported", "type": .string(String(describing: t))])
        }
    }

    /// Optional payloads arrive boxed in `Any`; nil (at any depth) is null.
    static func unwrap(_ value: Any?) -> Any? {
        guard let value else { return nil }
        let m = Mirror(reflecting: value)
        if m.displayStyle == .optional {
            guard let child = m.children.first else { return nil }
            return unwrap(child.value)
        }
        return value
    }

    static func int(_ v: Int64) -> JSONValue {
        v.magnitude <= UInt64(maxSafeInt) ? .int(Int(v)) : .object([tag: "int", "v": .string(String(v))])
    }

    static func uint(_ v: UInt64) -> JSONValue {
        v <= UInt64(maxSafeInt) ? .int(Int(v)) : .object([tag: "int", "v": .string(String(v))])
    }

    static func double(_ v: Double) -> JSONValue {
        let plain = v.isFinite && v != v.rounded(.towardZero) && !(v == 0 && v.sign == .minus)
        return plain ? .double(v) : .object([tag: "double", "v": .string(dartString(v))])
    }

    static func bytes(_ d: Data) -> JSONValue { .object([tag: "bytes", "b64": .string(d.base64EncodedString())]) }

    static func floatItem(_ v: Double) -> JSONValue {
        v.isFinite && !(v == 0 && v.sign == .minus) ? .double(v) : .string(dartString(v))
    }

    /// Dart's `double.toString()`.
    static func dartString(_ v: Double) -> String {
        if v.isNaN { return "NaN" }
        if v.isInfinite { return v < 0 ? "-Infinity" : "Infinity" }
        return JSON.formatDouble(v)
    }

    static func encodeMap(_ entries: [(key: Any?, value: Any?)], sorted: Bool = false) -> JSONValue {
        var encoded = entries.map { (encode($0.key), encode($0.value)) }
        let plain = encoded.allSatisfy { k, _ in
            if case .string(let s) = k { return s != tag }
            return false
        }
        if plain, entries.allSatisfy({ unwrap($0.key) is String }) {
            var o = JSONObject()
            for (k, v) in encoded { o[k.stringValue!] = v }
            return .object(o)
        }
        // Unordered sources (dictionaries) get a stable entry order, so
        // capture and replay processes hash the same key.
        if sorted {
            encoded.sort { utf16Less(RequestKeyBuilder.canonicalJSON($0.0), RequestKeyBuilder.canonicalJSON($1.0)) }
        }
        return .object([tag: "map", "e": .array(encoded.map { .array([$0.0, $0.1]) })])
    }

    /// Plain JSON handed to the encoder: objects keep their order; doubles
    /// follow the double rule; a `$t` key makes the object a tagged map.
    static func encodeJSON(_ v: JSONValue) -> JSONValue {
        switch v {
        case .double(let d): return double(d)
        case .int(let i): return int(Int64(i))
        case .array(let a): return .array(a.map(encodeJSON))
        case .object(let o):
            if o.contains(tag) {
                return .object([tag: "map", "e": .array(o.map { .array([.string($0.key), encodeJSON($0.value)]) })])
            }
            var out = JSONObject()
            for (k, x) in o { out[k] = encodeJSON(x) }
            return .object(out)
        default: return v
        }
    }

    // MARK: decode

    /// Decodes typed-value JSON back into Swift values (the inverse of
    /// `encode`). An `unsupported` tag decodes to nil.
    public static func decode(_ json: JSONValue) -> Any? {
        switch json {
        case .null: return nil
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map(decode)
        case .object(let o):
            guard let t = tagOf(o) else {
                var out: [String: Any?] = [:]
                for (k, v) in o { out[k] = .some(decode(v)) }
                return out
            }
            let v = o["v"]
            switch t.stringValue {
            case "int":
                guard let s = v?.stringValue else { return nil }
                if let i = Int(s) { return i }
                if let u = UInt64(s) { return u }
                return Double(s)
            case "double":
                return v?.stringValue.flatMap(parseDouble)
            case "bytes":
                return Data(base64Encoded: o["b64"]?.stringValue ?? "") ?? Data()
            case "i32":
                return (v?.arrayValue ?? []).map { Int32(truncatingIfNeeded: intItem($0)) }
            case "i64":
                return (v?.arrayValue ?? []).map { intItem($0) }
            case "f32":
                return (v?.arrayValue ?? []).map { Float(floatValue($0)) }
            case "f64":
                return (v?.arrayValue ?? []).map(floatValue)
            case "map":
                return TypedMap(
                    (o["e"]?.arrayValue ?? []).map { e in
                        let pair = e.arrayValue ?? []
                        return (key: pair.first.flatMap(decode), value: pair.count > 1 ? decode(pair[1]) : nil)
                    })
            default:
                return nil
            }
        }
    }

    /// The `$t` value; nil when absent or null (a plain object).
    static func tagOf(_ o: JSONObject) -> JSONValue? {
        guard let t = o[tag], !t.isNull else { return nil }
        return t
    }

    static func parseDouble(_ s: String) -> Double? {
        switch s {
        case "NaN": return .nan
        case "Infinity": return .infinity
        case "-Infinity": return -.infinity
        default: return Double(s)
        }
    }

    static func intItem(_ v: JSONValue) -> Int64 {
        switch v {
        case .int(let i): return Int64(i)
        case .string(let s): return Int64(s) ?? 0
        case .double(let d): return Int64(d)
        default: return 0
        }
    }

    static func floatValue(_ v: JSONValue) -> Double {
        switch v {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .string(let s): return parseDouble(s) ?? .nan
        default: return .nan
        }
    }

    // MARK: inspection

    /// Whether [json] holds no `unsupported` tag.
    public static func isReplayable(_ json: JSONValue) -> Bool {
        switch json {
        case .array(let a): return a.allSatisfy(isReplayable)
        case .object(let o):
            guard let t = tagOf(o) else { return o.allSatisfy { isReplayable($0.value) } }
            if t == "unsupported" { return false }
            if t == "map" {
                return (o["e"]?.arrayValue ?? []).allSatisfy { e in (e.arrayValue ?? []).allSatisfy(isReplayable) }
            }
            return true
        default: return true
        }
    }

    /// Redacts typed-value JSON like `Redactor.redactJSON` does plain JSON:
    /// values under sensitive keys (string keys of plain or tagged maps) are
    /// replaced, strings are scrubbed. Byte and numeric arrays are left
    /// alone (binary content is the app's to describe). Returns the value
    /// and whether anything changed.
    public static func redact(_ json: JSONValue, _ redactor: Redactor) -> (JSONValue, Bool) {
        switch json {
        case .string:
            let out = redactor.redactJSON(json)
            return (out, out != json)
        case .array(let a):
            var changed = false
            var out: [JSONValue] = []
            out.reserveCapacity(a.count)
            for v in a {
                let (r, c) = redact(v, redactor)
                out.append(r)
                changed = changed || c
            }
            return (.array(out), changed)
        case .object(let o):
            guard let t = tagOf(o) else {
                var changed = false
                var out = JSONObject()
                for (k, v) in o {
                    if !v.isNull && redactor.isSensitiveKey(k) {
                        out[k] = .string(Redactor.placeholder)
                        changed = true
                    } else {
                        let (r, c) = redact(v, redactor)
                        out[k] = r
                        changed = changed || c
                    }
                }
                return (.object(out), changed)
            }
            guard t == "map" else { return (json, false) }
            var changed = false
            var entries: [JSONValue] = []
            for e in o["e"]?.arrayValue ?? [] {
                let pair = e.arrayValue ?? []
                let key = pair.first ?? .null
                let value = pair.count > 1 ? pair[1] : .null
                if case .string(let k) = key, !value.isNull, redactor.isSensitiveKey(k) {
                    entries.append(.array([key, .string(Redactor.placeholder)]))
                    changed = true
                } else {
                    let (rk, kc) = redact(key, redactor)
                    let (rv, vc) = redact(value, redactor)
                    entries.append(.array([rk, rv]))
                    changed = changed || kc || vc
                }
            }
            return (.object([tag: "map", "e": .array(entries)]), changed)
        default:
            return (json, false)
        }
    }

    /// Whether [json] contains binary data (`bytes` or numeric arrays).
    public static func hasBinary(_ json: JSONValue) -> Bool {
        switch json {
        case .array(let a): return a.contains(where: hasBinary)
        case .object(let o):
            switch tagOf(o)?.stringValue {
            case "bytes"?, "i32"?, "i64"?, "f32"?, "f64"?: return true
            case "map"?: return (o["e"]?.arrayValue ?? []).contains { e in (e.arrayValue ?? []).contains(where: hasBinary) }
            default: return o.contains { hasBinary($0.value) }
            }
        default: return false
        }
    }
}
