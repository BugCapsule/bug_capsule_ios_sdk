#if canImport(UIKit)
    import SwiftUI
    import UIKit
    import XCTest

    @testable import BugCapsule

    /// UIKit / SwiftUI pieces; run on the iOS simulator
    /// (`xcodebuild test -scheme BugCapsule-Package -destination ...`).
    @MainActor
    final class UIKitIntegrationTests: XCTestCase {
        override func setUp() async throws {
            await BugCapsule.resetForTesting()
            BugCapsule.start(
                BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa), integrations: [BugCapsuleNavigation.shared],
                overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory()))
        }

        override func tearDown() async throws { await BugCapsule.resetForTesting() }

        var events: [BugCapsuleEvent] { BugCapsuleSession.current!.recorderForTesting!.window().events }

        func testTextFieldTrackingRedactsSecureEntryAndReplaySetsText() {
            let coupon = UITextField()
            let pin = UITextField()
            pin.isSecureTextEntry = true
            BugCapsule.trackText("cart.coupon", field: coupon)
            BugCapsule.trackText("login.code", field: pin)
            coupon.text = "SAVE10"
            coupon.sendActions(for: .editingChanged)
            pin.text = "123456"
            pin.sendActions(for: .editingChanged)
            let texts = events.filter { $0.type == EventTypes.text }
            XCTAssertEqual(texts.map { $0.data["value"] }, ["SAVE10", "[REDACTED]"])

            var hits = 0
            coupon.addAction(UIAction { _ in MainActor.assumeIsolated { hits += 1 } }, for: .editingChanged)
            XCTAssertTrue(ActionRegistry.shared.setText("cart.coupon", "SAVE100"))
            XCTAssertEqual(coupon.text, "SAVE100")
            XCTAssertEqual(hits, 1, "replay fires the app's editingChanged handlers")
        }

        func testUIActionRecordsAndRegisters() {
            var taps = 0
            let action = BugCapsule.uiAction("home.refresh") { taps += 1 }
            let button = UIButton()
            button.addAction(action, for: .touchUpInside)
            button.sendActions(for: .touchUpInside)
            XCTAssertEqual(taps, 1)
            XCTAssertEqual(events.last?.data["id"], "home.refresh")
            XCTAssertTrue(ActionRegistry.shared.invoke("home.refresh", payload: nil))
            XCTAssertEqual(taps, 2)
        }

        func testNavigationProxyRecordsRoutesAndForwards() {
            final class AppDelegateNav: NSObject, UINavigationControllerDelegate {
                var shown = 0
                func navigationController(_ n: UINavigationController, didShow vc: UIViewController, animated: Bool) { shown += 1 }
                func navigationControllerSupportedInterfaceOrientations(_ n: UINavigationController) -> UIInterfaceOrientationMask {
                    .portrait
                }
            }
            final class Cart: UIViewController, BugCapsuleRouteNaming {
                var bugCapsuleRoute: String { "/cart?token=abc" }
            }
            let appDelegate = AppDelegateNav()
            let nav = UINavigationController(rootViewController: UIViewController())
            nav.delegate = appDelegate
            BugCapsule.observe(nav)
            XCTAssertFalse(nav.delegate === appDelegate)
            XCTAssertEqual(nav.delegate?.navigationControllerSupportedInterfaceOrientations?(nav), .portrait, "forwarded")
            let cart = Cart()
            nav.pushViewController(cart, animated: false)
            nav.delegate?.navigationController?(nav, didShow: cart, animated: false)
            XCTAssertEqual(appDelegate.shown, 1)
            let routes = events.filter { $0.type == EventTypes.route }
            XCTAssertEqual(routes.last?.data["location"], "/cart?token=[REDACTED]")
            XCTAssertEqual(routes.last?.data["action"], "push")
            XCTAssertEqual(routes.last?.data["source"], "uikit")
            let snap = BugCapsuleNavigation.shared.snapshot(.periodic)
            XCTAssertEqual(snap?["route"], "/cart?token=%5BREDACTED%5D")
        }

        func testLifecycleReplayPostsNotifications() {
            var posted: [Notification.Name] = []
            let names: [Notification.Name] = [UIApplication.didEnterBackgroundNotification, UIApplication.willResignActiveNotification]
            let tokens = names.map { n in
                NotificationCenter.default.addObserver(forName: n, object: nil, queue: nil) { note in
                    let name = note.name
                    MainActor.assumeIsolated { posted.append(name) }
                }
            }
            XCTAssertTrue(LifecycleReplayer.post("inactive"))
            XCTAssertTrue(LifecycleReplayer.post("paused"))
            XCTAssertTrue(LifecycleReplayer.post("paused"), "same state is not posted twice")
            XCTAssertFalse(LifecycleReplayer.post("hidden"), "no iOS equivalent → lifecycle.unsupported")
            XCTAssertEqual(posted, [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification])
            tokens.forEach(NotificationCenter.default.removeObserver)
        }

        func testSwiftUITrackedTextBindingRecordsAndReplays() {
            var value = ""
            let binding = Binding(get: { value }, set: { value = $0 })
            let tracked = BugCapsule.trackedText("cart.coupon", binding)
            tracked.wrappedValue = "SAVE"
            XCTAssertEqual(value, "SAVE")
            XCTAssertEqual(events.last?.data["value"], "SAVE")
            XCTAssertTrue(ActionRegistry.shared.setText("cart.coupon", "SAVE100"))
            XCTAssertEqual(value, "SAVE100")
        }
    }
#endif
