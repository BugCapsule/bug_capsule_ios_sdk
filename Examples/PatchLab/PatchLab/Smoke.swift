import Foundation

struct Line { let sku: String; let qty: Int; let unitCents: Int }
struct Cart { let lines: [Line]; let couponPercent: Int }
struct Priced { let subtotal: String; let discount: String; let total: String; let label: String }

/// The app's own smoke check on the price it is about to show. It recomputes the
/// expected subtotal from the cart (the product rule: lines of 10+ units get 5%
/// off, half-even) and checks the discount and total against it, independently
/// of the patch's code. Returns why the result is not acceptable, or nil. A
/// patched result that fails is never marked healthy, so a signed but wrong
/// patch stays in probation and the engine rolls it back.
///
/// Amounts are parsed with a bound (at most 9 whole digits) before any
/// arithmetic, so a huge value is refused instead of overflowing.
func smokeFailure(_ c: Cart, _ p: Priced) -> String? {
    guard let s = boundedCents(p.subtotal), let d = boundedCents(p.discount), let t = boundedCents(p.total) else { return "unparseable_amounts" }
    if s != expectedSubtotalCents(c) { return "subtotal_mismatch" }
    if d != halfEven(s * min(max(c.couponPercent, 0), 50), 100) { return "discount_mismatch" }
    if t != s - d { return "total_mismatch" }
    if p.label.isEmpty { return "empty_label" }
    return nil
}

/// Lab carts are small (quantities and prices well under 10^6), so this cannot overflow.
func expectedSubtotalCents(_ c: Cart) -> Int {
    c.lines.reduce(0) { sum, l in
        let gross = l.unitCents * l.qty
        return sum + (l.qty >= 10 ? halfEven(gross * 95, 100) : gross)
    }
}

/// `-?(0|[1-9][0-9]{0,8})\.[0-9]{2}`, or nil.
func boundedCents(_ text: String) -> Int? {
    let negative = text.hasPrefix("-")
    let body = Array((negative ? String(text.dropFirst()) : text).utf8)
    guard let dot = body.firstIndex(of: UInt8(ascii: ".")), body.count - dot == 3, (1...9).contains(dot) else { return nil }
    let digits = body[..<dot] + body[(dot + 1)...]
    guard digits.allSatisfy({ $0 >= 48 && $0 <= 57 }), dot == 1 || body[0] != 48 else { return nil }
    let v = digits.reduce(0) { $0 * 10 + Int($1 - 48) }
    return negative ? -v : v
}

func halfEven(_ n: Int, _ d: Int) -> Int {
    let q = n / d, r = n % d
    return r * 2 > d || (r * 2 == d && q % 2 != 0) ? q + 1 : q
}
