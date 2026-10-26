import Foundation

/// What an interaction adapter declares about itself (capsule-v2 §2): the
/// `manifest.dependencies` entry it produces and what it can replay.
public struct BugCapsuleAdapterDescriptor: Sendable, Equatable {
    /// Dependency id in capsules (`data.dep`), unique per session.
    public var dependencyId: String
    /// `websocket`, `platform.channel` or `native`.
    public var kind: String
    /// Adapter identity, e.g. `bugcapsule-ios.urlsession-websocket`, `acme.location`.
    public var adapter: String
    public var adapterVersion: String
    /// Version of the event payloads this adapter records.
    public var schema: Int
    /// Payload schemas this adapter can replay (preflight `dependency.schema`).
    public var replaySchemas: ClosedRange<Int>
    /// false: diagnostic capture only, never served during replay.
    public var required: Bool
    /// Operations the adapter records and replays. Others run live during
    /// capture with an `operation.unsupported` gap and fail in replay.
    public var operations: [String]
    /// Package versions the adapter was qualified against.
    public var tested: [BugCapsuleTestedPackage]
    /// Keep binary values (byte frames, typed arrays) instead of metadata.
    public var captureBinary: Bool
    /// Payloads the redactor changed stay replayable (the app does not
    /// branch on the redacted fields).
    public var redactedReplayable: Bool
    /// Argument fields removed before hashing match keys (capture and
    /// replay alike): values that differ on every run (timestamps, nonces).
    public var nondeterministicFields: Set<String>

    public init(
        dependencyId: String, kind: String = DependencyKinds.native, adapter: String, adapterVersion: String,
        schema: Int = 1, replaySchemas: ClosedRange<Int>? = nil, required: Bool = true, operations: [String] = [],
        tested: [BugCapsuleTestedPackage] = [], captureBinary: Bool = false, redactedReplayable: Bool = false,
        nondeterministicFields: Set<String> = []
    ) {
        self.dependencyId = dependencyId
        self.kind = kind
        self.adapter = adapter
        self.adapterVersion = adapterVersion
        self.schema = schema
        self.replaySchemas = replaySchemas ?? schema...schema
        self.required = required
        self.operations = operations
        self.tested = tested
        self.captureBinary = captureBinary
        self.redactedReplayable = redactedReplayable
        self.nondeterministicFields = nondeterministicFields
    }
}

public struct BugCapsuleTestedPackage: Sendable, Equatable {
    public var package: String
    public var version: String
    public init(_ package: String, _ version: String) {
        self.package = package
        self.version = version
    }
}

/// An entry of `checkpoint.data.interactions.open` (capsule-v2 §6).
public struct BugCapsuleOpenInteraction: Sendable, Equatable {
    public var dep: String
    /// `ws`, `platform` or `native`.
    public var type: String
    /// Connection or subscription id.
    public var id: String
    public var restorable: Bool

    public init(dep: String, type: String, id: String, restorable: Bool = false) {
        self.dep = dep
        self.type = type
        self.id = id
        self.restorable = restorable
    }

    init?(json: JSONValue) {
        guard let o = json.objectValue, let dep = o["dep"]?.stringValue, let type = o["type"]?.stringValue,
            let id = o["id"]?.stringValue
        else { return nil }
        self.init(dep: dep, type: type, id: id, restorable: o["restorable"]?.boolValue ?? false)
    }

    var json: JSONValue {
        ["dep": .string(dep), "type": .string(type), "id": .string(id), "restorable": .bool(restorable)]
    }
}

/// Capture-side state of one dependency: payload encoder, stats and gaps,
/// occurrence counters and the interactions open right now.
final class DependencyRecorder: @unchecked Sendable {
    let descriptor: BugCapsuleAdapterDescriptor
    let stats = DependencyStats()
    let encoder: PayloadEncoder
    let occurrences = OccurrenceCounter()
    private unowned let runtime: InteractionRuntime
    private let lock = NSLock()
    private var nextId = 0
    private var open: [(id: String, type: String, restorable: @Sendable () -> Bool)] = []

    init(_ descriptor: BugCapsuleAdapterDescriptor, runtime: InteractionRuntime) {
        self.descriptor = descriptor
        self.runtime = runtime
        encoder = PayloadEncoder(
            redactor: { [unowned runtime] in runtime.redactor() }, budget: runtime.budget, stats: stats,
            now: { [unowned runtime] in runtime.now() }, captureBinary: descriptor.captureBinary,
            redactedReplayable: descriptor.redactedReplayable)
    }

    var id: String { descriptor.dependencyId }

    /// A new id (`<prefix><n>`) unique in this session.
    func newId(_ prefix: String) -> String {
        lock.locked {
            nextId += 1
            return "\(prefix)\(nextId)"
        }
    }

