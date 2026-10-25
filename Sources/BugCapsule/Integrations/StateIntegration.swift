import Foundation

/// App state objects snapshotted into checkpoints (`checkpoint.data.state`)
/// and restored in replay.
///
/// ```swift
/// BugCapsule.registerState("cart.session",
///     snapshot: { ["coupon": .string(store.coupon)] },
///     restore: { json in store.coupon = json["coupon"]?.stringValue ?? "" })
/// ```
///
/// Replay restores a key when it is registered. Registering after the
/// first replayed input reports `restore.late`; checkpoint keys never
/// registered report `restore.missing`; placeholders report `state.redacted`.
public final class BugCapsuleStateIntegration: BugCapsuleIntegration, @unchecked Sendable {
    public static let shared = BugCapsuleStateIntegration()
    public let name = "state"

    struct Entry {
        let snapshot: @MainActor () -> JSONValue?
        let restore: @MainActor (JSONValue) throws -> Void
    }

    private let lock = NSLock()
    @MainActor private var entries: [String: Entry] = [:]
    @MainActor private var order: [String] = []
    private var pending: JSONObject = JSONObject()
    private var session: BugCapsuleSession?
    private var registeredCount = 0

    /// App state objects registered with `BugCapsule.registerState` (`BugCapsule.status`).
    var hasRegisteredState: Bool { lock.locked { registeredCount > 0 } }

    public init() {}

    public func setUp(_ session: BugCapsuleSession) { lock.locked { self.session = session } }

    @MainActor
    func register(_ key: String, snapshot: @escaping @MainActor () -> JSONValue?, restore: @escaping @MainActor (JSONValue) throws -> Void) {
        if entries[key] == nil {
            order.append(key)
            lock.locked { registeredCount += 1 }
        }
        entries[key] = Entry(snapshot: snapshot, restore: restore)
        let (session, data) = lock.locked { () -> (BugCapsuleSession?, JSONValue?) in
            let d = pending[key]
            pending[key] = nil
            return (self.session, d)
        }
        guard let data, let replay = session?.replay else { return }
        apply(key, data, entry: entries[key]!, replay: replay)
    }

    @MainActor
    private func apply(_ key: String, _ data: JSONValue, entry: Entry, replay: ReplayContext) {
        if replay.hasDispatchedInput { replay.diverge("restore.late", "state \(key) registered after replay started") }
        if JSON.encode(data).contains(Redactor.placeholder) { replay.diverge("state.redacted", key) }
        do { try entry.restore(data) } catch { replay.diverge("restore.state", "\(key): \(error)") }
    }

    @MainActor public func snapshot(_ kind: CheckpointKind) -> JSONValue? {
        var out = JSONObject()
        for key in order {
            if let v = entries[key]?.snapshot() { out[key] = v }
        }
        return out.isEmpty ? nil : .object(out)
    }

    @MainActor public func restore(_ data: JSONValue?, session: BugCapsuleSession) throws {
        guard let o = data?.objectValue, let replay = session.replay else { return }
        for (key, value) in o {
            if let entry = entries[key] {
                apply(key, value, entry: entry, replay: replay)
            } else {
                lock.locked { pending[key] = value }
            }
        }
        (replay as? ReplayEngine)?.onFinish { [weak self] engine in
            guard let self else { return }
            let left = self.lock.locked { self.pending.keys }
            for key in left { engine.diverge("restore.missing", "state \(key) was captured but never registered") }
        }
    }

    /// Records a diagnostic `state` event (not replayed).
    func changed(_ key: String, value: JSONValue?) {
        guard let s = lock.locked({ session }), s.isObserving else { return }
        var data: JSONObject = ["key": .string(key)]
        if let value { data["value"] = value }
        s.record(EventTypes.state, data)
    }
}

extension BugCapsule {
    /// Registers an app state object for checkpoints and replay restoration.
    @MainActor
    public static func registerState(
        _ key: String, snapshot: @escaping @MainActor () -> JSONValue?, restore: @escaping @MainActor (JSONValue) throws -> Void
    ) {
        BugCapsuleStateIntegration.shared.register(key, snapshot: snapshot, restore: restore)
    }

    /// Records that registered state [key] changed (diagnostic `state` event).
    public static func stateChanged(_ key: String, value: JSONValue? = nil) {
        BugCapsuleStateIntegration.shared.changed(key, value: value)
    }
}
