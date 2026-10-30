// swift-tools-version: 6.0
//
// The patch runtime lives in its own package so the BugCapsule package never
// resolves a binary target. Run scripts/sync_patch_runtime.sh first.
import PackageDescription

let package = Package(
    name: "BugCapsulePatch",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "BugCapsulePatch", targets: ["BugCapsulePatch"]),
    ],
    targets: [
        .binaryTarget(name: "BcpatchRuntime", path: "Binaries/BcpatchRuntime.xcframework"),
        .target(name: "BugCapsulePatch", dependencies: ["BcpatchRuntime"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(
            name: "BugCapsulePatchTests",
            dependencies: ["BugCapsulePatch", "BcpatchRuntime"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
