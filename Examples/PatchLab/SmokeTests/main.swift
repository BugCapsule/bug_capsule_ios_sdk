import Foundation
// Standalone check of the lab's smoke predicate (no simulator needed):
//   swiftc -o /tmp/smoke PatchLab/Smoke.swift SmokeTests/main.swift && /tmp/smoke
let lab = Cart(lines: [Line(sku: "a", qty: 2, unitCents: 1999), Line(sku: "b", qty: 10, unitCents: 300)], couponPercent: 20)
var failures = 0
func expect(_ got: String?, _ want: String?, _ name: String) {
    if got != want { failures += 1; print("FAIL \(name): got \(got ?? "nil"), want \(want ?? "nil")") } else { print("ok   \(name)") }
}
func check(_ s: String, _ d: String, _ t: String, cart: Cart = lab, label: String = "PATCHED 20%") -> String? {
    smokeFailure(cart, Priced(subtotal: s, discount: d, total: t, label: label))
}
expect(String(expectedSubtotalCents(lab)), "6848", "expected lab subtotal")
expect(check("68.48", "13.70", "54.78"), nil, "signed fix passes")
expect(check("69.98", "1399.60", "-1329.62"), "subtotal_mismatch", "shipped bug fails")
expect(check("1.00", "0.20", "0.80"), "subtotal_mismatch", "consistent but wrong fails")
expect(check("68.48", "13.70", "55.78"), "total_mismatch", "wrong total fails")
expect(check("68.48", "6.85", "61.63"), "discount_mismatch", "wrong percentage fails")
expect(check("99999999999999999999.00", "0.00", "0.00"), "unparseable_amounts", "huge value refused, no overflow")
expect(check("9223372036854775807.00", "0.00", "0.00"), "unparseable_amounts", "Int.max digits refused")
expect(check("999999999.99", "199999999.99", "800000000.00"), "subtotal_mismatch", "largest bounded value is safe")
expect(check("0.25", "0.12", "0.13", cart: Cart(lines: [Line(sku: "x", qty: 1, unitCents: 25)], couponPercent: 50)), nil, "half-even")
expect(check("10.00", "5.00", "5.00", cart: Cart(lines: [Line(sku: "x", qty: 1, unitCents: 1000)], couponPercent: 80)), nil, "50% cap")
expect(check("68.4", "13.70", "54.78"), "unparseable_amounts", "one decimal refused")
expect(check("068.48", "13.70", "54.78"), "unparseable_amounts", "leading zero refused")
expect(check("68.48", "13.70", "54.78", label: ""), "empty_label", "empty label")
if failures > 0 { print("\(failures) FAILED"); exit(1) } else { print("all passed") }
