import Foundation
import XCTest
@testable import BugCapsule

@MainActor final class ScreenshotTests: XCTestCase {
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAAC0lEQVR4nGNgAAMAAAcAAbKGrPQAAAAASUVORK5CYII=")!
    override func tearDown() async throws { await BugCapsule.resetForTesting() }
    func start(_ i: ScreenshotIntegration, drop: Bool = false) async {
        await BugCapsule.resetForTesting()
        var c = BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa)
        c.beforeRecord = { type, data in drop && type == "screenshot" ? nil : data }
        BugCapsule.start(c, integrations: [i], overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory(), captureSettleDelay: 0.01))
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    func testPortableFrameAndThrottle() async throws {
        let png = self.png
        let i = ScreenshotIntegration(enabled: true, captureRedactedPng: { png })
        await start(i)
        XCTAssertTrue(i.capture()); XCTAssertFalse(i.capture())
        let result = await BugCapsule.capture()
        let capsule = try CapsuleCodec.decode(Data(contentsOf: XCTUnwrap(result).file))
        XCTAssertEqual(capsule.events.filter { $0.type == "screenshot" }.first?.data["base64"], .string(png.base64EncodedString()))
    }
    func testDisabledMalformedAndPrivacyHook() async throws {
        let off = ScreenshotIntegration(captureRedactedPng: { XCTFail("provider must not run"); return nil })
        await start(off); XCTAssertFalse(off.capture())
        let bad = ScreenshotIntegration(enabled: true, captureRedactedPng: { Data([1, 2, 3]) })
        await start(bad); XCTAssertFalse(bad.capture())
        let png = self.png
        let i = ScreenshotIntegration(enabled: true, captureRedactedPng: { png })
        await start(i, drop: true); _ = i.capture()
        let result = await BugCapsule.capture()
        let capsule = try CapsuleCodec.decode(Data(contentsOf: XCTUnwrap(result).file))
        XCTAssertFalse(capsule.events.contains { $0.type == "screenshot" })
    }
}