    /// Records an interaction event of this dependency.
    func emit(_ type: String, _ data: JSONObject) {
        var d: JSONObject = ["dep": .string(id)]
        for (k, v) in data where k != "dep" { d[k] = v }
        stats.addEvent()
        runtime.record(type, d)
    }

    func payload(_ value: Any?, kind: String? = nil) -> InteractionPayload { encoder.encode(value, kind: kind) }

    /// `<scope>|<method>|<hash>` of the redacted, normalized arguments.
    func key(_ scope: String, _ method: String?, _ args: Any?) -> String {
        interactionKey(scope, method, Self.strip(encoder.keyInput(args), descriptor.nondeterministicFields))
    }

    static func strip(_ value: JSONValue, _ fields: Set<String>) -> JSONValue {
        guard !fields.isEmpty else { return value }
        switch value {
        case .object(let o):
            var out = JSONObject()
            for (k, v) in o where !fields.contains(k) { out[k] = strip(v, fields) }
            return .object(out)
        case .array(let a): return .array(a.map { strip($0, fields) })
        default: return value
        }
    }

    func gap(_ code: String, _ detail: String? = nil) { stats.gap(code, detail) }

    func opened(_ id: String, type: String, restorable: @escaping @Sendable () -> Bool = { false }) {
        lock.locked { open.append((id, type, restorable)) }
    }

    func closed(_ id: String) { lock.locked { open.removeAll { $0.id == id } } }

    var openInteractions: [BugCapsuleOpenInteraction] {
        lock.locked { open.map { BugCapsuleOpenInteraction(dep: id, type: $0.type, id: $0.id, restorable: $0.restorable()) } }
    }
}

/// Interaction dependencies of one session (capsule-v2): which adapters are
/// installed, capture bookkeeping shared by all of them (payload budget,
/// active connection limit, remote kill switch) and, in replay, the
/// scheduler. The runtime of a `BugCapsuleSession`, or of
/// `BugCapsuleAdapterConformance` for offline adapter tests.
final class InteractionRuntime: @unchecked Sendable {
    let budget: PayloadBudget
    private let lock = NSLock()
    private var recorders: [String: DependencyRecorder] = [:]
    private var recorderOrder: [String] = []
    private var installed: [String: BugCapsuleAdapterDescriptor] = [:]
    private var disabled: Set<String> = []
    private var active = 0
    private var _replay: InteractionReplay?

    // Host hooks (session or conformance harness).
    let record: @Sendable (String, JSONObject) -> Void
    let now: @Sendable () -> Int
    let redactor: @Sendable () -> Redactor
    let recording: @Sendable () -> Bool

    init(
        limits: InteractionLimits = InteractionLimits(), record: @escaping @Sendable (String, JSONObject) -> Void,
        now: @escaping @Sendable () -> Int, redactor: @escaping @Sendable () -> Redactor,
        recording: @escaping @Sendable () -> Bool
    ) {
        budget = PayloadBudget(limits)
        self.record = record
        self.now = now
        self.redactor = redactor
        self.recording = recording
    }

    var limits: InteractionLimits { budget.limits }

    // MARK: adapters

    /// Declares an installed adapter (preflight looks it up by adapter id).
    func install(_ d: BugCapsuleAdapterDescriptor) {
        lock.locked { installed[d.adapter] = d }
    }

    func installedAdapter(_ adapter: String) -> BugCapsuleAdapterDescriptor? { lock.locked { installed[adapter] } }

    var installedAdapters: [BugCapsuleAdapterDescriptor] { lock.locked { Array(installed.values) } }

    /// The capture recorder of [d] (created on first use).
    func recorder(_ d: BugCapsuleAdapterDescriptor) -> DependencyRecorder {
        lock.locked {
            if let r = recorders[d.dependencyId] { return r }
            let r = DependencyRecorder(d, runtime: self)
            recorders[d.dependencyId] = r
            recorderOrder.append(d.dependencyId)
            return r
        }
    }

    func recorder(forDependency id: String) -> DependencyRecorder? { lock.locked { recorders[id] } }

    // MARK: capture switches

    /// Remote config `disabledAdapters` (capsule-v2 §7): those adapters stop
    /// recording; HTTP capture is unaffected. Returns the dependency ids of
    /// newly disabled adapters (their buffered events are dropped).
    @discardableResult
    func setDisabledAdapters(_ adapters: Set<String>) -> Set<String> {
        lock.locked {
            let added = adapters.subtracting(disabled)
            disabled = adapters
            return Set(recorders.values.filter { added.contains($0.descriptor.adapter) }.map(\.id))
        }
    }

    func isDisabled(_ adapter: String) -> Bool { lock.locked { disabled.contains(adapter) } }

    var disabledAdapters: Set<String> { lock.locked { disabled } }

