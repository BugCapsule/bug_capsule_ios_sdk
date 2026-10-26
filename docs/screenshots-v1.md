# Capsule screenshots extension (screenshots-v1)

Status: implemented on `codex/capsule-screenshots`; not yet released.

Screenshots are optional diagnostic `screenshot` events in the existing gzip JSON
capsule. This additive extension works with specVersion 1 and 2. It does not
introduce a dependency, change replay eligibility, or supply replay inputs.
Existing unknown-event preservation keeps PNG bytes through every SDK codec and
CLI. Old capsules without screenshots remain valid. Old dashboards show the
unknown event; updated dashboards render its pixels.

## Wire format

```json
{"seq": 42, "t": 1235, "type": "screenshot", "data": {
  "schema": 1, "mimeType": "image/png", "privacy": "reviewed",
  "capturedAtT": 1230, "width": 640, "height": 360, "base64": "<PNG bytes>"
}}
```

`seq` and `t` are assigned by the existing recorder when the frame is committed.
`capturedAtT` is the session-clock time immediately before the capture provider
starts. It must be an integer no later than the event's `t`; like other session
times it may be negative before the first frame anchor. Providers must render
immediately, not fetch historical images or wait for network operations. Async
render/encoding can finish later; the dashboard uses capturedAtT and reports the
age of the nearest preceding image, never interpolating or claiming a frame is
replay output. Sequence numbers remain monotonic; image capture is single-flight.

PNG is the only format. Width/height must match IHDR and be 1–2048 each. Base64
must be canonical, with no data URI or whitespace. Maximum decoded frame size:
262144 bytes. Maximum 20 frames and 2097152 decoded image bytes per capsule.
SDKs conservatively enforce these counts over the entire session, including
frames later evicted by the ordinary recorder. They throttle attempts to at least
1000 ms apart. Limits can be lowered, never raised beyond these hard ceilings.
Providers are not invoked once count/total budgets are exhausted. Images are
counted inside existing capsule-size, outbox and cache budgets as well.

Supported PNG chunks: IHDR, PLTE, tRNS, IDAT, IEND, sRGB, gAMA, cHRM, pHYs, sBIT.
A complete bounded chunk stream and IDAT/IEND are required. Text, EXIF, arbitrary
ancillary metadata and animation chunks are rejected, as are trailing bytes.
Validation checks structure and dimensions, not a full PNG pixel/CRC decode;
corrupt pixel data fails in the image element without interpreting markup.
SDKs reject invalid provider output without recording it. Backend and dashboard
readers reject invalid screenshot payloads and aggregate limits. The capsule's
existing SHA-256 verifies stored/downloaded gzip integrity.

## Capture and privacy

Install `ScreenshotIntegration` in the existing integrations list and explicitly
set `enabled: true`. It is disabled by default. The required
`captureRedactedPng` callback owns capture and masking, and returns null/nil for a
sensitive or unsupported screen. Call `capture()` after a reviewed screen renders
or at application-selected action boundaries; await it on web/Flutter before
calling the ordinary capsule capture API. Native capture runs synchronously on
the main/UI thread. There is no background timer, automatic full-window capture,
or rendering in a crash handler. Crashes can include previously recorded frames;
there is no promise of a final crash frame. Android CrashBridge is unchanged.

The API intentionally requires an app-owned renderer: web has no portable silent
DOM screenshot API; generic full-window capture cannot reliably mask custom
canvases, embedded views, payment widgets, or OS secure surfaces. Native bitmap
and Flutter image encoders, and the web canvas encoder, help return PNG bytes.
For UIKit/Views/Compose/Flutter, render an allowlisted subtree or a dedicated safe
preview; replace sensitive controls and custom content with opaque masks before
encoding. For web, draw an approved canvas/offscreen view. Do not use desktop
capture, bypass FLAG_SECURE/secure entry, or automatically snapshot an entire app.
No renderer or external image library is downloaded by the SDK.

