import BugCapsule
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Demo-only switch used by the capture UI tests to start from a
        // clean store. It runs before BugCapsule.start so the launch
        // checkpoint sees exactly what the app will read.
        if ProcessInfo.processInfo.arguments.contains("-DemoResetStorage") {
            for key in ["cart_cache", "demo.visits", "demo.lastCoupon"] { UserDefaults.standard.removeObject(forKey: key) }
        }

        // First line that matters: in replay this restores UserDefaults
        // before any app code reads them.
        BugCapsule.start(
            DemoConfig.bugCapsuleConfig(),
            integrations: [
                ShopAPI.network,
                BugCapsuleUserDefaults(keys: ["cart_cache"], prefixes: ["demo."]),
                BugCapsuleNavigation.shared,
                BugCapsuleStateIntegration.shared,
            ])

        AppState.shared.registerWithBugCapsule()
        AppState.shared.visits += 1
        return true
    }

    func application(
        _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        // BugCapsuleWindow records touches (pointer capture is explicit).
        let window = BugCapsuleWindow(windowScene: scene)
        let nav = UINavigationController(rootViewController: HomeViewController(api: ShopAPI.shared))
        nav.navigationBar.prefersLargeTitles = true
        BugCapsule.observe(nav)  // UIKit navigation capture through a delegate proxy
        window.rootViewController = nav
        window.makeKeyAndVisible()
        self.window = window
    }
}

/// Backend and capture settings. The ingest key and backend URL come from
/// build settings (`BUGCAPSULE_BACKEND_URL`, `BUGCAPSULE_INGEST_KEY`)
/// through Info.plist; they are never committed into sources.
enum DemoConfig {
    static func plist(_ key: String) -> String? {
        guard let v = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let t = v.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t.hasPrefix("$(") ? nil : t
    }

    static var backend: BugCapsuleBackendConfig? {
        // Demo-only override used by the offline-capture UI test.
        let url = ProcessInfo.processInfo.environment["BUGCAPSULE_DEMO_BACKEND_URL"] ?? plist("BugCapsuleBackendURL")
        guard let url, let key = plist("BugCapsuleIngestKey") else { return nil }
        return BugCapsuleBackendConfig(url: url, ingestKey: key)
    }

    static func bugCapsuleConfig() -> BugCapsuleConfig {
        BugCapsuleConfig(
            appName: "BugCapsule Shop", mode: .qa, backend: backend, stateSchemaVersion: 1,
            labels: ["demo": "ios"])
    }
}

/// App-level state registered with BugCapsule (checkpoint `state` data).
@MainActor
final class AppState {
    static let shared = AppState()

    var visits: Int {
        get { UserDefaults.standard.integer(forKey: "demo.visits") }
        set { UserDefaults.standard.set(newValue, forKey: "demo.visits") }
    }
    var lastOrderId: String?
    var appliedCoupon: String? {
        didSet { BugCapsule.stateChanged("app.session", value: appliedCoupon.map { .string($0) }) }
    }

    func registerWithBugCapsule() {
        BugCapsule.registerState(
            "app.session",
            snapshot: { [unowned self] in
                ["lastOrderId": lastOrderId.map { .string($0) } ?? .null, "appliedCoupon": appliedCoupon.map { .string($0) } ?? .null]
            },
            restore: { [unowned self] json in
                lastOrderId = json["lastOrderId"]?.stringValue
                appliedCoupon = json["appliedCoupon"]?.stringValue
            })
    }
}
