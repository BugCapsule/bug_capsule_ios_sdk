import Foundation

/// A third-party SDK adapter (capsule-v2 §4.3, `kind: native`): records
/// what a native dependency (Firebase, maps, location, payments) answered
/// the app and serves those answers in replay, without the dependency.
///
/// An adapter wraps the SDK's API and routes every operation through the
/// `BugCapsuleNativeBridge` it receives in `attach`:
///
/// * one-shot operations with `bridge.call(_:args:live:)`
///   (`native.call` → `native.result` / `native.error`);
/// * streams with `bridge.subscribe(_:args:onEvent:live:)`
///   (`native.subscribe` → `native.event`… → `native.done` / `native.error`,
///   `native.cancel` from the app).
///
/// Values cross the bridge as typed values (`TypedValue`: strings, numbers,
/// `Data`, arrays, dictionaries): the adapter converts its SDK's types to
/// and from them, the bridge encodes, redacts and bounds them
/// (`PayloadEncoder`). Install it with `BugCapsuleNativeIntegration`:
///
/// ```swift
/// let location = BugCapsuleLocationAdapter(provider: CoreLocationProvider())
/// BugCapsule.start(config, integrations: [BugCapsuleNativeIntegration(location)])
/// let fix = try await location.currentLocation()
/// ```
///
/// Test an adapter offline with `BugCapsuleAdapterConformance.run`.
public protocol BugCapsuleNativeAdapter: AnyObject, Sendable {
    /// Identity, version, operations and payload policy.
    var descriptor: BugCapsuleAdapterDescriptor { get }
    /// Receives the bridge to route operations through (session setup,
    /// capture or replay).
    func attach(_ bridge: BugCapsuleNativeBridge)
    /// Adapter state for a periodic checkpoint (stored under the
    /// integration's checkpoint key); nil: nothing to restore.
    func snapshot() -> JSONValue?
    /// Whether the open subscription [id] can be restored from `snapshot`
    /// state. Default false: a capsule whose periodic checkpoint has one
    /// open is `incompatible` (`dependency.unrestorable`).
    func canRestore(subscription id: String) -> Bool
    /// Restores checkpoint state in replay before app code runs.
    func restore(_ state: JSONValue?, open: [BugCapsuleOpenInteraction]) throws
    /// The session ended (tests): release resources.
    func dispose()
}

extension BugCapsuleNativeAdapter {
    public func snapshot() -> JSONValue? { nil }
    public func canRestore(subscription id: String) -> Bool { false }
    public func restore(_ state: JSONValue?, open: [BugCapsuleOpenInteraction]) throws {}
    public func dispose() {}
}

/// Installs a `BugCapsuleNativeAdapter` in a session (preflight finds it by
/// its adapter id).
public final class BugCapsuleNativeIntegration: BugCapsuleIntegration, @unchecked Sendable {
    public let adapter: BugCapsuleNativeAdapter
    public var name: String { "native.\(adapter.descriptor.dependencyId)" }
    public var capabilities: [(String, String)] { [("interaction.native.\(adapter.descriptor.adapter)", "supported")] }

    public init(_ adapter: BugCapsuleNativeAdapter) { self.adapter = adapter }

    public func setUp(_ session: BugCapsuleSession) {
        session.interactions.install(adapter.descriptor)
        adapter.attach(BugCapsuleNativeBridge(descriptor: adapter.descriptor, runtime: session.interactions, adapter: adapter))
    }

    @MainActor public func snapshot(_ kind: CheckpointKind) -> JSONValue? { kind == .periodic ? adapter.snapshot() : nil }

    @MainActor public func restore(_ data: JSONValue?, session: BugCapsuleSession) throws {
        guard let capsule = session.replay?.capsule else { return }
        let dep = capsule.manifest.dependencies.first { $0.adapter == adapter.descriptor.adapter }?.id
        let open = (capsule.checkpoint.data["interactions"]?["open"]?.arrayValue ?? [])
            .compactMap(BugCapsuleOpenInteraction.init(json:)).filter { $0.dep == dep }
        if data != nil || !open.isEmpty { try adapter.restore(data, open: open) }
    }
}

