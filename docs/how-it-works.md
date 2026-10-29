# How the iOS SDK works

Reference details behind the [README](../README.md): the full API, what is
captured and when, monitoring internals, how replay runs, how data is stored
and sent, and the full list of limitations. The capsule format is documented
at [docs.bugcapsule.com/capsule-format](https://docs.bugcapsule.com/capsule-format.html).

| | |
|---|---|
| SDK name in capsules and envelopes | `bugcapsule-ios`, `runtime.name: ios`, `language: swift` |
| Platforms | iOS 15+ (the package also builds on macOS 12+ for its unit tests) |
| Language | Swift 6 language mode, strict concurrency |
| Products | `BugCapsule` (app target), `BugCapsuleXCTest` (UI test target) |
| Dependencies | none (Foundation, zlib, UIKit/SwiftUI/CoreData when available). The package has a small C target, `BugCapsuleCrash` (async-signal-safe crash writer) |

## Integration reference

| API | Purpose |
|---|---|
| `BugCapsule.start(token:integrations:)` | Start with the SDK token and defaults. |
| `BugCapsule.start(_:integrations:)` | Start capture (or replay, see below) with a full `BugCapsuleConfig`. |
| `BugCapsule.status` | Connection state and the two confirmations, plus installed / missing instrumentation. |
| `BugCapsuleConnectionToken.parse(_:)`, `BugCapsuleBackendConfig(token:)` | Parse a token offline (`invalid_token` / `unsupported_token_version` with an actionable message). |
| `BugCapsuleConfig` | `token`, `mode`, `enabled`, `backend` (wins over `token`), `gitSha`/`gitDirty`, `stateSchemaVersion`, `checkpointInterval` (30 s), `window` (5 min), `maxEvents` (20,000), `productionSampleRate` (0.1), `autoCaptureOnFailure`, `maxCapsulesPerSession` (3), `captureNetworkBodies`, `maxBodyBytes` (256 KiB), `redactKeys`, `redactHeaders`, `redactPatterns`, `beforeRecord`, `beforeCheckpoint`, `outboxLimits` (10 / 10 MiB / 7 days), `maxStaleConfig` (7 days), `ignoreError`, `labels`. |
| `BugCapsule.action(_:_:)`, `uiAction(_:_:)`, `registerAction`, `recordAction` | Semantic actions. |
| `BugCapsule.trackText(_:field:)`, `trackedText(_:_:)`, `trackText(_:setter:)` + `textChanged` | Tracked text. |
| `BugCapsule.check / fail / report(error:) / report(exception:)` | Failures. |
| `BugCapsule.log(_:level:)` | `log` events. |
| `BugCapsule.capture(note:)` | Manual capture (QA button); uses the latest failure if any, otherwise the capsule is `ineligible`. |
| `BugCapsule.savedCaptures()` | The newest 20 capsule files. |
| `BugCapsule.refreshRemoteConfig()`, `flushUploads()` | Force a config fetch / an upload pass (foreground only). |
| `BugCapsule.random` | Seeded `RandomNumberGenerator` (`nextInt`, `nextDouble`), re-seeded in replay. |
| `BugCapsule.now()` | Wall clock; the virtual replay clock in replay. |
| `BugCapsule.instrument(_:)`, `instrumentSharedSession()` | URLSession capture/replay. |
| `BugCapsule.observe(_:)`, `BugCapsuleNavigation.shared.setRoute`, `.bugCapsuleRoute(_:)`, `BugCapsuleRouteNaming` | Navigation. |
| `BugCapsule.registerState(_:snapshot:restore:)`, `stateChanged` | App state in checkpoints (`state`). |
| `BugCapsuleWindow`, `BugCapsule.recordTouches(_:in:)` | Explicit pointer capture. |
| `BugCapsuleWebSockets`, `BugCapsuleWebSocket` | WebSocket capture/replay (see [Interaction dependencies](#interaction-dependencies-websockets-and-native-adapters)). |
| `BugCapsuleNativeAdapter`, `BugCapsuleNativeIntegration`, `BugCapsuleNativeBridge` | Adapters for third-party SDKs. |
| `BugCapsuleAdapterConformance.run` | Offline conformance run for an adapter. |
| `BugCapsuleIntegration` | Write your own integration (name, snapshot, restore, eligibility). |

Integrations and their checkpoint keys: `urlsession` (events only),
`user_defaults` (`{key: {type, value}}`; types `bool`, `int`, `double`,
`string`, `stringArray`, `data` base64, `date` epoch ms), `navigation`
(`{route, backStack}`, periodic checkpoints), `state` (`{key: <JSON>}`).

### URLSession interception

`BugCapsule.instrument(config)` puts a `BugCapsuleURLProtocol` subclass
created for that configuration first in its `protocolClasses`. The protocol
re-issues each request on a downstream session built from a copy of the
configuration as it was when `instrument` ran, minus the SDK's protocol:
`httpAdditionalHeaders`, cookie storage, cache policy, credential storage, TLS,
proxy and timeout settings and its own protocol classes apply to that
configuration's requests only, never to another session's. Finish setting up
a configuration before instrumenting it. Requests reached through
`instrumentSharedSession()` use `URLSessionConfiguration.default`, as
`URLSession.shared` does. A downstream session is closed after 60 s without
requests and re-created when needed. Requests the SDK re-issues are marked
and never intercepted again.

The app's session delegate works for instrumented sessions as without the SDK:

* Authentication challenges (server trust for certificate pinning, client
  certificates for mTLS, HTTP authentication) are forwarded to the app's
  session, which asks its delegate (or applies default handling), and its
  answer completes the challenge below the SDK. Pinning that rejects a
  certificate fails the request as it does without the SDK. The forwarded
  challenge has no `failureResponse` or `error`: URLSession drops the answer
  to a forwarded challenge that carries a failure response.
* Redirects are not followed below the SDK. The app's session gets
  `willPerformHTTPRedirection` and its redirect policy decides; a followed
  redirect goes through the SDK's protocol again. Capture records each hop
  as its own exchange (the 3xx with its `Location` and an empty body, then
  the target), and replay serves the 3xx as a redirect, so the app's
  session follows it to the next fixture.

## Supported frameworks and capabilities

Frameworks seen are listed in `manifest.runtime.frameworks` (`uikit`,
`swiftui`). `manifest.capabilities` declares:

| Capability | Value | Meaning |
|---|---|---|
| `input.semantic.replay` | supported | Registered actions invoked by id. |
| `text.replay` | supported | Tracked text restored by id (UIKit fields get `.editingChanged`). |
| `input.pointer.capture` | explicit | Touches recorded when the app uses `BugCapsuleWindow` / `recordTouches`. |
| `input.pointer.replay` | **unsupported** | See [Limitations](#limitations). |
| `lifecycle.replay` | partial | `UIApplication` notifications are posted; the real application state does not change. |
| `network.urlsession` | supported | URLSession (and Alamofire through its configuration). |
| `storage.user_defaults` | supported | Allowlisted keys only. |
| `navigation.uikit`, `navigation.explicit` | explicit | Through `observe` / `setRoute`. |
| `clock.virtual`, `random.seeded` | explicit | Only through `BugCapsule.now()` / `BugCapsule.random`. |
| `crash.uncaught` | partial | NSException only, best effort, uploaded next launch. |
| `interaction.websocket` | supported | Through `BugCapsuleWebSocket` (adapter `bugcapsule-ios.urlsession-websocket`). |
| `interaction.native.<adapter>` | supported | One per installed native adapter. |

## Failure capture boundaries

Captured automatically:

* failures the app reports: `BugCapsule.check`, `BugCapsule.fail`,
  `BugCapsule.report(error:)` (type `String(describing: type(of: error))`,
  message `String(describing: error)`), `BugCapsule.report(exception:)`;
* uncaught Objective-C `NSException`s (thrown by UIKit/Foundation or with
  `NSException.raise()`), through a chained `NSSetUncaughtExceptionHandler`. The
  previously installed handler (e.g. a crash reporter) is always called
  afterwards. The capsule is built and written synchronously to the outbox and
  uploaded on the next launch; it carries `crash.persisted` in its eligibility
  (nothing after the crash point exists). This is best effort: the process is
  terminating.

**A capsule on the next launch** ([crash capsules](#crash-capsules)), when
the session that crashed was recording and monitoring's crash handler ran:

* Swift runtime traps (`fatalError`, `precondition`, force-unwrapping `nil`,
  array index out of range, integer overflow, `try!`), POSIX signals
  (`SIGSEGV`, `SIGBUS`, `SIGABRT` from `abort()`, ...) and Mach exceptions.
  Building a capsule is not async-signal-safe, so the crash writer only
  writes its report; the next launch sends a `fatal` event with the crashing
  thread's stack and every other thread's, marks the session `crashed`, and
  builds the capsule from the crash journal.
* Watchdog kills and crashes the handler missed, when iOS delivers a
  MetricKit crash diagnostic naming the process (iOS 17+) within 7 days.

**No capsule** (but a monitoring event or session status), and never claimed:

* Out-of-memory (jetsam) terminations and the user force-quitting the app in
  the foreground: no code runs and MetricKit sends no crash diagnostic. The
  next launch reports the session as `abnormal` (no event).
* C++ exceptions are reported as the `SIGABRT` that follows them, without the
  C++ type.

For a replayable capsule of such a failure, report the condition yourself
(`check`/`report(error:)`) before the code that would trap. Exchanges still in flight when a capsule is written (typically by
the crash handler) are recorded as `http` events with `"pending": true`; replay
keeps those requests open, as the app never got their response.

## Monitoring

On by default (`BugCapsuleConfig.monitoring`); nothing is sent without a
token or `backend`. Turn it all off with `monitoring: .disabled`, or remotely with
`monitoringEnabled: false` (capsules are unaffected). Replay sessions never
monitor (no events, sessions or trace headers).

```swift
var config = BugCapsuleConfig(token: "bcsdk.v1.…")
config.monitoring = BugCapsuleMonitoringOptions(
    tracesSampleRate: 0.2,                               // remote tracesSampleRate overrides it
    tracePropagationTargets: ["api.shop.example.com"],   // substrings or "/regex/"; none by default
    enableTimeToFullDisplayTracing: true,
    enableShakeToReport: true)
BugCapsule.start(config, integrations: [BugCapsuleURLSession(), BugCapsuleNavigation.shared])
```

Defaults: `release` = `<bundle id>@<version>+<build>`, `environment` =
`production` / `qa` / `development` from the capture mode.

### Errors

| What | How | Event |
|---|---|---|
| `BugCapsule.captureException(error, options:)`, `report(error:)`, `fail`/`check` | also the capsule pipeline: when a capsule is written for the failure, the event has `capsuleId` and the capsule `manifest.monitoring = {eventId, traceId, release, environment}` | `error`, mechanism `manual` / `assertion`, handled |
| `captureMessage(_:level:)` | event only; `attachStacktrace` adds the calling thread | `message` |
| Uncaught `NSException` | chained handler; event written synchronously, sent next launch | `fatal`, `nsexception`, unhandled |
| Signals (`SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGFPE`, `SIGTRAP`, `SIGABRT`, `SIGSYS`) and Mach exceptions (`EXC_BAD_ACCESS`, `EXC_BAD_INSTRUCTION`, `EXC_ARITHMETIC`, `EXC_BREAKPOINT`) | C handler (`BugCapsuleCrash`): preallocated buffers, only async-signal-safe calls, frame-pointer walk through `vm_read_overwrite`; the other threads are listed with `task_threads`, suspended while they are walked and resumed before the report is written (Mach exception thread; best effort from the signal handler); on arm64 the link register is added as the first caller when the pc is in a leaf function; writes `monitoring/crash.report` with the threads, the release and environment, the scope (tags, user, breadcrumbs, contexts) and the loaded images mirrored before the crash; previous handlers / exception ports are chained | `fatal`, `signal` / `mach_exception`, `threads` (crashed first, then main; ≤ 100 threads, 250 frames for the crashed one, 40 for the others, 1,500 in all, ≤ 448 KiB), sent next launch; the report is deleted only once the event is in the outbox |
| App hangs | watchdog thread; main thread blocked ≥ 2 s (`appHangTimeout`) in the foreground; one event per hang with every thread sampled (main, the hung thread, first and `crashed`); off under a debugger | `App Hanging`, `app_hang` |
| MetricKit (iOS 14+, `enableMetricKit`) | `MXMetricManager` subscriber registered off the main thread; call stack trees become frames and `macho` images. A diagnostic of a crash or hang BugCapsule reported itself (`monitoring/crash_times.json`: same pid within the payload's window, or within 60 s) is dropped; events are written to the outbox before the callback returns; the release is the diagnostic's build (`<bundle id>@<version>+<build>` unless `release` is custom) | `fatal`, `metrickit`; hangs `error`, `app_hang` |

Frames carry `instructionAddr` (callers adjusted into the call instruction)
and `package`; `debugImages` are the `macho` images the frames point into
(LC_UUID, load address, `__TEXT` vmaddr and size). System frames are named on
device with `dladdr` (Swift names demangled); app frames are symbolicated by
the server from the uploaded dSYM. `inApp` is the main executable (plus
`inAppIncludes` / minus `inAppExcludes`).

Scope (`setUser`, `setTag(s)`, `setExtra(s)`, `setContext`, `setLevel`,
`setFingerprint`, `addBreadcrumb`, `clearBreadcrumbs`, `configureScope`,
`withScope` for a temporary copy), `beforeSend(event, hint)`,
`errorSampleRate` (fatal and capsule-linked events are always sent),
`lastEventId()`, `flush(timeout:)`, `close()`.

Breadcrumbs come from the same event stream as capsules (route, action,
tracked-text id without its value, http, lifecycle, log, state, failure), so
nothing is instrumented twice. They are collected even when the session is
not recording a capsule (production sampling); `maxBreadcrumbs` (100, remote
override) and `beforeBreadcrumb` apply.

### Release health

One session per foreground run, ending after 30 s in the background
(`sessionTimeout`). Updates: `init` on start, one when the first error is
captured, the end (`exited`; with errors it counts as errored). The open
session is persisted; the next launch closes an unfinished one as `crashed`
(crash report present), `abnormal` (died in the foreground: OOM, watchdog,
force-quit) or `exited` (died in the background), with the release and
environment it ran with (persisted; older files fall back to the current
release). `did` is the user id or a
random install id. `startSession()` / `endSession()` for manual control;
`enableAutoSessionTracking: false` or remote `sessionTracking: false` to turn
it off. Sessions are never sampled.

### Tracing

* `startTransaction(name:op:bindToScope:)`, `startSpan(name:op:) { span in }`
  (sync and async; the span is active inside the closure), `span.startChild`,
  `setData`, `setTag`, `setStatus`, `finish()`. Sampling once per root
  (`tracesSampler`, else the remote rate, else `tracesSampleRate`); the
  decision propagates to children and through `traceparent`.
* Screens (`ui.load`): every screen shown by a navigation controller passed to
  `BugCapsule.observe(_:)`, every SwiftUI view with `.bugCapsuleRoute(_:)`,
  and `BugCapsule.screenWillAppear(_:)` for anything else (modals, tabs). TTID
  is the first frame after the screen starts; with
  `enableTimeToFullDisplayTracing`, TTFD ends at
  `BugCapsule.reportFullyDisplayed()` (30 s deadline). Ids in names become
  `:id`. The transaction ends when its child spans have been idle for 3 s.
* App start: `app.start.cold` from process start (or `app.start.warm` when
  iOS prewarmed the process, from SDK start) to the first frame after the app
  became active, with `app_start_cold`/`app_start_warm`.
* Frames: `CADisplayLink` counts total, slow (> 1.5 × refresh interval) and
  frozen (≥ 700 ms) frames; every transaction gets `frames_total`,
  `frames_slow`, `frames_frozen`, `frames_delay`.
* User interactions: a recorded action starts an `ui.action.click`
  transaction when no screen load is running (dropped if it started no span).
* URLSession: instrumented sessions (`BugCapsule.instrument`) get an
  `http.client` span under the active span, and requests to
  `tracePropagationTargets` get `traceparent` and `baggage` (existing
  `baggage` entries kept, an existing `traceparent` never replaced). The
  headers are added to the forwarded copy only: capsule request keys and
  recorded request headers are unchanged, and replay never adds them. When
  the session is not recording a capsule, the SDK's URL protocol still runs
  for monitoring (spans, headers, http breadcrumbs) without recording bodies.
* Core Data: `context.bugCapsuleFetch(request)` / `context.bugCapsuleSave()`
  record `db.sql.query` spans (explicit wrappers, no swizzling).
* Custom clients: `getTraceparent()`, `getBaggage(existing:)`,
  `continueTrace(traceparent:baggage:)`; `beforeSendTransaction`.

### User feedback

`captureFeedback(message:name:email:associatedEventId:url:tags:capsuleId:)`,
`BugCapsuleFeedbackViewController` (UIKit; `BugCapsule.showFeedbackForm()`),
`BugCapsuleFeedbackForm` / `.bugCapsuleFeedbackSheet(isPresented:)`
(SwiftUI). The forms link the feedback to `lastEventId()` and, with
`captureCapsuleWithFeedback` (default in `qa` mode) while recording, write a
capsule and link it. Shake to report: `enableShakeToReport` with
`BugCapsuleWindow` as the window class, or call `BugCapsule.handleShake()`
from your window's `motionEnded(_:with:)` (no swizzling).

### Uploading dSYMs

`scripts/bugcapsule-upload-dsyms.sh` uploads each DWARF file once per UUID and
architecture (gzipped). It needs the project **secret** key, so run it in CI or a local
build, never ship the key:

```bash
BUGCAPSULE_URL=https://api.bugcapsule.com BUGCAPSULE_SECRET_KEY=bcs_... \
  scripts/bugcapsule-upload-dsyms.sh build/App.xcarchive/dSYMs
```

As an Xcode Run Script build phase (Release, `DEBUG_INFORMATION_FORMAT =
dwarf-with-dsym`; set the two variables in the scheme or CI environment):

```bash
"${BUILD_DIR%/Build/*}/SourcePackages/checkouts/bug_capsule_ios_sdk/scripts/bugcapsule-upload-dsyms.sh"
```

Inside Xcode it reads `DWARF_DSYM_FOLDER_PATH`, skips `Debug` builds and never
fails the build (`BUGCAPSULE_ALLOW_FAILURE=0` to make upload errors fatal).

### Envelopes

Items are redacted with the capsule rules (keys, headers, URL parameters,
free text; ids, timestamps, addresses and debug images are kept) before they
are persisted, batched for 1 s (≤ 100 items) into one envelope, gzipped on
disk in `bugcapsule/envelopes/` (30 envelopes / 5 MiB / 7 days,
`outboxLimits`), and sent with `sentAt` added, gzipped over 1 KiB. Same rules
as capsule uploads: only with a fresh enabled remote config, retried with
backoff and `Retry-After` on temporary errors, dropped when refused, rejected
items never retried. Crash paths write their envelope synchronously. Remote
`monitoringEnabled: false` (or the kill switch) deletes queued envelopes.

## Privacy controls

Redaction runs on device before anything is written (capsule spec
*Redaction*; checked against `spec-fixtures/conformance/redaction.json`):

* sensitive key names anywhere in bodies, UserDefaults values, action
  payloads, state snapshots and checkpoints (`password`, `token`, `secret`,
  `apikey`, `authorization`, `cookie`, `cardnumber`, `pin`, `otp`, `cvv`, ...
  plus `redactKeys` and the remote config's `redactKeys`);
* headers (`authorization`, `cookie`, `set-cookie`, `x-api-key`, ... plus
  `redactHeaders`); URLs (user info, sensitive query/fragment parameters);
* free text (bearer/basic tokens, JWTs, known API key formats, `key=value`
  pairs, Luhn-valid card numbers, `redactPatterns`);
* tracked text: the whole value when the id looks sensitive, when
  `sensitive: true`, and always for `UITextField.isSecureTextEntry`.

More controls: `beforeRecord` (edit/drop any event), `beforeCheckpoint`,
`BugCapsuleURLSession(exclude:)` (record only method/URL/status/timing),
`captureNetworkBodies: false` locally or remotely (also strips buffered
bodies), the UserDefaults allowlist (nothing else is read), and the remote kill
switch. Automatic redaction is best effort: it does not find secrets in URL
path segments, personal data that is not a credential (names, emails,
addresses), secrets under innocuous key names, or binary bodies.

## Crash capsules

A crash that ends the process leaves no time to write a capsule (the
crash-capsules contract, `docs/crash-capsules.md` in the backend repository).
While a session records, a **crash journal** mirrors the flight recorder on
disk, and the next launch builds the capsule from it.

**The journal** (`journal/<pid>/`, protected until first unlock, excluded
from backup with the rest):

| File | Content |
|---|---|
| `header.json` | The manifest fields known while running (`mode`, `app`, `source`, `sdk`, `platform`, `session`, `integrations`, `redaction`, `labels`, `dependencies`, `runtime`, `capabilities`), plus `pid`, `release`, `environment`, `writtenAt`, `anchorT` and `wallClockAtStartMs`. Rewritten when the anchor is set, at periodic checkpoints and when redaction changes. |
| `checkpoints/<afterSeq>.json` | The launch checkpoint while nothing was evicted, and the newest periodic one. |
| `events/<afterSeq + 1>.jsonl` | One file per checkpoint, one already-redacted event per line. |

* Event and checkpoint `t` are on the recorder's clock (ms since
  `BugCapsule.start`); `anchorT` (null until the first window) places the
  anchor on it, so a crash before the first window still has a journal.
* The app's threads only hand events to a serial background queue, which
  writes once per file per flush: at least every 250 ms, at once on a
  checkpoint, a recorded failure and going to the background.
* Eviction mirrors the recorder: once it evicts its first event, the launch
  checkpoint and the files before the newest periodic checkpoint go. Above
  `2 × maxCapsuleBytes` the oldest events file goes, and the launch
  checkpoint with it.
* A session that doesn't record keeps no journal; stopping recording (lower
  sample rate) deletes it, the kill switch deletes every journal. After the
  synchronous NSException capsule the process's journal is deleted.

**Next launch**: monitoring reads the previous run's crash report; when a
journal of that `pid` exists, a background queue builds the capsule before
sending the `fatal` event (crash-capsules §2):

* checkpoint: the launch one when every event after it is still journaled,
  else the newest periodic one (also when the capsule is over
  `maxCapsuleBytes`; still too big: no capsule);
* `failure`: kind `crash`, `type` the signal (`SIGSEGV`), Mach exception
  (`EXC_BAD_ACCESS`), NSException name (MetricKit) or
  `ApplicationNotResponding` (a MetricKit watchdog kill), signature
  `crash:<type>`, `crash.mechanism` (`signal`, `mach_exception`,
  `metrickit`), `crash.signal` / `crash.exception`, `crash.inAppFrame` when
  this build can name the in-app frame closest to the crash;
* `monitoring`: the event's id, release and environment; the event gets
  `capsuleId`;
* eligibility: the usual checks plus the non-blocking `crash.native` gap
  (so `partial` at best); `labels.source: "crash_journal"`,
  `labels["crash.mechanism"]`; `stats.journalGapMs` (crash time minus the
  last journaled event, with the report's millisecond time);
* spec v2 always; not counted against `maxCapsulesPerSession`; saved and
  written to the outbox before the event is sent; the journal is deleted
  afterwards.

Every other journal of an earlier process is deleted on launch, except
one whose process ended in the foreground (its last lifecycle event is not
`paused`) while MetricKit runs: it is claimed for up to 7 days, and a
MetricKit crash diagnostic of that `pid` gets its capsule when it arrives.

**Replay** (crash-capsules §4) re-runs the steps; the attempt is judged on
how the app ends:

| What happens | Reported by | `outcome` | `reasonCodes` |
|---|---|---|---|
| The app dies with the same signal, Mach exception or uncaught NSException | `BugCapsuleXCTest`, from the crash report | `reproduced` | `failure.different_frame` when `crash.inAppFrame` names another function |
| `ApplicationNotResponding`: the main thread blocked past 2 s | the app (watchdog thread) | `reproduced` | |
| The app dies of another crash type | `BugCapsuleXCTest` (or the app for an NSException) | `inconclusive` | `failure.different` |
| The window replays to the end with the app alive | the app | `not_reproduced` | |

The runner fetches the attempt's settings and capsule from the CLI's
replay server before launching the app. When `XCUIApplication.state` is no
longer running, it reads the newest `.ips` crash report of this simulator
since the launch from `$SIMULATOR_HOST_HOME/Library/Logs/DiagnosticReports`
(waiting up to 20 s) and prints `BUGCAPSULE_RESULT::{json}`, the report the
CLI reads: `outcome`, `reasonCodes`, `observed` (kind `crash`, `type`,
`signature`, `message` with the report's summary, `crash.signal`,
`crash.exception`, `crash.inAppFrame`), `expectedSignature`, `attempt`,
`attemptId`, `durationMs`, `strategy`, `runtime: "ios"`. A CLI that doesn't
know `inconclusive` reads it as `error`, which is inconclusive too. Without a
crash report (the app exited, or reported itself) it prints nothing.

## Storage, uploads and backend connectivity

* Files live in `Application Support/bugcapsule` (excluded from iCloud/iTunes
  backup): `captures/` (newest 20), `outbox/`
  (`<enqueuedAtMs>_<capsuleId>.bugcapsule`), `envelopes/` (monitoring),
  `monitoring/` (open session, install id, crash report), `journal/` (crash
  journals, [above](#crash-capsules)), `remote_config.json`. Writes are
  atomic (temp + rename); temp files are removed at start; corrupt files are
  dropped; a full disk drops the capsule. No SDK error reaches the app.
* Uploads: capsules are gzipped and sent to the token's address (or the
  explicit backend URL) with the token's credential (or the ingest key).
  Network errors, timeouts and temporary server errors retry later
  (30 s → 1 h, ±20 % jitter, `Retry-After` honoured); a capsule BugCapsule
  refuses is dropped; a "capture disabled" answer refreshes the config.
* Remote config: TTL from `configTtlSeconds` (default 300 s, at least 30 s),
  failure backoff 30 s → 30 min honouring `Retry-After`, refreshed when the app
  becomes active, cached per (backend URL, ingest key); uploads only after a
  successful fetch or with a cached config younger than `maxStaleConfig`
  (7 days). Kill switch (`enabled: false`): recording stops, the buffer is
  dropped, queued and saved capsules are deleted, and it persists across
  launches until a fetch re-enables it. A refused credential (a revoked,
  expired or unknown token or key) stops capture and uploads for the session; the SDK logs the
  reason and advice once and `BugCapsule.status` reports `rejected`.
  Network errors, timeouts and server errors are never fatal: the app keeps running, data
  waits in the outbox, and the status says `offline` until a fetch succeeds.
  Production sampling: `min(productionSampleRate, remote sampleRate)` at launch;
  a lower rate mid-session keeps recording with probability new/old.
* Lifecycle: uploads run only while the app is running (at launch, when it
  becomes active, after a capture). No background task or background
  `URLSession` is used, so nothing is promised while the app is suspended;
  capsules wait in the outbox for the next foreground.
* Simulator: `127.0.0.1` reaches a server on the Mac. Devices need a reachable
  host (and an ATS exception for plain HTTP, e.g. `NSAllowsLocalNetworking`
  for LAN addresses).

## Replay with the CLI (XCUITest)

```
bugcapsule run <id>
  └─ xcodebuild build-for-testing   (once; BUGCAPSULE_GIT_SHA/BUGCAPSULE_GIT_DIRTY build settings)
  └─ per attempt:
       simctl uninstall <bundleId>   (fresh data container)
       TEST_RUNNER_BUGCAPSULE_REPLAY_URL=http://127.0.0.1:<port>/a/<token> \
       xcodebuild test-without-building -xctestrun … -destination id=<udid> \
         -only-testing:<UITestTarget>/BugCapsuleReplayTests/testReplay
         └─ BugCapsuleReplayTestCase: XCUIApplication + launchEnvironment[BUGCAPSULE_REPLAY_URL]
                                      + launch argument -BugCapsuleReplay
              └─ app: BugCapsule.start() → GET settings + capsule → restore UserDefaults/state
                      → at the first visible window: dispatch actions/text/lifecycle at recorded
                        times, serve URLSession fixtures, watch for the failure
                      → POST /result (+ BUGCAPSULE_RESULT:: line, + accessibility element)
```

* **Production protection**: the replay code path is compiled only with
  `DEBUG` (`#if DEBUG`) and arms only when the process was launched with the
  `-BugCapsuleReplay` argument *and* `BUGCAPSULE_REPLAY_URL` in its environment
  (both set by the UI test). There is no URL scheme, deep link, push or file
  trigger. A release build ignores both.
* **Result channels**: the app POSTs the report (`attemptId` echoed; 409/410
  mean the attempt is stale and are not retried). It also prints
  `BUGCAPSULE_RESULT::{json}` and exposes the JSON as the value of an
  accessibility element (`bugcapsule.replay.result`) in a 2×2 pt overlay window;
  the UI test prints it as `BUGCAPSULE_RESULT::{json}` into the xcodebuild
  output, which the CLI reads as the fallback channel. If the reproduced
  failure is an uncaught NSException, the report is posted synchronously from
  the exception handler before the process dies.
* **Strategy**: semantic (see pointer replay below). Idle gaps longer than
  1.5 s are compressed when nothing is in flight; recorded network latency is
  always kept, so response ordering (races) replays.
* **Network**: fixtures served by request key + occurrence after the recorded
  `durationMs`; recorded errors are raised as `URLError`; cancellation works;
  unrecorded requests fail with `URLError(.cannotConnectToHost)` and
  `network.unrecorded` unless `--lenient-network`.
* **Isolation**: every attempt uninstalls the app (fresh container); the CLI
  enforces the attempt timeout (plus `startupSeconds` for xcodebuild/install),
  kills xcodebuild on timeout or Ctrl-C, and treats a missing report as `error`.

## `bugcapsule.json` keys

Put it next to the `.xcodeproj`/`.xcworkspace`:

```json
{
  "runtime": "ios",
  "ios": {
    "project": "BugCapsuleDemo.xcodeproj",
    "scheme": "BugCapsuleDemo",
    "configuration": "Debug",
    "bundleId": "com.bugcapsule.demo",
    "replayTest": "BugCapsuleDemoUITests/BugCapsuleReplayTests/testReplay",
    "simulator": "iPhone 18 Pro",
    "startupSeconds": 120,
    "buildSettings": {"SOME_SETTING": "value"}
  },
  "timeouts": {"buildSeconds": 1200, "attemptSeconds": 180}
}
```

| Key | Default | Meaning |
|---|---|---|
| `ios.project` / `ios.workspace` | — | Passed as `-project` / `-workspace`. |
| `ios.scheme` | required | Scheme that builds the app and the UI test target. |
| `ios.configuration` | `Debug` | Must be a configuration that defines `DEBUG`. |
| `ios.bundleId` | from the built app | App bundle id (required with `--xctestrun`). |
| `ios.replayTest` | `<uiTestTarget>/BugCapsuleReplayTests/testReplay` | `-only-testing:` identifier. |
| `ios.uiTestTarget` | `UITests` | Used only to derive `replayTest`. |
| `ios.simulator` | first booted iPhone | Name substring or UDID (`--device` wins). Booted if needed. |
| `ios.derivedDataPath` | `$TMPDIR/bugcapsule-ios-<hash>` | Build output (reused across runs). |
| `ios.buildSettings` | — | Extra `KEY=VALUE` build settings for every build. |
| `ios.startupSeconds` | 120 | Added to each attempt's timeout for install + launch. |
| env `BUGCAPSULE_IOS_BUILD_SETTINGS` | — | Extra `KEY=VALUE KEY2=VALUE2` settings for this invocation only (temporary fix toggles). |
| `--xctestrun <file>` | — | Prebuilt `build-for-testing` output; skips the build. |

## Simulator vs physical devices

* **Simulator (implemented and tested)**: no signing needed; the app reaches
  the CLI's loopback replay server at `127.0.0.1`; isolation uninstalls the app
  with `simctl`. Tested on iPhone 18 Pro, iOS 27.0, Xcode 27.0.
* **Physical devices (not implemented in the launcher)**: capture works on any
  device (it is ordinary app code). Replay on a device would need code signing
  for the app and the UI test runner (a development team and provisioning
  profiles), `--lan` so the replay server listens on the Mac's LAN address, an
  ATS exception for that plain-HTTP address in the DEBUG build, and
  `devicectl`/`xcodebuild` for uninstall and launch. The launcher refuses
  device queries that match no simulator.

## Demo app

`Examples/Demo` is a small shop app (UIKit home screen, SwiftUI cart) with an
in-process fake backend (`FakeShopServer`, a `URLProtocol` below the SDK's) that
randomizes latency and data. Three planted bugs, each captured automatically:

| # | Bug | Capture path | Notes |
|---|---|---|---|
| 1 | Data-dependent: coupon `SAVE100` takes a fixed 100 off, so carts below 100 get a negative total. | `BugCapsule.check("cart_total_non_negative")` | Has the isolated fix toggle `FIX_NEGATIVE_TOTAL`. |
| 2 | Timing-sensitive network: profile and recommendations load concurrently; when the recommendations arrive first (~1 in 4) the banner code raises an `NSException`. | uncaught NSException → capsule written synchronously, uploaded next launch | The profile request in flight at the crash is recorded as `pending`. |
| 3 | State restoration: "Simulate upgrade from v0.9" writes the v0.9 list format to `cart_cache`; opening the cart in a *later* session fails to decode it. | `BugCapsule.report(error:)` | Reproduces only because the checkpoint restores `UserDefaults`. |

Also exercised: allowlisted UserDefaults (`cart_cache`, `demo.*`), a registered
state object (`app.session`), UIKit navigation capture, SwiftUI tracked text and
actions, `BugCapsuleWindow` pointer capture.

**Fix toggle (bug 1)**: the cart's discount reads `#if FIX_NEGATIVE_TOTAL`. The
app target's `SWIFT_ACTIVE_COMPILATION_CONDITIONS` is `DEBUG $(DEMO_FIXES)` and
`DEMO_FIXES` is empty in the project. Apply the fix for one CLI invocation
without touching tracked sources:

```bash
BUGCAPSULE_IOS_BUILD_SETTINGS='DEMO_FIXES=FIX_NEGATIVE_TOTAL' bugcapsule verify <id> -p Examples/Demo
```

Revert by omitting the variable (the next build is the buggy one again).

Build and capture by hand (the SDK token is passed on the command line, never
committed):

```bash
cd Examples/Demo
xcodebuild test -project BugCapsuleDemo.xcodeproj -scheme BugCapsuleDemo \
  -destination 'id=<simulator udid>' -collect-test-diagnostics never \
  BUGCAPSULE_TOKEN=bcsdk.v1.... \
  -only-testing:BugCapsuleDemoUITests/CaptureFlowTests/testCaptureNegativeTotal
```

With an explicit address instead, pass `BUGCAPSULE_BACKEND_URL=https://api.bugcapsule.com BUGCAPSULE_INGEST_KEY=bci_…`;
the explicit pair wins over the token.

`CaptureFlowTests` drives the app into each bug (`testCaptureNegativeTotal`,
`testCaptureRaceCrash`, `testCaptureLegacyCart`,
`testOfflineCaptureUploadsAfterRestart`). That is capture automation; replay is
`BugCapsuleReplayTests`, run by the CLI. The project is generated from
`project.yml` with XcodeGen (`xcodegen generate`); the generated project is
checked in.

## Interaction dependencies: WebSockets and native adapters

Capsules that recorded a WebSocket or a native adapter are written as capsule
spec v2: `manifest.dependencies` lists each dependency (adapter id, version,
payload schema, coverage, gaps, stats) and the interaction events carry
`data.dep`. Capsules without one stay spec v1. The SDK reads both and rejects
newer versions.

**Payloads.** Every message body, argument and result is a payload object
(`mode`: `full`, `redacted`, `metadata`, `omitted`, `truncated`;
`replayable`). Values are typed: integers beyond 2^53, integral doubles, NaN
and -0.0, `Data`, `[Int32]`/`[Int64]`/`[Float]`/`[Double]` and maps with
non-string keys (`TypedMap`) survive the round trip (`TypedValue`). The SDK
redactor runs first; a redacted payload is replayable only when the adapter
declares it (`redactedReplayable`). Bounds: 64 KiB per payload (larger:
`truncated`), 1 MiB of payloads per recorder window across adapters (later
ones: `metadata`), 32 captured connections and subscriptions at a time
(further ones run uncaptured with a `connections.limit` gap). Each gap makes
the dependency `partial` and adds a `dependency.<id>` eligibility entry.

**WebSocket** (`BugCapsuleWebSockets`, dependency `ws`, schema 1). Events:
`ws.connect` (connection id, redacted URL, match key = redacted URL without
ignored query parameters, occurrence of that key, reconnect attempt,
subprotocols), `ws.open`, `ws.send` / `ws.message` (index per connection,
text or binary payload), `ws.error` (`connect`, `send` with the index,
`stream`), `ws.close` (`client` for the app's close, then `server`, or
`unknown` for a dropped connection, with code and reason). The wrapper keeps
the socket alive until the task completes, as URLSession keeps the task, so
the close is recorded even when the app dropped its reference. Its open,
close and completion callbacks reach `delegate`, `onOpen` / `onClose` and the
session's own delegate.

**Replay.** The SDK checks every required dependency before the app starts:
an adapter with the same id must be installed and support the schema, and a
periodic checkpoint must not have a connection open; otherwise the attempt
ends `incompatible` with `dependency.unsupported`, `dependency.schema` or
`dependency.unrestorable`. Connects are matched by key and occurrence, so
identical concurrent connections pair up in invocation order; sends and the
app's close are matched in order and compared. Inbound events are delivered
at their recorded offset from the operation that preceded them, never before
an earlier one of the same connection, on the replay clock: idle compression
does not skip past a due delivery, and an open socket with nothing due does
not keep replay busy. Divergences (all material except `*.unusedAfterFailure`):

| Divergence | Meaning |
|---|---|
| `ws.unrecorded`, `native.unrecorded` | The app connected, sent, closed or called something not recorded. The operation fails with `BugCapsuleReplayError` (`bugcapsule.unrecorded`); the network or SDK is never reached. |
| `ws.mismatch`, `native.mismatch` | Matched in order but the frame (or close code) differs; arguments differ from every remaining recorded call. |
| `ws.noPayload`, `native.noPayload` | A recorded message or result is not replayable (binary metadata, truncated, dropped, redacted). It is not delivered. |
| `ws.unused`, `native.unused` | Recorded at or before the failure and never matched or delivered. |
| `ws.unusedAfterFailure`, `native.unusedAfterFailure` | The same after the failure (expected). |
| `ws.undelivered`, `native.undelivered` | A delivery waited more than 5 s for its handler. |

Verdict reasons carry the matching reason codes (`interaction.unexpected`,
`interaction.mismatch`, `interaction.incomplete`, `interaction.missing`,
`dependency.unsupported`).

**Native adapters.** An adapter declares a `BugCapsuleAdapterDescriptor`
(dependency id, adapter id, version, schema and the schemas it replays,
operations, tested packages, payload policy, nondeterministic argument fields
left out of match keys) and routes its SDK through the bridge:
`call(_:args:live:)` records `native.call` → `native.result` /
`native.error`; `subscribe(_:args:onEvent:live:)` records
`native.subscribe` → `native.event`… → `native.done` / `native.error` and
`native.cancel`. Match keys are
`<operation>[@<instance>]||<hash of the redacted args>` plus the occurrence,
so calls are matched within their adapter instance. Replay hands the adapter
decoded typed values and never calls the SDK: also not when the capsule has
no recording for the adapter, for capture-only (`required: false`)
adapters, or when the adapter is not installed (`native.unrecorded`). Operations not in the descriptor run live with an
`operation.unsupported` gap and fail as unrecorded in replay.
`snapshot` / `canRestore` / `restore` let an adapter restore open
subscriptions from a periodic checkpoint (default: not restorable).
`BugCapsuleLocationAdapter` wraps a `BugCapsuleLocationProvider` as an
example.

```swift
func testMyAdapterIsConformant() async throws {
    let report = try await BugCapsuleAdapterConformance.run(
        makeAdapter: { replaying in MyAdapter(sdk: replaying ? FailingSDK() : FakeSDK()) }
    ) { adapter, log in
        log.append("value: \(try await (adapter as! MyAdapter).get("carts/1"))")
    }
    XCTAssertTrue(report.isClean, report.problems.joined(separator: "\n"))
}
```

**Data controls.** Adapters follow the session's capture settings (enabled,
sampling, kill switch, redaction). The project's capture settings can switch
off a single adapter by id (`bugcapsule-ios.urlsession-websocket`): its
buffered events are dropped and it stops recording, while HTTP capture goes
on.

## Limitations

* **Pointer replay is not implemented** (`input.pointer.replay: unsupported`).
  Touches are captured (explicitly) for diagnosis, but replay uses semantic
  actions. A capsule with pointer input and no semantic action (or
  `--strategy pointer`) gets the material `pointer.unsupported` divergence, and
  such capsules are `partial` (`capability.input.pointer.replay`). Rationale:
  XCUICoordinate taps from the test process cannot be timed to the recorded
  milliseconds (each synthesized event waits for app quiescence) and cannot
  follow idle compression, so they would make races and timing-dependent
  failures unreliable. Name the actions that matter.
* Lifecycle replay posts notifications only (`partial`); `hidden` has no iOS
  equivalent (`lifecycle.unsupported`).
* `BugCapsule.now()` / `BugCapsule.random` are the only virtualized clock and
  randomness; `Date()` and `Int.random` in app code are not.
* URLSession: `httpBodyStream` bodies are keyed without a body hash and not
  recorded; stream tasks are not captured. Challenges reach the app's
  delegate without `failureResponse` or `error`, and the body of a redirect
  response is not recorded (replay serves it empty when the app refuses the
  redirect).
* WebSockets: only through `BugCapsuleWebSocket` (a directly created
  `URLSessionWebSocketTask` is neither recorded nor blocked in replay); ping
  and pong are not recorded (`sendPing` succeeds at once in replay); binary
  frames are size-only unless `captureBinary`; a recorded message that isn't
  replayable is not delivered (`ws.noPayload`); open connections are not
  restored from periodic checkpoints. Native adapters cover the operations
  they declare; nothing is recorded below them.
* Only allowlisted UserDefaults keys of the listed types are captured;
  Keychain, Core Data, files and SQLite are not (write an integration).
* Navigation is restored from periodic checkpoints only through an app-provided
  `BugCapsuleNavigation.shared.restorer`.
* Cross-runtime replay is not supported (spec §12).
* Crash capsules: the last ≤ 250 ms before a crash may be missing from the
  journal (`stats.journalGapMs` says how long). Crash reports are read on
  the simulator only (the CLI replays on simulators); a death without a
  report prints no result. MetricKit capsules need the diagnostic's `pid`
  (iOS 17+). The `crash.inAppFrame` check needs the build that crashed to
  have symbols on device. OOM kills give no capsule.
* Monitoring: native crash reports carry no registers, and threads other
  than the crashing one are best effort (at most 100; 40 frames each in the
  event, trimmed to 448 KiB); the walk relies on frame pointers (always on for
  Apple arm64), and the leaf-function caller comes from the link register
  only on arm64. The alternate signal stack covers the main thread only, so a
  stack overflow on another thread may leave no report. The Mach exception
  server is not installed while a debugger is attached. Screens are traced
  through `observe(_:)`, `.bugCapsuleRoute` and `screenWillAppear` (no
  UIViewController swizzling), so screens shown otherwise need the explicit
  call. Core Data spans need the explicit wrappers. No background
  `URLSession` tracing, no fatal app-hang (watchdog) detection, no
  MetricKit.
