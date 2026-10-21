#if canImport(UIKit)
    import UIKit

    /// Explicit pointer capture: use it as your app's window class (or call
    /// `BugCapsule.recordTouches(_:in:)` from your own `UIWindow`/
    /// `UIApplication` `sendEvent` override). No method swizzling.
    ///
    /// Touches are recorded as `pointer` events in window points. iOS does
    /// not replay them (`input.pointer.replay: unsupported`); replay uses
    /// semantic actions, and a capsule with only pointer input is reported
    /// as needing `capability.input.pointer.replay`.
    open class BugCapsuleWindow: UIWindow {
        open override func sendEvent(_ event: UIEvent) {
            BugCapsule.recordTouches(event, in: self)
            super.sendEvent(event)
        }
    }

    extension BugCapsule {
        @MainActor private static var pointerIds: [ObjectIdentifier: Int] = [:]
        @MainActor private static var nextPointerId = 1

        /// Records the touches of [event] relative to [window].
        @MainActor
        public static func recordTouches(_ event: UIEvent, in window: UIWindow) {
            guard event.type == .touches, let s = BugCapsuleSession.current, s.isRecording,
                let touches = event.allTouches
            else { return }
            for touch in touches {
                let phase: String
                switch touch.phase {
                case .began: phase = "down"
                case .moved: phase = "move"
                case .ended: phase = "up"
                case .cancelled: phase = "cancel"
                default: continue
                }
                let key = ObjectIdentifier(touch)
                let id: Int
                if let existing = pointerIds[key] {
                    id = existing
                } else {
                    id = nextPointerId
                    nextPointerId += 1
                    pointerIds[key] = id
                }
                if phase == "up" || phase == "cancel" { pointerIds[key] = nil }
                let p = touch.location(in: window)
                var data: JSONObject = [
                    "phase": .string(phase), "pointer": .int(id),
                    "x": .double((Double(p.x) * 100).rounded() / 100), "y": .double((Double(p.y) * 100).rounded() / 100),
                    "kind": .string(touch.type == .pencil ? "stylus" : "touch"),
                ]
                if touch.type == .indirectPointer { data["kind"] = "mouse" }
                s.record(EventTypes.pointer, data)
            }
        }
    }
#endif
