import Foundation

/// Allowlisted `UserDefaults` keys snapshotted into every checkpoint
/// (`checkpoint.data.user_defaults = {key: {type, value}}`) and restored in
/// replay inside `BugCapsule.start`, before app code reads them.
///
/// Types: `bool`, `int`, `double`, `string`, `stringArray`, `data`
/// (base64), `date` (epoch ms). Other values (dictionaries, mixed arrays)
/// are skipped and reported as `storage.<key>` in eligibility. Values are
/// redacted (sensitive key names become `[REDACTED]`; strings are scrubbed,
/// JSON strings redacted as JSON); restoring a placeholder reports
/// `storage.redacted`.
public final class BugCapsuleUserDefaults: BugCapsuleIntegration, @unchecked Sendable {
    public let name = "user_defaults"
    public var capabilities: [(String, String)] { [("storage.user_defaults", "supported")] }

    public let keys: Set<String>
    public let prefixes: [String]
    public let denyPrefixes: [String]
    public let suiteName: String?
    private let lock = NSLock()
    private var session: BugCapsuleSession?
    private var redacted = Set<String>()
    private var unsupported = Set<String>()

    /// Captures [keys] plus keys starting with one of [prefixes];
    /// [denyPrefixes] win. Nothing is captured unless allowlisted.
    public init(keys: [String] = [], prefixes: [String] = [], denyPrefixes: [String] = ["bugcapsule.", "com.apple.", "Apple", "NS"], suiteName: String? = nil) {
        self.keys = Set(keys)
        self.prefixes = prefixes
        self.denyPrefixes = denyPrefixes
        self.suiteName = suiteName
    }

    var defaults: UserDefaults { suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard }

    private var domainName: String? { suiteName ?? Bundle.main.bundleIdentifier }

    func allowed(_ key: String) -> Bool {
        (keys.contains(key) || prefixes.contains(where: { key.hasPrefix($0) })) && !denyPrefixes.contains(where: { key.hasPrefix($0) })
    }

    public func setUp(_ session: BugCapsuleSession) { lock.locked { self.session = session } }

    /// The app's own persisted values (not registered defaults or the global domain).
    private func persisted() -> [String: Any] {
        if let domainName, let d = defaults.persistentDomain(forName: domainName) { return d }
        return [:]
    }

    static func encode(_ value: Any) -> (String, JSONValue)? {
        switch value {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return ("bool", .bool(n.boolValue)) }
            if CFNumberIsFloatType(n) { return ("double", .double(n.doubleValue)) }
            return ("int", .int(n.intValue))
        case let s as String: return ("string", .string(s))
        case let d as Data: return ("data", .string(d.base64EncodedString()))
        case let date as Date: return ("date", .int(epochMs(date)))
        case let a as [Any]:
            let strings = a.compactMap { $0 as? String }
            return strings.count == a.count ? ("stringArray", .array(strings.map { .string($0) })) : nil
        default: return nil
        }
    }

    @MainActor public func snapshot(_ kind: CheckpointKind) -> JSONValue? {
        guard let session = lock.locked({ session }) else { return nil }
        let redactor = session.redactor
        var out = JSONObject()
        let values = persisted()
        for key in values.keys.sorted(by: utf16Less) where allowed(key) {
            guard let (type, value) = Self.encode(values[key]!) else {
                lock.locked { _ = unsupported.insert(key) }
                continue
            }
            if redactor.isSensitiveKey(key) {
                lock.locked { _ = redacted.insert(key) }
                out[key] = ["type": .string(type), "value": .string(Redactor.placeholder)]
                continue
            }
            var clean = value
            if type == "string" || type == "stringArray" {
                clean = redactor.redactJSON(value)
                if clean != value { lock.locked { _ = redacted.insert(key) } }
            }
            out[key] = ["type": .string(type), "value": clean]
        }
        return .object(out)
    }

    @MainActor public func restore(_ data: JSONValue?, session: BugCapsuleSession) throws {
        let d = defaults
        for key in persisted().keys where allowed(key) { d.removeObject(forKey: key) }
        guard let o = data?.objectValue else { return }
        let replay = session.replay
        for (key, entry) in o {
            guard let item = entry.objectValue else {
                replay?.diverge("storage.redacted", key)
                continue
            }
            let value = item["value"] ?? .null
            if JSON.encode(value).contains(Redactor.placeholder) { replay?.diverge("storage.redacted", key) }
            switch item["type"]?.stringValue {
            case "bool": d.set(value.boolValue ?? false, forKey: key)
            case "int": d.set(value.intValue ?? 0, forKey: key)
            case "double": d.set(value.doubleValue ?? 0, forKey: key)
            case "string": d.set(value.stringValue ?? "", forKey: key)
            case "stringArray": d.set((value.arrayValue ?? []).compactMap(\.stringValue), forKey: key)
            case "data": d.set(Data(base64Encoded: value.stringValue ?? "") ?? Data(), forKey: key)
            case "date": d.set(Date(timeIntervalSince1970: (value.doubleValue ?? 0) / 1000), forKey: key)
            default: replay?.diverge("storage.unknownType", key)
            }
        }
    }

    public func describeEligibility(_ eligibility: EligibilityBuilder, window: RecordedWindow) {
        let (r, u) = lock.locked { (redacted, unsupported) }
        for key in r.sorted() {
            eligibility.missing("storage.\(key)", "value redacted on device; replay restores a placeholder")
        }
        for key in u.sorted() {
            eligibility.missing("storage.\(key)", "UserDefaults value of an unsupported type was not captured")
        }
    }
}