/// An error a native dependency reported (`native.error`): replay throws
/// the recorded one. Adapters may throw it from `live` to choose the code.
public struct BugCapsuleNativeError: Error, LocalizedError, CustomStringConvertible, @unchecked Sendable {
    public let code: String
    public let message: String?
    /// Typed-value details (decoded in replay).
    public let details: Any?

    public init(code: String, message: String? = nil, details: Any? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }

    public var errorDescription: String? { message ?? code }
    public var description: String { message.map { "\(code): \($0)" } ?? code }
}

/// Feeds a live subscription's values to the bridge while capturing.
public final class BugCapsuleNativeSink: @unchecked Sendable {
    private let onEvent: @Sendable (Any?) -> Void
    private let onError: @Sendable (Error) -> Void
    private let onDone: @Sendable () -> Void

    init(
        event: @escaping @Sendable (Any?) -> Void, error: @escaping @Sendable (Error) -> Void,
        done: @escaping @Sendable () -> Void
    ) {
        onEvent = event
        onError = error
        onDone = done
    }

    public func event(_ value: Any?) { onEvent(value) }
    public func error(_ error: Error) { onError(error) }
    public func done() { onDone() }
}

/// A running subscription; `cancel` records `native.cancel` and stops the
/// live stream (capture) or the recorded deliveries (replay).
public final class BugCapsuleNativeSubscription: @unchecked Sendable {
    private let lock = NSLock()
    private var onCancel: (@Sendable () -> Void)?
    /// `sub` id in the capsule (nil when not captured or not matched).
    public let id: String?

    init(id: String?, cancel: @escaping @Sendable () -> Void) {
        self.id = id
        onCancel = cancel
    }

    public func cancel() {
        let c: (@Sendable () -> Void)? = lock.locked {
            defer { onCancel = nil }
            return onCancel
        }
        c?()
    }
}

/// The capture and replay dispatch of one native adapter (capsule-v2 §4.3).
/// Thread-safe. Without a BugCapsule session every operation runs live.
public final class BugCapsuleNativeBridge: @unchecked Sendable {
    public let descriptor: BugCapsuleAdapterDescriptor
    private let runtime: InteractionRuntime?
    private weak var adapter: BugCapsuleNativeAdapter?
    private let callbacks = DispatchQueue(label: "com.bugcapsule.native.callbacks")

    init(descriptor: BugCapsuleAdapterDescriptor, runtime: InteractionRuntime?, adapter: BugCapsuleNativeAdapter?) {
        self.descriptor = descriptor
        self.runtime = runtime
        self.adapter = adapter
    }

    /// A bridge without a session: everything runs live, nothing is recorded.
    public static func detached(_ descriptor: BugCapsuleAdapterDescriptor) -> BugCapsuleNativeBridge {
        BugCapsuleNativeBridge(descriptor: descriptor, runtime: nil, adapter: nil)
    }

    /// Operations are served from a capsule (never live).
    public var isReplaying: Bool { runtime?.replay != nil }
    /// Operations are recorded.
    public var isRecording: Bool { runtime?.captures(descriptor.adapter) ?? false }

    /// Whether [operation] is one the adapter records and replays.
    public func supports(_ operation: String) -> Bool {
        descriptor.operations.isEmpty || descriptor.operations.contains(operation)
    }

    /// Reports a coverage gap (capsule-v2 §7), e.g. `payload.binaryMetadata`
    /// or `adapter.captureFailed`: the dependency becomes `partial` and the
    /// capsule eligibility names it.
    public func gap(_ code: String, _ detail: String? = nil) {
        guard let runtime, runtime.captures(descriptor.adapter) else { return }
        runtime.recorder(descriptor).gap(code, detail)
    }

    private func replayDep(_ replay: InteractionReplay) -> String {
        replay.dependencyId(adapter: descriptor.adapter) ?? descriptor.dependencyId
    }

