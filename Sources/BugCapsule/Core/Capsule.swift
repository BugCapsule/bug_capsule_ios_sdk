import Foundation

public enum CaptureMode: String, Sendable, CaseIterable {
    case debug, qa, production
}

public enum CheckpointKind: String, Sendable {
    case launch, periodic
}

public enum EligibilityStatus: String, Sendable {
    case eligible, partial, ineligible
}

/// Event types defined by capsule spec v1 (plus `state`, runtimes-v1 §4).
public enum EventTypes {
    public static let lifecycle = "lifecycle"
    public static let pointer = "pointer"
    public static let action = "action"
    public static let text = "text"
    public static let route = "route"
    public static let http = "http"
    public static let emergencyDecision = "emergency.decision"
    public static let log = "log"
    public static let failure = "failure"
    public static let state = "state"
}

/// One recorded event. `t` is milliseconds relative to the session anchor
/// in a capsule; inside the recorder it is milliseconds since start.
public struct BugCapsuleEvent: Sendable, Equatable {
    public var seq: Int
    public var t: Int
    public var type: String
    public var data: JSONObject

    public init(seq: Int, t: Int, type: String, data: JSONObject = JSONObject()) {
        self.seq = seq
        self.t = t
        self.type = type
        self.data = data
    }

    init(json: JSONObject) {
        seq = json["seq"]?.intValue ?? 0
        t = json["t"]?.intValue ?? 0
        type = json["type"]?.stringValue ?? ""
        data = json["data"]?.objectValue ?? JSONObject()
    }

    public func shifted(_ offset: Int) -> BugCapsuleEvent {
        BugCapsuleEvent(seq: seq, t: t - offset, type: type, data: data)
    }

    public var json: JSONValue {
        ["seq": .int(seq), "t": .int(t), "type": .string(type), "data": .object(data)]
    }
}

public struct Checkpoint: Sendable, Equatable {
    public var kind: CheckpointKind
    public var t: Int
    public var wallClockMs: Int
    public var afterSeq: Int
    public var data: JSONObject

    public init(kind: CheckpointKind, t: Int, wallClockMs: Int, afterSeq: Int, data: JSONObject = JSONObject()) {
        self.kind = kind
        self.t = t
        self.wallClockMs = wallClockMs
        self.afterSeq = afterSeq
        self.data = data
    }

    init(json: JSONObject) {
        kind = CheckpointKind(rawValue: json["kind"]?.stringValue ?? "") ?? .launch
        t = json["t"]?.intValue ?? 0
        wallClockMs = json["wallClockMs"]?.intValue ?? 0
        afterSeq = json["afterSeq"]?.intValue ?? 0
        data = json["data"]?.objectValue ?? JSONObject()
    }

    public func shifted(_ offset: Int) -> Checkpoint {
        Checkpoint(kind: kind, t: t - offset, wallClockMs: wallClockMs, afterSeq: afterSeq, data: data)
    }

    public var json: JSONValue {
        [
            "kind": .string(kind.rawValue), "t": .int(t), "wallClockMs": .int(wallClockMs),
            "afterSeq": .int(afterSeq), "data": .object(data),
        ]
    }
}

public struct MissingDependency: Sendable, Equatable {
    public var dependency: String
    public var reason: String
    public var blocking: Bool

    public init(_ dependency: String, _ reason: String, blocking: Bool = false) {
        self.dependency = dependency
        self.reason = reason
        self.blocking = blocking
    }

    public var json: JSONValue {
        var o: JSONObject = ["dependency": .string(dependency), "reason": .string(reason)]
        if blocking { o["blocking"] = true }
        return .object(o)
    }
}

public struct Eligibility: Sendable, Equatable {
    public var status: EligibilityStatus
    public var missing: [MissingDependency]

    public init(status: EligibilityStatus, missing: [MissingDependency]) {
        self.status = status
        self.missing = missing
    }

    init(json: JSONObject) {
        status = EligibilityStatus(rawValue: json["status"]?.stringValue ?? "") ?? .ineligible
        missing = (json["missing"]?.arrayValue ?? []).compactMap { v in
            guard let o = v.objectValue else { return nil }
            return MissingDependency(
                o["dependency"]?.stringValue ?? "", o["reason"]?.stringValue ?? "",
                blocking: o["blocking"]?.boolValue ?? false)
        }
    }

