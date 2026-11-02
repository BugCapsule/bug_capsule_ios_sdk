// swift-tools-version: 6.0
// Compatibility entry point for existing local source checkouts.
// Remote consumers select BugCapsulePatch from the repository-root package.
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
        // Through the compatibility target, not the root product again: Xcode 26.6
        // registered the product's dynamic variant once per dependent and failed
        // with "GUID … has already been registered" (BC-ENT-053).
        .testTarget(
            name: "BugCapsulePatchTests",
            dependencies: ["BugCapsulePatchCompatibility"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
