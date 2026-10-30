import BugCapsule
import BugCapsulePatch
import Foundation
import SwiftUI

private let trustAnchor = "bcpk.v1.dev-root-1.BA4PNvbk7UmdPR93U56lG_Bpqwq3WgzIrI3zk7IuT-hKhRymUfOY4eQFQGei0tjUkzmpyqaHCZf3MtgxbBxq68U"

struct Line { let sku: String; let qty: Int; let unitCents: Int }
struct Cart { let lines: [Line]; let couponPercent: Int }
struct Priced { let subtotal: String; let discount: String; let total: String; let label: String }

private func money(_ cents: Int) -> String {
    let abs = Swift.abs(cents)
    let frac = abs % 100
    return "\(cents < 0 ? "-" : "")\(abs / 100).\(frac < 10 ? "0" : "")\(frac)"
}

/// The shipped behavior, with the bug the fix removes: the percentage is
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

/// Captures a real failure on whatever patch is active, for replay acceptance.
/// A negative total fails an assertion, so a replay reproduces it exactly when
/// the pinned module still has the bug.
@MainActor
final class Lab: ObservableObject {
    @Published var total = ""
    private let binding: BugCapsulePatchBinding
    private(set) lazy var checkout: @MainActor () -> Void = BugCapsule.action("lab.checkout") { [unowned self] in
        let priced = binding.patch.call(coupon, sample).value
        total = priced.total
        BugCapsule.check("order.total_positive", !priced.total.hasPrefix("-"), "negative order total")
    }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        binding = BugCapsulePatchBinding(
            config: PatchConfig(
                storeDir: support.appendingPathComponent("bcpatch").path,
                projectId: "demo",
                applicationId: "dev.bugcapsule.capsulelab.ios",
                environment: "staging",
                distributionProfile: "development",
                baseBuildId: "ios-capsule-1",
                installationId: "device-1",
                trustRoots: [trustAnchor]
            ),
            modules: [coupon.contract],
            surfaces: [summarySurface]
        )
        var config = BugCapsuleConfig(mode: .qa, gitSha: "capsule-lab", autoCaptureOnFailure: false)
        config.patchBinding = binding
        BugCapsule.start(config)
        _ = checkout
        if !BugCapsule.isReplaying { capture() }
    }

    private func capture() {
        let exchange = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let inbox = exchange.appendingPathComponent("inbox")
        let patch = binding.patch
        let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
        for f in files.sorted(by: { $0.path < $1.path }) {
            if let bundle = try? Data(contentsOf: f) { _ = try? patch.stage(bundle) }
            try? FileManager.default.removeItem(at: f)
        }
        _ = try? patch.markHealthy("first_screen")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            checkout()
            try? await Task.sleep(nanoseconds: 300_000_000)
            if let captured = await BugCapsule.capture() {
                let out = exchange.appendingPathComponent("lab.bugcapsule")
                try? FileManager.default.removeItem(at: out)
                try? FileManager.default.copyItem(at: captured.file, to: out)
            }
            let running = (try? patch.status())?["running"] ?? "none"
            try? "\(running)".write(to: exchange.appendingPathComponent("capture.txt"), atomically: true, encoding: .utf8)
        }
    }
}

@main
struct CapsuleLabApp: App {
    @StateObject private var lab = Lab()

    var body: some Scene {
        WindowGroup {
            VStack {
                Text("Total: \(lab.total)")
                Button("Check out", action: lab.checkout)
            }
        }
    }
}
