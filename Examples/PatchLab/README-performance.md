# Opt-in physical performance run

Build the lab **once in Release** after generating its project with XcodeGen. Keep that exact installed binary, device, OS, power state and runtime-store history for all comparisons. A same-binary `baseline` bypasses runtime open and calls the bundled function directly; it does not measure removal of the SDK's linked code from the binary. This path is disabled unless Documents/benchmark-config.json exists. It does not process inboxes, start network updates or upload receipts while measuring.

After normal HTTP acceptance has activated the intended artifact, place this request in the app's Documents directory, terminate only this app and launch it. Fetch Documents/benchmark-result.json after the UI appears. Keep each result under its runId before launching again; the next request replaces the result.

```json
{"runId":"iphone17pro-native-patch-01","mode":"runtime","expectedSource":"patched","expectedReasons":["none"],"expectedOutput":{"subtotal":"68.48","discount":"13.70","total":"54.78","label":"PATCHED 20%"}}
```

Those outputs are for the checked-in coupon_v2 fixture, not a universal patch expectation. Use the exact expected outputs of the artifact actually deployed. The bundled sample expectation is `subtotal=69.98`, `discount=1399.60`, `total=-1329.62`, `label=BASE 20%`. A direct baseline uses mode `baseline`, source `direct_bundled`, and that bundled output. A runtime-on-base fallback run uses mode `runtime`, source `bundled`, and the bundled output; set `expectedReasons` to the reason verified for that scenario (normally `not_patched`). A known faulting artifact can exercise error fallback, but its reason must be explicitly allowed and its actual identity/state retained; it is not equivalent to the on-base fallback.

Every first call, 20 warm-up calls and 200 timed calls checks source and all output fields. Unexpected fallback fails correctness instead of quietly contaminating patched latency. The timed interval is the full Swift SDK call including bridge/JSON conversion; output validation happens after timing. Raw nanoseconds, nearest-rank p50/p95/p99/max and reason counts are retained. Runtime-open and markHealthy (including any journal write) are measured separately. The first call is first in this process, **not proof of a cold filesystem/cache**. For first-call distributions repeat complete launches and aggregate those single observations separately; do not treat 200 warm calls as 200 cold starts.

Mach RSS values are current-process resident-memory snapshots before/after open, after evaluation and at the first SwiftUI appearance dispatch. They are not peak RSS or physical-footprint measurements. `appCodeToFirstAppearanceNs` includes app setup and the benchmark before the UI callback; it is not OS process launch or display presentation latency. Root's separately scheduled Instruments/xctrace launch/allocations run is needed for those measurements. Record hardware/OS, thermal state and low-power mode; repeat runs after cooling and reject comparisons with different thermal or power conditions. No device serial or credentials are written.

No latency budget passes by default. Optionally supply `budgetsNs`, for example `{"p95Ns": YOUR_PREDECLARED_LIMIT_IN_NS}` as a numeric value chosen from the application's actual frame/request budget before observing the result. The result reports comparisons to those user limits, not a production qualification. No arbitrary hardware threshold is built in. `correctness=passed` establishes checked output only. Compare baseline, runtime-on-base and patched distributions with identical hardware/run ordering, and retain raw runs rather than only averaged percentiles. Physical release execution, HTTP acceptance, distribution policy and battery/network impact remain separate evidence.

Remove benchmark-config.json to restore ordinary lab behavior. Do not delete the runtime journal to manufacture a clean comparison; explicitly identify any fresh-install runs separately.

## Real HTTP delivery timing

Remove `benchmark-config.json` to resume the normal delivery flow. Add
`"measurePerformance": "true"` to the private `patch-config.json` (native uses
string values; Flutter uses a boolean). `results.jsonl` then includes
`deliveryPerformance`: whole check/verify/stage nanoseconds, receipt-flush
nanoseconds, and each actual artifact fetch's elapsed nanoseconds and received
byte count. The actor delegates to the existing real transport unchanged and
records neither URLs, tokens, payloads nor error text. A failed download has
`completed: false` and no claimed byte count. Empty fetches mean no download.

Download timing includes transport overhead and buffering; it is not pure wire
time. Use a fresh authorized digest plus backend request logs to substantiate
a first-download claim. Do not erase monotonic trust journals to fake a cold
state. Receipt timing alone does not prove server acceptance; retain HTTP and
backend evidence separately. Keep private delivery configuration out of shared
evidence. No network-latency threshold is assumed.