    public var json: JSONValue {
        ["status": .string(status.rawValue), "missing": .array(missing.map(\.json))]
    }
}

/// Collects gaps from the core and from every integration.
public final class EligibilityBuilder: @unchecked Sendable {
    private var items: [MissingDependency] = []

    public init() {}

    public func missing(_ dependency: String, _ reason: String, blocking: Bool = false) {
        let dependency = dependency.dartPrefix(200)
        let reason = reason.dartPrefix(2000)
        if items.count >= 200 { return }
        if items.contains(where: { $0.dependency == dependency && $0.reason == reason }) { return }
        items.append(MissingDependency(dependency, reason, blocking: blocking))
    }

    public func build() -> Eligibility {
        let status: EligibilityStatus =
            items.contains(where: \.blocking) ? .ineligible : items.isEmpty ? .eligible : .partial
        return Eligibility(status: status, missing: items)
    }
}

public struct AppInfo: Sendable, Equatable {
    public var id: String?
    public var name: String?
    public var version: String
    public var build: String
    public var flavor: String?

    public init(id: String? = nil, name: String? = nil, version: String, build: String, flavor: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.build = build
        self.flavor = flavor
    }

    public var json: JSONValue {
        [
            "id": id.map { .string($0) } ?? .null, "name": name.map { .string($0) } ?? .null,
            "version": .string(version), "build": .string(build),
            "flavor": flavor.map { .string($0) } ?? .null,
        ]
    }
}

public struct PlatformInfo: Sendable, Equatable {
    public var os: String
    public var osVersion: String
    public var locale: String
    public var screenWidth: Double
    public var screenHeight: Double
    public var pixelRatio: Double

    public init(os: String, osVersion: String, locale: String, screenWidth: Double, screenHeight: Double, pixelRatio: Double) {
        self.os = os
        self.osVersion = osVersion
        self.locale = locale
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.pixelRatio = pixelRatio
    }

    init(json: JSONObject) {
        os = json["os"]?.stringValue ?? ""
        osVersion = json["osVersion"]?.stringValue ?? ""
        locale = json["locale"]?.stringValue ?? ""
        let screen = json["screen"]?.objectValue ?? JSONObject()
        screenWidth = screen["width"]?.doubleValue ?? 0
        screenHeight = screen["height"]?.doubleValue ?? 0
        pixelRatio = screen["pixelRatio"]?.doubleValue ?? 1
    }

    public var json: JSONValue {
        [
            "os": .string(os), "osVersion": .string(osVersion), "locale": .string(locale),
            "screen": [
                "width": .double(screenWidth), "height": .double(screenHeight), "pixelRatio": .double(pixelRatio),
            ],
        ]
    }
}

/// The capturing runtime (runtimes-v1 §2).
/// `manifest.monitoring` (monitoring-v1 §4.3): the error event sent for
/// the capsule's failure, so the backend links the capsule to its issue.
public struct CapsuleMonitoringLink: Sendable, Equatable {
    public var eventId: String
    public var traceId: String?
    public var release: String
    public var environment: String

    public init(eventId: String, traceId: String? = nil, release: String, environment: String) {
        self.eventId = eventId
        self.traceId = traceId
        self.release = release
        self.environment = environment
    }

    init?(json: JSONObject) {
        guard let eventId = json["eventId"]?.stringValue else { return nil }
        self.eventId = eventId
        traceId = json["traceId"]?.stringValue
        release = json["release"]?.stringValue ?? ""
        environment = json["environment"]?.stringValue ?? ""
    }

    public var json: JSONValue {
        var o: JSONObject = ["eventId": .string(eventId)]
        if let traceId { o["traceId"] = .string(traceId) }
        o["release"] = .string(release)
        o["environment"] = .string(environment)
        return .object(o)
    }
}

public struct RuntimeInfo: Sendable, Equatable {
    public var name: String
    public var version: String?
    public var language: String?
    public var frameworks: [String]

    public init(name: String, version: String? = nil, language: String? = nil, frameworks: [String] = []) {
        self.name = name
        self.version = version
        self.language = language
        self.frameworks = frameworks
    }

