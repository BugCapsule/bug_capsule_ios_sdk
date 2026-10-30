# Emergency policies: client contract v1

What an SDK or a server guard does to fetch, verify, cache and evaluate
BugCapsule emergency policies. This file is public-safe: it is copied into the
SDK repositories (`spec/emergency-client-v1.md`, `spec-fixtures/emergency-v1/`).
Every client must pass the vectors in `emergency-fixtures/` (§9).

Emergency policies are **remote feature guards**, not code delivery. A client
never downloads or runs code. A policy only tells the app whether a named
feature may run and what to show instead. The app's own server must enforce
the same restriction for anything that moves money or data (§8).

## 1. Terms

| Term | Meaning |
|---|---|
| application | A BugCapsule project. Its id is a UUID. |
| environment | A free-form name such as `production` or `staging`. Every environment has its own policies and its own revision counter. Pattern `^[a-z0-9][a-z0-9_-]{0,39}$`. |
| feature key | Lower-case dotted name, e.g. `checkout.confirm_order`. Pattern `^[a-z0-9_-]{1,64}(\.[a-z0-9_-]{1,64}){0,7}$`. A policy key may end in `.*` to cover every key below it (`checkout.*` matches `checkout.pay`, not `checkout`). There is no global wildcard. |
| document | The signed list of active policies of one application and environment, with a revision that only ever increases. |
| trust anchor | A string the developer embeds in the app: the application id and the public keys allowed to sign its documents. |

Platforms: `FLUTTER_ANDROID`, `FLUTTER_IOS`, `NATIVE_ANDROID`, `NATIVE_IOS`, `SERVER`.
A Flutter app reports `FLUTTER_ANDROID` or `FLUTTER_IOS` according to the host OS.

## 2. Trust anchor

```
bcek.v1.<base64url(UTF-8 JSON)>
{"app":"<application uuid>","keys":[{"kid":"ek_…","alg":"ES256","spki":"<base64url DER SubjectPublicKeyInfo>"}]}
```

* The anchor is compiled into the app or set in the app's configuration. It is
  **never** fetched from the network, and a key inside a response is never trusted.
* base64url is unpadded (RFC 4648 §5); decoders must accept input without padding.
* `alg` must be `ES256` (ECDSA P-256, SHA-256). A key with another `alg` makes the
  anchor invalid. An invalid anchor means emergency policies are off: the
  client logs one warning and every evaluation uses its failure mode (§7.4).
* Rotation: the dashboard first publishes a *next* key, so the anchor lists
  two keys. Apps that ship with that anchor keep verifying after the backend
  promotes the next key. Apps carrying only the old key stop accepting new
  documents after the promotion and fall back to their failure mode once
  their cached document expires.

## 3. Fetching

```
GET {api}/v1/apps/{application_id}/emergency/policies?environment={env}&platform={PLATFORM}&app_version={v}&sdk_version={v}
Authorization: Bearer {ingest credential}      // the bct_/bci_ key from the SDK connection token
If-None-Match: {etag of the cached envelope}   // when there is one
```

`{api}` and the credential are the same as for capture. The application id
comes from the trust anchor (`app`). `app_version` and `sdk_version` are
diagnostics only; every caller receives the same document.

| Answer | Client action |
|---|---|
| `200` + envelope | Verify (§4), then accept or reject (§5). Store the `ETag` header with it. |
| `304` | The cached envelope is current. Nothing to do: its `expires_at` is unchanged. |
| `409` with `reason: emergency_not_configured` | The project has no signing key. Treat as a failed fetch. Retry on the normal schedule. |
| `401`, `403` | The credential is refused. Stop scheduled fetches for this process. The cached document stays in use until it expires. |
| `404` | The application id does not match the credential. Treat as `401`. |
| `429`, `5xx`, network error, timeout | Failed fetch. Back off (§7.2). Honor `Retry-After` (seconds, clamped to 0–86400). |

Timeouts: 5 s to connect, 10 s for the whole request. The response body is at
most 1 MiB; larger bodies are a failed fetch.

## 4. Envelope and verification

```json
{ "format": "bugcapsule.emergency.v1", "alg": "ES256", "kid": "ek_…",
  "payload": "<base64url of the document's UTF-8 JSON bytes>",
  "signature": "<base64url of the DER ECDSA signature over those bytes>" }
```

Verify in this order. Stop at the first failure and use that reason code:

1. Missing or non-string `kid`, `payload` or `signature`, or a body that is not an object. Reason: `malformed`.
2. `format` is not `bugcapsule.emergency.v1` or `alg` is not `ES256`. Reason: `unsupported_format`.
3. `kid` is not in the anchor. Reason: `unknown_key`.
4. ECDSA P-256/SHA-256 verification of the **decoded payload bytes** fails, including undecodable base64 or DER. Reason: `bad_signature`.
5. The payload is not a JSON object. Reason: `malformed`.
6. `schema_version` is not `1`. Reason: `unsupported_schema`.
7. `application_id` is not the anchor's `app`. Reason: `wrong_application`.
8. `environment` is not the configured environment. Reason: `wrong_environment`.

Never re-serialize the payload before verifying. Parse it only after the
signature checks out. Unknown fields are ignored, which keeps a v1 client
forward-compatible within schema 1.

### Document (payload)

```json
{
  "type": "bugcapsule.emergency.policy-document",
  "schema_version": 1,
  "application_id": "7c9e6679-…",
  "environment": "production",
  "revision": 42,
  "issued_at": "2026-10-29T08:00:00.000Z",
  "expires_at": "2026-10-29T09:00:00.000Z",
  "policies": [ {
    "policy_id": "…", "key": "checkout.confirm_order", "revision": 3,
    "action": "BLOCK", "priority": 0, "severity": "P0", "incident_id": "…",
    "target_platforms": [], "version_ranges": [{"min": "2.4.0", "max": "2.4.2"}],
    "rollout_bp": 10000, "rollout_seed": "…",
    "reason_code": "PRICING_SAFETY", "public_user_message": "Checkout is temporarily unavailable.",
    "required_version": null, "fallback": null, "expires_at": null
  } ]
}
```

Actions are `ALLOW`, `BLOCK`, `READ_ONLY`, `REQUIRE_UPDATE`, `SHOW_MAINTENANCE`,
`DISABLE_FEATURE` and `USE_SAFE_FALLBACK`. If a policy has an unknown action,
the client treats it as `BLOCK`, which fails safe. Whatever the action, a
policy whose fields are malformed makes the whole document `malformed`.

## 5. Accepting a verified document

The client keeps the current envelope, its ETag, the time it was received
(`received_at`), and the highest revision it has ever accepted. All of these
persist across restarts.

* `revision` lower than the highest accepted revision: reject with `stale_revision`. This blocks replay of an older document that had fewer restrictions.
* Same revision and `issued_at` not later than the current document's: keep the current document and change nothing.
* `expires_at` already past by more than 300 s on the device clock: reject with `expired_on_arrival`.
* Otherwise accept. Swap the in-memory snapshot atomically, persist the envelope (write to a temp file, then rename), and notify observers if any decision could have changed.

Callers must never see a half-applied revision. Evaluations use either the
old snapshot or the new one, never a mix.

## 6. Evaluation

Input: feature key, platform, app version (or null), subject (or null), now.

1. **Candidates** are policies where all of the following hold:
   * the key matches (exact, or `prefix.*`);
   * `expires_at` is null or later than now;
   * `target_platforms` is empty or contains the platform;
   * the version is targeted;
   * the subject is in the rollout.
2. **Version targeted.** `version_ranges` is empty, or the version falls in a range (both bounds inclusive, null means unbounded). An app version that does not parse, or is null, counts as targeted.
3. **Version order.** The syntax is `v?N(.N){0,5}(-pre)?(+build)?`, where each `N` is 1–9 digits and the leading `v` is case-insensitive. Missing parts count as 0 and build metadata is ignored. A pre-release sorts before its release. Pre-release identifiers compare as in SemVer §11: numeric identifiers numerically and before alphanumeric ones, alphanumeric identifiers by ASCII.
4. **Rollout.** `rollout_bp >= 10000` includes everyone; `<= 0` includes no one. Otherwise, if the subject is null or empty, the subject is included (fails safe). Else `bucket = uint32_be(SHA-256(UTF-8 "<rollout_seed>:<subject>")[0..4]) mod 10000`, and the subject is included when `bucket < rollout_bp`.
5. **Winner.** Highest `priority` first. Then the most restrictive action, in the order BLOCK > REQUIRE_UPDATE > SHOW_MAINTENANCE > DISABLE_FEATURE > READ_ONLY > USE_SAFE_FALLBACK > ALLOW. Then an exact key over a wildcard. Then the lowest `policy_id` by code-unit order.
6. With no candidate the result is ALLOW. Only ALLOW is `allowed: true`. `fallback_available` is true only for USE_SAFE_FALLBACK with a non-null `fallback`.

