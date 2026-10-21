import Foundation

#if canImport(UIKit)
    import UIKit
#endif

/// A view controller's route name in `route` events and checkpoints.
@MainActor
public protocol BugCapsuleRouteNaming {
    var bugCapsuleRoute: String { get }
}

/// Navigation capture (`checkpoint.data.navigation = {route, backStack}`).
///
/// * UIKit: `BugCapsule.observe(navigationController)` installs a
///   `UINavigationControllerDelegate` proxy that records `route` events
///   and forwards every delegate call to the app's own delegate.
/// * Explicit: `BugCapsuleNavigation.shared.setRoute(...)` or the SwiftUI
///   `.bugCapsuleRoute(_:)` modifier.
///
/// Route events are diagnostic. Navigation is reproduced by replaying the
/// inputs that caused it; periodic checkpoints restore the route only
/// through `restorer`, which the app registers (otherwise replay reports
/// `restore.navigation`). Locations are redacted like URLs.
public final class BugCapsuleNavigation: BugCapsuleIntegration, @unchecked Sendable {
    public static let shared = BugCapsuleNavigation()

    public let name = "navigation"
    public var capabilities: [(String, String)] { [("navigation.uikit", "explicit"), ("navigation.explicit", "explicit")] }

    private let lock = NSLock()
    private var session: BugCapsuleSession?
    private var route: String?
    private var backStack: [String] = []
    private var pending: JSONObject?

    /// Restores a periodic checkpoint's route (main thread, before inputs replay).
    @MainActor public var restorer: ((_ route: String, _ backStack: [String]) throws -> Void)?

    public init() {}

    public func setUp(_ session: BugCapsuleSession) { lock.locked { self.session = session } }

    public var currentRoute: String? { lock.locked { route } }

    /// Records a navigation change. [action]: push, pop, replace, reset.
    public func setRoute(_ location: String, backStack: [String]? = nil, action: String = "push", source: String = "explicit") {
        let s = lock.locked { () -> BugCapsuleSession? in
            route = location
            if let backStack { self.backStack = backStack }
            return session
        }
        guard let s, s.isObserving else { return }
        let redacted = s.redactor.redactURL(location)
        s.record(EventTypes.route, ["location": .string(redacted), "source": .string(source), "action": .string(action)])
    }

    @MainActor public func snapshot(_ kind: CheckpointKind) -> JSONValue? {
        guard kind == .periodic else { return nil }
        return lock.locked { () -> JSONValue? in
            guard let route else { return nil }
            let r = session?.redactor
            return [
                "route": .string(r?.redactURL(route) ?? route),
                "backStack": .array(backStack.map { .string(r?.redactURL($0) ?? $0) }),
            ]
        }
    }

    @MainActor public func restore(_ data: JSONValue?, session: BugCapsuleSession) throws {
        guard let o = data?.objectValue, let route = o["route"]?.stringValue else { return }
        let stack = (o["backStack"]?.arrayValue ?? []).compactMap(\.stringValue)
        if route.contains(Redactor.placeholder) || stack.contains(where: { $0.contains(Redactor.placeholder) }) {
            session.replay?.diverge("route.redacted", route)
        }
        guard let restorer else {
            session.replay?.diverge("restore.navigation", "no BugCapsuleNavigation.restorer registered for route \(route)")
            return
        }
        try restorer(route, stack)
    }

    #if canImport(UIKit)
        @MainActor private var proxies: [ObjectIdentifier: NavigationDelegateProxy] = [:]

        @MainActor
        func observe(_ nav: UINavigationController) {
            let key = ObjectIdentifier(nav)
            if let existing = proxies[key], nav.delegate === existing { return }
            let proxy = NavigationDelegateProxy(original: nav.delegate, owner: self, depth: nav.viewControllers.count)
            proxies[key] = proxy
            nav.delegate = proxy
            if let top = nav.topViewController {
                let name = (top as? BugCapsuleRouteNaming)?.bugCapsuleRoute ?? String(describing: type(of: top))
                BugCapsuleSession.current?.monitoring?.screenWillAppear(name)
                record(nav, shown: top, action: "reset")
            }
        }

        @MainActor
        func record(_ nav: UINavigationController, shown: UIViewController, action: String) {
            func routeName(_ vc: UIViewController) -> String {
                (vc as? BugCapsuleRouteNaming)?.bugCapsuleRoute ?? String(describing: type(of: vc))
            }
            setRoute(routeName(shown), backStack: nav.viewControllers.map(routeName), action: action, source: "uikit")
        }
    #endif
}

#if canImport(UIKit)
    /// Records `route` events and forwards every delegate method to the app's
    /// delegate (unknown selectors through `forwardingTarget(for:)`).
    final class NavigationDelegateProxy: NSObject, UINavigationControllerDelegate {
        nonisolated(unsafe) weak var original: UINavigationControllerDelegate?
        weak var owner: BugCapsuleNavigation?
        private var depth = 0

        private weak var lastShown: UIViewController?

        init(original: UINavigationControllerDelegate?, owner: BugCapsuleNavigation, depth: Int) {
            self.original = original
            self.owner = owner
            self.depth = depth
        }

        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if original?.responds(to: aSelector) == true { return original }
            return super.forwardingTarget(for: aSelector)
        }

        func navigationController(_ nav: UINavigationController, willShow vc: UIViewController, animated: Bool) {
            if vc !== lastShown {
                MainActor.assumeIsolated {
                    let name = (vc as? BugCapsuleRouteNaming)?.bugCapsuleRoute ?? String(describing: type(of: vc))
                    BugCapsuleSession.current?.monitoring?.screenWillAppear(name)
                }
            }
            original?.navigationController?(nav, willShow: vc, animated: animated)
        }

        func navigationController(_ nav: UINavigationController, didShow vc: UIViewController, animated: Bool) {
            let count = nav.viewControllers.count
            let action = count > depth ? "push" : count < depth ? "pop" : "replace"
            depth = count
            // The root shown at launch was already recorded by `observe`.
            if vc !== lastShown && !(action == "replace" && lastShown == nil && count == 1) {
                MainActor.assumeIsolated { owner?.record(nav, shown: vc, action: action) }
            }
            lastShown = vc
            original?.navigationController?(nav, didShow: vc, animated: animated)
        }
    }

    extension BugCapsule {
        /// Records the navigation of [nav] (route events + checkpoint route)
        /// through a delegate proxy that forwards to `nav.delegate`. Set your
        /// own delegate before calling this.
        @MainActor
        public static func observe(_ nav: UINavigationController) {
            BugCapsuleNavigation.shared.observe(nav)
        }
    }
#endif
