# Changelog

## 0.4.1-beta.5

- Expose the optional iOS `BugCapsulePatch` product directly from the canonical
  repository-root SwiftPM package alongside core and XCTest helpers.
- Bundle the pinned iOS device/simulator runtime with complete SHA256 inventory;
  source release archives now retain the patch package and binaries.
- Preserve macOS core builds while keeping patch APIs iOS-only.


- Capsules with screenshots are no longer rejected: `capturedAtT` now moves
  with the event time when a capsule is rebased to its anchor. With a first
  frame over 1 s the backend answered `invalid_capsule` and dropped the whole
  capsule.
- Release-health sessions report `patchBaseBuildId` and `patchSetDigest`, so
  patch rollouts can be judged from real sessions. A session recovered on the
  next launch reports the patch it ran, not the current one.
- URLSession interception: a followed redirect could end the request on the
  3xx response when that response reached the loading system before the app's
  answer. The 3xx now waits for the answer, in capture and in replay. A
  refused redirect delivers its 3xx after 1 second, as a refusal can't be
  detected sooner; followed redirects don't wait.
- Native adapters: no `native.event` is recorded after its subscription was
  cancelled or ended. A cancel during an event could put the event after
  `native.cancel` in the capsule.
- Emergency recovery: guard decisions are recorded into capsules and replayed
  (emergency-client-v1 §7.8). A decision that changes writes an
  `emergency.decision` event through the usual capture path; subjects are
  written only as a hash, and at most 256 feature and subject pairs are
  tracked. Decisions made before recording starts are written when it starts,
  and every periodic checkpoint is followed by one event per tracked decision.
  `manifest.capabilities["emergency.decisions"]` is `supported`, or `partial`
  past the limit or when the capture rules drop a decision or change its `key`,
  `subject` or `action` (such a decision isn't kept). During replay `evaluate` returns
  the recorded decision with source `.replay` and no policy object, instead of
  always `ALLOW`; a feature the capsule has no decision for is still allowed.
  Idle compression ignores these events. `BugCapsule.emergency.updates` does
  nothing during a replay: no provider call, no App Store lookup, no status;
  `checkAvailability` reports no update available and `presentUpdate` returns
  `.notAvailable`. Passes the shared vectors in
  `spec-fixtures/emergency-v1/replay-decisions.json`.
- Emergency recovery: App Store update adapter and runtime reports
  (emergency-client-v1 §7.6, §7.7). `EmergencyConfiguration.updateProvider`
  takes an `EmergencyUpdateProvider`; `AppStoreUpdateProvider` checks the
  listed version with the public iTunes lookup API (bundle id and device
  storefront, overridable) against a `REQUIRE_UPDATE` decision's required
  version, and shows the App Store page (`SKStoreProductViewController`, or
  the store URL). `BugCapsule.emergency.updates` offers
  `checkAvailability(requiredVersion:)` / `checkAvailability(for:)`,
  `presentUpdate(from:)`, `markDeclined()` and `status`; failures are typed
  `EmergencyUpdateError`s and never count as available. The adapter's state
  is sent as `RUNTIME` receipts (on change, never the same object twice in a
  row, at most one per 60 s, latest wins; not in replay), and `APPLIED` /
  `FAILED` receipts carry it. Nothing is ever installed or downloaded.
  Objective-C: `BCAppStoreUpdateProvider`, `BCEmergencyConfiguration.updateProvider`,
  `BCEmergency.updates` (`BCEmergencyUpdates`).
- Emergency recovery (feature guards): `BugCapsule.emergency` fetches the
  project's signed emergency policies, verifies them (ECDSA P-256 against the
  `bcek.v1` trust anchor compiled into the app), caches them and answers
  `evaluate(featureKey:subject:)` / `isFeatureAllowed(_:)` synchronously:
  `ALLOW`, `BLOCK`, `READ_ONLY`, `REQUIRE_UPDATE`, `SHOW_MAINTENANCE`,
  `DISABLE_FEATURE` or `USE_SAFE_FALLBACK`, with the operator's message.
  Per-key failure modes (`failOpen` default, `failClosed`,
  `useLastValidPolicy`) apply when no usable document exists. Refreshes every
  60 s in the foreground and on resume, backs off on failures, stops on a
  refused credential, sends apply/reject receipts, and works without
  `BugCapsule.start` or with capture disabled. `changes`, `observe(_:)` and
  `status` report state; an Objective-C surface (`BCEmergency`) is included.
  Policies carry no code. Implements emergency-client-v1
  (`docs/emergency-client-v1.md`) and passes its shared vectors
  (`spec-fixtures/emergency-v1`).
- URLSession (security): the app's session delegate works for instrumented
  sessions. Authentication challenges (certificate pinning, mTLS client
  certificates, HTTP auth) were answered with default handling below the
  SDK and never reached the delegate; they are now forwarded to the app's
  session. Redirects were followed below the SDK without asking the
  delegate or applying its redirect policy; the app's session now decides
  and a followed redirect is re-issued through it. Capture records each
  redirect hop as its own exchange (the 3xx without its body, then the
  target) and replay serves recorded redirects as redirects. Capsules
  recorded before replay as before.
- URLSession (security): every instrumented configuration gets its own
  downstream session, built from a copy of that configuration. Requests
  were re-issued with the configuration passed to `instrument(_:)` last,
  so one session's `httpAdditionalHeaders` (e.g. `Authorization`) went out
  on another session's requests, an ephemeral session's cookies were stored
  in `HTTPCookieStorage.shared`, and the original session's cache policy,
  TLS, proxy and timeout settings were not applied. `URLSession.shared`
  (`instrumentSharedSession()`) uses `URLSessionConfiguration.default`.
  `instrument(_:)` now inserts a `BugCapsuleURLProtocol` subclass created
  for that configuration, so `protocolClasses.first` is no longer
  `BugCapsuleURLProtocol.self` itself; custom protocol classes of one
  configuration no longer run for another's requests.
- URLSession: a response is always delivered to the request that made it.
  Requests on two instrumented sessions in flight at the same time could
  get each other's response, and one of them then never completed.

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
