// swift-tools-version: 6.0
//
// BugCapsule for iOS. Consumed by git URL through Swift Package Manager:
//
//   .package(url: "https://github.com/BugCapsule/bug_capsule_ios_sdk.git", from: "0.4.0")
//
// Products:
//   BugCapsule        the SDK linked into the app target
//   BugCapsuleXCTest  helpers for the app's UI test target (replay runner)
import PackageDescription

let package = Package(
    name: "BugCapsule",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "BugCapsule", targets: ["BugCapsule"]),
        .library(name: "BugCapsuleXCTest", targets: ["BugCapsuleXCTest"]),
        .library(name: "BugCapsulePatch", targets: ["BugCapsulePatch"]),
    ],
    targets: [
        .binaryTarget(name: "BcpatchRuntime", path: "Packages/BugCapsulePatch/Binaries/BcpatchRuntime.xcframework"),
        .target(
            name: "BugCapsulePatch",
            dependencies: ["BugCapsule", .target(name: "BcpatchRuntime", condition: .when(platforms: [.iOS]))],
            path: "Packages/BugCapsulePatch/Sources/BugCapsulePatch",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Async-signal-safe native crash writer (signals, Mach exceptions).
        .target(
            name: "BugCapsuleCrash",
            path: "Sources/BugCapsuleCrash",
            publicHeadersPath: "include"
        ),
        .target(
            name: "BugCapsule",
            dependencies: ["BugCapsuleCrash"],
            path: "Sources/BugCapsule",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "BugCapsuleXCTest",
            dependencies: ["BugCapsule"],
            path: "Sources/BugCapsuleXCTest",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedFramework("XCTest")]
        ),
        .testTarget(
            name: "BugCapsuleTests",
            dependencies: ["BugCapsule"],
            path: "Tests/BugCapsuleTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
