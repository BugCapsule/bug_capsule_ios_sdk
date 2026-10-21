import Foundation

#if canImport(UIKit)
    import UIKit
#endif

/// Named UI actions and tracked text fields. Semantic replay invokes
/// actions by id; text fields are restored by id. The latest registration
/// of an id wins (views re-register when rebuilt).
@MainActor
public final class ActionRegistry {
    public static let shared = ActionRegistry()

    private var actions: [String: @MainActor (JSONObject?) -> Void] = [:]
    private var textSetters: [String: @MainActor (String) -> Void] = [:]

    public func register(_ id: String, handler: @escaping @MainActor (JSONObject?) -> Void) { actions[id] = handler }
    public func unregister(_ id: String) { actions[id] = nil }

    @discardableResult
    public func invoke(_ id: String, payload: JSONObject?) -> Bool {
        guard let handler = actions[id] else { return false }
        handler(payload)
        return true
    }

    public func trackText(_ id: String, setter: @escaping @MainActor (String) -> Void) { textSetters[id] = setter }
    public func untrackText(_ id: String) { textSetters[id] = nil }

    @discardableResult
    public func setText(_ id: String, _ value: String) -> Bool {
        guard let setter = textSetters[id] else { return false }
        setter(value)
        return true
    }

    var registeredActionIds: [String] { Array(actions.keys) }
}

/// Posts the `UIApplication` notification matching a recorded lifecycle
/// state (`lifecycle.replay: partial`: observers run, the real application
/// state does not change). A state equal to the current one is not posted again.
@MainActor
enum LifecycleReplayer {
    private static var current: String?

    static func post(_ state: String) -> Bool {
        #if canImport(UIKit)
            let name: Notification.Name
            switch state {
            case "resumed": name = UIApplication.didBecomeActiveNotification
            case "inactive": name = UIApplication.willResignActiveNotification
            case "paused": name = UIApplication.didEnterBackgroundNotification
            case "detached": name = UIApplication.willTerminateNotification
            default: return false
            }
            let real: String? =
                switch UIApplication.shared.applicationState {
                case .active: "resumed"
                case .inactive: "inactive"
                case .background: "paused"
                @unknown default: nil
                }
            if (current ?? real) == state { return true }
            current = state
            NotificationCenter.default.post(name: name, object: UIApplication.shared)
            return true
        #else
            return ["resumed", "inactive", "paused", "detached"].contains(state)
        #endif
    }
}

extension BugCapsule {
    // MARK: semantic actions

    /// Wraps a UI callback as a named semantic action: calling the returned
    /// closure records the action and runs [perform]; semantic replay
    /// invokes [perform] by [id].
    ///
    /// ```swift
    /// Button("Checkout", action: BugCapsule.action("cart.checkout") { model.checkout() })
    /// ```
    @MainActor
    public static func action(_ id: String, _ perform: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        ActionRegistry.shared.register(id) { _ in perform() }
        return {
            recordAction(id)
            perform()
        }
    }

    /// Like `action` with a JSON payload passed to the handler.
    @MainActor
    public static func action(_ id: String, payloadHandler perform: @escaping @MainActor (JSONObject) -> Void)
        -> @MainActor (JSONObject) -> Void
    {
        ActionRegistry.shared.register(id) { p in perform(p ?? JSONObject()) }
        return { payload in
            recordAction(id, payload: payload)
            perform(payload)
        }
    }

    /// Registers a replay handler for [id] without wrapping (pair it with
    /// `recordAction` in your own control handler).
    @MainActor
    public static func registerAction(_ id: String, handler: @escaping @MainActor (JSONObject?) -> Void) {
        ActionRegistry.shared.register(id, handler: handler)
    }

    /// Records that the user performed action [id] (capture only).
    public static func recordAction(_ id: String, payload: JSONObject? = nil) {
        guard let s = BugCapsuleSession.current, s.isRecording else { return }
        var data: JSONObject = ["id": .string(id.dartPrefix(200))]
        if let payload { data["payload"] = .object(payload) }
        s.record(EventTypes.action, data)
    }

    // MARK: tracked text

    /// Registers [setter] so replay can restore tracked text [id]; record
    /// each edit with `textChanged(_:value:sensitive:)`.
    @MainActor
    public static func trackText(_ id: String, setter: @escaping @MainActor (String) -> Void) {
        ActionRegistry.shared.trackText(id, setter: setter)
    }

    /// Records the new value of tracked text [id].
    public static func textChanged(_ id: String, value: String, sensitive: Bool = false) {
        guard let s = BugCapsuleSession.current, s.isRecording else { return }
        let v = s.redactor.redactText(fieldId: id, value: value, sensitive: sensitive)
        s.record(EventTypes.text, ["id": .string(id.dartPrefix(200)), "value": .string(v.dartPrefix(100_000))])
    }

    #if canImport(UIKit)
        /// Tracks a `UITextField`: edits are recorded (`isSecureTextEntry`
        /// fields are always recorded as `[REDACTED]`), and replay sets the
        /// text and sends `.editingChanged` so the app's handlers run.
        @MainActor
        public static func trackText(_ id: String, field: UITextField, sensitive: Bool = false) {
            BugCapsuleSession.current?.noteFramework("uikit")
            let tracker = TextFieldTracker(id: id, sensitive: sensitive)
            field.addAction(UIAction { [weak field, tracker] _ in if let field { tracker.changed(field) } }, for: .editingChanged)
            objc_setAssociatedObject(field, &TextFieldTracker.key, tracker, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            ActionRegistry.shared.trackText(id) { [weak field] value in
                guard let field else { return }
                field.text = value
                field.sendActions(for: .editingChanged)
            }
        }

        /// Wraps a control target as a semantic action (UIKit).
        ///
        /// `button.addAction(BugCapsule.uiAction("home.refresh") { [weak self] in self?.refresh() }, for: .touchUpInside)`
        @MainActor
        public static func uiAction(_ id: String, _ perform: @escaping @MainActor () -> Void) -> UIAction {
            BugCapsuleSession.current?.noteFramework("uikit")
            let wrapped = action(id, perform)
            return UIAction { _ in wrapped() }
        }
    #endif
}

#if canImport(UIKit)
    @MainActor
    final class TextFieldTracker: NSObject {
        nonisolated(unsafe) static var key: UInt8 = 0
        let id: String
        let sensitive: Bool
        var last: String?

        init(id: String, sensitive: Bool) {
            self.id = id
            self.sensitive = sensitive
        }

        func changed(_ field: UITextField) {
            let text = field.text ?? ""
            if text == last { return }
            last = text
            BugCapsule.textChanged(id, value: text, sensitive: sensitive || field.isSecureTextEntry)
        }
    }
#endif
