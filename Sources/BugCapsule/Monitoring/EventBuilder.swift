import Foundation

/// Builds `exception` values, stack traces and debug images (monitoring-v1 §2, §3).
struct StackBuilder {
    let inAppIncludes: [String]
    let inAppExcludes: [String]
    let mainExecutable: String?

    init(options: BugCapsuleMonitoringOptions) {
        inAppIncludes = options.inAppIncludes
        inAppExcludes = options.inAppExcludes
        mainExecutable = DebugImageCache.mainExecutablePath
    }

    /// The main executable (also from an earlier install of the same app,
    /// whose container path differs) or, in Xcode debug builds, the
    /// `<executable>.debug.dylib` next to it that holds the app's code; or
    /// an image named in `inAppIncludes`.
    func isInApp(_ imagePath: String) -> Bool {
        let name = (imagePath as NSString).lastPathComponent
        if inAppExcludes.contains(where: { name.hasPrefix($0) }) { return false }
        if inAppIncludes.contains(where: { name.hasPrefix($0) }) { return true }
        guard let mainExecutable else { return false }
        if imagePath == mainExecutable || imagePath == mainExecutable + ".debug.dylib" { return true }
        let mainName = (mainExecutable as NSString).lastPathComponent
        let names = [mainName, mainName + ".debug.dylib"]
        // A bare binary name (MetricKit) matches the main executable's.
        if !imagePath.contains("/") { return names.contains(name) }
        return names.contains(name) && imagePath.contains(".app/") && mainExecutable.contains(".app/")
    }

    /// Frames for return addresses (innermost first, as the runtime and the
    /// crash writer give them). Output is oldest call first, crashing frame
    /// last. Caller frames point one byte into the call instruction so they
    /// resolve to the call's line. [resolve] maps an address to its image
    /// (another launch's images for crash reports) and [symbol] names
    /// system frames.
    func frames(
        _ addresses: [UInt64], firstIsPC: Bool, resolve: (UInt64) -> DebugImage?,
        symbol: (UInt64, DebugImage) -> String? = { a, _ in Symbolicator.function(at: a) }
    ) -> (frames: [JSONValue], images: [DebugImage]) {
        var out: [JSONValue] = []
        var used: [String: DebugImage] = [:]
        for (i, raw) in addresses.prefix(250).enumerated() {
            let address = (i == 0 && firstIsPC) || raw == 0 ? raw : raw - 1
            var frame: JSONObject = ["instructionAddr": .string(hex(address))]
            if let image = resolve(address) {
                used[image.debugId] = image
                let inApp = isInApp(image.path)
                frame["package"] = .string(image.path)
                frame["imageAddr"] = .string(hex(image.loadAddress))
                frame["inApp"] = .bool(inApp)
                // App frames are symbolicated by the server from the dSYM.
                if !inApp, let name = symbol(address, image) { frame["function"] = .string(name.dartPrefix(1000)) }
            } else {
                frame["inApp"] = false
            }
            out.append(.object(frame))
        }
        let images = used.values.sorted { $0.loadAddress < $1.loadAddress }
        return (out.reversed(), images)
    }

    /// Frames of this process for [addresses], dropping the SDK's own
    /// capture frames at the top.
    func liveFrames(_ addresses: [UInt64], firstIsPC: Bool = false, dropSDKFrames: Bool = true) -> (
        frames: [JSONValue], images: [DebugImage]
    ) {
        var addrs = addresses
        if dropSDKFrames {
            while let first = addrs.first, let name = Symbolicator.function(at: first),
                name.contains("BugCapsule.") || name.hasPrefix("BugCapsule") || name.contains("10BugCapsule")
            {
                addrs.removeFirst()
            }
        }
        return frames(addrs, firstIsPC: firstIsPC, resolve: { DebugImageCache.shared.image(containing: $0) })
    }

    static func stacktrace(_ frames: [JSONValue]) -> JSONValue { ["frames": .array(frames)] }

    /// One exception value.
    static func exceptionValue(
        type: String, value: String, module: String?, mechanism: String, handled: Bool, frames: [JSONValue]?,
        data: JSONObject? = nil
    ) -> JSONValue {
        var mech: JSONObject = ["type": .string(mechanism), "handled": .bool(handled)]
        if let data { mech["data"] = .object(data) }
        var o: JSONObject = [
            "type": .string(type.isEmpty ? "Error" : type.dartPrefix(200)), "value": .string(value.dartPrefix(8192)),
        ]
        if let module { o["module"] = .string(module.dartPrefix(200)) }
        o["mechanism"] = .object(mech)
        if let frames, !frames.isEmpty { o["stacktrace"] = stacktrace(frames) }
        return .object(o)
    }

    /// Swift `Error` (with `NSUnderlyingErrorKey` causes) as exception values,
    /// innermost cause first. The stack goes on the outermost value.
    static func errorValues(
        _ error: Error, mechanism: String, handled: Bool, frames: [JSONValue], scrub: (String) -> String
    ) -> [JSONValue] {
        var chain: [Error] = [error]
        var current = error as NSError
        while chain.count < 10, let next = current.userInfo[NSUnderlyingErrorKey] as? Error {
            chain.append(next)
            current = next as NSError
        }
        var values: [JSONValue] = []
        for (i, e) in chain.enumerated().reversed() {
            let ns = e as NSError
            let isObjC = type(of: e) is NSError.Type
            let typeName = isObjC ? ns.domain : String(describing: type(of: e))
            let value = isObjC ? "\(ns.domain) \(ns.code): \(ns.localizedDescription)" : String(describing: e)
            values.append(
                exceptionValue(
                    type: typeName, value: scrub(value), module: isObjC ? nil : moduleName(of: e),
                    mechanism: mechanism, handled: handled, frames: i == 0 ? frames : nil,
                    data: isObjC ? ["code": .int(ns.code)] : nil))
        }
        return values
    }

