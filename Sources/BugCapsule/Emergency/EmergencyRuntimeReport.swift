import Foundation

/// The `runtime` object of receipts (§7.6): building and validating it. iOS
/// has no hotfix adapter, so only `update` is ever built.
enum EmergencyRuntimeReport {
    static let status = "RUNTIME"
    /// At most one report per this many seconds.
    static let interval: TimeInterval = 60

    static let flows: Set<String> = ["immediate", "flexible", "store_page", "custom"]
    static let updateStates: Set<String> = [
        "not_available", "available", "in_progress", "downloaded", "declined", "failed", "opened_store",
    ]
    static let updateKeys: Set<String> = ["provider", "flow", "state", "availableVersion", "requiredVersion"]

    /// `^[a-z][a-z0-9_]{0,31}$`.
    static func isProvider(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard (1...32).contains(b.count), b[0] >= UInt8(ascii: "a"), b[0] <= UInt8(ascii: "z") else { return false }
        return b.allSatisfy {
            ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z")) || ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
                || $0 == UInt8(ascii: "_")
        }
    }

    /// A version field: 1–64 characters, else null.
    private static func version(_ v: String?) -> JSONValue {
        guard let v, !v.isEmpty, v.count <= 64 else { return .null }
        return .string(v)
    }

    /// `{"update":{…}}`, keys in a fixed order so equal objects encode
    /// equally.
    static func object(update: EmergencyUpdateStatus) -> JSONObject {
        var u = JSONObject()
        u["provider"] = .string(update.provider)
        u["flow"] = .string(update.flow.rawValue)
        u["state"] = .string(update.state.rawValue)
        u["availableVersion"] = version(update.availableVersion)
        u["requiredVersion"] = version(update.requiredVersion)
        return ["update": .object(u)]
    }

    /// Nil when [runtime] is a valid `runtime` object for this platform;
    /// otherwise what is wrong. `hotfix` is refused: iOS has no hotfix
    /// adapter.
    static func validate(_ runtime: JSONObject) -> String? {
        for key in runtime.keys where key != "update" { return "runtime.\(key) is not allowed" }
        guard let update = runtime["update"] else { return nil }
        guard let u = update.objectValue else { return "runtime.update is not an object" }
        for key in u.keys where !updateKeys.contains(key) { return "runtime.update.\(key) is not allowed" }
        guard let provider = u["provider"]?.stringValue, isProvider(provider) else {
            return "runtime.update.provider must match ^[a-z][a-z0-9_]{0,31}$"
        }
        guard let flow = u["flow"]?.stringValue, flows.contains(flow) else { return "runtime.update.flow is not a flow" }
        guard let state = u["state"]?.stringValue, updateStates.contains(state) else {
            return "runtime.update.state is not a state"
        }
        for key in ["availableVersion", "requiredVersion"] {
            switch u[key] {
            case nil, .null?: continue
            case .string(let s)? where !s.isEmpty && s.count <= 64: continue
            default: return "runtime.update.\(key) must be a string of 1–64 characters or null"
            }
        }
        return nil
    }
}
