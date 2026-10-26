import Foundation

// Interaction dependencies (capsule-v2): port of `interactions.dart`.
// Conformance: `spec-fixtures/conformance/interactions.json`.

/// Event types of the interaction families (capsule-v2 §4).
public enum InteractionTypes {
    public static let wsConnect = "ws.connect"
    public static let wsOpen = "ws.open"
    public static let wsSend = "ws.send"
    public static let wsMessage = "ws.message"
    public static let wsError = "ws.error"
    public static let wsClose = "ws.close"

    public static let platformCall = "platform.call"
    public static let platformResult = "platform.result"
    public static let platformError = "platform.error"
    public static let platformListen = "platform.listen"
    public static let platformEvent = "platform.event"
    public static let platformCancel = "platform.cancel"
    public static let platformDone = "platform.done"

    public static let nativeCall = "native.call"
    public static let nativeResult = "native.result"
    public static let nativeError = "native.error"
    public static let nativeSubscribe = "native.subscribe"
    public static let nativeEvent = "native.event"
    public static let nativeCancel = "native.cancel"
    public static let nativeDone = "native.done"

    /// Data fields that hold payload objects.
    public static let payloadFields: [String] = ["payload", "args", "value", "details"]

    /// `ws`, `platform` or `native` for an interaction event type, else nil.
    public static func familyOf(_ type: String) -> String? {
        if type.hasPrefix("ws.") { return "ws" }
        if type.hasPrefix("platform.") { return "platform" }
        if type.hasPrefix("native.") { return "native" }
        return nil
    }

    public static func isInteraction(_ type: String) -> Bool { familyOf(type) != nil }
}

/// `manifest.dependencies[].kind`.
public enum DependencyKinds {
    public static let websocket = "websocket"
    public static let platformChannel = "platform.channel"
    public static let native = "native"
}

/// Gap codes of capsule-v2 §7.
public enum DependencyGaps {
    public static let payloadTruncated = "payload.truncated"
    public static let payloadDropped = "payload.dropped"
    public static let payloadBinaryMetadata = "payload.binaryMetadata"
    public static let payloadRedacted = "payload.redacted"
    public static let connectionsLimit = "connections.limit"
    public static let codecUnsupported = "codec.unsupported"
    public static let channelLate = "channel.late"
    public static let captureFailed = "adapter.captureFailed"
    public static let eventsDropped = "events.dropped"
    /// iOS: the app used an operation the adapter does not record (it ran
    /// live during capture and fails as unrecorded in replay).
    public static let operationUnsupported = "operation.unsupported"
}

public struct DependencyGap: Sendable, Equatable {
    public var code: String
    public var count: Int?
    public var detail: String?

    public init(_ code: String, count: Int? = nil, detail: String? = nil) {
        self.code = code
        self.count = count
        self.detail = detail
    }

    init(json j: JSONObject) {
        code = j["code"]?.stringValue ?? ""
        count = j["count"]?.intValue
        detail = j["detail"]?.stringValue
    }

    public var json: JSONValue {
        var o: JSONObject = ["code": .string(code)]
        if let count { o["count"] = .int(count) }
        if let detail { o["detail"] = .string(detail) }
        return .object(o)
    }
}

public enum DependencyCoverage: String, Sendable { case complete, partial, diagnostic }

/// One entry of `manifest.dependencies` (capsule-v2 §2).
public struct CapsuleDependency: Sendable, Equatable {
    public var id: String
    public var kind: String
    public var adapter: String
    public var adapterVersion: String
    public var schema: Int
    public var required: Bool
    public var coverage: DependencyCoverage
    public var operations: [String]
    /// Package versions the adapter was qualified against.
    public var tested: [(package: String, version: String)]
    public var gaps: [DependencyGap]
    /// `events`, `payloadBytes`, `dropped`, `truncated`.
    public var stats: [(String, Int)]

