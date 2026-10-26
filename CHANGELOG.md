# Changelog

## Unreleased

- Read capsule spec v2 (interaction dependencies) as well as v1; write v2
  only for capsules that recorded a WebSocket or a native adapter.
- Add WebSocket capture and offline replay through `BugCapsuleWebSocket` and
  `BugCapsuleWebSockets`.
- Add the native adapter API (`BugCapsuleNativeAdapter`,
  `BugCapsuleNativeBridge`), an example location adapter and
  `BugCapsuleAdapterConformance` for testing adapters offline.
- Verdicts report interaction reason codes; replay refuses capsules whose
  dependencies this app can't serve (`dependency.unsupported`).
- The project's capture settings can switch off a single adapter.
- Crash reporting:
  - Sessions recovered on the next launch (`crashed`, `abnormal`, `exited`)
    and native crash events keep the release and environment of the run
    that ended, also after an app update. Session files from older versions
    fall back to the current release.
  - Native crash reports (signals and Mach exceptions) include every thread
    (up to 100 threads, 100 frames each) as `event.threads`, not only the
    crashing one. App hang events also attach every thread, main first.
  - On arm64, a crash in a leaf function now includes its caller (the link
    register) as the first caller frame.
  - MetricKit (iOS 14+): crash diagnostics become `fatal` events (mechanism
    `metrickit`), sent only when BugCapsule did not report the same crash
    within 60 s; hang diagnostics become `app_hang` errors.
    `enableMetricKit: false` turns it off.
  - Add `BugCapsuleCrashBridge`, for SDKs that embed BugCapsule for iOS
    (the Flutter SDK): crash handlers, hang watchdog and MetricKit without
    the SDK's sessions or uploads. Same shape as Android's `CrashBridge`.

## 0.4.1-beta.2 — 2026-10-25

- Add single SDK token setup and connection status diagnostics.
- Report missing replay instrumentation and stop uploads when credentials are rejected.
- Update developer setup and integration documentation.
