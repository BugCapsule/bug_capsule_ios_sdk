# BugCapsule for iOS

BugCapsule turns a failure seen in QA into a portable `.bugcapsule` file that a
developer can replay against the real app code, verify after a fix, and keep as
a regression test. This is the native iOS SDK (Swift, Swift Package Manager).
It writes capsule spec v1 (`spec/capsule-v1.md`) and implements runtime contract
v1 for iOS (`spec/runtimes-v1.md`), so the `bugcapsule` CLI and the backend
treat its capsules like the Flutter, Android and web ones.

| | |
|---|---|
| SDK name in capsules | `bugcapsule-ios` 0.3.0, `runtime.name: ios`, `language: swift` |
| Platforms | iOS 15+ (the package also builds on macOS 12+ for its unit tests) |
| Language | Swift 6 language mode, strict concurrency |
| Products | `BugCapsule` (app target), `BugCapsuleXCTest` (UI test target) |
| Dependencies | none (Foundation, zlib, UIKit/SwiftUI when available) |

## Contents

1. [Quickstart](#quickstart)
2. [Integration reference](#integration-reference)
3. [Supported frameworks and capabilities](#supported-frameworks-and-capabilities)
4. [Failure capture boundaries](#failure-capture-boundaries)
5. [Privacy controls](#privacy-controls)
6. [Storage, uploads and backend connectivity](#storage-uploads-and-backend-connectivity)
7. [Replay with the CLI (XCUITest)](#replay-with-the-cli-xcuitest)
8. [`bugcapsule.json` keys](#bugcapsulejson-keys)
9. [Simulator vs physical devices](#simulator-vs-physical-devices)
10. [Demo app](#demo-app)
11. [Limitations](#limitations)
12. [Development, tests and release procedure](#development-tests-and-release-procedure)

## Quickstart

### 1. Add the package

Xcode: *File → Add Package Dependencies…* with the repository URL, or in a
`Package.swift`:

```swift
.package(url: "https://github.com/<org>/bug_capsule_ios_sdk.git", from: "0.3.0"),
// app target
.product(name: "BugCapsule", package: "bug_capsule_ios_sdk"),
// UI test target
.product(name: "BugCapsuleXCTest", package: "bug_capsule_ios_sdk"),
```

### 2. Start it first thing

```swift
import BugCapsule

func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    BugCapsule.start(
        BugCapsuleConfig(
            mode: .qa,  // default: .debug in DEBUG builds, .production otherwise
            backend: BugCapsuleBackendConfig(url: "https://bugcapsule.example.com",
                                             ingestKey: "bci_..."),   // never the bcs_ secret key
            redactKeys: ["loyaltyId"]),
        integrations: [
            BugCapsuleURLSession(rules: [
                EndpointRule("POST", "/api/checkout", ignoreBodyFields: ["timestamp", "nonce"]),
            ]),
            BugCapsuleUserDefaults(keys: ["cart_cache"], prefixes: ["settings."]),
            BugCapsuleNavigation.shared,
            BugCapsuleStateIntegration.shared,
        ])
    return true
}
```

`start` must run before app code reads `UserDefaults` (first line of
`application(_:didFinishLaunchingWithOptions:)`, or `App.init` for a SwiftUI
`App`): in replay it restores the checkpoint there. It never blocks the app: if
storage or setup fails, the app runs without capture.

### 3. Instrument networking

```swift
let config = URLSessionConfiguration.default
BugCapsule.instrument(config)                 // inserts BugCapsuleURLProtocol first
let session = URLSession(configuration: config)

// Alamofire: same thing, Session(configuration: config)
// URLSession.shared: BugCapsule.instrumentSharedSession() (URLProtocol.registerClass, opt-in)
```

### 4. Name the user's actions and text fields

```swift
// UIKit
button.addAction(BugCapsule.uiAction("cart.checkout") { [weak self] in self?.checkout() }, for: .touchUpInside)
BugCapsule.trackText("cart.coupon", field: couponField)        // isSecureTextEntry is always redacted
BugCapsule.observe(navigationController)                         // route events

// SwiftUI
Button("Checkout", action: BugCapsule.action("cart.checkout") { model.checkout() })
TextField("Coupon", text: BugCapsule.trackedText("cart.coupon", $model.coupon))
SecureField("PIN", text: BugCapsule.trackedText("login.pin", $pin, sensitive: true))
SomeView().bugCapsuleRoute("/cart")
```

Semantic replay invokes these actions by id and restores tracked text by id.

### 5. Assert what "broken" means

```swift
BugCapsule.check("cart_total_non_negative", total >= 0, "total \(total)")
BugCapsule.fail("checkout_stuck", "spinner after 10s")
BugCapsule.report(error: error)            // errors the app caught
```

A failure writes a capsule automatically (after a 300 ms settle delay; at most 3
per session, one per signature), saves it locally and queues it for upload.

### 6. Add the replay test to the UI test target

```swift
import BugCapsuleXCTest

final class BugCapsuleReplayTests: BugCapsuleReplayTestCase {
    func testReplay() throws { try runBugCapsuleReplay() }
}
```

and a `bugcapsule.json` next to the `.xcodeproj` (see
[keys](#bugcapsulejson-keys)). Then:

```bash
bugcapsule list
bugcapsule inspect <id>
bugcapsule run <id> -n 3          # REPRODUCED 3/3
bugcapsule verify <id> -n 3       # after your fix: FIXED
bugcapsule regress add <id> && bugcapsule regress run
```

### 7. Embed the git SHA (recommended)

Add to the app's Info.plist:

```xml
<key>BugCapsuleGitSHA</key><string>$(BUGCAPSULE_GIT_SHA)</string>
<key>BugCapsuleGitDirty</key><string>$(BUGCAPSULE_GIT_DIRTY)</string>
```

The CLI passes both build settings when it builds; for QA/CI builds pass
`BUGCAPSULE_GIT_SHA=$(git rev-parse HEAD)` to `xcodebuild`. Without it capsules
are `partial` (`build.gitSha`) and `bugcapsule run` cannot pin the commit.

## Integration reference

| API | Purpose |
|---|---|
| `BugCapsule.start(_:integrations:)` | Start capture (or replay, see below). |
| `BugCapsuleConfig` | `mode`, `enabled`, `backend`, `gitSha`/`gitDirty`, `stateSchemaVersion`, `checkpointInterval` (30 s), `window` (5 min), `maxEvents` (20,000), `productionSampleRate` (0.1), `autoCaptureOnFailure`, `maxCapsulesPerSession` (3), `captureNetworkBodies`, `maxBodyBytes` (256 KiB), `redactKeys`, `redactHeaders`, `redactPatterns`, `beforeRecord`, `beforeCheckpoint`, `outboxLimits` (10 / 10 MiB / 7 days), `maxStaleConfig` (7 days), `ignoreError`, `labels`. |
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
| `BugCapsuleIntegration` | Write your own integration (name, snapshot, restore, eligibility). |

Integrations and their checkpoint keys: `urlsession` (events only),
`user_defaults` (`{key: {type, value}}`; types `bool`, `int`, `double`,
`string`, `stringArray`, `data` base64, `date` epoch ms), `navigation`
(`{route, backStack}`, periodic checkpoints), `state` (`{key: <JSON>}`).

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

**Not captured**, and never claimed:

* Swift runtime traps: `fatalError`, `precondition`, force-unwrapping `nil`,
  array index out of range, integer overflow, `try!` failures, unowned
  references. They do not raise an NSException.
* POSIX signals (`SIGSEGV`, `SIGBUS`, `SIGABRT` from `abort()`, ...), C++
  exceptions, crashes in other threads' native code.
* Out-of-memory (jetsam) terminations, watchdog kills (launch/resume time
  limits, main-thread hangs), the user force-quitting the app, and the system
  terminating a suspended app.

Report such conditions yourself (`check`/`report(error:)`) before the code that
would trap. Exchanges still in flight when a capsule is written (typically by
the crash handler) are recorded as `http` events with `"pending": true`; replay
keeps those requests open, as the app never got their response.

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

## Storage, uploads and backend connectivity

* Files live in `Application Support/bugcapsule` (excluded from iCloud/iTunes
  backup): `captures/` (newest 20), `outbox/`
  (`<enqueuedAtMs>_<capsuleId>.bugcapsule`), `remote_config.json`. Writes are
  atomic (temp + rename); temp files are removed at start; corrupt files are
  dropped; a full disk drops the capsule. No SDK error reaches the app.
* Backend: `GET /v1/sdk/config` and `POST /v1/capsules` (gzip body,
  `Content-Type: application/octet-stream`, `Authorization: Bearer bci_...`).
  200/201 uploaded; 401/408/429/5xx/network errors retry later (30 s → 1 h, ±20 %
  jitter, `Retry-After` honoured); other 4xx drop the capsule; body
  `code: capture_disabled` refreshes the config.
* Remote config: TTL from `configTtlSeconds` (default 300 s, at least 30 s),
  failure backoff 30 s → 30 min honouring `Retry-After`, refreshed when the app
  becomes active, cached per (backend URL, ingest key); uploads only after a
  successful fetch or with a cached config younger than `maxStaleConfig`
  (7 days). Kill switch (`enabled: false`): recording stops, the buffer is
  dropped, queued and saved capsules are deleted, and it persists across
  launches until a fetch re-enables it. 401/403 stops capture for the session.
  Production sampling: `min(productionSampleRate, remote sampleRate)` at launch;
  a lower rate mid-session keeps recording with probability new/old.
* Lifecycle: uploads run only while the app is running (at launch, when it
  becomes active, after a capture). No background task or background
  `URLSession` is used, so nothing is promised while the app is suspended;
  capsules wait in the outbox for the next foreground.
* Simulator: `http://127.0.0.1:8787` reaches a backend on the Mac. Devices need
  a reachable host (and an ATS exception for plain HTTP, e.g.
  `NSAllowsLocalNetworking` for LAN addresses).

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

Build and capture by hand (the ingest key and URL are passed on the command
line, never committed):

```bash
cd Examples/Demo
xcodebuild test -project BugCapsuleDemo.xcodeproj -scheme BugCapsuleDemo \
  -destination 'id=<simulator udid>' -collect-test-diagnostics never \
  BUGCAPSULE_BACKEND_URL=http://127.0.0.1:8787 BUGCAPSULE_INGEST_KEY=bci_... \
  -only-testing:BugCapsuleDemoUITests/CaptureFlowTests/testCaptureNegativeTotal
```

`CaptureFlowTests` drives the app into each bug (`testCaptureNegativeTotal`,
`testCaptureRaceCrash`, `testCaptureLegacyCart`,
`testOfflineCaptureUploadsAfterRestart`). That is capture automation; replay is
`BugCapsuleReplayTests`, run by the CLI. The project is generated from
`project.yml` with XcodeGen (`xcodegen generate`); the generated project is
checked in.

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
* URLSession: redirects are followed inside the SDK's protocol (the final
  response is recorded and served; app redirect delegates are not consulted);
  authentication challenges use default handling; `httpBodyStream` bodies are
  keyed without a body hash and not recorded; WebSocket/stream tasks are not
  captured. When several instrumented configurations carry different custom
  protocols, the SDK's downstream session uses all of them.
* Only allowlisted UserDefaults keys of the listed types are captured;
  Keychain, Core Data, files and SQLite are not (write an integration).
* Navigation is restored from periodic checkpoints only through an app-provided
  `BugCapsuleNavigation.shared.restorer`.
* Cross-runtime replay is not supported (spec §12).

## Development, tests and release procedure

```bash
swift build
swift test                                    # macOS host: core, conformance, network, outbox, replay
swift test -c release -Xswiftc -enable-testing --filter ReplayProtocolTests/testGate   # release build cannot arm replay
xcodebuild test -scheme BugCapsule-Package -destination 'platform=iOS Simulator,name=iPhone 18 Pro'  # same suite + UIKit tests on iOS
cd Examples/Demo && xcodebuild build-for-testing -project BugCapsuleDemo.xcodeproj -scheme BugCapsuleDemo \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

`spec-fixtures/` is a vendored copy of `bug_capsule_flutter_sdk/spec/fixtures`
(sync with `bug_capsule_flutter_sdk/tool/sync_spec.sh`); `FixtureTests` fails
when the copy differs from a sibling checkout.

Release (SwiftPM is distributed by git tag; nothing to upload):

1. Update `sdkVersion` in `Sources/BugCapsule/Runtime/Session.swift` and the
   version in this README; sync `spec-fixtures`.
2. Run the test commands above and an E2E replay of the demo
   (`bugcapsule run`/`verify`).
3. Tag `vX.Y.Z` (semantic versioning) and push the tag; consumers pin
   `from: "X.Y.Z"`. Optionally publish release notes listing capability changes.
4. Binary distribution is not needed (source package, no dependencies). An
   XCFramework could be produced with `xcodebuild archive` +
   `-create-xcframework` if a closed-source build is ever required.