    public init(
        id: String, kind: String, adapter: String, adapterVersion: String, schema: Int, required: Bool,
        coverage: DependencyCoverage, operations: [String] = [], tested: [(package: String, version: String)] = [],
        gaps: [DependencyGap] = [], stats: [(String, Int)] = []
    ) {
        self.id = id
        self.kind = kind
        self.adapter = adapter
        self.adapterVersion = adapterVersion
        self.schema = schema
        self.required = required
        self.coverage = coverage
        self.operations = operations
        self.tested = tested
        self.gaps = gaps
        self.stats = stats
    }

    init(json j: JSONObject) {
        id = j["id"]?.stringValue ?? ""
        kind = j["kind"]?.stringValue ?? ""
        adapter = j["adapter"]?.stringValue ?? ""
        adapterVersion = j["adapterVersion"]?.stringValue ?? ""
        schema = j["schema"]?.intValue ?? 1
        required = j["required"]?.boolValue ?? true
        coverage = DependencyCoverage(rawValue: j["coverage"]?.stringValue ?? "") ?? .partial
        operations = (j["operations"]?.arrayValue ?? []).compactMap(\.stringValue)
        tested = (j["tested"]?.arrayValue ?? []).compactMap { t in
            guard let o = t.objectValue else { return nil }
            return (package: o["package"]?.stringValue ?? "", version: o["version"]?.stringValue ?? "")
        }
        gaps = (j["gaps"]?.arrayValue ?? []).compactMap { $0.objectValue.map(DependencyGap.init(json:)) }
        stats = (j["stats"]?.objectValue ?? JSONObject()).compactMap { k, v in v.intValue.map { (k, $0) } }
    }

    public var json: JSONValue {
        var o: JSONObject = [
            "id": .string(id), "kind": .string(kind), "adapter": .string(adapter),
            "adapterVersion": .string(adapterVersion), "schema": .int(schema), "required": .bool(required),
            "coverage": .string(coverage.rawValue),
        ]
        if !operations.isEmpty { o["operations"] = .array(operations.map { .string($0) }) }
        if !tested.isEmpty {
            o["tested"] = .array(tested.map { ["package": .string($0.package), "version": .string($0.version)] })
        }
        if !gaps.isEmpty { o["gaps"] = .array(gaps.map(\.json)) }
        if !stats.isEmpty {
            var s = JSONObject()
            for (k, v) in stats { s[k] = .int(v) }
            o["stats"] = .object(s)
        }
        return .object(o)
    }

    public static func == (a: CapsuleDependency, b: CapsuleDependency) -> Bool { a.json == b.json }
}

public enum PayloadMode: String, Sendable { case full, redacted, metadata, omitted, truncated }

/// A payload object (capsule-v2 §3).
public struct InteractionPayload: Sendable, Equatable {
    public var mode: PayloadMode
    public var replayable: Bool
    /// Typed-value JSON (see `TypedValue`); nil when absent.
    public var value: JSONValue?
    public var bytes: Int?
    /// `text`, `binary` or nil (`value`).
    public var kind: String?

    public init(mode: PayloadMode, replayable: Bool, value: JSONValue? = nil, bytes: Int? = nil, kind: String? = nil) {
        self.mode = mode
        self.replayable = replayable
        self.value = value
        self.bytes = bytes
        self.kind = kind
    }

    /// Nil when [json] is not a payload object.
    public init?(json: JSONValue?) {
        guard let o = json?.objectValue, let m = o["mode"]?.stringValue, let mode = PayloadMode(rawValue: m),
            let replayable = o["replayable"]?.boolValue
        else { return nil }
        if let b = o["bytes"], !b.isNull, b.intValue == nil { return nil }
        if let k = o["kind"], !k.isNull, k.stringValue == nil { return nil }
        self.mode = mode
        self.replayable = replayable
        value = o["value"]
        bytes = o["bytes"]?.intValue
        kind = o["kind"]?.stringValue
    }