`privacy: reviewed` describes the provider contract; it is not proof of automated
redaction. Regex/key redaction cannot remove secrets from pixels. Binary bytes
bypass text scrubbing, as binary HTTP bodies already do; `beforeRecord` still runs
and can drop a screenshot. Do not put tokens, URLs, account identifiers or labels
in screenshot payloads. Providers must avoid screenshots of payment/password/
personal information and use opaque masking, not reversible blur. Do not rely on
tracked-text masking to mask pixels. The normal enabled/sampling/remote kill
switch and replay guards apply. Web/Flutter/iOS reject inactive app capture;
Android providers must also check their Activity lifecycle before rendering.

A false result means disabled, throttled, over budget, skipped or failed capture.
A true result means submitted to the recorder; beforeRecord may still drop it.
Provider errors never propagate into application code. A pending web/Flutter
capture is discarded if recording stops or the integration is rebound. A provider
that never resolves keeps that integration busy; it cannot accumulate tasks.

## Storage, reading and rollout

The backend validates screenshot events before writing the original capsule
bytes. PNGs share the capsule's project authorization, retention, encryption,
export and deletion; no database migration, public media URL, separate file or
image endpoint is needed. Ingest credentials cannot download them. Existing
storage must still be configured with the project's encryption requirements.
The dashboard recording reader revalidates image bounds. The Timeline contains
a screenshot lane, frame selector and preceding-frame preview; Events expands a
frame image and metadata without dumping large base64 text into the page.

Release the backend and dashboard readers before enabling screenshot capture in
SDK consumers. Existing backend releases accepting unknown events preserve these
bytes but do not enforce the new image-specific limits. Existing project capsule
size limits still apply: a low project limit can reject a capsule below the image
budget. Lower screenshot budgets for those projects. PNG frames can increase
upload size and UI-thread work; encode a small approved raster, not a high-DPI
full screen. The SDK doesn't retain raw bitmaps after provider completion; callers
own disposal of images/bitmaps they create.

## Basic usage

All four integrations use the same options: enabled, minIntervalMs, maxFrames,
maxFrameBytes, maxTotalBytes, captureRedactedPng. Android uses Kotlin named
arguments, Swift uses `captureRedactedPng:` returning Data?, Dart returns
FutureOr<Uint8List?>, and web returns Uint8Array/null (optionally a Promise).

Web:
```ts
const screenshots = new ScreenshotIntegration({
  enabled: true,
  captureRedactedPng: () => screenshotPngFromCanvas(approvedMaskedCanvas),
});
await BugCapsule.init({ mode: 'qa', integrations: [screenshots] });
// After rendering only approved content:
await screenshots.capture();
await BugCapsule.capture();
```

Android:
```kotlin
val screenshots = ScreenshotIntegration(enabled = true) {
    if (!safeScreenIsResumed) null
    else ScreenshotIntegration.pngFromRedactedBitmap(approvedMaskedBitmap)
}
// Include screenshots in BugCapsule.init(..., integrations).
// On UI thread, after rendering:
screenshots.capture()
// Then use BugCapsule.capture() normally.
```

iOS:
```swift
let screenshots = ScreenshotIntegration(enabled: true) {
    guard safeScreenIsVisible else { return nil }
    return ScreenshotIntegration.pngFromRedactedImage(approvedMaskedImage)
}
// Include screenshots in BugCapsule.start(..., integrations:).
// On MainActor, after rendering:
screenshots.capture()
// Then await BugCapsule.capture().
```

Flutter:
```dart
final screenshots = ScreenshotIntegration(
  enabled: true,
  captureRedactedPng: () async {
    if (!safeScreenIsVisible) return null;
    return ScreenshotIntegration.pngFromRedactedImage(approvedMaskedImage);
  },
);
// Include screenshots in BugCapsule.init(..., integrations:).
await screenshots.capture();
await BugCapsule.capture();
```

Names beginning `approvedMasked` and the screen visibility conditions above are
application-owned objects/policies, not SDK APIs. Never pass an unreviewed raw
window image as a shortcut.
