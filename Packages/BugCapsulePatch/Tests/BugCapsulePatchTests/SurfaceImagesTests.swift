import XCTest
@testable import BugCapsulePatch

final class SurfaceImagesTests: XCTestCase {
    private var document: [String: Any] {
        ["type": "column", "children": [
            ["type": "button", "label": "Pay", "action": "pay"],
            ["type": "list", "children": [["type": "image", "asset": "brand.logo", "label": "Brand logo"]]]
        ]]
    }
    func testEveryReferencedImageIsAvailable() {
        XCTAssertTrue(surfaceImagesAvailable(document, available: ["brand.logo"]))
    }
    func testMissingNestedImageRejectsWholeTree() {
        XCTAssertFalse(surfaceImagesAvailable(document, available: []))
        XCTAssertFalse(surfaceImagesAvailable(document, available: ["other.logo"]))
    }
    func testSurfaceWithoutImagesRemainsCompatible() {
        XCTAssertTrue(surfaceImagesAvailable(["type": "text", "text": "Checkout"], available: []))
    }
    func testEveryImageAndAccessibilityLabelRequired() {
        let root: [String: Any] = ["type": "column", "children": [document,
            ["type": "image", "asset": "badge", "label": "Verified"]]]
        XCTAssertFalse(surfaceImagesAvailable(root, available: ["brand.logo"]))
        XCTAssertTrue(surfaceImagesAvailable(root, available: ["brand.logo", "badge"]))
        XCTAssertFalse(surfaceImagesAvailable(["type": "image", "asset": "badge"], available: ["badge"]))
    }
}