    public static let none = InteractionPayload(mode: .full, replayable: true)

    /// The Swift value replay hands the app.
    public var decoded: Any? { TypedValue.decode(value ?? .null) }

    /// Whether this recording and [other] carry the same value (canonical
    /// JSON), for mismatch checks. Non-replayable payloads compare by size.
    public func sameAs(_ other: InteractionPayload) -> Bool {
        if !replayable || !other.replayable { return bytes == other.bytes && kind == other.kind }
        return RequestKeyBuilder.canonicalJSON(value ?? .null) == RequestKeyBuilder.canonicalJSON(other.value ?? .null)
    }

    public var json: JSONValue {
        var o: JSONObject = ["mode": .string(mode.rawValue), "replayable": .bool(replayable)]
        if replayable || (value != nil && value != .null) { o["value"] = value ?? .null }
        if let bytes { o["bytes"] = .int(bytes) }
        if let kind { o["kind"] = .string(kind) }
        return .object(o)
    }
}

/// Bounds of capsule-v2 §7.
public struct InteractionLimits: Sendable, Equatable {
    /// Per payload (encoded JSON).
    public var maxPayloadBytes: Int
    /// Interaction payloads retained in the recorder window, all adapters.
    public var maxWindowPayloadBytes: Int
    /// Captured connections and subscriptions open at the same time.
    public var maxActive: Int
    /// Matches the flight recorder window: older payloads no longer count.
    public var windowMs: Int

    public init(
        maxPayloadBytes: Int = 64 * 1024, maxWindowPayloadBytes: Int = 1024 * 1024, maxActive: Int = 32,
        windowMs: Int = 5 * 60 * 1000
    ) {
        self.maxPayloadBytes = maxPayloadBytes
        self.maxWindowPayloadBytes = maxWindowPayloadBytes
        self.maxActive = maxActive
        self.windowMs = windowMs
    }

    public func lowered(maxPayloadBytes: Int? = nil, maxWindowBytes: Int? = nil) -> InteractionLimits {
        func lower(_ a: Int, _ b: Int?) -> Int { b == nil || b! > a ? a : b! }
        return InteractionLimits(
            maxPayloadBytes: lower(self.maxPayloadBytes, maxPayloadBytes),
            maxWindowPayloadBytes: lower(maxWindowPayloadBytes, maxWindowBytes), maxActive: maxActive,
            windowMs: windowMs)
    }
}

/// Shared payload byte budget of every adapter in a session: a rolling
/// window so a long session keeps recording recent traffic. Thread-safe.
public final class PayloadBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var _limits: InteractionLimits
    private var spent: [(Int, Int)] = []
    private var head = 0
    private var total = 0

    public init(_ limits: InteractionLimits) { _limits = limits }

    public var limits: InteractionLimits {
        get { lock.locked { _limits } }
        set { lock.locked { _limits = newValue } }
    }

    public func spend(now: Int, bytes: Int) -> Bool {
        lock.locked {
            while head < spent.count && spent[head].0 < now - _limits.windowMs {
                total -= spent[head].1
                head += 1
            }
            if head > 1024 && head * 2 > spent.count {
                spent.removeFirst(head)
                head = 0
            }
            if total + bytes > _limits.maxWindowPayloadBytes { return false }
            spent.append((now, bytes))
            total += bytes
            return true
        }
    }
}

/// Per-dependency capture bookkeeping: gaps and stats for the manifest.
/// Thread-safe.
public final class DependencyStats: @unchecked Sendable {
    private let lock = NSLock()
    private var _events = 0
    private var _payloadBytes = 0
    private var _dropped = 0
    private var _truncated = 0
    private var gapOrder: [String] = []
    private var gapMap: [String: (Int, String?)] = [:]

    public init() {}