The decision has these fields: `feature_key`, `allowed`, `action`, `reason_code`,
`policy_id`, `policy_revision`, `document_revision`, `public_user_message`,
`required_version`, `fallback` and `fallback_available`. SDKs add `source` (§7.4).

The subject defaults to the installation id (§7.3). Apps may pass their own
stable pseudonymous user id instead. They must not pass an email address or
anything else that identifies a person.

## 7. Client runtime

### 7.1 Startup

1. Parse the anchor. If it is invalid, see §2.
2. Load the persisted envelope and verify it again (§4) against the current anchor and environment. Discard it if verification fails, for example after a key rotation or an anchor change.
3. Publish the snapshot. Startup must not wait for the network, and evaluation is always synchronous and in memory.
4. Start the first fetch in the background.

### 7.2 Refresh

* Clients fetch on startup and every `refreshInterval` (default 60 s, minimum 15 s). They also fetch when the app returns to the foreground, and when the app calls `refreshPolicies()`. Concurrent calls join the fetch already in flight.
* After a failure, the delay is `min(refreshInterval × 2^(failures−1), 15 min)`, raised to `Retry-After` when that is larger, with ±20% jitter. A success resets the failure count.
* While the app is in the background, no timers run. The app fetches on resume.
* A push message or any other "something changed" signal only triggers a fetch. It is never applied as a policy.

### 7.3 Installation id and receipts

* The installation id is 16 random bytes in base64url (22 characters), created on first use and persisted apart from the policy cache. It is the default rollout subject and the receipt identity, and it is never linked to a person.
* After accepting a revision, the client sends one receipt with status `APPLIED` and that revision. After rejecting a `200` response, it sends one receipt with status `FAILED` and the reason as `errorCode`. Each `(revision, status, errorCode)` is sent at most once per process. Receipts are fire-and-forget: a failure is logged and dropped, never retried in a loop.

```
POST {api}/v1/apps/{application_id}/emergency/receipts
{"environment":"production","platform":"NATIVE_IOS","installationId":"…","appVersion":"2.4.1","sdkVersion":"0.5.0","revision":42,"status":"APPLIED","errorCode":null}
→ 204
```

`errorCode` takes one of the verification or acceptance reasons in lower case
(`bad_signature`, `stale_revision`, …), matching `^[a-z][a-z0-9_]{0,63}$`.
A third status, `RUNTIME`, carries adapter state and is described in §7.6.

### 7.4 Failure modes

The current document is *usable* while `now <= expires_at + 300 s` on the device
clock. When it is not usable, or there is no document, the app's configured
failure mode for that feature applies. The default for every key is
`FAIL_OPEN`. Apps opt individual keys (exact or `prefix.*`; exact wins, then
the longest prefix) into one of three modes:

| Mode | No usable document |
|---|---|
| `FAIL_OPEN` (default) | ALLOW, `reason_code: POLICY_UNAVAILABLE`, `source: failure_mode`. |
| `FAIL_CLOSED` | BLOCK, `reason_code: POLICY_UNAVAILABLE`, `source: failure_mode`. Use for actions that move money. |
| `USE_LAST_VALID_POLICY` | Evaluate the last verified document even though it has expired (`source: stale_policy`). With no document at all, ALLOW as in FAIL_OPEN. |

A usable document gives `source: policy`. The whole app never fails closed
by default.

While the SDK replays a Capsule, the emergency module makes no network calls
and sends no receipts. Every evaluation returns what the app saw during
capture, with `source: replay` (§7.8).

### 7.5 Status and observation

The client exposes the current state:

| Field | Values |
|---|---|
| `state` | `none`, `usable`, `expired` |
| `revision` | number |
| `issuedAt`, `expiresAt` | timestamps |
| `lastFetchAt`, `lastError` | timestamp, error |
| `credentialRejected` | boolean |

It also offers a way to observe snapshot changes. Observers are called after
the swap, off any lock, and the platform-appropriate thread rule applies (for
example the main thread for UI listeners). Failures inside observers never
affect the client.

### 7.6 Runtime reports

A client with a hotfix or update adapter (§7.7) reports what that adapter
knows. The backend uses the reports to check that a recovery can reach the
installed builds, and to follow a recovery once it ships. Reports are
optional; a client without adapters never sends one.

A report is a receipt (§7.3) with status `RUNTIME`, the highest accepted
revision (`0` before any), `errorCode: null`, and a `runtime` object:

