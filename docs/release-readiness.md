# BugCapsule release candidates — 2026-10-23

No package has been published. Versions remain Flutter/Android/iOS 0.4.0 and Web 0.3.0. Review the readiness ledger before release: a distributable archive does not close outstanding device/feature gates.

All four SDKs and both CLIs now carry Apache-2.0, matching the pre-existing Android metadata, under the user's instruction to prepare the licensing. No individual copyright attribution was invented.

## Flutter and multi-runtime CLI

From `bug_capsule_flutter_sdk`, run `flutter analyze`, package tests, then `python3 tool/package_release.py`. It produces `dist/bug_capsule-0.4.0.tar.gz` and SHA-256. The candidate removes workspace-only resolution and validates outside the repository to avoid inherited ignores. Extract outside the checkout, run `flutter pub publish --dry-run`, and after reviewing release gates publish with `flutter pub publish` yourself.

Clean local install: depend on the extracted package using a path dependency, run `flutter pub get`, and invoke `dart run bug_capsule:bugcapsule --help` from that Flutter app. The package includes all integrations; constraints are in pubspec.yaml and a fresh consumer resolved bloc 9, Riverpod 3, Dio 5, http 1, go_router 18 and SharedPreferences 2 successfully on this host. This is not evidence for every allowed lower-bound version.

For a standalone command, `flutter pub global activate --source path /absolute/path/to/extracted/bug_capsule-0.4.0` was verified with an isolated PUB_CACHE; add that cache’s bin directory to PATH.

The multi-runtime `bugcapsule` CLI is this Dart executable. npm `@bugcapsule/cli` is the sourcemap tool; it does not supply run/verify/regress. `capture --on` enables the kill switch (capture disabled); `capture --off` resumes capture. Keep this meaning in scripts.

## Android

Run `./gradlew test lintRelease publishAll`. Local Maven repository: `build/repo` (including Gradle plugin `dev.bugcapsule.gradle` 0.4.0 and its marker); coordinates `dev.bugcapsule:bugcapsule-android:0.4.0` plus optional modules. A standalone API 23 consumer successfully compiled release against this repository. Lint errors fail the build.

Run `python3 scripts/central-bundle.py` to produce an explicitly UNSIGNED review ZIP. POMs contain SCM, developer, URL and license metadata; source and Javadoc jars are included. To prepare an upload candidate, configure your existing GPG key and run `python3 scripts/central-bundle.py --sign-key YOUR_KEY_ID`. The script signs and adds checksums but never uploads. Confirm ownership of `dev.bugcapsule` in the Central Portal before uploading; if that namespace is not yours, decide coordinates and rebuild rather than publishing under an unauthorized namespace. Validate the signed bundle in the portal and publish manually. No signing key or registry credential was generated here.

## iOS

Run `sh scripts/package-release.sh`. Candidate: `dist/bugcapsule-ios-0.4.0.tar.gz` plus SHA-256. A separate SwiftPM executable built and ran using the extracted source. Actual SwiftPM distribution resolves the repository's version tag: after review, commit the candidate source, create `v0.4.0` on the intended commit and push it yourself. Consumers use the repository URL and version 0.4.0. No tag was created or pushed here.

Capture/semantic replay on the tested iOS 27 simulator is separate from minimum iOS 15 and physical-device validation. Pointer replay and physical-device CLI launch are still missing features.

## Web

Run `npm ci`, `npx playwright install chromium firefox webkit`, `npm run typecheck`, `npm run build`, `npm test`, then `npm run pack:all`. Four candidates are in `dist-packages`. Install all local tarballs together to resolve same-version peer dependencies; add React for the React package. The clean consumer import check passed.

After checking package-name ownership and release availability, publish each reviewed tarball yourself, starting with `@bugcapsule/web`, then React, web-replay and the sourcemap CLI. Do not assume these versions are currently available in the registry. SDK browser tests cover Playwright Chromium/Firefox/WebKit; the external replay launcher still supports Chromium only. WebKit is not certification of every Safari release.

## Evidence limits

Unit/browser/simulator tests, isolated backend E2E and artifact consumption are recorded separately in the readiness ledger. Physical-device overhead, native fatal-crash handling under real OS conditions, minimum iOS and full backend symbolication remain explicit gates. Hosted CI workflows were added but have not been executed on GitHub in this session.

Detailed test results and remaining gates: [validation evidence](validation-2026-10-23.md).
