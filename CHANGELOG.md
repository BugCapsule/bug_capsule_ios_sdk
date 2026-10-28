# Changelog

## 0.4.1-beta.4 — 2026-10-28

- Apply the project's `maxInteractionPayloadBytes` capture setting to every interaction adapter (`RemoteCaptureConfig.maxInteractionPayloadBytes`).
- Crash capsules keep at most 98 app labels, so the two crash labels fit and an app with 99 or more labels no longer loses its crash capsule to validation.

## 0.4.1-beta.3 — 2026-10-27

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
- Crash capsules (crash-capsules.md): a native crash is now replayable.
  - While a session records, a crash journal mirrors the flight recorder
    to `Application Support/bugcapsule/journal/<pid>/` (header, launch and
    newest periodic checkpoint, one events file per checkpoint), written by
    a background queue at least every 250 ms and at once on a checkpoint, a
    failure and going to the background; at most `2 × maxCapsuleBytes`;
    protected until first unlock. The synchronous NSException capsule
    deletes it; a session that doesn't record keeps none.
  - On the next launch, a signal or Mach crash report of a process that
    kept a journal becomes a capsule (failure kind `crash`, signature
    `crash:<type>`, e.g. `crash:SIGSEGV`, `crash:EXC_BAD_ACCESS`), built off
    the main thread and queued before its `fatal` event, which carries its
    `capsuleId`. The capsule is spec v2, `partial` (`crash.native` gap), with
    `labels.source: "crash_journal"`, `labels["crash.mechanism"]` and
    `stats.journalGapMs`. Crash capsules don't count against
    `maxCapsulesPerSession`.
  - MetricKit: the journal of a process that died in the foreground without
    a crash report is kept up to 7 days; a MetricKit crash diagnostic of
    that process (iOS 17+ `pid`) gets its capsule when it arrives. A
    watchdog kill (`0x8badf00d`) is type `ApplicationNotResponding`.
  - Unclaimed journals are deleted on the next launch, any journal after
    7 days, all of them by the kill switch.
  - Crash reports now carry the crash time in milliseconds (`timems`).
  - Replay: `BugCapsuleXCTest` (which now depends on `BugCapsule`) judges
    a crash capsule's attempt from the simulator's crash report when the
    app dies: `reproduced` for the same signal / Mach exception / uncaught
    NSException (`failure.different_frame` when the in-app frame differs),
    `inconclusive` with `failure.different` for another type. In the app,
    an `ApplicationNotResponding` capsule is reproduced when the main thread
    is blocked past 2 s. New `ReplayOutcome.inconclusive` and
    `ReplayReport.reasonCodes`.
  - Reading: failure kind `crash` (with `failure.crash`) is valid in spec v2
    documents, and `stats.journalGapMs`.

## 0.4.1-beta.2 — 2026-10-25

- Add single SDK token setup and connection status diagnostics.
- Report missing replay instrumentation and stop uploads when credentials are rejected.
- Update developer setup and integration documentation.