    public var events: Int { lock.locked { _events } }
    public var payloadBytes: Int { lock.locked { _payloadBytes } }
    public var dropped: Int { lock.locked { _dropped } }
    public var truncated: Int { lock.locked { _truncated } }

    func addEvent() { lock.locked { _events += 1 } }
    func addPayloadBytes(_ n: Int) { lock.locked { _payloadBytes += n } }
    func addDropped() { lock.locked { _dropped += 1 } }
    func addTruncated() { lock.locked { _truncated += 1 } }

    public func gap(_ code: String, _ detail: String? = nil) {
        lock.locked {
            if let (n, d) = gapMap[code] {
                gapMap[code] = (n + 1, d ?? detail)
            } else {
                gapOrder.append(code)
                gapMap[code] = (1, detail)
            }
        }
    }

    public var hasGaps: Bool { lock.locked { !gapOrder.isEmpty } }

    public var gaps: [DependencyGap] {
        lock.locked { gapOrder.map { DependencyGap($0, count: gapMap[$0]!.0, detail: gapMap[$0]!.1) } }
    }

    public var json: [(String, Int)] {
        lock.locked { [("events", _events), ("payloadBytes", _payloadBytes), ("dropped", _dropped), ("truncated", _truncated)] }
    }
}

/// Turns live values into payload objects: typed encoding, redaction,
/// binary policy, size limits and the shared budget.
public final class PayloadEncoder: @unchecked Sendable {
    public let redactor: @Sendable () -> Redactor
    public let budget: PayloadBudget
    public let stats: DependencyStats
    public let now: @Sendable () -> Int
    /// Binary values (byte frames, typed arrays) are kept only when true;
    /// otherwise recorded as metadata.
    public var captureBinary: Bool
    /// Whether a value the redactor changed can still be replayed (the app
    /// does not branch on the redacted fields).
    public var redactedReplayable: Bool

    public init(
        redactor: @escaping @Sendable () -> Redactor, budget: PayloadBudget, stats: DependencyStats,
        now: @escaping @Sendable () -> Int, captureBinary: Bool = false, redactedReplayable: Bool = false
    ) {
        self.redactor = redactor
        self.budget = budget
        self.stats = stats
        self.now = now
        self.captureBinary = captureBinary
        self.redactedReplayable = redactedReplayable
    }

    /// Encodes [value]. [kind] is `text`/`binary` for WebSocket frames.
    public func encode(_ value: Any?, kind: String? = nil) -> InteractionPayload {
        let raw = TypedValue.unwrap(value)
        let typed: JSONValue = (raw as? String).map { .string($0) } ?? TypedValue.encode(raw)
        let size = Self.size(raw, typed)
        if !captureBinary && (kind == "binary" || TypedValue.hasBinary(typed)) {
            stats.gap(
                DependencyGaps.payloadBinaryMetadata, "binary data recorded as metadata; register a serializer to keep it")
            return InteractionPayload(mode: .metadata, replayable: false, bytes: size, kind: kind)
        }
        let (redacted, changed) = TypedValue.redact(typed, redactor())
        let encodedLength = JSON.encode(redacted).dartLength
        let limits = budget.limits
        if encodedLength > limits.maxPayloadBytes {
            stats.addTruncated()
            stats.gap(DependencyGaps.payloadTruncated)
            return InteractionPayload(mode: .truncated, replayable: false, bytes: size, kind: kind)
        }
        if !budget.spend(now: now(), bytes: encodedLength) {
            stats.addDropped()
            stats.gap(DependencyGaps.payloadDropped, "capsule payload budget spent")
            return InteractionPayload(mode: .metadata, replayable: false, bytes: size, kind: kind)
        }
        stats.addPayloadBytes(encodedLength)
        if changed { stats.gap(DependencyGaps.payloadRedacted) }
        let replayable = TypedValue.isReplayable(redacted) && (!changed || redactedReplayable)
        return InteractionPayload(
            mode: changed ? .redacted : .full, replayable: replayable, value: redacted, bytes: size, kind: kind)
    }