    static func moduleName(of error: Error) -> String? {
        let full = String(reflecting: type(of: error))
        guard let dot = full.firstIndex(of: ".") else { return nil }
        return String(full[..<dot])
    }
}

/// Converts flight-recorder events into breadcrumbs (monitoring-v1 §2):
/// the same integrations feed capsules and monitoring.
enum BreadcrumbMapper {
    static func breadcrumb(type: String, data: JSONObject, previousRoute: String?) -> Breadcrumb? {
        switch type {
        case EventTypes.route:
            var d: JSONObject = ["to": data["location"] ?? .null]
            if let previousRoute { d["from"] = .string(previousRoute) }
            if let action = data["action"] { d["action"] = action }
            return Breadcrumb(type: "navigation", category: "navigation", data: d)
        case EventTypes.action:
            let id = data["id"]?.stringValue
            return Breadcrumb(type: "user", category: "ui.action", message: id, data: id.map { ["id": .string($0)] })
        case EventTypes.text:
            // The id only: values stay in capsules.
            let id = data["id"]?.stringValue
            return Breadcrumb(type: "user", category: "ui.text", message: id, data: id.map { ["id": .string($0)] })
        case EventTypes.http:
            var d: JSONObject = ["method": data["method"] ?? "GET", "url": data["url"] ?? ""]
            if let status = data["status"], status.intValue != 0 { d["status_code"] = status }
            if let duration = data["durationMs"] { d["durationMs"] = duration }
            if let error = data["error"]?["type"] { d["reason"] = error }
            let status = data["status"]?.intValue ?? 0
            let failed = status == 0 || status >= 400
            return Breadcrumb(type: "http", category: "http", level: failed ? .warning : .info, data: d)
        case EventTypes.lifecycle:
            return Breadcrumb(
                type: "navigation", category: "app.lifecycle", data: ["state": data["state"] ?? .null])
        case EventTypes.log:
            let level = MonitoringLevel(rawValue: data["level"]?.stringValue ?? "") ?? .info
            return Breadcrumb(
                type: level == .debug ? "debug" : "info", category: "log", message: data["message"]?.stringValue,
                level: level == .fatal ? .error : level)
        case EventTypes.state:
            return Breadcrumb(type: "state", category: "state", data: ["key": data["key"] ?? .null])
        case EventTypes.failure:
            let t = data["type"]?.stringValue ?? ""
            let m = data["message"]?.stringValue ?? ""
            return Breadcrumb(type: "error", category: "failure", message: m.isEmpty ? t : "\(t): \(m)", level: .error)
        default:
            return nil
        }
    }
}

/// Redaction of envelope items before they are persisted (monitoring-v1 §1):
/// every string goes through the capsule rules; ids, timestamps, addresses
/// and debug images are structural and kept.
enum ItemRedaction {
    private static let structuralTop: Set<String> = [
        "eventId", "feedbackId", "sid", "seq", "init", "timestamp", "startTimestamp", "started", "level", "runtime",
        "release", "environment", "status", "traceId", "spanId", "parentSpanId", "capsuleId", "debugImages", "duration",
        "errors", "did", "op",
    ]

    static func redact(_ payload: JSONObject, redactor: Redactor) -> JSONObject {
        var out = redactor.redactJSON(.object(payload)).objectValue ?? JSONObject()
        for key in structuralTop where payload[key] != nil { out[key] = payload[key] }
        if let trace = payload["contexts"]?["trace"], out["contexts"]?.objectValue != nil {
            var c = out["contexts"]!.objectValue!
            c["trace"] = trace
            out["contexts"] = .object(c)
        }
        if let values = payload["exception"]?["values"]?.arrayValue, let redacted = out["exception"]?["values"]?.arrayValue,
            values.count == redacted.count
        {
            out["exception"] = ["values": .array(zip(values, redacted).map { restoreFrames($0, into: $1) })]
        }
        if let threads = payload["threads"]?.arrayValue, let redacted = out["threads"]?.arrayValue,
            threads.count == redacted.count
        {
            out["threads"] = .array(zip(threads, redacted).map { restoreFrames($0, into: $1) })
        }
        if let spans = payload["spans"]?.arrayValue, let redacted = out["spans"]?.arrayValue, spans.count == redacted.count {
            out["spans"] = .array(
                zip(spans, redacted).map { original, r in
                    guard var o = r.objectValue else { return r }
                    for k in ["spanId", "parentSpanId", "traceId", "startTimestamp", "timestamp", "status", "op"] {
                        if let v = original[k] { o[k] = v }
                    }
                    return .object(o)
                })
        }
        return out
    }

    private static func restoreFrames(_ original: JSONValue, into redacted: JSONValue) -> JSONValue {
        guard var o = redacted.objectValue, let frames = original["stacktrace"]?["frames"]?.arrayValue,
            let rFrames = o["stacktrace"]?["frames"]?.arrayValue, frames.count == rFrames.count
        else { return redacted }
        let restored = zip(frames, rFrames).map { f, r -> JSONValue in
            guard var ro = r.objectValue else { return r }
            for k in ["instructionAddr", "imageAddr", "package", "inApp", "function"] {
                if let v = f[k] { ro[k] = v }
            }
            return .object(ro)
        }
        var st = o["stacktrace"]!.objectValue!
        st["frames"] = .array(restored)
        o["stacktrace"] = .object(st)
        return .object(o)
    }
}
