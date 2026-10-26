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

## 0.4.1-beta.2 — 2026-10-25

- Add single SDK token setup and connection status diagnostics.
- Report missing replay instrumentation and stop uploads when credentials are rejected.
- Update developer setup and integration documentation.