    /// The match-key input for [value]: encoded and redacted like a payload,
    /// whatever the capture limits (so capture and replay agree).
    public func keyInput(_ value: Any?) -> JSONValue {
        TypedValue.redact(TypedValue.encode(value), redactor()).0
    }

    /// UTF-8 bytes for text, byte/element count for binary, encoded JSON
    /// size (UTF-16 code units, as Dart's `jsonEncode(...).length`) otherwise.
    static func size(_ value: Any?, _ typed: JSONValue) -> Int {
        switch value {
        case let s as String: return s.utf8.count
        case let d as Data: return d.count
        case let a as [UInt8]: return a.count
        case let a as [Int32]: return a.count
        case let a as [Int64]: return a.count
        default: return JSON.encode(typed).dartLength
        }
    }
}

/// `<scope>|<method>|<hash of canonical args>` (capsule-v2 §5).
public func interactionKey(_ scope: String, _ method: String?, _ args: JSONValue) -> String {
    "\(scope)|\(method ?? "")|\(RequestKeyBuilder.hash(RequestKeyBuilder.canonicalJSON(args)))"
}

/// Counts occurrences per key on the capture side. Thread-safe.
public final class OccurrenceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    public init() {}

    public func next(_ key: String) -> Int {
        lock.locked {
            let n = counts[key, default: 0]
            counts[key] = n + 1
            return n
        }
    }
}

/// A recorded interaction event plus its scheduling metadata.
public final class RecordedInteraction: @unchecked Sendable, CustomStringConvertible {
    public let event: BugCapsuleEvent
    public let scope: String
    public let outbound: Bool
    /// For inbound events: the outbound event that releases it.
    public internal(set) weak var anchor: RecordedInteraction?
    var hasAnchor = false
    public internal(set) var consumed = false
    /// Replay-clock time this event was matched (outbound) or delivered.
    public internal(set) var at: Int?
    public internal(set) var dueAt: Int?

    init(_ event: BugCapsuleEvent, _ scope: String, _ outbound: Bool) {
        self.event = event
        self.scope = scope
        self.outbound = outbound
    }

    public var type: String { event.type }
    public var family: String { InteractionTypes.familyOf(event.type)! }
    public var data: JSONObject { event.data }
    public var dep: String { data["dep"]?.stringValue ?? "" }

    public func payload(_ field: String) -> InteractionPayload? { InteractionPayload(json: data[field]) }

    public var description: String { "\(event.type)#\(event.seq)" }
}

/// The scheduling scope and direction of an interaction event (§5): the
/// scope orders deliveries and is what an adapter binds a handler to.
func interactionScope(_ e: BugCapsuleEvent, callDirections: [String: String]) -> (String, Bool)? {
    let d = e.data
    func s(_ k: String) -> String { scopeString(d[k]) }
    switch e.type {
    case InteractionTypes.wsConnect, InteractionTypes.wsSend:
        return ("ws:\(s("conn"))", true)
    case InteractionTypes.wsClose:
        return ("ws:\(s("conn"))", d["initiator"] == .string("client"))
    case InteractionTypes.wsOpen, InteractionTypes.wsMessage, InteractionTypes.wsError:
        return ("ws:\(s("conn"))", false)
    case InteractionTypes.platformCall:
        return d["dir"] == .string("platform") ? ("platform.in:\(s("channel"))", false) : ("platform.call:\(s("call"))", true)
    case InteractionTypes.platformResult, InteractionTypes.platformError:
        // The reply to a platform-to-Dart call is the app's own (outbound).
        return ("platform.call:\(s("call"))", callDirections[s("call")] == "platform")
    case InteractionTypes.platformListen, InteractionTypes.platformCancel:
        return ("platform.sub:\(s("sub"))", true)
    case InteractionTypes.platformEvent, InteractionTypes.platformDone:
        return ("platform.sub:\(s("sub"))", false)
    case InteractionTypes.nativeCall:
        return ("native.op:\(s("op"))", true)
    case InteractionTypes.nativeResult:
        return ("native.op:\(s("op"))", false)
    case InteractionTypes.nativeError:
        return d["sub"].map { !$0.isNull } == true ? ("native.sub:\(s("sub"))", false) : ("native.op:\(s("op"))", false)
    case InteractionTypes.nativeSubscribe, InteractionTypes.nativeCancel:
        return ("native.sub:\(s("sub"))", true)
    case InteractionTypes.nativeEvent, InteractionTypes.nativeDone:
        return ("native.sub:\(s("sub"))", false)
    default:
        return nil
    }
}

