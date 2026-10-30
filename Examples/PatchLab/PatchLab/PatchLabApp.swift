import BugCapsulePatch
import Foundation
import SwiftUI

private let baseBuildId = "ios-demo-1"
private let trustAnchor = "bcpk.v1.dev-root-1.BA4PNvbk7UmdPR93U56lG_Bpqwq3WgzIrI3zk7IuT-hKhRymUfOY4eQFQGei0tjUkzmpyqaHCZf3MtgxbBxq68U"

struct Line { let sku: String; let qty: Int; let unitCents: Int }
struct Cart { let lines: [Line]; let couponPercent: Int }
struct Priced { let subtotal: String; let discount: String; let total: String; let label: String }

private func money(_ cents: Int) -> String {
    let abs = Swift.abs(cents)
    let frac = abs % 100
    return "\(cents < 0 ? "-" : "")\(abs / 100).\(frac < 10 ? "0" : "")\(frac)"
}

/// The shipped behavior, with the bug the patch fixes: the percentage is
/// applied without dividing by 100.
private func bundledCoupon(_ c: Cart) -> Priced {
    let subtotal = c.lines.reduce(0) { $0 + $1.unitCents * $1.qty }
    let discount = subtotal * c.couponPercent
    return Priced(subtotal: money(subtotal), discount: money(discount), total: money(subtotal - discount), label: "BASE \(c.couponPercent)%")
}

private let coupon = PatchModule<Cart, Priced>(
    id: "pricing.coupon",
    inputSchema: "rec(couponPercent:int,lines:list(rec(qty:int,sku:str,unitPrice:dec(2))))",
    outputSchema: "rec(discount:dec(2),label:str,subtotal:dec(2),total:dec(2))",
    encode: { c in
        ["couponPercent": c.couponPercent, "lines": c.lines.map { ["sku": $0.sku, "qty": $0.qty, "unitPrice": money($0.unitCents)] }]
    },
    decode: { o in
        guard let m = o as? [String: String] else { throw PatchError(code: "bad_output", message: "") }
        return Priced(subtotal: m["subtotal"] ?? "", discount: m["discount"] ?? "", total: m["total"] ?? "", label: m["label"] ?? "")
    },
    fallback: bundledCoupon
)

private let summarySurface = PatchSurfaceContract(
    id: "lab.summary",
    components: ["column", "row", "text", "spacer", "button"],
    actions: ["lab.pay"],
    requiredActions: ["lab.pay"]
)

private let sample = Cart(lines: [Line(sku: "a", qty: 2, unitCents: 1999), Line(sku: "b", qty: 10, unitCents: 300)], couponPercent: 20)

