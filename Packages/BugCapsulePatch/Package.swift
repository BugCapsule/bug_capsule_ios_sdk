// swift-tools-version: 6.0
// Compatibility entry point for existing local source checkouts (Xcode 27+).
// Remote consumers select BugCapsulePatch from the repository-root package.
// Its product has the root product's name, which Xcode 26 cannot load in one
// graph; its tests live in the root package (BugCapsulePatchTests).
import PackageDescription
let package = Package(
    name: "BugCapsulePatchLocal",
    platforms: [.iOS(.v15)],
    products: [.library(name: "BugCapsulePatch", targets: ["BugCapsulePatchCompatibility"])],
    dependencies: [.package(name: "BugCapsule", path: "../..")],
    targets: [
        .target(
            name: "BugCapsulePatchCompatibility",
            dependencies: [.product(name: "BugCapsulePatch", package: "BugCapsule")],
            path: "Compatibility"
        ),
    ]
)
