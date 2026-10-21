import Foundation

/// Resource bounds of the capsule format (capsule v1 "Validation").
public enum CapsuleLimits {
    public static let maxEvents = 200_000
    public static let maxDepth = 100
    public static let maxLabels = 100
    public static let maxIntegrations = 100
    public static let maxMissing = 500
    public static let maxRedactionKeys = 500
    public static let maxCapabilities = 200
    public static let maxFrameworks = 20
    /// JSON values in the whole document, counted before parsing.
    public static let maxJSONValues = 4_000_000
}

/// Structural validation of a decoded capsule document, the same rules as
/// the Dart reader and the backend. Returns `nil` when valid, otherwise
/// `<json path> <reason>`.
public func validateCapsuleDocument(_ doc: JSONValue) -> String? {
    do {
        try CapsuleValidator.validate(doc)
        return nil
    } catch let e as CapsuleValidator.Invalid {
        return e.message
    } catch {
        return "$ \(error)"
    }
}

enum CapsuleValidator {
    struct Invalid: Error { let message: String }

    static let maxSafeInt = 9_007_199_254_740_991

    static func fail(_ path: String, _ reason: String) -> Invalid { Invalid(message: "\(path) \(reason)") }

    static let isoDateTime = try! NSRegularExpression(
        pattern: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]{1,9})?)?(Z|[+-][0-9]{2}:?[0-9]{2})$"#,
        options: [.caseInsensitive])

    static func object(_ v: JSONValue?, _ path: String) throws -> JSONObject {
        guard case .object(let o)? = v else { throw fail(path, "must be an object") }
        return o
    }

    static func optObject(_ o: JSONObject, _ key: String, _ path: String) throws -> JSONObject? {
        guard let v = o[key], !v.isNull else { return nil }
        return try object(v, "\(path).\(key)")
    }

    static func array(_ v: JSONValue?, _ path: String, _ max: Int) throws -> [JSONValue] {
        guard case .array(let a)? = v else { throw fail(path, "must be an array") }
        if a.count > max { throw fail(path, "must have at most \(max) items") }
        return a
    }

    @discardableResult
    static func string(_ o: JSONObject, _ key: String, _ path: String, max: Int = 1000, min: Int = 1) throws -> String {
        guard case .string(let v)? = o[key] else { throw fail("\(path).\(key)", "must be a string") }
        if v.dartLength < min { throw fail("\(path).\(key)", "must not be empty") }
        if v.dartLength > max { throw fail("\(path).\(key)", "must be at most \(max) characters") }
        return v
    }

    static func optString(_ o: JSONObject, _ key: String, _ path: String, max: Int = 1000) throws {
        guard let v = o[key], !v.isNull else { return }
        guard case .string(let s) = v else { throw fail("\(path).\(key)", "must be a string or null") }
        if s.dartLength > max { throw fail("\(path).\(key)", "must be at most \(max) characters") }
    }

    @discardableResult
    static func int(_ o: JSONObject, _ key: String, _ path: String, min: Int? = nil) throws -> Int {
        guard case .int(let v)? = o[key], v.magnitude <= UInt(maxSafeInt) else {
            throw fail("\(path).\(key)", "must be an integer")
        }
        if let min, v < min { throw fail("\(path).\(key)", "must be >= \(min)") }
        return v
    }

    static func optInt(_ o: JSONObject, _ key: String, _ path: String, min: Int? = nil) throws {
        guard let v = o[key], !v.isNull else { return }
        try int(o, key, path, min: min)
    }

    static func optNum(_ o: JSONObject, _ key: String, _ path: String) throws {
        guard let v = o[key], !v.isNull else { return }
        guard let d = v.doubleValue, d.isFinite else { throw fail("\(path).\(key)", "must be a number or null") }
    }

    static func optBool(_ o: JSONObject, _ key: String, _ path: String) throws {
        guard let v = o[key], !v.isNull else { return }
        guard case .bool = v else { throw fail("\(path).\(key)", "must be a boolean or null") }
    }

    static func oneOf(_ o: JSONObject, _ key: String, _ path: String, _ values: [String]) throws {
        guard case .string(let v)? = o[key], values.contains(v) else {
            throw fail("\(path).\(key)", "must be one of \(values.joined(separator: ", "))")
        }
    }

    static func isoDate(_ o: JSONObject, _ key: String, _ path: String) throws {
        guard case .string(let v)? = o[key],
            isoDateTime.firstMatch(in: v, range: NSRange(location: 0, length: (v as NSString).length)) != nil
        else { throw fail("\(path).\(key)", "must be an ISO-8601 date-time with a time zone") }
    }

    static func stringMap(_ m: JSONObject, _ path: String, maxEntries: Int = 1000, max: Int = 10000) throws {
        if m.count > maxEntries { throw fail(path, "must have at most \(maxEntries) entries") }
        for (k, v) in m {
            guard case .string(let s) = v else { throw fail("\(path).\(k)", "must be a string") }
            if s.dartLength > max { throw fail("\(path).\(k)", "must be at most \(max) characters") }
        }
    }

    static func depth(_ root: JSONValue) throws {
        var stack: [(JSONValue, Int)] = [(root, 0)]
        while let (value, d) = stack.popLast() {
            if d > CapsuleLimits.maxDepth { throw fail("$", "nests deeper than \(CapsuleLimits.maxDepth) levels") }
            switch value {
            case .object(let o):
                for (_, v) in o {
                    switch v {
                    case .object, .array: stack.append((v, d + 1))
                    default: break
                    }
                }
            case .array(let a):
                for v in a {
                    switch v {
                    case .object, .array: stack.append((v, d + 1))
                    default: break
                    }
                }
            default: break
            }
        }
    }

    static func validate(_ root: JSONValue) throws {
        let doc = try object(root, "$")
        try depth(root)
        if doc["format"] != .string("bugcapsule.capsule") { throw fail("$.format", "must be \"bugcapsule.capsule\"") }
        try int(doc, "specVersion", "$", min: 1)

        let mp = "$.manifest"
        let m = try object(doc["manifest"], mp)
        try string(m, "capsuleId", mp, max: 100)
        try isoDate(m, "createdAt", mp)
        try oneOf(m, "mode", mp, ["debug", "qa", "production"])

        let app = try object(m["app"], "\(mp).app")
        try string(app, "version", "\(mp).app", max: 200)
        try string(app, "build", "\(mp).app", max: 200)
        for k in ["id", "name", "flavor"] { try optString(app, k, "\(mp).app", max: 200) }

        if let source = try optObject(m, "source", mp) {
            try optString(source, "gitSha", "\(mp).source", max: 200)
            try optBool(source, "dirty", "\(mp).source")
        }
        if let sdk = try optObject(m, "sdk", mp) {
            try optString(sdk, "name", "\(mp).sdk", max: 100)
            try optString(sdk, "version", "\(mp).sdk", max: 100)
        }
        try optInt(m, "stateSchemaVersion", mp)

        let platform = try object(m["platform"], "\(mp).platform")
        try string(platform, "os", "\(mp).platform", max: 100)
        try optString(platform, "osVersion", "\(mp).platform", max: 200)
        try optString(platform, "locale", "\(mp).platform", max: 100)
        try optString(platform, "dartVersion", "\(mp).platform", max: 200)
        if let screen = try optObject(platform, "screen", "\(mp).platform") {
            for k in ["width", "height", "pixelRatio"] { try optNum(screen, k, "\(mp).platform.screen") }
        }

        let session = try object(m["session"], "\(mp).session")
        try string(session, "id", "\(mp).session", max: 200)
        try isoDate(session, "startedAt", "\(mp).session")
        try int(session, "wallClockAtAnchorMs", "\(mp).session")
        try int(session, "seed", "\(mp).session")
        try int(session, "durationMs", "\(mp).session")

        if let failure = try optObject(m, "failure", mp) { try validateFailure(failure, "\(mp).failure") }

        let eligibility = try object(m["eligibility"], "\(mp).eligibility")
        try oneOf(eligibility, "status", "\(mp).eligibility", ["eligible", "partial", "ineligible"])
        if let missingV = eligibility["missing"], !missingV.isNull {
            let missing = try array(missingV, "\(mp).eligibility.missing", CapsuleLimits.maxMissing)
            for (i, item) in missing.enumerated() {
                let path = "\(mp).eligibility.missing[\(i)]"
                let o = try object(item, path)
                try string(o, "dependency", path, max: 200)
                try string(o, "reason", path, max: 2000, min: 0)
                try optBool(o, "blocking", path)
            }
        }

        if let integrationsV = m["integrations"], !integrationsV.isNull {
            let integrations = try array(integrationsV, "\(mp).integrations", CapsuleLimits.maxIntegrations)
            for (i, v) in integrations.enumerated() {
                guard case .string(let s) = v, !s.isEmpty, s.dartLength <= 100 else {
                    throw fail("\(mp).integrations[\(i)]", "must be a non-empty string of at most 100 characters")
                }
            }
        }

        if let stats = try optObject(m, "stats", mp) {
            try optInt(stats, "eventCount", "\(mp).stats", min: 0)
            try optInt(stats, "droppedEvents", "\(mp).stats", min: 0)
            if let ck = stats["checkpointKind"], !ck.isNull {
                try oneOf(stats, "checkpointKind", "\(mp).stats", ["launch", "periodic"])
            }
        }

        if let labels = try optObject(m, "labels", mp) {
            try stringMap(labels, "\(mp).labels", maxEntries: CapsuleLimits.maxLabels, max: 2000)
            for k in labels.keys where k.dartLength > 100 {
                throw fail("\(mp).labels", "keys must be at most 100 characters")
            }
        }

        if let redaction = try optObject(m, "redaction", mp) {
            for k in ["extraKeys", "extraHeaders"] {
                guard let v = redaction[k], !v.isNull else { continue }
                let list = try array(v, "\(mp).redaction.\(k)", CapsuleLimits.maxRedactionKeys)
                for (i, item) in list.enumerated() {
                    guard case .string(let s) = item, s.dartLength <= 200 else {
                        throw fail("\(mp).redaction.\(k)[\(i)]", "must be a string")
                    }
                }
            }
        }

        if let runtime = try optObject(m, "runtime", mp) {
            try string(runtime, "name", "\(mp).runtime", max: 50)
            try optString(runtime, "version", "\(mp).runtime", max: 200)
            try optString(runtime, "language", "\(mp).runtime", max: 50)
            if let fw = runtime["frameworks"], !fw.isNull {
                let list = try array(fw, "\(mp).runtime.frameworks", CapsuleLimits.maxFrameworks)
                for (i, v) in list.enumerated() {
                    guard case .string(let s) = v, !s.isEmpty, s.dartLength <= 50 else {
                        throw fail(
                            "\(mp).runtime.frameworks[\(i)]", "must be a non-empty string of at most 50 characters")
                    }
                }
            }
        }
        if let capabilities = try optObject(m, "capabilities", mp) {
            try stringMap(capabilities, "\(mp).capabilities", maxEntries: CapsuleLimits.maxCapabilities, max: 100)
            for k in capabilities.keys where k.dartLength > 100 {
                throw fail("\(mp).capabilities", "keys must be at most 100 characters")
            }
        }

        let cp = "$.checkpoint"
        let checkpoint = try object(doc["checkpoint"], cp)
        try oneOf(checkpoint, "kind", cp, ["launch", "periodic"])
        try int(checkpoint, "t", cp)
        try int(checkpoint, "wallClockMs", cp)
        try optInt(checkpoint, "afterSeq", cp, min: 0)
        _ = try optObject(checkpoint, "data", cp)

        let events = try array(doc["events"], "$.events", CapsuleLimits.maxEvents)
        var lastSeq: Int?
        for (i, ev) in events.enumerated() {
            let path = "$.events[\(i)]"
            let e = try object(ev, path)
            let seq = try int(e, "seq", path)
            if let lastSeq, seq <= lastSeq { throw fail("\(path).seq", "must be greater than the previous seq") }
            lastSeq = seq
            try int(e, "t", path)
            let type = try string(e, "type", path, max: 100)
            let data = try optObject(e, "data", path) ?? JSONObject()
            try validateEventData(type, data, "\(path).data")
        }
    }

    static func validateFailure(_ f: JSONObject, _ path: String) throws {
        try oneOf(f, "kind", path, ["exception", "assertion", "manual"])
        try string(f, "signature", path, max: 1000)
        try string(f, "type", path, max: 1000, min: 0)
        try optString(f, "message", path, max: 10000)
        try optString(f, "stack", path, max: 20000)
        try optString(f, "assertionId", path, max: 200)
        try optInt(f, "t", path)
    }

    static func validateEventData(_ type: String, _ d: JSONObject, _ path: String) throws {
        switch type {
        case "http":
            try string(d, "key", path, max: 10000)
            try optInt(d, "occurrence", path, min: 0)
            try optInt(d, "status", path)
            try optInt(d, "durationMs", path, min: 0)
            try optString(d, "bodyEncoding", path, max: 20)
            try optString(d, "statusMessage", path, max: 1000)
            if let headers = try optObject(d, "responseHeaders", path) {
                try stringMap(headers, "\(path).responseHeaders")
            }
            _ = try optObject(d, "error", path)
        case "pointer":
            try string(d, "phase", path, max: 20)
            try int(d, "pointer", path)
            for k in ["x", "y"] {
                guard let v = d[k]?.doubleValue, v.isFinite else { throw fail("\(path).\(k)", "must be a number") }
            }
            try optInt(d, "buttons", path)
        case "action":
            try string(d, "id", path, max: 200)
            _ = try optObject(d, "payload", path)
        case "text":
            try string(d, "id", path, max: 200)
            try optString(d, "value", path, max: 100_000)
        case "lifecycle":
            try string(d, "state", path, max: 20)
        default:
            break
        }
    }
}