private func processInbox(_ patch: BugCapsulePatch, _ exchange: URL) -> [String] {
    var log: [String] = []
    let inbox = exchange.appendingPathComponent("inbox")
    let files = ((try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
    for f in files {
        do {
            if f.pathExtension == "channel" {
                let sig = f.appendingPathExtension("sig")
                let r = try patch.applyChannel(Data(contentsOf: f), signature: Data(contentsOf: sig))
                log.append("channel \(describe(r))")
                try? FileManager.default.removeItem(at: sig)
                try? FileManager.default.removeItem(at: f)
            } else if f.pathExtension == "bcpatch" {
                let r = try patch.stage(Data(contentsOf: f))
                log.append("stage \(describe(r))")
                try? FileManager.default.removeItem(at: f)
            }
        } catch {
            log.append("rejected \(f.lastPathComponent): \(error)")
            try? FileManager.default.removeItem(at: f)
        }
    }
    return log
}

private func describe(_ d: [String: Any]) -> String {
    (try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
}

struct Run {
    let priced: Priced
    let source: String
    let state: String
    let micros: Int
    let patch: BugCapsulePatch?
}

/// Carries the record into the update task; nothing else touches it.
private struct Sendable_: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

private func append(_ record: [String: Any], to url: URL) {
    guard var line = try? JSONSerialization.data(withJSONObject: record) else { return }
    line.append(0x0A)
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(line)
        h.closeFile()
    } else {
        try? line.write(to: url)
    }
}

private func run() -> Run {
    _ = PerformanceHarness.entryNs
    let fm = FileManager.default
    let exchange = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    try? fm.createDirectory(at: support, withIntermediateDirectories: true)
    // Test-only: an acceptance run points the lab at a real backend. Without
    // this file the lab uses its file inbox. The base build id stays the binary's.
    let remote = (try? Data(contentsOf: exchange.appendingPathComponent("patch-config.json")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
    func openPatch() -> BugCapsulePatch {
        BugCapsulePatch.open(
        config: PatchConfig(
            storeDir: support.appendingPathComponent("bcpatch").path,
            projectId: remote?["projectId"] ?? "demo",
            applicationId: "dev.bugcapsule.patchlab.ios",
            environment: "staging",
            distributionProfile: "development",
            baseBuildId: baseBuildId,
            installationId: "device-1",
            trustRoots: [remote?["trustRoot"] ?? trustAnchor]
        ),
        modules: [coupon.contract],
        surfaces: [summarySurface]
    )
    }
    if fm.fileExists(atPath: exchange.appendingPathComponent("benchmark-config.json").path) {
        try? fm.removeItem(at: exchange.appendingPathComponent("benchmark-result.json"))
        do {
            let b = try PerformanceHarness.run(exchange: exchange, module: coupon, input: sample, open: openPatch) {
                ["subtotal": $0.subtotal, "discount": $0.discount, "total": $0.total, "label": $0.label]
            }
            return Run(priced: b.value, source: b.source, state: "BENCHMARK", micros: Int(b.firstNs / 1000), patch: b.patch)
        } catch {
            if !fm.fileExists(atPath: exchange.appendingPathComponent("benchmark-result.json").path) {
                PerformanceHarness.write(["correctness": "failed", "error": "\(error)"], exchange: exchange)
            }
            return Run(priced: bundledCoupon(sample), source: "benchmark_failed", state: "FAILED", micros: 0, patch: nil)
        }
    }
    let patch = openPatch()
    let start = DispatchTime.now().uptimeNanoseconds
    let result = patch.call(coupon, sample)
    let micros = Int((DispatchTime.now().uptimeNanoseconds - start) / 1000)
    let before = (try? patch.status()) ?? ["state": "UNAVAILABLE"]
    let inbox = patch.available ? processInbox(patch, exchange) : []
    if patch.available { _ = try? patch.markHealthy("first_screen") }
    #if DEBUG
    let mode = "debug"
    #else
    let mode = "release"
    #endif
    let record: [String: Any] = [
        "at": ISO8601DateFormatter().string(from: Date()),
        "mode": mode,
        "platform": "ios",
        "baseBuildId": baseBuildId,
        "source": result.source.rawValue,
        "reason": result.reason as Any? ?? NSNull(),
        "output": ["subtotal": result.value.subtotal, "discount": result.value.discount, "total": result.value.total, "label": result.value.label],
        "evalMicros": micros,
        "state": before["state"] ?? "?",
        "running": before["running"] ?? NSNull(),
        "inbox": inbox,
        "status": (try? patch.status()) ?? NSNull(),
    ]
    let results = exchange.appendingPathComponent("results.jsonl")
    if let remote, let base = remote["baseUrl"], let token = remote["deliveryToken"],
        let transport = try? HttpPatchTransport(
            baseURL: base, deliveryToken: token, applicationId: "dev.bugcapsule.patchlab.ios", platform: "ios",
            distributionProfile: "development", baseBuildId: baseBuildId, installationId: "device-1")
    {
        let updater = PatchUpdater(patch: patch, transport: transport)
        let snapshot = Sendable_(record)
        Task.detached {
            let r = await updater.checkForUpdate()
            var doc = snapshot.value
            var sent = -1
            do { sent = try await updater.flushReceipts() } catch { doc["receiptError"] = "\(error)" }
            doc["update"] = ["state": "\(r.state)", "artifactDigest": r.artifactDigest as Any? ?? NSNull(), "reason": r.reason as Any? ?? NSNull(), "receiptsSent": sent]
            doc["status"] = (try? patch.status()) ?? NSNull()
            append(doc, to: results)
        }
    } else {
        append(record, to: results)
    }
    return Run(priced: result.value, source: result.source.rawValue, state: before["state"] as? String ?? "?", micros: micros, patch: patch)
}

@main
struct PatchLabApp: App {
    private let r = run()

    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text("Patch Lab · iOS").font(.headline)
                Text("Source: \(r.source)")
                Text("State: \(r.state)")
                Text("Label: \(r.priced.label)")
                Text("Subtotal: \(r.priced.subtotal)")
                Text("Discount: \(r.priced.discount)")
                Text("Total: \(r.priced.total)")
                Text("Eval: \(r.micros) µs")
                Spacer().frame(height: 16)
                if let patch = r.patch {
                PatchSurfaceView(patch: patch, id: summarySurface.id, actions: ["lab.pay": {}]) {
                    VStack(alignment: .leading) {
                        Text("Bundled summary")
                        Button("Pay") {}
                    }
                }
                }
            }
            .padding()
            .onAppear {
                DispatchQueue.main.async {
                    let exchange = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    PerformanceHarness.firstFrame(exchange: exchange)
                }
            }
        }
    }
}
