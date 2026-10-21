#if canImport(SwiftUI)
    import SwiftUI

    extension BugCapsule {
        /// A binding that records edits of tracked text [id] and lets replay
        /// set it. Use it in place of the original binding:
        ///
        /// ```swift
        /// TextField("Coupon", text: BugCapsule.trackedText("cart.coupon", $coupon))
        /// SecureField("PIN", text: BugCapsule.trackedText("login.pin", $pin, sensitive: true))
        /// ```
        /// Mark `SecureField`s `sensitive: true` (the id is also checked
        /// against the redaction deny list).
        @MainActor
        public static func trackedText(_ id: String, _ binding: Binding<String>, sensitive: Bool = false) -> Binding<String> {
            BugCapsuleSession.current?.noteFramework("swiftui")
            ActionRegistry.shared.trackText(id) { value in binding.wrappedValue = value }
            return Binding(
                get: { binding.wrappedValue },
                set: { newValue in
                    let changed = newValue != binding.wrappedValue
                    binding.wrappedValue = newValue
                    if changed { BugCapsule.textChanged(id, value: newValue, sensitive: sensitive) }
                })
        }
    }

    extension View {
        /// Records a `route` event (`source: explicit`) when the view appears
        /// and makes it the current route of `BugCapsuleNavigation`.
        public func bugCapsuleRoute(_ location: String) -> some View {
            onAppear {
                BugCapsuleSession.current?.noteFramework("swiftui")
                BugCapsuleNavigation.shared.setRoute(location, action: "push", source: "explicit")
            }
        }

        /// Registers a semantic action handler for [id] while the view is
        /// alive (for controls whose action you record with `BugCapsule.recordAction`).
        public func bugCapsuleAction(_ id: String, perform: @escaping @MainActor () -> Void) -> some View {
            onAppear {
                BugCapsuleSession.current?.noteFramework("swiftui")
                ActionRegistry.shared.register(id) { _ in perform() }
            }
        }
    }
#endif
