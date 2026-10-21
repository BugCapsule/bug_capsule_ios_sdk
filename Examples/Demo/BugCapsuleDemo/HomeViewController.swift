import BugCapsule
import UIKit

/// UIKit home screen. Planted bug 2 (timing-sensitive network): `refresh`
/// loads the profile and the recommendations concurrently and assumes the
/// profile arrives first. When the recommendations win the race (about 1 in
/// 4), building the banner raises an `NSException` and the app crashes.
/// BugCapsule's uncaught-exception handler writes the capsule synchronously;
/// it uploads on the next launch.
final class HomeViewController: UIViewController, BugCapsuleRouteNaming {
    let api: ShopAPI
    var bugCapsuleRoute: String { "/" }

    private let greeting = UILabel()
    private let banner = UILabel()
    private let picks = UILabel()
    private let status = UILabel()
    private var tier: String?
    private var refreshGeneration = 0

    init(api: ShopAPI) {
        self.api = api
        super.init(nibName: nil, bundle: nil)
        title = "BugCapsule Shop"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        greeting.text = "Welcome"
        greeting.font = .preferredFont(forTextStyle: .title2)
        banner.text = "Tap refresh for picks"
        banner.accessibilityIdentifier = "home.banner"
        picks.numberOfLines = 0
        picks.accessibilityIdentifier = "home.picks"
        status.textColor = .secondaryLabel
        status.accessibilityIdentifier = "home.status"
        status.text = "visits: \(AppState.shared.visits)"

        let refresh = button("Refresh picks", id: "home.refresh") { [weak self] in self?.refresh() }
        let cart = button("Open cart", id: "home.openCart") { [weak self] in self?.openCart() }
        let upgrade = button("Simulate upgrade from v0.9", id: "home.simulateUpgrade") { [weak self] in
            self?.simulateUpgrade()
        }
        let capture = UIButton(type: .system, primaryAction: UIAction(title: "Capture now (QA)") { _ in
            Task { await BugCapsule.capture(note: "manual QA capture") }
        })
        capture.accessibilityIdentifier = "home.capture"

        let stack = UIStackView(arrangedSubviews: [greeting, banner, picks, refresh, cart, upgrade, capture, status])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
        ])
    }

    /// A button whose tap is a BugCapsule semantic action (replayed by id).
    private func button(_ title: String, id: String, _ perform: @escaping @MainActor () -> Void) -> UIButton {
        let b = UIButton(configuration: .borderedProminent())
        b.setTitle(title, for: .normal)
        b.accessibilityIdentifier = id
        b.addAction(BugCapsule.uiAction(id, perform), for: .touchUpInside)
        return b
    }

    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        tier = nil
        banner.text = "Loading…"
        api.get("/api/profile", as: Profile.self) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, generation == self.refreshGeneration else { return }
                if case .success(let p) = result {
                    self.tier = p.tier
                    self.greeting.text = "Hi \(p.name)"
                }
            }
        }
        api.get("/api/recommendations", as: Recommendations.self) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, generation == self.refreshGeneration else { return }
                guard case .success(let recs) = result else { return }
                self.picks.text = recs.items.joined(separator: "\n")
                // Bug: assumes the profile response always arrives first.
                guard let tier = self.tier else {
                    NSException(
                        name: NSExceptionName("HomeBannerInconsistency"),
                        reason: "recommendations arrived before the profile: no tier for the banner", userInfo: nil
                    ).raise()
                    return
                }
                self.banner.text = "Picks for \(tier.uppercased()) members"
            }
        }
    }

    func openCart() {
        navigationController?.pushViewController(CartHostingController(model: CartModel(api: api)), animated: true)
    }

    /// Writes the cart cache in the v0.9 format (a JSON array) as a device
    /// upgraded from v0.9 would have it.
    func simulateUpgrade() {
        UserDefaults.standard.set(#"[{"sku":"mug","qty":2},{"sku":"cap","qty":1}]"#, forKey: "cart_cache")
        status.text = "legacy v0.9 cart written"
    }
}
