import Foundation

#if canImport(StoreKit)
    import StoreKit
#endif
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// The App Store update adapter (§7.7). iOS has no in-app install flow, so it
/// does three things: finds the listed version with the public iTunes lookup
/// API, shows the App Store product page, and reports `opened_store`. Whether
/// the user then updates shows up later, as the new app version in the next
/// receipt.
///
/// ```swift
/// BugCapsule.emergency.initialize(EmergencyConfiguration(
///     trustAnchor: "bcek.v1.…", updateProvider: AppStoreUpdateProvider()))
/// ```
///
/// It never downloads code, and it shows nothing on its own: the app calls
/// `BugCapsule.emergency.updates.presentUpdate(from:)` where the guarded
/// feature starts.
@objc(BCAppStoreUpdateProvider)
public final class AppStoreUpdateProvider: NSObject, EmergencyUpdateProvider, Sendable {
    /// How `presentUpdate` takes the user to the App Store.
    public enum Presentation: Sendable, Equatable {
        /// `SKStoreProductViewController` over the app's view controller.
        /// Without a view controller, the store URL is opened instead.
        case productPage
        /// The listing's URL, opened in the App Store app.
        case storeURL
    }

    static let defaultEndpoint = URL(string: "https://itunes.apple.com/lookup")!
    static let maxBodyBytes = 1 << 20

    public let providerId = "app_store"
    public let flow = EmergencyUpdateFlow.storePage
    /// The bundle id looked up; nil: `Bundle.main.bundleIdentifier`.
    @objc public let bundleId: String?
    /// The storefront, as an ISO 3166-1 alpha-2 (or alpha-3) country code;
    /// nil: the device's App Store storefront, else its region, else `us`.
    @objc public let country: String?
    public let presentation: Presentation
    /// A product page that fails to load opens the store URL instead; false:
    /// the presentation fails.
    @objc public let fallbackToStoreURL: Bool
    private let endpoint: URL
    /// Seconds for the whole lookup; 5 s without progress fails it sooner.
    private let timeout: TimeInterval
    private let session: URLSession

    /// [bundleId] and [country] override what the device says; see the
    /// properties.
    public init(
        bundleId: String? = nil, country: String? = nil, presentation: Presentation = .productPage,
        fallbackToStoreURL: Bool = true
    ) {
        self.bundleId = bundleId
        self.country = country
        self.presentation = presentation
        self.fallbackToStoreURL = fallbackToStoreURL
        self.endpoint = Self.defaultEndpoint
        self.timeout = 10
        self.session = Self.makeSession(timeout: 10)
    }

    /// Tests: another lookup endpoint and timeout.
    init(bundleId: String?, country: String?, endpoint: URL, timeout: TimeInterval) {
        self.bundleId = bundleId
        self.country = country
        self.presentation = .productPage
        self.fallbackToStoreURL = true
        self.endpoint = endpoint
        self.timeout = timeout
        self.session = Self.makeSession(timeout: timeout)
    }

    /// Objective-C: the product page with the store URL as fallback.
    @objc(initWithBundleId:country:)
    public convenience init(bundleId: String?, country: String?) {
        self.init(bundleId: bundleId, country: country, presentation: .productPage, fallbackToStoreURL: true)
    }

