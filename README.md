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
version `0.4.1-beta.2`. Add **`BugCapsule`** to your app target and
**`BugCapsuleXCTest`** to your UI test target.

Or in a `Package.swift`:

```swift
.package(url: "https://github.com/BugCapsule/bug_capsule_ios_sdk.git", exact: "0.4.1-beta.2"),

// app target
.product(name: "BugCapsule", package: "bug_capsule_ios_sdk"),
// UI test target
.product(name: "BugCapsuleXCTest", package: "bug_capsule_ios_sdk"),
```

> **Versions.** SDK tokens and connection status are available starting with `0.4.1-beta.2`.
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

The `bugcapsule` CLI replays capsules from every BugCapsule SDK. It is a Dart
tool shipped in the Flutter package, so it needs
[Flutter](https://docs.flutter.dev/get-started/install) installed even for iOS
projects.

```bash
dart pub global activate bug_capsule 0.4.1-beta.2
bugcapsule --version
```

If the shell can't find `bugcapsule`, add `~/.pub-cache/bin` to your `PATH`.

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
| Errors | `captureException`, `report(error:)`, `check`/`fail`, uncaught `NSException`s, **native crashes** (signals and Mach exceptions) and **app hangs** (main thread blocked 2 s) |
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

## Privacy

Redaction runs on the device before anything is written: sensitive keys in
bodies, `UserDefaults`, action payloads and state; sensitive headers;
credentials in URLs; and tokens, JWTs, API keys and card numbers in free text.
Secure text fields are always redacted.

Tighten it with `redactKeys`, `redactHeaders`, `redactPatterns`,
`beforeRecord`, `beforeCheckpoint` and `BugCapsuleURLSession(exclude:)`. Only
allowlisted `UserDefaults` keys are read. Your project settings can also add
redaction keys, turn off body capture, lower sampling or switch capture off
remotely.

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
- URLSession WebSocket and stream tasks, Keychain, Core Data, files and SQLite
  are not captured (write an integration for your own storage).
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