/// Dart's `'${value}'` for scope ids (strings as-is, null as "null").
func scopeString(_ v: JSONValue?) -> String {
    switch v {
    case nil, .null?: return "null"
    case .string(let s)?: return s
    case let x?: return JSON.encode(x)
    }
}

/// Replay of interaction dependencies (capsule-v2 §5), without timers: the
/// runtime calls `pump` when `nextDueAt` arrives. Same semantics as the Dart
/// `InteractionScript`. Not thread-safe: the runtime serializes access.
///
/// Adapters consume outbound expectations with `take` (keyed operations:
/// connects, calls, listens) or `takeNext` (ordered operations within a
/// scope: sends, cancels, replies), and `bind` a handler to a scope to
/// receive its inbound events. Each inbound event is released by its anchor
/// (the latest outbound event of its scope before it) and delivered
/// `t(inbound) - t(anchor)` after the anchor was matched; events without an
/// anchor follow the replay clock once `runStarted`.
public final class InteractionScript: @unchecked Sendable {
    /// Replay clock in milliseconds (monotonic, includes skipped idle time).
    public let clock: @Sendable () -> Int
    /// Recorded time replay starts from: 0 for a launch checkpoint, the
    /// checkpoint time for a periodic one.
    public let base: Int
    /// How long a due event may wait for its scope's handler.
    public let maxHandlerWaitMs: Int

    private var _all: [RecordedInteraction] = []
    private var keyed: [String: [RecordedInteraction]] = [:]
    private var keyedOrder: [String] = []
    private var ordered: [String: [RecordedInteraction]] = [:]
    private var released: [ObjectIdentifier: [RecordedInteraction]] = [:]
    private var unanchored: [RecordedInteraction] = []
    private var pending: [RecordedInteraction] = []
    private var handlers: [String: (RecordedInteraction) -> Void] = [:]
    private var lastDue: [String: Int] = [:]
    private var divergences: [(String, String)] = []
    private var runStart: Int?

    public init(
        events: [BugCapsuleEvent], dependencies: Set<String>, clock: @escaping @Sendable () -> Int, base: Int = 0,
        maxHandlerWaitMs: Int = 5000
    ) {
        self.clock = clock
        self.base = base
        self.maxHandlerWaitMs = maxHandlerWaitMs
        var calls: [String: String] = [:]
        for e in events where e.type == InteractionTypes.platformCall {
            calls[scopeString(e.data["call"])] = scopeString(e.data["dir"])
        }
        var lastOutbound: [String: RecordedInteraction] = [:]
        for e in events {
            guard InteractionTypes.isInteraction(e.type) else { continue }
            guard let dep = e.data["dep"]?.stringValue, dependencies.contains(dep) else { continue }
            if e.data["diagnostic"] == .bool(true) { continue }
            guard let (scope, outbound) = interactionScope(e, callDirections: calls) else { continue }
            let r = RecordedInteraction(e, scope, outbound)
            _all.append(r)
            let channelScope = e.type.hasPrefix("platform.") ? "channel:\(scopeString(e.data["channel"]))" : nil
            if outbound {
                lastOutbound[scope] = r
                if let channelScope { lastOutbound[channelScope] = r }
                if case .string(let key)? = e.data["key"] {
                    let k = "\(r.dep)|\(e.type)|\(key)"
                    if keyed[k] == nil { keyedOrder.append(k) }
                    keyed[k, default: []].append(r)
                } else {
                    ordered[scope, default: []].append(r)
                }
            } else {
                let anchor = e.type == InteractionTypes.platformCall
                    ? channelScope.flatMap { lastOutbound[$0] } : lastOutbound[scope]
                if let anchor {
                    r.anchor = anchor
                    r.hasAnchor = true
                    released[ObjectIdentifier(anchor), default: []].append(r)
                } else {
                    unanchored.append(r)
                }
            }
        }
    }

