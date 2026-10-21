import BugCapsule
import SwiftUI

enum CartCacheError: Error, CustomStringConvertible {
    case legacyFormat(version: String)
    var description: String {
        switch self {
        case .legacyFormat(let v): return "cart_cache holds the v\(v) list format; expected an object"
        }
    }
}

/// The saved cart, as v1.0 writes it.
struct CartCache: Codable {
    var cartId: String
    var items: [CartItem]
    var coupon: String?
}

/// SwiftUI cart. Planted bugs:
/// * Bug 1 (data-dependent): `SAVE100` takes a fixed 100 off, so carts whose
///   subtotal is below 100 (it depends on what the server returns) get a
///   negative total; `BugCapsule.check("cart_total_non_negative", ...)`
///   captures it. Fixed when built with `DEMO_FIXES=FIX_NEGATIVE_TOTAL`.
/// * Bug 3 (state restoration): v0.9 stored `cart_cache` as a JSON list;
///   v1.0 decodes an object. Only devices "upgraded from v0.9" fail, and
///   replay reproduces it only because the checkpoint restores UserDefaults.
@MainActor
final class CartModel: ObservableObject {
    let api: ShopAPI
    @Published var items: [CartItem] = []
    @Published var coupon = ""
    @Published var appliedCoupon: String?
    @Published var status = "loading"
    @Published var orderId: String?
    var cartId = ""

    init(api: ShopAPI) { self.api = api }

    var subtotal: Double { items.reduce(0) { $0 + $1.price * Double($1.qty) } }

    var discount: Double {
        switch appliedCoupon {
        case "SAVE10": return subtotal * 0.1
        case "SAVE100":
            #if FIX_NEGATIVE_TOTAL
                return min(100, subtotal)
            #else
                return 100  // Bug: larger than small carts.
            #endif
        default: return 0
        }
    }

    var total: Double { subtotal - discount }

    func load() async {
        status = "loading"
        do {
            let cart = try await api.get("/api/cart", as: CartResponse.self)
            cartId = cart.cartId
            items = cart.items
            // Merge the coupon remembered from the last session.
            if let saved = try readCache() { appliedCoupon = saved.coupon }
            try writeCache()
            status = "ready"
        } catch {
            BugCapsule.report(error: error)
            status = "error: could not load your saved cart"
        }
    }

    private func readCache() throws -> CartCache? {
        guard let raw = UserDefaults.standard.string(forKey: "cart_cache") else { return nil }
        if raw.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            // Bug: v0.9 list format is not migrated.
            throw CartCacheError.legacyFormat(version: "0.9")
        }
        return try JSONDecoder().decode(CartCache.self, from: Data(raw.utf8))
    }

    private func writeCache() throws {
        let data = try JSONEncoder().encode(CartCache(cartId: cartId, items: items, coupon: appliedCoupon))
        UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: "cart_cache")
    }

    func applyCoupon() {
        appliedCoupon = coupon.trimmingCharacters(in: .whitespaces).uppercased()
        AppState.shared.appliedCoupon = appliedCoupon
        BugCapsule.check(
            "cart_total_non_negative", total >= 0,
            String(format: "total %.2f with coupon %@", total, appliedCoupon ?? "-"))
        try? writeCache()
    }

    func checkout() async {
        status = "checking out"
        do {
            let result = try await api.post(
                "/api/checkout",
                json: [
                    "cart_id": cartId, "amount": total,
                    "timestamp": Int(BugCapsule.now().timeIntervalSince1970 * 1000),
                    "nonce": BugCapsule.random.nextInt(1 << 30),
                ], as: CheckoutResponse.self)
            orderId = result.orderId
            AppState.shared.lastOrderId = result.orderId
            status = "paid \(result.orderId)"
        } catch {
            BugCapsule.report(error: error)
            status = "checkout failed"
        }
    }
}

struct CartView: View {
    @ObservedObject var model: CartModel

    var body: some View {
        List {
            Section("Items") {
                ForEach(model.items) { item in
                    HStack {
                        Text("\(item.qty)× \(item.name)")
                        Spacer()
                        Text(String(format: "$%.2f", item.price * Double(item.qty)))
                    }
                    .accessibilityIdentifier("cart.item.\(item.sku)")
                }
            }
            Section("Coupon") {
                TextField("Coupon code", text: BugCapsule.trackedText("cart.coupon", $model.coupon))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("cart.coupon")
                Button("Apply coupon", action: BugCapsule.action("cart.applyCoupon") { model.applyCoupon() })
                    .accessibilityIdentifier("cart.applyCoupon")
            }
            Section("Total") {
                Text(String(format: "%.2f", model.total)).accessibilityIdentifier("cart.total")
                Button("Checkout", action: BugCapsule.action("cart.checkout") { Task { await model.checkout() } })
                    .accessibilityIdentifier("cart.checkout")
                Text(model.status).accessibilityIdentifier("cart.status")
            }
        }
        .task { await model.load() }
    }
}

final class CartHostingController: UIHostingController<CartView>, BugCapsuleRouteNaming {
    var bugCapsuleRoute: String { "/cart" }

    init(model: CartModel) {
        super.init(rootView: CartView(model: model))
        title = "Cart"
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("not used") }
}
