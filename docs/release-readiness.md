# Release validation and distribution

The release workflow builds and tests candidates before publishing. Historical
validation evidence remains in [validation-2026-10-23.md](validation-2026-10-23.md);
it describes that run, not the latest package versions. See the repository
CHANGELOG and manifest for the candidate version, and the package registry or
GitHub release for publication status.

## Standalone CLI

Install `npm install -g @bugcapsule/cli@0.4.0-beta.3`, then `bugcapsule login`.
The CLI downloads and checks a native executable; it does not require Dart or
Flutter. Direct macOS, Linux and Windows executables are attached to the
Flutter repository's v0.4.1-beta.7 release. Replay needs only its app's toolchain.

## Release checks

- Flutter: `flutter pub get`, `flutter analyze`, core and native plugin tests,
  then `python3 tool/package_release.py` (includes a pub.dev dry run).
- Standalone CLI: `python3 tool/build_cli.py`; the GitHub Actions matrix builds
  macOS ARM64/x64, Linux ARM64/x64 and Windows x64 and tests without Dart on PATH.
- Android: `./gradlew test lintRelease publishAll`, native smoke test, then
  `python3 scripts/central-bundle.py --sign-key KEY_ID`. Coordinates use
  `io.github.bugcapsule`, including the Gradle plugin. Publish the signed bundle
  through Maven Central and verify an independent consumer.
- iOS: `sh scripts/package-release.sh`, release-mode replay gate, and an iOS
  simulator build. SwiftPM distribution resolves the version tag.
- Web: `npm ci`, `npm run build`, `npm run typecheck`, `npm test`, then
  `npm run pack:all`. Publish the reviewed tarballs with the `beta` dist-tag.

Publish Android and iOS before the Flutter native plugin, which references their
released versions. Publish the standalone executable assets before the npm CLI.
Check all published artifacts with clean consumers; packaging alone does not
prove publication or runtime compatibility.

Physical-device behavior, minimum OS versions, overhead and end-to-end native
symbolication require their own evidence. Simulator/unit checks do not replace
those checks. Each package's LICENSE is authoritative for its license.
