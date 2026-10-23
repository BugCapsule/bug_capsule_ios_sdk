# BugCapsule SDK release-readiness ledger — 2026-10-23

## Decision

**Validated release candidates, not an unconditional 100% sign-off.** The four supported local demo replay paths now pass capture → upload → reproduced → still failing → fix → fixed → regression fail/pass. Important feature/device gates below remain open. No registry publication, release tag, production data use or dashboard/backend source edits were performed. Validation evidence accompanies the SDK release-readiness changes in repository history.

## Changes and final checks

| Component | Completed work | Evidence |
|---|---|---|
| Flutter SDK 0.4.0 | Deterministic encoder barrier proves kill-switch cancellation; synthetic conformance credential allowlist; LICENSE/CHANGELOG; standalone packaging | 311 package tests, analyzer clean; fresh extracted consumer imports SDK; publish dry-run zero warnings |
| Multi-runtime CLI 0.4.0 | Fixed adb discovery when Android SDK is installed but platform-tools is absent from PATH; filesystem test covers SDK env/local.properties and spaces | Regression test passed; real Flutter Android replay subsequently passed; standalone global activation/version verified in isolated PUB_CACHE |
| Android SDK 0.4.0 | Replace API 24/26 calls with API 23-compatible FutureTask, ThreadLocal subclass, exception constructor, conditional ConcurrentHashMap.remove; escape BOM; enable blocking lint | 178 debug +178 release +14 plugin executions, zero failures; zero lint errors. Runtime tests cover Robolectric API 23/24/25/26/35 |
| Android UI/demo | Espresso IdlingResource waits for network completion; actual coupon fix toggle caps discount | API 35 emulator Views/Compose tests pass; native replay E2E below. An initial System UI ANR and later test synchronization failure were diagnosed, not hidden with retries |
| Android distribution | Source/Javadoc/POM/SCM/developer metadata; local bundle signing/checksum tool; include Gradle plugin and marker at unified 0.4.0 (previously 0.3.0) | Clean independent consumer resolves both SDK and Gradle plugin from local Maven and builds release; unsigned review ZIP generated |
| iOS 0.4.0 | LICENSE and release source packaging/documentation; existing semantic path verified through CLI | 114 host tests +119 iOS 27 simulator tests +release guard passed; archive clean SwiftPM consumer builds/runs |
| Web 0.3.0 | Expand browser suite to Chromium/Firefox/WebKit; engine-correct error signatures; omit CLS when layout-shift observation unsupported | 251 unit +75 browser tests; typecheck/build; four tarballs installed together in independent consumer and imported |
| Shared distribution | Apache-2.0 unified following user instruction, based on pre-existing Android declaration; no invented personal copyright name | LICENSE included in packages/archives; publishing guide and artifact SHA-256 manifest |
| CI | Add blocking validation/artifact workflows for Android/iOS/Web | Configured locally; hosted GitHub runs not executed here |

## Fresh E2E results

All attempts used an isolated local backend database `bugcapsule_sdk_release_20261023`, synthetic demo data and local simulators/emulators. Two attempts per replay/verification/regression scenario.

| Runtime/device | Capture and upload | Run | Verify broken | Verify fixed | Regression fixed / broken |
|---|---|---|---|---|---|
| Flutter / Android API 35 emulator | Integration test captures; SDK uploads automatically | REPRODUCED 2/2 | STILL FAILING 2/2 | FIXED 2/2 | pass / fail |
| Android / API 35 emulator | Instrumentation captures; CLI uploads same file | REPRODUCED 2/2 | STILL FAILING 2/2 | FIXED 2/2 | pass / fail |
| iOS / iPhone 18 Pro, iOS 27 simulator | UI test captures; CLI uploads same file | REPRODUCED 2/2 semantic | STILL FAILING 2/2 | FIXED 2/2 | pass / fail |
| Web / Chromium | Browser captures and uploads automatically | REPRODUCED 2/2 | STILL FAILING 2/2 | FIXED 2/2 | pass / fail |

Flutter/Web run results were submitted to the backend. Native Android/iOS additionally repeated run → verify broken → verify fixed with one attempt per phase against backend capsule IDs; all result submissions succeeded. All four persisted statuses were independently read as `fixed` (see `e2e-backend-final-status-2026-10-23.json`). Capture eligibility is partial for native/Flutter fixtures because build.gitSha is absent; Web captured a SHA but replay used the current prebuilt app. **Source-pinned checkout replay was not revalidated.** These limits are not converted to a universal full-chain sign-off.

Logs: `e2e-{flutter,android,ios,web}-{run,verify,fixed,regression-pass,regression-fail}-2026-10-23.log`. Android/iOS uploads: `e2e-android-upload` / `e2e-ios-upload`; Flutter automatic upload: `flutter-device-capture-upload`. Captured files are under `e2e-capsules/`. Flutter generated regression suite is stored under `e2e-fixtures/flutter-regressions/`, outside the SDK's normal test suite.

## Production/privacy checks

- Existing suites cover redaction, offline queues, quotas, revoked credentials, kill switch and strict replay/divergence handling. No guards were weakened.
- Flutter release APK built and launched on API 35. Explicit replay URL produced `ignoring replay request: replay is disabled in release builds` and `BUGCAPSULE_RELEASE_GUARD_PASSED`; see `flutter-release-guard-device-2026-10-23.log`.
- iOS compiled release replay guard passed. Web production guard ran in all three browser engines. Android release tests and blocking lint passed.
- NDK host SIGSEGV/SIGABRT smoke passed; this is not Android device native signal validation.
- Backend symbolication suite passed 9/9 in separate scratch database `bugcapsule_sdk_symbols_20261023`. Native symbolizer is a fake in that suite; real dSYM/ELF symbolication end-to-end remains open.

## Remaining gates — not claimed complete

1. **Missing features:** iOS pointer replay and physical-device CLI launcher are still unimplemented. Semantic simulator replay is verified. Completing them requires a supported XCTest/device transport implementation with divergence/coordinate/timing tests; merely documenting unsupported does not complete them.
2. **Device coverage:** no physical device was available. Android API 23/24/25/26 coverage is Robolectric, not on-device. iOS 15 runtime/device was not tested. Playwright WebKit does not certify all released Safari/iOS browsers.
3. **Performance:** release-device startup/memory/frame/network overhead budgets have not been measured against disabled-SDK baselines. The release guard's launch timing is not an overhead benchmark.
4. **Full contract:** source-pinned replay and actual uploaded release debug-file symbolication still need end-to-end evidence. Browser WebSocket/EventSource/service-worker behavior and native storage/platform integrations retain documented limits.
5. **Publication prerequisites:** owner must verify registry/package namespace rights, choose the exact reviewed commit, supply their existing signing key/credentials and publish. Maven ZIP is explicitly unsigned; script can produce signed bundle but never uploads. No version tag was created. Hosted CI still needs an actual run.

## Deliverables

- `sdk-publishing-guide-2026-10-23.md`: exact local packaging/publishing paths and support limits.
- `sdk-release-artifacts-2026-10-23.json`: absolute artifact paths, sizes and SHA-256.
- `android-final-results-2026-10-23.json`: final test counts and lint errors.
- `{flutter,android,ios,web}-release-source-status-2026-10-23.log`: reviewable source change inventory.

Artifacts: Flutter `dist/bug_capsule-0.4.0.tar.gz`; Android `build/bugcapsule-0.4.0-UNSIGNED-REVIEW.zip`; iOS `dist/bugcapsule-ios-0.4.0.tar.gz`; Web `dist-packages/*.tgz`, each under its SDK repository.
