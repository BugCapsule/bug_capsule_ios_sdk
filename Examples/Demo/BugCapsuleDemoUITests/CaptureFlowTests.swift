import XCTest

/// UI automation that drives the demo into each planted bug so BugCapsule
/// captures it (test automation for capture, not replay). Each attempt is a
/// fresh app session, so every capsule holds one short session.
final class CaptureFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    private func launch(reset: Bool = true, offline: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        if reset { app.launchArguments.append("-DemoResetStorage") }
        if offline { app.launchEnvironment["BUGCAPSULE_DEMO_BACKEND_URL"] = "http://127.0.0.1:9" }
        app.launch()
        return app
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, timeout: TimeInterval = 10, _ predicate: (String) -> Bool) -> String? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if element.exists {
                let label = element.label
                if predicate(label) { return label }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    /// Bug 1: SAVE100 on a cart below 100 → `cart_total_non_negative`.
    @MainActor
    func testCaptureNegativeTotal() throws {
        for attempt in 1...15 {
            let app = launch()
            app.buttons["home.openCart"].tap()
            let status = app.staticTexts["cart.status"]
            guard waitForLabel(status, { $0 == "ready" }) != nil else {
                app.terminate()
                continue
            }
            let field = app.textFields["cart.coupon"]
            field.tap()
            field.typeText("SAVE100")
            app.buttons["cart.applyCoupon"].tap()
            let total = app.staticTexts["cart.total"].label
            print("[capture] attempt \(attempt): total \(total)")
            if total.hasPrefix("-") {
                Thread.sleep(forTimeInterval: 4)  // settle + upload
                app.terminate()
                return
            }
            app.terminate()
        }
        XCTFail("bug 1 not hit in 15 attempts")
    }

    /// Bug 2: recommendations before profile → NSException crash; the
    /// capsule written by the crash handler uploads on the next launch.
    @MainActor
    func testCaptureRaceCrash() throws {
        // The planted crash is the point of this test.
        XCTExpectFailure("the race bug crashes the app", options: .nonStrict())
        for attempt in 1...25 {
            let app = launch()
            app.buttons["home.refresh"].tap()
            let won = waitForLabel(app.staticTexts["home.banner"], timeout: 4) { $0.hasPrefix("Picks for") }
            if won == nil {
                print("[capture] attempt \(attempt): app crashed (race hit); relaunching to upload")
                let again = launch(reset: false)
                Thread.sleep(forTimeInterval: 6)
                again.terminate()
                return
            }
            print("[capture] attempt \(attempt): profile won the race")
            app.terminate()
        }
        XCTFail("bug 2 not hit in 25 attempts")
    }

    /// Bug 3: a v0.9 cart in UserDefaults (written in a previous session)
    /// breaks loading the cart in the next one.
    @MainActor
    func testCaptureLegacyCart() throws {
        let first = launch()
        first.buttons["home.simulateUpgrade"].tap()
        XCTAssertNotNil(waitForLabel(first.staticTexts["home.status"]) { $0.contains("legacy") })
        first.terminate()
        let app = launch(reset: false)
        app.buttons["home.openCart"].tap()
        XCTAssertNotNil(waitForLabel(app.staticTexts["cart.status"]) { $0.hasPrefix("error") })
        Thread.sleep(forTimeInterval: 4)
        app.terminate()
    }

    /// Offline capture, part 1: the backend is unreachable while the bug
    /// happens; the capsule stays queued in the outbox.
    @MainActor
    func testOffline1CaptureWhileBackendUnreachable() throws {
        let first = launch()
        first.buttons["home.simulateUpgrade"].tap()
        XCTAssertNotNil(waitForLabel(first.staticTexts["home.status"]) { $0.contains("legacy") })
        first.terminate()
        let offline = launch(reset: false, offline: true)
        offline.buttons["home.openCart"].tap()
        XCTAssertNotNil(waitForLabel(offline.staticTexts["cart.status"]) { $0.hasPrefix("error") })
        Thread.sleep(forTimeInterval: 3)
        offline.terminate()
    }

    /// Offline capture, part 2: restart with the backend reachable; the
    /// queued capsule uploads.
    @MainActor
    func testOffline2RestartWithBackendUploadsQueued() throws {
        let online = launch(reset: true)
        Thread.sleep(forTimeInterval: 6)
        online.terminate()
    }
}