    /// Recorded interactions (for preflight and inspection).
    public var all: [RecordedInteraction] { _all }

    public var isEmpty: Bool { _all.isEmpty }

    /// Divergences found while scheduling (undelivered events), drained by
    /// the runtime.
    public func takeDivergences() -> [(String, String)] {
        let out = divergences
        divergences = []
        return out
    }

    /// Matches a keyed outbound operation (`ws.connect`, `platform.call`,
    /// `platform.listen`, `native.call`, `native.subscribe`) by key and
    /// invocation order. Nil: nothing recorded (the caller reports
    /// `<family>.unrecorded` and fails the operation).
    public func take(dep: String, type: String, key: String) -> RecordedInteraction? {
        let k = "\(dep)|\(type)|\(key)"
        guard var queue = keyed[k] else { return nil }
        defer { keyed[k] = queue }
        while !queue.isEmpty {
            let r = queue.removeFirst()
            if r.consumed { continue }
            consume(r)
            return r
        }
        return nil
    }

    /// Unmatched keyed operations of [type] in [dep] whose key starts with
    /// [prefix]: lets an adapter tell a payload mismatch from an unrecorded
    /// operation.
    public func hasUnconsumed(dep: String, type: String, prefix: String) -> Bool {
        let p = "\(dep)|\(type)|\(prefix)"
        for k in keyedOrder where k.hasPrefix(p) {
            if keyed[k]?.contains(where: { !$0.consumed }) == true { return true }
        }
        return false
    }

    /// Matches the next unconsumed outbound event of [types] in [scope], in
    /// recorded order (sends on a connection, a client close, a cancel, the
    /// app's reply to a platform call).
    public func takeNext(scope: String, types: Set<String>) -> RecordedInteraction? {
        guard let list = ordered[scope] else { return nil }
        for r in list where !r.consumed && types.contains(r.type) {
            consume(r)
            return r
        }
        return nil
    }

    /// The next unconsumed outbound event of [types] in [scope] without
    /// consuming it.
    public func peekNext(scope: String, types: Set<String>) -> RecordedInteraction? {
        ordered[scope]?.first { !$0.consumed && types.contains($0.type) }
    }

    private func consume(_ r: RecordedInteraction) {
        let now = clock()
        r.consumed = true
        r.at = now
        for inbound in released[ObjectIdentifier(r)] ?? [] {
            schedule(inbound, now + (inbound.event.t - r.event.t))
        }
    }

    private func schedule(_ r: RecordedInteraction, _ due: Int) {
        let last = lastDue[r.scope]
        let at = last.map { $0 > due ? $0 : due } ?? due
        lastDue[r.scope] = at
        r.dueAt = at
        pending.append(r)
    }

    /// Replay of recorded input started at replay time [at], which
    /// corresponds to recorded time `base`. Events without an anchor become
    /// due on this clock.
    public func runStarted(at: Int) {
        runStart = at
        for r in unanchored where r.dueAt == nil && !r.consumed {
            schedule(r, at + (r.event.t - base))
        }
        sortPending()
    }