    init(json: JSONObject) {
        name = json["name"]?.stringValue ?? ""
        version = json["version"]?.stringValue
        language = json["language"]?.stringValue
        frameworks = (json["frameworks"]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    public static func infer(sdkName: String) -> String {
        switch sdkName {
        case "bug_capsule_flutter": return "flutter"
        case "bugcapsule-android": return "android"
        case "bugcapsule-ios": return "ios"
        case "@bugcapsule/web": return "web"
        default: return "flutter"
        }
    }

    public var json: JSONValue {
        var o: JSONObject = ["name": .string(name)]
        if let version { o["version"] = .string(version) }
        if let language { o["language"] = .string(language) }
        if !frameworks.isEmpty { o["frameworks"] = .array(frameworks.map { .string($0) }) }
        return .object(o)
    }
}

public struct SessionInfo: Sendable, Equatable {
    public var id: String
    public var startedAt: Date
    public var wallClockAtAnchorMs: Int
    public var seed: Int
    public var durationMs: Int

    public init(id: String, startedAt: Date, wallClockAtAnchorMs: Int, seed: Int, durationMs: Int) {
        self.id = id
        self.startedAt = startedAt
        self.wallClockAtAnchorMs = wallClockAtAnchorMs
        self.seed = seed
        self.durationMs = durationMs
    }

    init(json: JSONObject) {
        id = json["id"]?.stringValue ?? ""
        startedAt = ISODate.parse(json["startedAt"]?.stringValue ?? "") ?? Date(timeIntervalSince1970: 0)
        wallClockAtAnchorMs = json["wallClockAtAnchorMs"]?.intValue ?? 0
        seed = json["seed"]?.intValue ?? 0
        durationMs = json["durationMs"]?.intValue ?? 0
    }

    public var json: JSONValue {
        [
            "id": .string(id), "startedAt": .string(ISODate.format(startedAt)),
            "wallClockAtAnchorMs": .int(wallClockAtAnchorMs), "seed": .int(seed), "durationMs": .int(durationMs),
        ]
    }
}

public struct CapsuleManifest: Sendable, Equatable {
    public var capsuleId: String
    public var createdAt: Date
    public var mode: CaptureMode
    public var app: AppInfo
    public var gitSha: String?
    public var dirty: Bool?
    public var sdkName: String
    public var sdkVersion: String
    public var stateSchemaVersion: Int
    public var platform: PlatformInfo
    public var session: SessionInfo
    public var failure: FailureRecord?
    public var eligibility: Eligibility
    public var integrations: [String]
    public var eventCount: Int
    public var droppedEvents: Int
    public var checkpointKind: CheckpointKind
    public var labels: [(String, String)]
    public var redactionKeys: [String]
    public var redactionHeaders: [String]
    public var runtime: RuntimeInfo?
    public var capabilities: [(String, String)]
    public var monitoring: CapsuleMonitoringLink?
    /// Interaction dependencies (capsule-v2 §2). A capsule with at least one
    /// is written as spec v2; v1 capsules have none (a v1 document's field
    /// is ignored).
    public var dependencies: [CapsuleDependency]
    /// `stats.journalGapMs` of a crash capsule: crash time minus the last
    /// journaled event's time (crash-capsules §2).
    public var journalGapMs: Int?

    public init(
        capsuleId: String, createdAt: Date, mode: CaptureMode, app: AppInfo, gitSha: String?, dirty: Bool?,
        sdkName: String, sdkVersion: String, stateSchemaVersion: Int, platform: PlatformInfo, session: SessionInfo,
        failure: FailureRecord?, eligibility: Eligibility, integrations: [String], eventCount: Int,
        droppedEvents: Int, checkpointKind: CheckpointKind, labels: [(String, String)] = [],
        redactionKeys: [String] = [], redactionHeaders: [String] = [], runtime: RuntimeInfo? = nil,
        capabilities: [(String, String)] = [], monitoring: CapsuleMonitoringLink? = nil,
        dependencies: [CapsuleDependency] = [], journalGapMs: Int? = nil
    ) {
        self.capsuleId = capsuleId
        self.createdAt = createdAt
        self.mode = mode
        self.app = app
        self.gitSha = gitSha
        self.dirty = dirty
        self.sdkName = sdkName
        self.sdkVersion = sdkVersion
        self.stateSchemaVersion = stateSchemaVersion
        self.platform = platform
        self.session = session
        self.failure = failure
        self.eligibility = eligibility
        self.integrations = integrations
        self.eventCount = eventCount
        self.droppedEvents = droppedEvents
        self.checkpointKind = checkpointKind
        self.labels = labels
        self.redactionKeys = redactionKeys
        self.redactionHeaders = redactionHeaders
        self.runtime = runtime
        self.capabilities = capabilities
        self.monitoring = monitoring
        self.dependencies = dependencies
        self.journalGapMs = journalGapMs
    }

    init(json j: JSONObject, specVersion: Int = 1) {
        let source = j["source"]?.objectValue ?? JSONObject()
        let sdk = j["sdk"]?.objectValue ?? JSONObject()
        let stats = j["stats"]?.objectValue ?? JSONObject()
        let redaction = j["redaction"]?.objectValue ?? JSONObject()
        let appJ = j["app"]?.objectValue ?? JSONObject()
        capsuleId = j["capsuleId"]?.stringValue ?? ""
        createdAt = ISODate.parse(j["createdAt"]?.stringValue ?? "") ?? Date(timeIntervalSince1970: 0)
        mode = CaptureMode(rawValue: j["mode"]?.stringValue ?? "") ?? .debug
        app = AppInfo(
            id: appJ["id"]?.stringValue, name: appJ["name"]?.stringValue,
            version: appJ["version"]?.stringValue ?? "", build: appJ["build"]?.stringValue ?? "",
            flavor: appJ["flavor"]?.stringValue)
        gitSha = source["gitSha"]?.stringValue
        dirty = source["dirty"]?.boolValue
        sdkName = sdk["name"]?.stringValue ?? "unknown"
        sdkVersion = sdk["version"]?.stringValue ?? "unknown"
        stateSchemaVersion = j["stateSchemaVersion"]?.intValue ?? 1
        platform = PlatformInfo(json: j["platform"]?.objectValue ?? JSONObject())
        session = SessionInfo(json: j["session"]?.objectValue ?? JSONObject())
        failure = j["failure"]?.objectValue.map { FailureRecord(json: $0) }
        eligibility = Eligibility(json: j["eligibility"]?.objectValue ?? JSONObject())
        integrations = (j["integrations"]?.arrayValue ?? []).compactMap(\.stringValue)
        eventCount = stats["eventCount"]?.intValue ?? 0
        droppedEvents = stats["droppedEvents"]?.intValue ?? 0
        checkpointKind = CheckpointKind(rawValue: stats["checkpointKind"]?.stringValue ?? "launch") ?? .launch
        labels = (j["labels"]?.objectValue ?? JSONObject()).compactMap { k, v in v.stringValue.map { (k, $0) } }
        redactionKeys = (redaction["extraKeys"]?.arrayValue ?? []).compactMap(\.stringValue)
        redactionHeaders = (redaction["extraHeaders"]?.arrayValue ?? []).compactMap(\.stringValue)
        runtime = j["runtime"]?.objectValue.map { RuntimeInfo(json: $0) }
        capabilities = (j["capabilities"]?.objectValue ?? JSONObject()).compactMap { k, v in
            v.stringValue.map { (k, $0) }
        }
        monitoring = j["monitoring"]?.objectValue.flatMap(CapsuleMonitoringLink.init(json:))
        dependencies =
            specVersion >= 2
            ? (j["dependencies"]?.arrayValue ?? []).compactMap { $0.objectValue.map(CapsuleDependency.init(json:)) } : []
        journalGapMs = stats["journalGapMs"]?.intValue
    }

    /// Written as spec v2: with interaction dependencies, or a crash
    /// capsule (crash-capsules §2: always v2).
    public var isV2: Bool { !dependencies.isEmpty || failure?.kind == .crash }

    public func dependency(_ id: String) -> CapsuleDependency? { dependencies.first { $0.id == id } }

    public var runtimeName: String { runtime?.name ?? RuntimeInfo.infer(sdkName: sdkName) }

    public func capability(_ key: String) -> String? { capabilities.first { $0.0 == key }?.1 }

    public var json: JSONValue {
        var o: JSONObject = [
            "capsuleId": .string(capsuleId),
            "createdAt": .string(ISODate.format(createdAt)),
            "mode": .string(mode.rawValue),
            "app": app.json,
            "source": ["gitSha": gitSha.map { .string($0) } ?? .null, "dirty": dirty.map { .bool($0) } ?? .null],
            "sdk": ["name": .string(sdkName), "version": .string(sdkVersion)],
            "stateSchemaVersion": .int(stateSchemaVersion),
            "platform": platform.json,
            "session": session.json,
            "failure": failure?.json ?? .null,
            "eligibility": eligibility.json,
            "integrations": .array(integrations.map { .string($0) }),
        ]
        var stats: JSONObject = [
            "eventCount": .int(eventCount), "droppedEvents": .int(droppedEvents),
            "checkpointKind": .string(checkpointKind.rawValue),
        ]
        if let journalGapMs { stats["journalGapMs"] = .int(journalGapMs) }
        o["stats"] = .object(stats)
        var l = JSONObject()
        for (k, v) in labels { l[k] = .string(v) }
        o["labels"] = .object(l)
        if !redactionKeys.isEmpty || !redactionHeaders.isEmpty {
            o["redaction"] = [
                "extraKeys": .array(redactionKeys.map { .string($0) }),
                "extraHeaders": .array(redactionHeaders.map { .string($0) }),
            ]
        }
        if let runtime { o["runtime"] = runtime.json }
        if !capabilities.isEmpty {
            var c = JSONObject()
            for (k, v) in capabilities { c[k] = .string(v) }
            o["capabilities"] = .object(c)
        }
        if let monitoring { o["monitoring"] = monitoring.json }
        if isV2 { o["dependencies"] = .array(dependencies.map(\.json)) }
        return .object(o)
    }

    public static func == (a: CapsuleManifest, b: CapsuleManifest) -> Bool { a.json == b.json }
}

public struct Capsule: Sendable, Equatable {
    public var manifest: CapsuleManifest
    public var checkpoint: Checkpoint
    public var events: [BugCapsuleEvent]

    public init(manifest: CapsuleManifest, checkpoint: Checkpoint, events: [BugCapsuleEvent]) {
        self.manifest = manifest
        self.checkpoint = checkpoint
        self.events = events
    }

    public func events(ofType type: String) -> [BugCapsuleEvent] { events.filter { $0.type == type } }
}

/// ISO-8601 helpers matching the validator's accepted forms.
enum ISODate {
    static func format(_ date: Date) -> String {
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
        let seconds = TimeInterval(ms / 1000)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: seconds))
        let millis = Int(((ms % 1000) + 1000) % 1000)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!,
            millis)
    }

    /// `yyyy-MM-ddTHH:mm[:ss[.fraction]](Z|±hh[:]mm)`.
    static func parse(_ s: String) -> Date? {
        let chars = Array(s.utf8)
        func num(_ from: Int, _ len: Int) -> Int? {
            guard from + len <= chars.count else { return nil }
            var v = 0
            for i in from..<from + len {
                let c = chars[i]
                guard c >= 0x30 && c <= 0x39 else { return nil }
                v = v * 10 + Int(c - 0x30)
            }
            return v
        }
        guard chars.count >= 17, let y = num(0, 4), chars[4] == 0x2D, let mo = num(5, 2), chars[7] == 0x2D,
            let d = num(8, 2), chars[10] == 0x54 || chars[10] == 0x74, let h = num(11, 2), chars[13] == 0x3A,
            let mi = num(14, 2)
        else { return nil }
        var i = 16
        var sec = 0
        var frac = 0.0
        if i < chars.count, chars[i] == 0x3A {
            guard let s2 = num(i + 1, 2) else { return nil }
            sec = s2
            i += 3
            if i < chars.count, chars[i] == 0x2E {
                i += 1
                var scale = 0.1
                while i < chars.count, chars[i] >= 0x30 && chars[i] <= 0x39 {
                    frac += Double(chars[i] - 0x30) * scale
                    scale /= 10
                    i += 1
                }
            }
        }
        guard i < chars.count else { return nil }
        var offset = 0
        if chars[i] == 0x5A || chars[i] == 0x7A {
            i += 1
        } else if chars[i] == 0x2B || chars[i] == 0x2D {
            let sign = chars[i] == 0x2D ? -1 : 1
            guard let oh = num(i + 1, 2) else { return nil }
            var j = i + 3
            if j < chars.count, chars[j] == 0x3A { j += 1 }
            guard let om = num(j, 2) else { return nil }
            offset = sign * (oh * 3600 + om * 60)
            i = j + 2
        } else {
            return nil
        }
        guard i == chars.count else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let base = cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: sec))
        else { return nil }
        return base.addingTimeInterval(frac - TimeInterval(offset))
    }
}