    /// Whether [adapter] records right now (session recording, not replaying,
    /// not switched off remotely).
    func captures(_ adapter: String) -> Bool {
        replay == nil && recording() && !isDisabled(adapter)
    }

    /// Takes one of the `maxActive` capture slots for a connection or
    /// subscription; false: not captured (`connections.limit` gap).
    func acquireActive() -> Bool {
        lock.locked {
            if active >= budget.limits.maxActive { return false }
            active += 1
            return true
        }
    }

    func releaseActive() { lock.locked { active = max(active - 1, 0) } }

    // MARK: replay

    var replay: InteractionReplay? {
        get { lock.locked { _replay } }
        set { lock.locked { _replay = newValue } }
    }

    // MARK: capsule

    /// `checkpoint.data.interactions` for a periodic checkpoint: every
    /// captured connection and subscription open now.
    func checkpointData() -> JSONValue? {
        let open = lock.locked { recorderOrder.compactMap { recorders[$0] } }.flatMap(\.openInteractions)
        if open.isEmpty { return nil }
        return ["open": .array(open.map(\.json))]
    }

    /// The `manifest.dependencies` of a capsule with [events] and
    /// [checkpoint], plus eligibility entries (§7: a dependency with gaps;
    /// §6: open interactions a periodic checkpoint cannot restore).
    func manifestDependencies(
        events: [BugCapsuleEvent], checkpoint: Checkpoint, eligibility: EligibilityBuilder
    ) -> [CapsuleDependency] {
        var counts: [String: Int] = [:]
        for e in events where InteractionTypes.isInteraction(e.type) {
            if let dep = e.data["dep"]?.stringValue { counts[dep, default: 0] += 1 }
        }
        let open = (checkpoint.data["interactions"]?["open"]?.arrayValue ?? []).compactMap(BugCapsuleOpenInteraction.init(json:))
        let used = Set(counts.keys).union(open.map(\.dep))
        let list = lock.locked { recorderOrder.compactMap { recorders[$0] } }
        var out: [CapsuleDependency] = []
        for r in list where used.contains(r.id) {
            let d = r.descriptor
            let gaps = r.stats.gaps
            let coverage: DependencyCoverage = !d.required ? .diagnostic : gaps.isEmpty ? .complete : .partial
            var stats = r.stats.json
            stats[0] = ("events", counts[r.id] ?? 0)
            out.append(
                CapsuleDependency(
                    id: r.id, kind: d.kind, adapter: d.adapter, adapterVersion: d.adapterVersion, schema: d.schema,
                    required: d.required, coverage: coverage, operations: Array(d.operations.prefix(100)),
                    tested: d.tested.prefix(20).map { (package: $0.package, version: $0.version) },
                    gaps: Array(gaps.prefix(100)), stats: stats))
            if !gaps.isEmpty {
                eligibility.missing(
                    "dependency.\(r.id)",
                    "\(d.adapter) recorded partially: " + gaps.map { "\($0.code)×\($0.count ?? 1)" }.joined(separator: ", "))
            }
        }
        if checkpoint.kind == .periodic, open.contains(where: { !$0.restorable }) {
            let ids = open.filter { !$0.restorable }.map { "\($0.dep)/\($0.id)" }
            eligibility.missing(
                "interactions.restore",
                "connections or subscriptions open at the checkpoint cannot be restored: \(ids.joined(separator: ", "))",
                blocking: true)
        }
        return out
    }

    /// Preflight (capsule-v2 §2): nil when every required dependency of
    /// [capsule] can be replayed, otherwise the `incompatible` message.
    func preflight(_ capsule: Capsule) -> String? {
        for dep in capsule.manifest.dependencies where dep.required {
            guard let installed = installedAdapter(dep.adapter) else {
                return "dependency.unsupported: \(dep.id) needs adapter \(dep.adapter) \(dep.adapterVersion) "
                    + "(schema \(dep.schema)), which this app does not install"
            }
            if !installed.replaySchemas.contains(dep.schema) {
                return "dependency.schema: \(dep.id) was recorded with \(dep.adapter) schema \(dep.schema); "
                    + "the installed \(installed.adapterVersion) replays schema \(installed.replaySchemas.lowerBound)"
                    + (installed.replaySchemas.count > 1 ? "-\(installed.replaySchemas.upperBound)" : "")
            }
        }
        if capsule.checkpoint.kind == .periodic {
            let open = (capsule.checkpoint.data["interactions"]?["open"]?.arrayValue ?? [])
                .compactMap(BugCapsuleOpenInteraction.init(json:))
            let required = Set(capsule.manifest.dependencies.filter(\.required).map(\.id))
            if let o = open.first(where: { required.contains($0.dep) && !$0.restorable }) {
                return "dependency.unrestorable: \(o.dep) \(o.type) \(o.id) was open at the checkpoint and cannot be restored"
            }
        }
        return nil
    }
}