    @objc public override convenience init() {
        self.init(bundleId: nil, country: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    /// Like the emergency transport: ephemeral, no cache or cookies.
    private static func makeSession(timeout: TimeInterval) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = min(timeout, 5)
        c.timeoutIntervalForResource = timeout
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpCookieStorage = nil
        return URLSession(configuration: c)
    }

    // MARK: availability

    /// The App Store listing of one bundle id in one storefront.
    struct Listing: Sendable, Equatable {
        var version: String
        var trackId: Int
        var trackViewURL: URL?
    }

    public func checkAvailability(requiredVersion: String?, installedVersion: String?) async throws(EmergencyUpdateError)
        -> EmergencyUpdateAvailability
    {
        guard let bundleId = bundleId ?? Bundle.main.bundleIdentifier, !bundleId.isEmpty else {
            throw EmergencyUpdateError(.noBundleId, "the app has no bundle identifier; pass bundleId")
        }
        if let requiredVersion, EmergencyContract.parseVersion(requiredVersion) == nil {
            throw EmergencyUpdateError(.invalidVersion, "the required version \"\(requiredVersion)\" is not a version")
        }
        let country = await resolvedCountry()
        let listing = try await lookup(bundleId: bundleId, country: country)
        return try Self.availability(listing: listing, requiredVersion: requiredVersion, installedVersion: installedVersion)
    }

    /// Available when the store's version is at least [requiredVersion] and
    /// newer than [installedVersion] (an installed version that does not
    /// parse is not compared). §6 version order.
    static func availability(listing: Listing, requiredVersion: String?, installedVersion: String?) throws(EmergencyUpdateError)
        -> EmergencyUpdateAvailability
    {
        let store = listing.version
        guard EmergencyContract.parseVersion(store) != nil else {
            throw EmergencyUpdateError(.invalidVersion, "the App Store version \"\(store)\" is not a version")
        }
        let installed = installedVersion.flatMap { EmergencyContract.parseVersion($0) == nil ? nil : $0 }
        if requiredVersion == nil && installed == nil {
            throw EmergencyUpdateError(.invalidVersion, "no required or installed version to compare the App Store version with")
        }
        var available = true
        if let requiredVersion {
            guard let c = EmergencyContract.compareVersions(store, requiredVersion) else {
                throw EmergencyUpdateError(.invalidVersion, "the required version \"\(requiredVersion)\" is not a version")
            }
            available = c >= 0
        }
        if let installed, let c = EmergencyContract.compareVersions(store, installed) {
            available = available && c > 0
        }
        return EmergencyUpdateAvailability(
            isAvailable: available, availableVersion: store, requiredVersion: requiredVersion,
            storeIdentifier: String(listing.trackId), storeURL: listing.trackViewURL ?? storeURL(trackId: listing.trackId))
    }

    static func storeURL(trackId: Int) -> URL? { URL(string: "itms-apps://apps.apple.com/app/id\(trackId)") }

    /// `GET {endpoint}?bundleId=…&country=…`.
    func lookup(bundleId: String, country: String) async throws(EmergencyUpdateError) -> Listing {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw EmergencyUpdateError(.networkError, "the lookup URL is not valid")
        }
        components.queryItems = [URLQueryItem(name: "bundleId", value: bundleId), URLQueryItem(name: "country", value: country)]
        guard let url = components.url else { throw EmergencyUpdateError(.networkError, "the lookup URL is not valid") }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: min(timeout, 5))
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        BugCapsuleURLProtocol.markInternal(&req)
        let status: Int
        var body = Data()
        do {
            let (bytes, response) = try await session.bytes(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw EmergencyUpdateError(.networkError, "not an HTTP response")
            }
            status = http.statusCode
            if status == 200 {
                for try await b in bytes {
                    body.append(b)
                    if body.count > Self.maxBodyBytes {
                        bytes.task.cancel()
                        throw EmergencyUpdateError(.invalidResponse, "the lookup response is larger than 1 MiB")
                    }
                }
            } else {
                bytes.task.cancel()
            }
        } catch let e as EmergencyUpdateError {
            throw e
        } catch let e as URLError where e.code == .timedOut {
            throw EmergencyUpdateError(.timeout, "the App Store lookup timed out")
        } catch {
            throw EmergencyUpdateError(.networkError, error.localizedDescription)
        }
        guard status == 200 else {
            throw EmergencyUpdateError(.httpError, "the App Store lookup answered HTTP \(status)", httpStatus: status)
        }
        return try Self.parseLookup(body, bundleId: bundleId, country: country)
    }

    /// `results[0]`: `version`, `trackId` and `trackViewUrl`.
    static func parseLookup(_ data: Data, bundleId: String, country: String) throws(EmergencyUpdateError) -> Listing {
        guard let json = try? JSON.parse(data), let results = json["results"]?.arrayValue else {
            throw EmergencyUpdateError(.invalidResponse, "the App Store lookup answer has no results")
        }
        guard let first = results.first else {
            throw EmergencyUpdateError(.notListed, "\(bundleId) is not listed in the \(country) storefront")
        }
        guard let version = first["version"]?.stringValue, !version.isEmpty else {
            throw EmergencyUpdateError(.invalidResponse, "the App Store listing has no version")
        }
        guard let trackId = first["trackId"]?.intValue, trackId > 0 else {
            throw EmergencyUpdateError(.invalidResponse, "the App Store listing has no trackId")
        }
        let page = first["trackViewUrl"]?.stringValue.flatMap { URL(string: $0) }
        return Listing(version: version, trackId: trackId, trackViewURL: page?.scheme == "https" ? page : nil)
    }

    // MARK: storefront

    func resolvedCountry() async -> String {
        if let c = country.flatMap(Self.alpha2) { return c }
        if let c = await Self.storefrontCountry().flatMap(Self.alpha2) { return c }
        if let c = Self.regionCountry().flatMap(Self.alpha2) { return c }
        return "us"
    }

    /// Lower-case alpha-2 for an alpha-2 or alpha-3 code; nil otherwise.
    static func alpha2(_ code: String) -> String? {
        let c = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard c.utf8.allSatisfy({ $0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z") }) else { return nil }
        switch c.utf8.count {
        case 2: return c.lowercased()
        case 3: return alpha3to2[c]?.lowercased()
        default: return nil
        }
    }

    /// The device's App Store storefront (ISO 3166-1 alpha-3), waiting at
    /// most 2 s for StoreKit.
    static func storefrontCountry() async -> String? {
        #if canImport(StoreKit)
            return await withCheckedContinuation { continuation in
                let once = OnceContinuation<String?>(continuation)
                let timeout = Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    once.resume(nil)
                }
                Task {
                    let code = await Storefront.current?.countryCode
                    once.resume(code)
                    timeout.cancel()
                }
            }
        #else
            return nil
        #endif
    }

    static func regionCountry() -> String? {
        if #available(iOS 16, macOS 13, *) { return Locale.current.region?.identifier }
        return Locale.current.regionCode
    }

    // MARK: presentation

    @MainActor
    public func presentUpdate(_ availability: EmergencyUpdateAvailability, presentation context: EmergencyUpdatePresentation)
        async -> EmergencyUpdateState
    {
        guard availability.isAvailable else { return .notAvailable }
        #if os(iOS)
            if presentation == .productPage, let presenter = context.viewController,
                let id = availability.storeIdentifier.flatMap(Int.init)
            {
                switch await showProductPage(trackId: id, from: presenter) {
                case .success:
                    return .openedStore
                case .failure(let error):
                    BugCapsuleLog.warn("emergency: the App Store page did not load (\(error))")
                    if !fallbackToStoreURL { return .failed }
                }
            }
        #endif
        let url = availability.storeURL ?? availability.storeIdentifier.flatMap(Int.init).flatMap(Self.storeURL)
        guard let url else {
            BugCapsuleLog.warn("emergency: no App Store URL to open")
            return .failed
        }
        if await Self.open(url) { return .openedStore }
        BugCapsuleLog.warn("emergency: could not open \(url.absoluteString)")
        return .failed
    }

    @MainActor
    private static func open(_ url: URL) async -> Bool {
        #if canImport(UIKit)
            return await UIApplication.shared.open(url)
        #elseif canImport(AppKit)
            return NSWorkspace.shared.open(url)
        #else
            return false
        #endif
    }

    #if os(iOS)
        /// Loads the product page, then presents it over the top-most view
        /// controller above [presenter].
        @MainActor
        private func showProductPage(trackId: Int, from presenter: UIViewController) async -> Result<
            Void, EmergencyUpdateError
        > {
            let controller = SKStoreProductViewController()
            let delegate = ProductPageDelegate()
            controller.delegate = delegate
            objc_setAssociatedObject(controller, &ProductPageDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            let failure: String? = await withCheckedContinuation { continuation in
                controller.loadProduct(withParameters: [SKStoreProductParameterITunesItemIdentifier: NSNumber(value: trackId)]) {
                    @Sendable loaded, error in
                    continuation.resume(returning: loaded ? nil : (error?.localizedDescription ?? "the product did not load"))
                }
            }
            if let failure { return .failure(EmergencyUpdateError(.presentationFailed, failure)) }
            var top = presenter
            while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
            guard top.viewIfLoaded?.window != nil else {
                return .failure(EmergencyUpdateError(.presentationFailed, "the view controller is not in a window"))
            }
            top.present(controller, animated: true)
            return .success(())
        }
    #endif
}

#if os(iOS)
    /// Dismisses the product page when the user closes it.
    @MainActor
    private final class ProductPageDelegate: NSObject, @preconcurrency SKStoreProductViewControllerDelegate {
        nonisolated(unsafe) static var key: UInt8 = 0

        func productViewControllerDidFinish(_ viewController: SKStoreProductViewController) {
            viewController.presentingViewController?.dismiss(animated: true)
        }
    }
#endif

/// A checked continuation resumed by whichever caller comes first.
private final class OnceContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        let c: CheckedContinuation<T, Never>? = lock.locked {
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: value)
    }
}