    /// The capture recorder, or nil when this operation is not recorded
    /// (no session, not recording, switched off, unsupported operation).
    private func recorder(for operation: String) -> DependencyRecorder? {
        guard let runtime, runtime.captures(descriptor.adapter) else { return nil }
        let rec = runtime.recorder(descriptor)
        if !supports(operation) {
            rec.gap(DependencyGaps.operationUnsupported, "\(operation) is not recorded by \(descriptor.adapter)")
            return nil
        }
        return rec
    }

    /// The key scope (capsule-v2 §5): calls are matched within their
    /// adapter instance, `<operation>@<instance>`.
    static func scope(_ operation: String, _ instance: String?) -> String {
        instance.map { "\(operation)@\($0)" } ?? operation
    }

    private func key(_ operation: String, _ instance: String?, _ args: Any?, rec: DependencyRecorder?) -> String {
        if let rec { return rec.key(Self.scope(operation, instance), nil, args) }
        let redactor = runtime?.redactor() ?? Redactor()
        let input = TypedValue.redact(TypedValue.encode(args), redactor).0
        return interactionKey(Self.scope(operation, instance), nil, DependencyRecorder.strip(input, descriptor.nondeterministicFields))
    }

    private func errorData(_ error: Error, rec: DependencyRecorder) -> JSONObject {
        let redactor = runtime?.redactor() ?? Redactor()
        if let e = error as? BugCapsuleNativeError {
            var d: JSONObject = ["code": .string(e.code)]
            if let m = e.message { d["message"] = .string(redactor.scrubText(m)) }
            if e.details != nil { d["details"] = rec.payload(e.details).json }
            return d
        }
        let ns = error as NSError
        return ["code": .string("\(ns.domain):\(ns.code)"), "message": .string(redactor.scrubText(ns.localizedDescription))]
    }

    static func replayedError(_ data: JSONObject) -> BugCapsuleNativeError {
        BugCapsuleNativeError(
            code: data["code"]?.stringValue ?? "unknown", message: data["message"]?.stringValue,
            details: InteractionPayload(json: data["details"]).flatMap { $0.replayable ? $0.decoded : nil })
    }

    /// A bridge without a runtime (adapter not installed) inside a replay:
    /// the operation fails instead of reaching the dependency.
    private func blockedInReplay(_ operation: String) -> BugCapsuleReplayError? {
        guard runtime == nil, let session = BugCapsuleSession.current, session.isReplaying else { return nil }
        session.replay?.diverge("native.unrecorded", "\(operation): \(descriptor.adapter) is not installed")
        return BugCapsuleReplayError(
            code: "bugcapsule.unrecorded", message: "replay: \(descriptor.adapter) is not installed, \(operation) was not run")
    }

    // MARK: calls

    /// Runs a one-shot [operation]: live (recorded while capturing) or, in
    /// replay, the recorded result or error (never the dependency, also
    /// not when nothing was recorded). The match key is
    /// `<operation>[@<instance>]||<hash of the redacted args>` plus the
    /// occurrence (capsule-v2 §5): [instance] (e.g. a Firebase app name)
    /// scopes matching; [parent] links an enclosing interaction. In replay
    /// the result is the decoded typed value.
    public func call(
        _ operation: String, args: Any? = nil, instance: String? = nil, parent: String? = nil,
        live: @Sendable () async throws -> Any?
    ) async throws -> Any? {
        if let replay = runtime?.replay { return try await replayCall(operation, args, instance, replay) }
        if let blocked = blockedInReplay(operation) { throw blocked }
        guard let rec = recorder(for: operation) else { return try await live() }
        let op = rec.newId("op")
        let key = key(operation, instance, args, rec: rec)
        var d: JSONObject = ["op": .string(op), "operation": .string(operation)]
        if let instance { d["instance"] = .string(instance) }
        if let parent { d["parent"] = .string(parent) }
        d["args"] = rec.payload(args).json
        d["key"] = .string(key)
        d["occurrence"] = .int(rec.occurrences.next(key))
        rec.emit(InteractionTypes.nativeCall, d)
        do {
            let value = try await live()
            rec.emit(InteractionTypes.nativeResult, ["op": .string(op), "value": rec.payload(value).json])
            return value
        } catch {
            var e = errorData(error, rec: rec)
            e["op"] = .string(op)
            rec.emit(InteractionTypes.nativeError, e)
            throw error
        }
    }