```
{"environment":"production","platform":"FLUTTER_ANDROID","installationId":"…","appVersion":"2.4.1+42","sdkVersion":"0.6.0",
 "revision":42,"status":"RUNTIME","errorCode":null,
 "runtime":{
   "hotfix":{"provider":"shorebird","available":true,"releaseVersion":"2.4.1+42","currentPatch":3,"nextPatch":4,"state":"restart_required"},
   "update":{"provider":"google_play","flow":"flexible","state":"downloaded","availableVersion":"2.4.2","requiredVersion":"2.4.2"}}}
→ 204
```

| Field | Rule |
|---|---|
| `hotfix.provider`, `update.provider` | `^[a-z][a-z0-9_]{0,31}$`. Shipped adapters use `shorebird`, `google_play`, `app_store`. |
| `hotfix.available` | The installed build carries the provider's patch runtime. A build made without it reports `false`. |
| `hotfix.releaseVersion` | The release patches apply to, or null. At most 64 characters. |
| `hotfix.currentPatch` | The patch the running process uses; null on the base release. |
| `hotfix.nextPatch` | The patch that becomes active on the next start, when it differs from `currentPatch`; otherwise null. |
| `hotfix.state` | `up_to_date`, `outdated`, `downloading`, `restart_required`, `unavailable`, `failed`. |
| `update.flow` | `immediate`, `flexible`, `store_page`, `custom`. |
| `update.state` | `not_available`, `available`, `in_progress`, `downloaded`, `declined`, `failed`, `opened_store`. |
| `update.availableVersion`, `update.requiredVersion` | Strings of at most 64 characters, or null. |

Patch numbers are integers from 1 to 2³¹−1. Either of `hotfix` and `update`
may be left out, and `runtime` must not carry other fields.

* A client sends a report when its runtime object changes. It never sends
  the same object twice in a row, and it sends at most one report every 60 s.
  When the object changes again within that interval, the client sends only
  the latest one when the interval ends. Reports are fire-and-forget, like
  every receipt.
* `RUNTIME` receipts are exempt from the once-per-`(revision, status,
  errorCode)` rule of §7.3. A client may send several of them for one
  revision.
* When `hotfix.state` is `failed` or `unavailable`, null patch numbers mean
  "unknown". They do not mean the base release.
* `APPLIED` and `FAILED` receipts may also carry the latest `runtime`.
* No adapter can observe that an update was installed, because the process
  that started it is gone by then. An installed update shows up as the new
  `appVersion` in that installation's next receipt.
* In replay mode (§7.4) nothing is reported.

### 7.7 Recovery adapters

The adapters help an app pick up a fix. A fix still arrives only through a
mechanism the platform allows. No adapter downloads native code, installs a
package by itself, or restarts the app.

**Hotfix adapter (Flutter only).** It has three operations:
`checkAvailability`, `downloadAvailablePatch` and `getStatus`. It reports
whether a patch was downloaded, and it never reports a downloaded patch as
active. A downloaded patch becomes active on the next start. The adapter
reports `restart_required` and leaves the timing to the app.

* The shipped adapter is for Shorebird, in a separate package. It works only in
  builds created with `shorebird release`. Any other build reports
  `available: false`; such a build can only be fixed by a store release.
* Code push delivers Dart code only. Changes to native code or plugins need a
  store release.

**Update adapter (Android and iOS).** It covers an app that has to move to a
newer store build, usually because a decision says `REQUIRE_UPDATE` with a
`required_version`. An update is available only when the store's version is
at least `required_version`, compared by the version rules in §6.

* **Google Play:** the adapter uses the Play In-App Updates API.
  * It uses the flexible flow by default.
  * It uses the immediate flow only when all three hold: the app opted in, the
    decision is `REQUIRE_UPDATE` with severity `P0` or `P1`, and Play allows an
    immediate update for that update.
  * After a flexible download, the app decides when to call complete. Complete
    restarts the app.
  * Play reports version codes, not version names. The adapter turns
    `required_version` into a version code in one of two ways:
    * the build number, so `2.4.2+57` becomes 57;
    * a mapping the app supplies.

    Without either, any Play update newer than the installed version code
    counts as available.
  * Apps distributed outside Google Play implement the same adapter
    interface themselves. The SDK never installs a package.