extension AppStoreUpdateProvider {
    /// ISO 3166-1 alpha-3 to alpha-2 (StoreKit storefronts are alpha-3; the
    /// lookup API takes alpha-2). Kosovo appears as XKS in StoreKit.
    static let alpha3to2: [String: String] = {
        let table = """
            AFG AF ALA AX ALB AL DZA DZ ASM AS AND AD AGO AO AIA AI ATA AQ ATG AG ARG AR ARM AM ABW AW AUS AU AUT AT \
            AZE AZ BHS BS BHR BH BGD BD BRB BB BLR BY BEL BE BLZ BZ BEN BJ BMU BM BTN BT BOL BO BES BQ BIH BA BWA BW \
            BVT BV BRA BR IOT IO BRN BN BGR BG BFA BF BDI BI CPV CV KHM KH CMR CM CAN CA CYM KY CAF CF TCD TD CHL CL \
            CHN CN CXR CX CCK CC COL CO COM KM COG CG COD CD COK CK CRI CR CIV CI HRV HR CUB CU CUW CW CYP CY CZE CZ \
            DNK DK DJI DJ DMA DM DOM DO ECU EC EGY EG SLV SV GNQ GQ ERI ER EST EE SWZ SZ ETH ET FLK FK FRO FO FJI FJ \
            FIN FI FRA FR GUF GF PYF PF ATF TF GAB GA GMB GM GEO GE DEU DE GHA GH GIB GI GRC GR GRL GL GRD GD GLP GP \
            GUM GU GTM GT GGY GG GIN GN GNB GW GUY GY HTI HT HMD HM VAT VA HND HN HKG HK HUN HU ISL IS IND IN IDN ID \
            IRN IR IRQ IQ IRL IE IMN IM ISR IL ITA IT JAM JM JPN JP JEY JE JOR JO KAZ KZ KEN KE KIR KI PRK KP KOR KR \
            KWT KW KGZ KG LAO LA LVA LV LBN LB LSO LS LBR LR LBY LY LIE LI LTU LT LUX LU MAC MO MDG MG MWI MW MYS MY \
            MDV MV MLI ML MLT MT MHL MH MTQ MQ MRT MR MUS MU MYT YT MEX MX FSM FM MDA MD MCO MC MNG MN MNE ME MSR MS \
            MAR MA MOZ MZ MMR MM NAM NA NRU NR NPL NP NLD NL NCL NC NZL NZ NIC NI NER NE NGA NG NIU NU NFK NF MKD MK \
            MNP MP NOR NO OMN OM PAK PK PLW PW PSE PS PAN PA PNG PG PRY PY PER PE PHL PH PCN PN POL PL PRT PT PRI PR \
            QAT QA REU RE ROU RO RUS RU RWA RW BLM BL SHN SH KNA KN LCA LC MAF MF SPM PM VCT VC WSM WS SMR SM STP ST \
            SAU SA SEN SN SRB RS SYC SC SLE SL SGP SG SXM SX SVK SK SVN SI SLB SB SOM SO ZAF ZA SGS GS SSD SS ESP ES \
            LKA LK SDN SD SUR SR SJM SJ SWE SE CHE CH SYR SY TWN TW TJK TJ TZA TZ THA TH TLS TL TGO TG TKL TK TON TO \
            TTO TT TUN TN TUR TR TKM TM TCA TC TUV TV UGA UG UKR UA ARE AE GBR GB USA US UMI UM URY UY UZB UZ VUT VU \
            VEN VE VNM VN VGB VG VIR VI WLF WF ESH EH YEM YE ZMB ZM ZWE ZW XKS XK XKX XK
            """
        let parts = table.split(separator: " ").map(String.init)
        var map: [String: String] = [:]
        for i in stride(from: 0, to: parts.count - 1, by: 2) { map[parts[i]] = parts[i + 1] }
        return map
    }()
}
