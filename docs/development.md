# Working on the iOS SDK

For maintainers of this repository. App developers want the
[README](../README.md) instead.

## Build and test

```bash
swift build
swift test                                    # macOS host: core, conformance, network, outbox, replay, monitoring
swift test -c release -Xswiftc -enable-testing --filter ReplayProtocolTests/testGate   # a release build cannot arm replay
xcodebuild test -scheme BugCapsule-Package -destination 'platform=iOS Simulator,name=iPhone 18 Pro'  # same suite + UIKit tests on iOS
cd Examples/Demo && xcodebuild build-for-testing -project BugCapsuleDemo.xcodeproj -scheme BugCapsuleDemo \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

The demo project is generated from `Examples/Demo/project.yml` with XcodeGen
(`xcodegen generate`); the generated project is checked in.

## Shared fixtures

`spec-fixtures/` is a copy of the Flutter SDK's `spec/fixtures`. Re-sync with
`tool/sync_spec.sh` in
[bug_capsule_flutter_sdk](https://github.com/BugCapsule/bug_capsule_flutter_sdk),
with both repositories checked out side by side. `FixtureTests` fails when the
copy differs from a sibling checkout.

## Release procedure

SwiftPM is distributed by git tag; there is nothing to upload.

1. Update `sdkVersion` in `Sources/BugCapsule/Runtime/Session.swift` and the
   version in the README; sync `spec-fixtures`.
2. Run the test commands above and an end-to-end replay of the demo
   (`bugcapsule run` / `verify`).
3. Tag `vX.Y.Z` (semantic versioning) and push the tag. Publish release notes
   listing capability changes.
4. Binary distribution is not needed (source package, no dependencies). An
   XCFramework could be produced with `xcodebuild archive` +
   `-create-xcframework` if a closed-source build is ever required.

Validation evidence for past releases: [release-readiness.md](release-readiness.md).