    private func unmatched(_ type: String, _ operation: String, _ instance: String?, _ replay: InteractionReplay) -> BugCapsuleReplayError {
        let dep = replayDep(replay)
        let what = instance.map { "\(operation) on \($0)" } ?? operation
        if replay.hasUnconsumed(dep: dep, type: type, prefix: "\(Self.scope(operation, instance))|") {
            replay.diverge("native.mismatch", "\(what): arguments differ from every remaining recorded \(type)")
        } else {
            replay.diverge("native.unrecorded", "\(what): no recorded \(type) left")
        }
        return BugCapsuleReplayError(code: "bugcapsule.unrecorded", message: "replay: \(what) was not recorded")
    }

    private func replayCall(_ operation: String, _ args: Any?, _ instance: String?, _ replay: InteractionReplay) async throws -> Any? {
        let key = key(operation, instance, args, rec: nil)
        guard let r = replay.take(dep: replayDep(replay), type: InteractionTypes.nativeCall, key: key) else {
            throw unmatched(InteractionTypes.nativeCall, operation, instance, replay)
        }
        let op = r.data["op"]?.stringValue ?? ""
        let scope = "native.op:\(op)"
        let callbacks = self.callbacks
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SendableBox, Error>) in
            replay.bind(scope) { [weak replay] answer in
                replay?.unbind(scope)
                let result: Result<SendableBox, Error>
                if answer.type == InteractionTypes.nativeError {
                    result = .failure(Self.replayedError(answer.data))
                } else if let p = answer.payload("value"), p.replayable {
                    result = .success(SendableBox(p.decoded))
                } else {
                    replay?.diverge("native.noPayload", "\(operation) \(op): the recorded result is not replayable")
                    result = .failure(
                        BugCapsuleReplayError(code: "bugcapsule.noPayload", message: "replay: the result of \(operation) was not recorded"))
                }
                callbacks.async { cont.resume(with: result) }
            }
        }.value
    }

    // MARK: subscriptions

    /// Starts a stream [operation]. Capture: `live` starts the real stream,
    /// feeds it to the sink and returns its canceller; every value is
    /// recorded and passed on. Replay: the recorded events arrive at their
    /// recorded offsets; `live` is never called. Callbacks run on a serial
    /// background queue.
    public func subscribe(
        _ operation: String, args: Any? = nil, instance: String? = nil, parent: String? = nil,
        onEvent: @escaping @Sendable (Any?) -> Void, onError: @escaping @Sendable (Error) -> Void = { _ in },
        onDone: @escaping @Sendable () -> Void = {},
        live: (BugCapsuleNativeSink) throws -> (@Sendable () -> Void)
    ) rethrows -> BugCapsuleNativeSubscription {
        if let replay = runtime?.replay {
            return replaySubscribe(operation, args, instance, replay, onEvent, onError, onDone)
        }
        if let blocked = blockedInReplay(operation) {
            callbacks.async { onError(blocked) }
            return BugCapsuleNativeSubscription(id: nil) {}
        }
        guard let runtime, let rec = recorder(for: operation) else {
            let stop = try live(BugCapsuleNativeSink(event: onEvent, error: onError, done: onDone))
            return BugCapsuleNativeSubscription(id: nil, cancel: stop)
        }
        guard runtime.acquireActive() else {
            rec.gap(DependencyGaps.connectionsLimit, "more than \(runtime.limits.maxActive) captured subscriptions at once")
            let stop = try live(BugCapsuleNativeSink(event: onEvent, error: onError, done: onDone))
            return BugCapsuleNativeSubscription(id: nil, cancel: stop)
        }
        let sub = rec.newId("sub")
        let key = key(operation, instance, args, rec: rec)
        var d: JSONObject = ["sub": .string(sub), "operation": .string(operation)]
        if let instance { d["instance"] = .string(instance) }
        if let parent { d["parent"] = .string(parent) }
        d["args"] = rec.payload(args).json
        d["key"] = .string(key)
        d["occurrence"] = .int(rec.occurrences.next(key))
        rec.emit(InteractionTypes.nativeSubscribe, d)
        rec.opened(sub, type: "native") { [weak adapter] in adapter?.canRestore(subscription: sub) ?? false }
        let state = SubscriptionState()
        let end: @Sendable () -> Void = {
            if state.end() {
                rec.closed(sub)
                runtime.releaseActive()
            }
        }
        let sink = BugCapsuleNativeSink(
            event: { value in
                guard let index = state.nextIndex() else { return }
                rec.emit(InteractionTypes.nativeEvent, ["sub": .string(sub), "index": .int(index), "value": rec.payload(value).json])
                onEvent(value)
            },
            error: { [weak self] error in
                guard !state.isEnded, let self else { return }
                var e = self.errorData(error, rec: rec)
                e["sub"] = .string(sub)
                rec.emit(InteractionTypes.nativeError, e)
                end()
                onError(error)
            },
            done: {
                guard !state.isEnded else { return }
                rec.emit(InteractionTypes.nativeDone, ["sub": .string(sub)])
                end()
                onDone()
            })
        let stop: @Sendable () -> Void
        do {
            stop = try live(sink)
        } catch {
            end()
            throw error
        }
        return BugCapsuleNativeSubscription(id: sub) {
            guard !state.isEnded else { return }
            rec.emit(InteractionTypes.nativeCancel, ["sub": .string(sub)])
            end()
            stop()
        }
    }

    private func replaySubscribe(
        _ operation: String, _ args: Any?, _ instance: String?, _ replay: InteractionReplay,
        _ onEvent: @escaping @Sendable (Any?) -> Void, _ onError: @escaping @Sendable (Error) -> Void,
        _ onDone: @escaping @Sendable () -> Void
    ) -> BugCapsuleNativeSubscription {
        let key = key(operation, instance, args, rec: nil)
        let callbacks = self.callbacks
        guard let r = replay.take(dep: replayDep(replay), type: InteractionTypes.nativeSubscribe, key: key) else {
            let error = unmatched(InteractionTypes.nativeSubscribe, operation, instance, replay)
            callbacks.async { onError(error) }
            return BugCapsuleNativeSubscription(id: nil) {}
        }
        let sub = r.data["sub"]?.stringValue ?? ""
        let scope = "native.sub:\(sub)"
        let state = SubscriptionState()
        replay.bind(scope) { [weak replay] e in
            switch e.type {
            case InteractionTypes.nativeEvent:
                guard !state.isEnded else { return }
                guard let p = e.payload("value"), p.replayable else {
                    replay?.diverge(
                        "native.noPayload", "\(operation) \(sub) event #\(e.data["index"]?.intValue ?? 0): not replayable")
                    return
                }
                let value = SendableBox(p.decoded)
                callbacks.async { onEvent(value.value) }
            case InteractionTypes.nativeError:
                replay?.unbind(scope)
                guard state.end() else { return }
                let error = Self.replayedError(e.data)
                callbacks.async { onError(error) }
            case InteractionTypes.nativeDone:
                replay?.unbind(scope)
                guard state.end() else { return }
                callbacks.async { onDone() }
            default:
                break
            }
        }
        return BugCapsuleNativeSubscription(id: sub) { [weak replay] in
            guard let replay, state.end() else { return }
            if replay.takeNext(scope: scope, types: [InteractionTypes.nativeCancel]) == nil {
                replay.diverge("native.unrecorded", "\(operation) \(sub): cancel was not recorded")
                replay.unbind(scope)
            }
            // A recorded `native.done` after the cancel is still consumed.
        }
    }
}

/// Moves a typed value across the callback queue.
struct SendableBox: @unchecked Sendable {
    let value: Any?
    init(_ value: Any?) { self.value = value }
}

private final class SubscriptionState: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false
    private var index = 0

    var isEnded: Bool { lock.locked { ended } }

    /// True the first time.
    func end() -> Bool {
        lock.locked {
            if ended { return false }
            ended = true
            return true
        }
    }

    func nextIndex() -> Int? {
        lock.locked {
            if ended { return nil }
            defer { index += 1 }
            return index
        }
    }
}
