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
    as `event.threads`, not only the crashing one: crashed thread first, then
    main; at most 100 threads, 250 frames for the crashed one, 40 for the
    others, 1,500 in all and 448 KiB of JSON. App hang events attach every
    thread too (main, the hung one, first).
  - On arm64, a crash in a leaf function now includes its caller (the link
    register) as the first caller frame.
  - MetricKit (iOS 14+): crash diagnostics become `fatal` events (mechanism
    `metrickit`), hang diagnostics `app_hang` errors, both with
    `data.source: "metrickit"`. One BugCapsule already reported (a crash
    report or a watchdog hang of the same process, or within 60 s) is not
    sent again. `enableMetricKit: false` turns it off.
  - A crash report, the recovered session and MetricKit events are written
    to the outbox before the report is deleted, so a crash right after
    launch doesn't lose them.
  - Add `BugCapsuleCrashBridge`, for SDKs that embed BugCapsule for iOS
    (the Flutter SDK): crash handlers, hang watchdog and MetricKit without
    the SDK's sessions or uploads. Same shape as Android's `CrashBridge`
    (`install`, `updateScope(json:)`, `takePendingEvents(timeoutMs:)`,
    `setListener`, `lastRunCrashed`, `nativeCrashHandlerInstalled`).

## 0.4.1-beta.2 — 2026-10-25

- Add single SDK token setup and connection status diagnostics.
- Report missing replay instrumentation and stop uploads when credentials are rejected.
- Update developer setup and integration documentation.