* **App Store:** iOS has no in-app install flow. The adapter does three things:
  * It finds the listed version through the public iTunes lookup API, using
    the bundle id and the storefront country.
  * It shows the App Store product page.
  * It reports `opened_store`. Whether the user then updates shows up later, as
    the new `appVersion` in that installation's next receipt (§7.6).

### 7.8 Decisions in Capsules

A guard changes what the app does, so a replay has to see the decisions the
user saw. The SDK records them while it records a Capsule. Evaluations before
recording starts are kept and written when it does.

**Recording.** The event is written when the decision for a feature key and
subject changes, not on every evaluation, because apps may evaluate during
every build or layout:

```json
{"seq": 41, "t": 1820, "type": "emergency.decision", "data": {
  "key": "checkout.confirm_order", "subject": "748982dd71b97baf",
  "action": "BLOCK", "source": "policy", "reasonCode": "INCIDENT",
  "policyId": "…", "policyRevision": 3, "documentRevision": 42,
  "message": "Payments are paused.", "requiredVersion": null,
  "fallback": null, "fallbackAvailable": false}}
```

| Field | Notes |
|---|---|
| `key` | The feature key as evaluated. |
| `subject` | Only when the app passed a subject: the first 16 hex characters of SHA-256 of the UTF-8 string `bugcapsule.emergency.subject:<subject>`. The subject itself is never written. |
| `action`, `source`, `reasonCode` | As in the decision (§6, §7.4). `allowed` is not stored: only ALLOW is allowed. |
| `policyId`, `policyRevision`, `documentRevision`, `message`, `requiredVersion`, `fallback`, `fallbackAvailable` | As in the decision; `message` is its `public_user_message`. Fields that are null may be omitted. |

Events go through the SDK's capture rules like any other: redaction, the
`beforeRecord` hook, sampling and the kill switch.

Two entries in the same state are the same decision. Any field that differs
is a change, including `documentRevision`.

A periodic checkpoint writes one event for each tracked decision, right after
the checkpoint, so a window that starts there still knows the decisions made
before it. These events aren't app activity, so idle compression ignores them.
The SDK tracks at most 256 key and subject pairs. Decisions for further pairs
are not recorded.

**Capability.** `manifest.capabilities["emergency.decisions"]` says whether a
replay can trust the Capsule's decisions:

| Value | Meaning |
|---|---|
| `supported` | Every decision is in the Capsule. A Capsule with no events made no evaluations. |
| `partial` | Some decisions are missing: the 256 pair limit was reached, or the capture rules dropped one or changed its `key`, `subject` or `action` (for example `key` in the app's redaction keys), including rules that arrive after it was recorded. |
| absent | The SDK didn't record decisions. |

**Replay.** Replay looks up each evaluation at the replay clock `t`, in the
same milliseconds as the events:

1. Take the entries with the same `key` and the same `subject` (absent matches
   absent). If there are none, take every entry with that `key`.
2. Return the latest entry with `entry.t <= t` (on equal `t`, the later event).
   If there is none, return the earliest entry: an app may evaluate a little
   sooner during replay.
3. With no entry for the key, return ALLOW. The user never reached that guard
   in the recording, and a fix may add a new key.

The result has the recorded fields with `source: replay` and no policy object.
The recorded `source` is not exposed. An entry with an unknown `action` or
without a `key` is ignored. Capsules without the capability replay as before:
every evaluation returns ALLOW with `source: replay`.

A replayed `REQUIRE_UPDATE` must not reach anything: recovery adapters (§7.7)
make no provider or network calls during replay.

Replay needs an SDK that supports this section. A candidate built with an
older SDK allows every feature.

## 8. Server enforcement

A client guard improves the user's experience and nothing more. A server that
commits an irreversible operation must check the policy itself, at the
transactional boundary, with `platform: SERVER`. The subject should be the
actor or operation id. The server must use idempotency keys so that retries
never charge twice. The BugCapsule server guard (`@bugcapsule/emergency-guard`)
implements this contract for Node.js and documents its consistency options.

## 9. Shared vectors

| File | What it pins down |
|---|---|
| `versions.json` | `compare` (−1/0/1/null), `invalid`, `targeted` |
| `rollout.json` | buckets |
| `evaluation.json` | full decisions; `expected` uses the snake_case decision fields of §6, without `source` |
| `envelopes.json` | verification outcomes with `anchor`; `valid_second_key` is `ok` with `anchor_rotated` |
| `replay-decisions.json` | §7.8: subject tags, and the decision replay returns at a time |

Clients load the files from their copy of the fixtures and assert every case.