    /// Events without an anchor recorded before the replayed window started
    /// (e.g. platform calls before the first frame) are due as soon as their
    /// handler exists.
    private func scheduleEarly(_ scope: String) {
        if runStart != nil { return }
        for r in unanchored where r.scope == scope && r.dueAt == nil && !r.consumed {
            if r.event.t < base { schedule(r, clock()) }
        }
    }

    /// Delivers inbound events of [scope] to [handler] from now on (and any
    /// already due).
    public func bind(_ scope: String, _ handler: @escaping (RecordedInteraction) -> Void) {
        handlers[scope] = handler
        scheduleEarly(scope)
    }

    public func unbind(_ scope: String) { handlers[scope] = nil }

    public func isBound(_ scope: String) -> Bool { handlers[scope] != nil }

    /// Earliest time an event is due whose handler is bound; nil when
    /// nothing is scheduled. Events waiting for a handler do not count (an
    /// open but idle subscription must not hold replay busy).
    public var nextDueAt: Int? {
        var next: Int?
        for r in pending where handlers[r.scope] != nil {
            let due = r.dueAt!
            if next == nil || due < next! { next = due }
        }
        return next
    }

    /// Whether any scheduled event waits for a handler.
    public var hasWaiting: Bool { pending.contains { handlers[$0.scope] == nil } }

    /// Delivers every event due at or before now, in (due, seq) order.
    /// Returns how many were delivered.
    @discardableResult
    public func pump() -> Int {
        let now = clock()
        sortPending()
        var delivered = 0
        var keep: [RecordedInteraction] = []
        var due: [RecordedInteraction] = []
        for r in pending {
            if r.dueAt! > now {
                keep.append(r)
                continue
            }
            if handlers[r.scope] == nil {
                if now - r.dueAt! > maxHandlerWaitMs {
                    r.consumed = true
                    divergences.append(("\(r.family).undelivered", "\(Self.describe(r)): no handler for \(now - r.dueAt!) ms"))
                } else {
                    keep.append(r)
                }
                continue
            }
            due.append(r)
        }
        pending = keep
        for r in due {
            r.consumed = true
            r.at = now
            guard let handler = handlers[r.scope] else {
                // Unbound by an earlier delivery in this batch (a close).
                pending.append(r)
                continue
            }
            handler(r)
            delivered += 1
        }
        return delivered
    }

    private func sortPending() {
        pending.sort { a, b in
            if a.dueAt! != b.dueAt! { return a.dueAt! < b.dueAt! }
            return a.event.seq < b.event.seq
        }
    }

    /// Unmatched and undelivered recorded interactions, grouped by family and
    /// scope: `<family>.unused` when recorded at or before [failureT] (or
    /// with no failure), `<family>.unusedAfterFailure` after it.
    public func unused(failureT: Int?) -> [(String, String)] {
        var order: [String] = []
        var groups: [String: (String, Bool, String, [RecordedInteraction])] = [:]
        for r in _all where !r.consumed {
            let after = failureT.map { r.event.t > $0 } ?? false
            let k = "\(r.family)|\(after)|\(r.scope)"
            if groups[k] == nil {
                order.append(k)
                groups[k] = (r.family, after, r.scope, [])
            }
            groups[k]!.3.append(r)
        }
        return order.map { k in
            let (family, after, scope, list) = groups[k]!
            return ("\(family).\(after ? "unusedAfterFailure" : "unused")", "\(scope): \(Self.summary(list))")
        }
    }

    static func summary(_ list: [RecordedInteraction]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for r in list {
            if counts[r.type] == nil { order.append(r.type) }
            counts[r.type, default: 0] += 1
        }
        let parts = order.map { counts[$0]! > 1 ? "\($0)×\(counts[$0]!)" : $0 }
        return "\(parts.joined(separator: ", ")) from \(list[0].event.t)ms"
    }

    static func describe(_ r: RecordedInteraction) -> String { "\(r.scope) \(r.type) @\(r.event.t)ms" }
}
