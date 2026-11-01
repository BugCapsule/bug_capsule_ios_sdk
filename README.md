# BugCapsule iOS SDK

BugCapsule records what led up to a bug in your iOS app and saves it as a
portable `.bugcapsule` file. A developer can **replay** that file on a
simulator against the real app code, **verify** a fix against it, and keep it
as a **regression test**. The same SDK also reports errors (including native
crashes and app hangs), release health, performance traces and user feedback,
and links each error to the capsule that replays it.

```
QA hits a bug      ─► capsule captured, redacted on the device, uploaded
bugcapsule run     ─► REPRODUCED 3/3   (XCUITest on a simulator)
fix the code
bugcapsule verify  ─► FIXED 3/3
bugcapsule regress ─► runs in CI from now on
```

📖 Full documentation: **[docs.bugcapsule.com/ios](https://docs.bugcapsule.com/ios.html)**

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Connect your app](#connect-your-app)
- [Make bugs replayable](#make-bugs-replayable)
- [Replay, verify and keep a regression test](#replay-verify-and-keep-a-regression-test)
- [Monitoring](#monitoring)
- [Emergency recovery (feature guards)](#emergency-recovery-feature-guards)
- [Privacy](#privacy)
- [Going to production](#going-to-production)
- [Limitations](#limitations)
- [Demo app](#demo-app)
- [More documentation](#more-documentation)
- [Support and license](#support-and-license)

## Requirements

- A BugCapsule project. Sign in at [app.bugcapsule.com](https://app.bugcapsule.com).
- iOS 15+, Xcode with Swift 6.
- An iOS simulator for replay.
- No third-party dependencies.

## Install

In Xcode, choose **File → Add Package Dependencies…**, enter
`https://github.com/BugCapsule/bug_capsule_ios_sdk.git` and pick the exact
version `0.4.1-beta.5`. Add **`BugCapsule`** to your app target and
**`BugCapsuleXCTest`** to your UI test target.

Or in a `Package.swift`:

```swift
.package(url: "https://github.com/BugCapsule/bug_capsule_ios_sdk.git", exact: "0.4.1-beta.5"),

// app target
.product(name: "BugCapsule", package: "bug_capsule_ios_sdk"),
// UI test target
.product(name: "BugCapsuleXCTest", package: "bug_capsule_ios_sdk"),
```

> **Versions.** SDK tokens and connection status are available starting with `0.4.1-beta.4`.
> Existing explicit backend configuration remains supported.

## Connect your app

### 1. Get an SDK token

In the dashboard, open **Project settings → Keys → SDK tokens** and generate a
token. It looks like `bcsdk.v1.…` and is shown once, so copy it right away.

The SDK token is the only value your app needs. It holds your BugCapsule
address and a send-only credential: it can upload capsules and events and read
capture settings, nothing else. That makes it safe to ship in the app. You can
rotate or revoke it in the dashboard at any time.

### 2. Start BugCapsule first thing

UIKit:

```swift
import BugCapsule

func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    BugCapsule.start(token: "bcsdk.v1.…")
    return true
}
```

SwiftUI:

```swift
import BugCapsule
import SwiftUI

@main
struct ShopApp: App {
    init() { BugCapsule.start(token: "bcsdk.v1.…") }
    var body: some Scene { WindowGroup { RootView() } }
}
```

That is a complete connection. App version and build come from
`CFBundleShortVersionString` / `CFBundleVersion`, and capture is on (`.debug`
mode in DEBUG builds, `.production` with sampling otherwise).

- **Start before your app reads `UserDefaults`.** In replay, `start` restores
  the checkpoint there.
- **It never breaks your app.** `start` never throws and never blocks. A token
  that can't be used logs one `[bugcapsule]` line saying what to fix, and the
  app runs without uploads.

### 3. Check the connection

```swift
let status = BugCapsule.status
status.connection.state                  // .connecting, .connected, .offline, .rejected, …
status.connection.message                // what to do, when something is wrong
status.connection.configFetchedAt        // set once BugCapsule accepted the token
status.connection.firstCapsuleAcceptedAt // set once a capsule reached your project
status.instrumentation.missing           // e.g. ["network", "navigation", "app_state"]
```

| `connection.state` | Meaning | What to do |
|---|---|---|
| `notConfigured` | Not started, or no token / backend: capsules stay on the device. | Pass a token. |
| `invalidToken`, `unsupportedTokenVersion` | The token can't be used; `message` says why. | Paste the full `bcsdk.v1.…` token, or update the SDK. |
| `connecting` | Waiting for the first configuration fetch. | Wait a moment. |
| `connected` | The configuration was fetched in this run. | Nothing. |
| `offline` | BugCapsule can't be reached. Data waits in the outbox and is retried. | Check the device's network. |
| `rejected` | The token was refused (`reason`: `token_revoked`, `token_expired`, `token_unknown`, …). Capture and uploads stop for this run. | Generate a new token. |
| `disabled` | `enabled: false`, or capture is switched off for the project. | — |

### Connect with an address and ingest key

For self-hosted setups, older SDK versions, or apps that already pass an
address explicitly:

```swift
BugCapsule.start(BugCapsuleConfig(
    backend: BugCapsuleBackendConfig(url: "https://api.bugcapsule.com",
                                     ingestKey: "bci_…")))
```

`backend` wins when both are set (the SDK logs that the token was ignored).
The ingest key is public like the token. **Never put a `bcs_…` secret key in
an app.**

## Make bugs replayable

Being connected is not the same as faithful replay. Replay also needs your
app's network, navigation and state. Add them as integrations;
`BugCapsule.status.instrumentation.missing` tells you what is left.

```swift
BugCapsule.start(
    BugCapsuleConfig(
        token: "bcsdk.v1.…",
        mode: .qa,                    // default: .debug in DEBUG builds, .production otherwise
        redactKeys: ["loyaltyId"]),
    integrations: [
        BugCapsuleURLSession(rules: [
            // Fields that change on every run must not affect request matching.
            EndpointRule("POST", "/api/checkout", ignoreBodyFields: ["timestamp", "nonce"]),
        ]),
        BugCapsuleUserDefaults(keys: ["cart_cache"], prefixes: ["settings."]),
        BugCapsuleNavigation.shared,
        BugCapsuleStateIntegration.shared,
    ])
```

### Network

```swift
let config = URLSessionConfiguration.default
BugCapsule.instrument(config)                 // inserts BugCapsule's URL protocol first
let session = URLSession(configuration: config)

// Alamofire: the same, with Session(configuration: config)
// URLSession.shared: BugCapsule.instrumentSharedSession() (opt-in)
```

### WebSockets

`URLSessionWebSocketTask` can't be intercepted, so open sockets through
`BugCapsuleWebSocket` (the same calls) and add `BugCapsuleWebSockets()`:

```swift
BugCapsule.start(config, integrations: [BugCapsuleURLSession(), BugCapsuleWebSockets()])

let socket = BugCapsuleWebSocket(session: .shared, url: URL(string: "wss://quotes.example.com/v1/stream")!)
socket.delegate = self              // didOpenWithProtocol / didCloseWith / didCompleteWithError
socket.resume()
try await socket.send(.string(#"{"op":"subscribe","symbol":"ACME"}"#))
let message = try await socket.receive()
socket.cancel(with: .normalClosure, reason: nil)
```

Connects, sends, received messages, errors and closes are recorded (redacted,
like everything else). Text frames are kept; binary frames are recorded as
their size only unless you pass `BugCapsuleWebSockets(captureBinary: true)`.
Replay never opens a socket: the app connects, sends and receives exactly as
recorded, in the recorded order and timing. A connection or frame that wasn't
recorded fails with `BugCapsuleReplayError` and makes the attempt
inconclusive, so a changed protocol never reads as a fix.

### Other SDKs (native adapters)

Results of third-party SDKs (location, Firebase, payments) are recorded through
an adapter that implements `BugCapsuleNativeAdapter` and routes its calls and
streams through `BugCapsuleNativeBridge`. Install it with
`BugCapsuleNativeIntegration(adapter)`. In replay the SDK is never called; the
recorded answers come back at their recorded times.
`BugCapsuleLocationAdapter` is a small working example, and
`BugCapsuleAdapterConformance.run` checks your own adapter offline
(capture → capsule → replay, no divergences). See
[docs/how-it-works.md](docs/how-it-works.md#interaction-dependencies-websockets-and-native-adapters).

### Actions, text and navigation

```swift
// UIKit
button.addAction(BugCapsule.uiAction("cart.checkout") { [weak self] in self?.checkout() }, for: .touchUpInside)
BugCapsule.trackText("cart.coupon", field: couponField)        // secure text entry is always redacted
BugCapsule.observe(navigationController)                         // route events

// SwiftUI
Button("Checkout", action: BugCapsule.action("cart.checkout") { model.checkout() })
TextField("Coupon", text: BugCapsule.trackedText("cart.coupon", $model.coupon))
SecureField("PIN", text: BugCapsule.trackedText("login.pin", $pin, sensitive: true))
SomeView().bugCapsuleRoute("/cart")
```

Replay invokes these actions by id and restores tracked text by id. **Name the
actions that matter**: iOS replay is semantic and doesn't replay raw touches
(see [Limitations](#limitations)).

### Say what "broken" means

```swift
BugCapsule.check("cart_total_non_negative", total >= 0, "total \(total)")
BugCapsule.fail("checkout_stuck", "spinner after 10s")
BugCapsule.report(error: error)            // errors your app caught
```

A failure writes a capsule automatically (300 ms after the failure; at most 3
per session, one per failure signature), saves it on the device and queues it
for upload. Uncaught `NSException`s also get a capsule, uploaded on the next
launch. Swift traps (`fatalError`, force-unwrapping `nil`, …) and signals get
no capsule but are still reported by [monitoring](#monitoring). For a
replayable capsule, report the condition yourself with `check` or
`report(error:)` before the code that would trap.

### Other hooks

| Add this | Why |
|---|---|
| `BugCapsule.registerState(_:snapshot:restore:)` | Your app's own state is saved in checkpoints and restored in replay. |
| `BugCapsule.now()` instead of `Date()` | Replay returns the recorded time. |
| `BugCapsule.random` instead of `Int.random` | Seeded per session, same seed in replay. |
| `BugCapsule.capture(note:)` | Manual capture, e.g. from a QA button. |

### Embed the git commit

Add to your app's Info.plist:

```xml
<key>BugCapsuleGitSHA</key><string>$(BUGCAPSULE_GIT_SHA)</string>
<key>BugCapsuleGitDirty</key><string>$(BUGCAPSULE_GIT_DIRTY)</string>
```

The CLI passes both build settings when it builds. For QA and CI builds, pass
`BUGCAPSULE_GIT_SHA=$(git rev-parse HEAD)` to `xcodebuild`. Without it,
capsules are `partial` and `bugcapsule run` can't check out the same commit.

Full API: [docs/how-it-works.md](docs/how-it-works.md#integration-reference).

## Replay, verify and keep a regression test

### Install the CLI

The standalone `bugcapsule` CLI replays capsules from every BugCapsule SDK.
Install it with Node.js 20 or newer; Dart and Flutter are not required.

```bash
npm install -g @bugcapsule/cli@0.4.0-beta.3
bugcapsule --version
```

Direct executables are also available from the [CLI release](https://github.com/BugCapsule/bug_capsule_flutter_sdk/releases/tag/v0.4.1-beta.7).

Log in with a personal token from **Project settings → Keys & CLI access**.
In CI, use a service token in `BUGCAPSULE_TOKEN` instead.

```bash
bugcapsule login --url https://api.bugcapsule.com --token bcp_…
```

### Add the replay test

In your UI test target:

```swift
import BugCapsuleXCTest

final class BugCapsuleReplayTests: BugCapsuleReplayTestCase {
    func testReplay() throws { try runBugCapsuleReplay() }
}
```

### Configure replay

Add a `bugcapsule.json` next to your `.xcodeproj` or `.xcworkspace`:

```json
{
  "runtime": "ios",
  "ios": {
    "project": "Shop.xcodeproj",
    "scheme": "Shop",
    "bundleId": "com.example.shop",
    "replayTest": "ShopUITests/BugCapsuleReplayTests/testReplay",
    "simulator": "iPhone 16 Pro"
  }
}
```

Use a build configuration that defines `DEBUG` (the default is `Debug`). All
keys: [docs/how-it-works.md](docs/how-it-works.md#bugcapsulejson-keys).

### Run it

```bash
bugcapsule list                      # capsules in your project
bugcapsule inspect <id>              # failure, eligibility, network, timeline
bugcapsule run <id> -n 3             # builds the capsule's commit and replays it on a simulator
bugcapsule verify <id> -n 3          # builds your working tree; FIXED when the bug is gone
bugcapsule regress add <id>          # keep it as a regression test
bugcapsule regress run               # in CI: exit 1 when a regression fails
```

The CLI builds once, then for each attempt reinstalls the app on the simulator
(fresh data) and runs your replay test. Replay on physical devices is not
supported yet; capture works on any device.

**Replay is off in production.** The replay code is compiled only in `DEBUG`
builds and only arms when the UI test launches the app with BugCapsule's
launch argument and environment. There is no URL scheme, deep link or push
into replay.

See the [CLI reference](https://docs.bugcapsule.com/cli.html) and
[how verdicts work](https://docs.bugcapsule.com/verdicts.html).

## Monitoring

Monitoring is on by default once a token (or backend) is set:

| Signal | What you get |
|---|---|
| Errors | `captureException`, `report(error:)`, `check`/`fail`, uncaught `NSException`s, **native crashes** (signals and Mach exceptions, with every thread's stack), **app hangs** (main thread blocked 2 s) and **MetricKit** crash and hang diagnostics |
| Release health | One session per foreground run; `crashed` and `abnormal` (OOM, watchdog, force-quit) sessions |
| Performance | Cold and warm app start, screen loads (TTID / TTFD), slow and frozen frames, URLSession spans, Core Data spans |
| User feedback | A UIKit form, a SwiftUI form or sheet, shake to report |

When a capsule is written for an error, the error links to it, so each issue
lists the capsules that replay it.

```swift
var config = BugCapsuleConfig(token: "bcsdk.v1.…")
config.monitoring = BugCapsuleMonitoringOptions(
    tracesSampleRate: 0.2,
    tracePropagationTargets: ["api.shop.example.com"],   // none by default
    enableTimeToFullDisplayTracing: true,
    enableShakeToReport: true)
BugCapsule.start(config, integrations: [BugCapsuleURLSession(), BugCapsuleNavigation.shared])
```

`monitoring: .disabled` turns monitoring off; capsules keep working. Full API
and behaviour: [docs/how-it-works.md](docs/how-it-works.md#monitoring).

### Crash reporting

Crashes are written to disk by an async-signal-safe handler and sent on the
next launch as `fatal` events:

- **Signals and Mach exceptions** (`EXC_BAD_ACCESS`, Swift traps, `abort()`):
  the crashing thread's stack plus every other thread (crashed thread first,
  then main; up to 100 threads, 250 frames for the crashed one and 40 for
  the others), with the scope, release and environment of the run that
  crashed. A crash in a leaf function keeps its caller (arm64 link register).
- **Uncaught `NSException`s**: written synchronously before the process ends.
- **App hangs**: one `app_hang` error per hang, with every thread's stack.
- **MetricKit** (iOS 14+): crash and hang diagnostics BugCapsule did not
  see itself (e.g. a crash before `start`), delivered by iOS on a later
  launch. A crash or hang BugCapsule already reported (same process, or
  within 60 s) is sent once.
- **Release health**: the run that crashed or died is closed on the next
  launch with its own release, also after an update.
- **Crash capsules**: when the session that crashed was recording, its
  crash journal becomes a replayable capsule on the next launch, linked to
  the crash event (`capsuleId`). `bugcapsule run` re-runs the steps and
  checks the app dies of the same signal or exception. See
  [docs/how-it-works.md](docs/how-it-works.md#crash-capsules).

Turn parts off with `enableNativeCrashHandling`, `enableMachExceptionHandling`,
`enableAppHangTracking` and `enableMetricKit` in `BugCapsuleMonitoringOptions`.
Upload dSYMs (below) to get file and line for app frames.

#### For SDK authors: `BugCapsuleCrashBridge` (embedding only)

Apps don't need this: `BugCapsule.start` already does all of the above.
`BugCapsuleCrashBridge` is for an SDK that embeds this one and sends events
itself (the BugCapsule Flutter SDK's iOS plugin). It runs the crash handlers,
hang watchdog and MetricKit without this SDK's sessions or outbox, and has
the same shape as Android's `dev.bugcapsule.android.embedding.CrashBridge`:

```swift
BugCapsuleCrashBridge.install(
    release: "com.shop.app@1.4.0+52", environment: "production",
    options: .init(nativeCrashes: true, appHangs: 2, metricKit: true, inAppIncludes: ["Runner"]))
BugCapsuleCrashBridge.updateScope(json: scopeJSON)        // user, tags, contexts, breadcrumbs (redacted)
BugCapsuleCrashBridge.setListener { event in send(event) } // hangs while the app runs
let crashed = BugCapsuleCrashBridge.lastRunCrashed
for event in BugCapsuleCrashBridge.takePendingEvents() {   // waits up to 5 s; oldest first
    send(event)                                            // returned once, then deleted
}
```

Events are monitoring-v1 event JSON with `runtime: "ios"`; the embedding SDK
adds its device contexts, redacts and sends them. An earlier run's event has
that run's scope only when it is known for that process (its crash report,
or the `scope.json` mirror for the same pid); otherwise it has none, never
the current one.

Only one of the two installs the handlers: while `BugCapsule.start` is
running, `install` returns false; when the bridge ran first, monitoring skips
its own crash handlers.

### Readable stack traces: upload dSYMs

Build release builds with `DEBUG_INFORMATION_FORMAT = dwarf-with-dsym` and
upload the dSYMs from CI with the bundled script. It needs the project
**secret** key, so keep it in CI secrets and never ship it:

```bash
BUGCAPSULE_URL=https://api.bugcapsule.com BUGCAPSULE_SECRET_KEY=bcs_… \
  scripts/bugcapsule-upload-dsyms.sh build/App.xcarchive/dSYMs
```

Or as an Xcode Run Script build phase (set the two variables in the scheme or
CI environment):

```bash
"${BUILD_DIR%/Build/*}/SourcePackages/checkouts/bug_capsule_ios_sdk/scripts/bugcapsule-upload-dsyms.sh"
```

In Xcode it skips Debug builds and never fails the build
(`BUGCAPSULE_ALLOW_FAILURE=0` makes upload errors fatal).

## Emergency recovery (feature guards)

Turn a broken feature off, or put it in read-only or maintenance mode, for
the apps already on your users' phones, without shipping a release. You
create the policy in the dashboard; the app fetches a signed list of policies,
checks the signature against a trust anchor compiled into the app, caches it
and evaluates it on the device.

```swift
// In application(_:didFinishLaunchingWithOptions:), before or after BugCapsule.start.
BugCapsule.emergency.initialize(EmergencyConfiguration(
    trustAnchor: "bcek.v1.…",                    // from the dashboard's emergency settings
    environment: "production",
    failureModes: ["checkout.*": .failClosed]))  // every other key fails open

// Where the feature starts:
let decision = BugCapsule.emergency.evaluate(featureKey: "checkout.confirm_order")
if !decision.allowed {
    showUnavailable(decision.publicUserMessage)  // decision.action says BLOCK, READ_ONLY, …
    return
}
```

- `initialize` never waits for the network: it loads and re-verifies the
  cached policies and fetches in the background (every `refreshInterval`,
  60 s by default, and when the app returns to the foreground; no timers run
  in the background). `evaluate` and `isFeatureAllowed` are synchronous,
  in memory and thread-safe.
- The connection is `token` or `backend` in the configuration, else the one
  given to `BugCapsule.start`. Guards work with capture disabled, and the
  remote capture kill switch does not turn them off.
- Policies are signed with ECDSA P-256. A document that fails verification
  is never used; the reason is in `BugCapsule.emergency.status.lastError`.
- With no usable policy document (never fetched, expired more than 5 minutes
  ago, invalid anchor), each feature uses its failure mode: `.failOpen`
  (default), `.failClosed` (use for actions that move money) or
  `.useLastValidPolicy`. Before `initialize` every feature is allowed.
- Partial rollouts bucket by a random installation id. Pass
  `subject:` to bucket by your own stable pseudonymous user id instead; never
  an email or anything else that identifies a person.
- `BugCapsule.emergency.changes` (an `AsyncStream`) and `observe(_:)` (main
  thread) report new policies; `status` reports the document state, revision,
  last fetch and last error.
- Objective-C: `BCEmergency.sharedInstance` with
  `initializeWithConfiguration:`, `isFeatureAllowed:subject:`,
  `evaluateFeatureKey:subject:` (a `BCEmergencyDecision`) and
  `refreshPoliciesWithCompletion:`.

### Sending users to the App Store (`REQUIRE_UPDATE`)

A `REQUIRE_UPDATE` decision carries the first version without the
restriction. Configure the App Store update adapter and let the guarded
feature offer the update:

```swift
BugCapsule.emergency.initialize(EmergencyConfiguration(
    trustAnchor: "bcek.v1.…",
    updateProvider: AppStoreUpdateProvider()))   // bundleId/country default to the app and the device storefront

// Where the feature starts, on the main actor:
let decision = BugCapsule.emergency.evaluate(featureKey: "checkout.confirm_order")
if decision.action == .requireUpdate {
    let update = try? await BugCapsule.emergency.updates.checkAvailability(for: decision)
    if update?.isAvailable == true {
        // Your UI first; then the App Store page over your view controller.
        let state = await BugCapsule.emergency.updates.presentUpdate(from: viewController)  // .openedStore or .failed
    } else {
        showUnavailable(decision.publicUserMessage)  // the store does not have the version yet
    }
}
```

- `checkAvailability` asks the public iTunes lookup API
  (`itunes.apple.com/lookup?bundleId=…&country=…`) for the listed version.
  An update is available only when that version is at least the required
  version (and newer than the installed one), compared like policy version
  ranges. Timeouts, HTTP errors and a missing listing throw an
  `EmergencyUpdateError` (`timeout`, `http_error`, `not_listed`, …); a
  failure never counts as available.
- `presentUpdate(from:)` shows `SKStoreProductViewController` over your view
  controller, or opens the listing in the App Store app when there is no view
  controller or the page does not load (`fallbackToStoreURL`). Pass
  `presentation: .storeURL` to always open the App Store app. Call
  `markDeclined()` when the user says no in your own prompt.
- iOS has no in-app install: the SDK never installs or restarts anything,
  and nothing else in the app is blocked. An installed update shows up as the
  new app version.
- What the adapter learns (`available`, `opened_store`, `declined`, …) is
  reported to BugCapsule as a runtime report: on change, at most once a
  minute, never in replay. No report is sent without an update adapter.
- Builds distributed outside the App Store implement `EmergencyUpdateProvider`
  (`flow: .custom`) themselves.
- Objective-C: set `BCEmergencyConfiguration.updateProvider` to a
  `BCAppStoreUpdateProvider`, then use `BCEmergency.sharedInstance.updates`
  (`checkAvailabilityWithRequiredVersion:completion:`,
  `presentUpdateWithRequiredVersion:fromViewController:completion:`,
  `markDeclined`).

**A client guard only improves what users see.** A modified or old app can
skip it. Your server must enforce the same restriction for anything that
moves money or data, at the point where the operation commits.

Platform limits:

- Policies never contain code, and the SDK never downloads or runs any. A
  bug in native code is fixed only by a new App Store build.
- iOS has no forced in-app update. `REQUIRE_UPDATE` is a decision your app
  shows (with `requiredVersion`); the App Store adapter above only checks the
  listed version and opens the store page.
- While BugCapsule replays a capsule, `evaluate` returns the decision the app
  saw at that point of the capture, with source `.replay` and no policy
  object, and no policy is fetched. A feature the capsule has no decision for
  is allowed. Capture records a decision when it changes, as a hash of the
  subject (never the subject), at most 256 feature and subject pairs per run.
  A replay of a capsule needs a build with an SDK that records decisions; an
  older one allows every feature. During a replay, `updates` reaches no
  provider or store: `checkAvailability` says no update is available and
  `presentUpdate` returns `.notAvailable`.

Wire format, verification and evaluation rules:
[docs/emergency-client-v1.md](docs/emergency-client-v1.md).

## Privacy

Redaction runs on the device before anything is written: sensitive keys in
bodies, `UserDefaults`, action payloads and state; sensitive headers;
credentials in URLs; and tokens, JWTs, API keys and card numbers in free text.
Secure text fields are always redacted.

Tighten it with `redactKeys`, `redactHeaders`, `redactPatterns`,
`beforeRecord`, `beforeCheckpoint` and `BugCapsuleURLSession(exclude:)`. Only
allowlisted `UserDefaults` keys are read. Your project settings can also add
redaction keys, turn off body capture, lower sampling, switch off a single
adapter (for example WebSockets, without touching HTTP capture) or switch
capture off remotely.

Redaction is best effort. It does **not** find secrets in URL path segments,
personal data that isn't a credential (names, emails, addresses), secrets
under innocuous key names, or binary bodies. Inspect real capsules with
`bugcapsule inspect` before a wider rollout. More:
[Privacy and redaction](https://docs.bugcapsule.com/privacy.html).

## Going to production

- Production sessions record a sample of sessions: `productionSampleRate`
  (default `0.1`), capped by your project's rate. Monitoring sessions are not
  sampled.
- Learn the kill switch before you need it: `bugcapsule capture --on` stops
  capture for every device and deletes queued capsules; `--off` resumes it.
- Upload dSYMs for every release build.
- Read the [production checklist](https://docs.bugcapsule.com/production.html).

Data lives in `Application Support/bugcapsule` (excluded from backups). Uploads
run while the app is in the foreground and retry with backoff; nothing is
uploaded in the background. Storage and network errors never reach your app.
Details: [docs/how-it-works.md](docs/how-it-works.md#storage-uploads-and-backend-connectivity).

## Limitations

- **Touches are not replayed.** Replay uses named actions and tracked text.
  Touches are captured for diagnosis only. A capsule that has only touches is
  `partial`.
- Replay runs on simulators only.
- Lifecycle replay posts notifications only; the real application state
  doesn't change.
- `BugCapsule.now()` and `BugCapsule.random` are the only virtualized clock
  and randomness; `Date()` and `Int.random` in app code are not.
- WebSockets are captured and replayed only through `BugCapsuleWebSocket`; a
  `URLSessionWebSocketTask` created directly is neither recorded nor blocked
  in replay. Binary frames are size-only by default, ping/pong is not
  recorded, and a capsule whose window starts at a periodic checkpoint with a
  socket open can't be replayed (record from launch).
- URLSession stream tasks, Keychain, Core Data, files and SQLite are not
  captured (write an integration for your own storage).
- Screens are traced through `observe(_:)`, `.bugCapsuleRoute` and
  `screenWillAppear` only (no swizzling).

Full list: [docs/how-it-works.md#limitations](docs/how-it-works.md#limitations).

## Demo app

[`Examples/Demo`](Examples/Demo) is a small shop (UIKit home screen, SwiftUI
cart) with three planted "can't reproduce" bugs: a wrong total, a network race
and a stale cache after an upgrade. Walkthrough and fix toggle:
[docs/how-it-works.md](docs/how-it-works.md#demo-app).

## More documentation

| Topic | Where |
|---|---|
| iOS SDK guide | [docs.bugcapsule.com/ios](https://docs.bugcapsule.com/ios.html) |
| Quickstart (30 minutes, capture to verified fix) | [docs.bugcapsule.com/quickstart](https://docs.bugcapsule.com/quickstart.html) |
| CLI reference | [docs.bugcapsule.com/cli](https://docs.bugcapsule.com/cli.html) |
| How capture, monitoring, uploads and replay work | [docs/how-it-works.md](docs/how-it-works.md) |
| Release symbols | [docs.bugcapsule.com/symbols](https://docs.bugcapsule.com/symbols.html) |
| Troubleshooting | [docs.bugcapsule.com/troubleshooting](https://docs.bugcapsule.com/troubleshooting.html) |
| Working on this repository | [docs/development.md](docs/development.md) |

## Support and license

Questions or access requests: [contact@bugcapsule.com](mailto:contact@bugcapsule.com).

This SDK is proprietary software of Bug Capsule. Use, copying, modification
and distribution require prior written permission. See [LICENSE](LICENSE).

## Optional capsule screenshots (unreleased)

Opt-in PNG frames are stored inside capsules and displayed against event time.
See [capture, privacy, limits and platform examples](docs/screenshots-v1.md).


## Optional signed patch runtime

Select **BugCapsulePatch** from the same repository-root SwiftPM dependency at
`0.4.1-beta.5`. The product links the existing core SDK and an embedded, pinned
XCFramework for iOS arm64 and iOS Simulator arm64/x86_64. It requires iOS15+; the
core SDK's macOS support is unchanged, but the patch API is iOS-only. No second
repository, local path dependency or runtime binary download is needed.

```swift
.package(url: "https://github.com/BugCapsule/bug_capsule_ios_sdk.git", exact: "0.4.1-beta.5")
// In your iOS target dependencies:
.product(name: "BugCapsule", package: "bug_capsule_ios_sdk"),
.product(name: "BugCapsulePatch", package: "bug_capsule_ios_sdk")
```

Register immutable module/surface contracts in the original binary and pin your
project's public roots; never ship the example's development root for a customer
project. See [patch release packaging](docs/patch-release.md) for provenance and
scope. Installing the package alone does not enable patching or establish store
qualification.
