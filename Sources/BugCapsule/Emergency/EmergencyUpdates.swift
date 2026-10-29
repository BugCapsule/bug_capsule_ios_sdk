import Foundation

#if canImport(UIKit)
    import UIKit
#endif

// MARK: - Update adapter (§7.7)

/// How an update adapter takes the user to a newer build.
public enum EmergencyUpdateFlow: String, Sendable, Equatable, CaseIterable {
    /// The store's product page (the App Store).
    case storePage = "store_page"
    /// The app's own update path, for builds distributed outside the App Store.
    case custom
}

/// What an update adapter knows about an update, as runtime reports carry it
/// (§7.6). No state says an update was installed: an installed update shows
/// up as the new app version in the next receipt.
public enum EmergencyUpdateState: String, Sendable, Equatable, CaseIterable {
    /// The store has no version that satisfies the required version.
    case notAvailable = "not_available"
    /// The store has a version that satisfies the required version.
    case available
    /// A custom flow is under way.
    case inProgress = "in_progress"
    /// The user chose not to update (`markDeclined()`).
    case declined
    /// The check or the presentation failed.
    case failed
    /// The store page was shown.
    case openedStore = "opened_store"
}

/// The result of an availability check.
public struct EmergencyUpdateAvailability: Sendable, Equatable {
    /// The store's version is at least `requiredVersion` and newer than the
    /// installed version (§6 version order).
    public var isAvailable: Bool
    /// The version the store offers.
    public var availableVersion: String?
    /// The version the check was made against.
    public var requiredVersion: String?
    /// The store's id of the listing (the App Store's track id).
    public var storeIdentifier: String?
    /// The listing's page.
    public var storeURL: URL?

    public init(
        isAvailable: Bool, availableVersion: String?, requiredVersion: String?, storeIdentifier: String? = nil,
        storeURL: URL? = nil
    ) {
        self.isAvailable = isAvailable
        self.availableVersion = availableVersion
        self.requiredVersion = requiredVersion
        self.storeIdentifier = storeIdentifier
        self.storeURL = storeURL
    }

    /// `available` or `not_available`.
    public var state: EmergencyUpdateState { isAvailable ? .available : .notAvailable }
}

/// Why an availability check or a presentation failed. A failure never
/// counts as an available update.
public struct EmergencyUpdateError: Error, Sendable, Equatable, CustomStringConvertible, CustomNSError {
    public enum Code: String, Sendable, Equatable, CaseIterable {
        /// No update provider: pass `updateProvider` to `EmergencyConfiguration`.
        case notConfigured = "not_configured"
        /// The app has no bundle identifier to look up.
        case noBundleId = "no_bundle_id"
        /// A version does not parse (§6.3), or there is nothing to compare with.
        case invalidVersion = "invalid_version"
        /// The store did not answer in time.
        case timeout
        /// The request failed before an HTTP response.
        case networkError = "network_error"
        /// The store answered with a status other than 200.
        case httpError = "http_error"
        /// The store's answer could not be read.
        case invalidResponse = "invalid_response"
        /// The app is not listed in that storefront.
        case notListed = "not_listed"
        /// The store page could not be shown.
        case presentationFailed = "presentation_failed"
        /// A custom provider failed for its own reason.
        case providerFailed = "provider_failed"
    }

    public var code: Code
    public var message: String
    public var httpStatus: Int?

    public init(_ code: Code, _ message: String, httpStatus: Int? = nil) {
        self.code = code
        self.message = message
        self.httpStatus = httpStatus
    }

    public var description: String { "\(code.rawValue): \(message)" }

    public static var errorDomain: String { "BugCapsuleEmergencyUpdateError" }
    /// 1-based position of `code` in `Code.allCases`.
    public var errorCode: Int { (Code.allCases.firstIndex(of: code) ?? 0) + 1 }
    public var errorUserInfo: [String: Any] {
        var info: [String: Any] = [NSLocalizedDescriptionKey: message, "code": code.rawValue]
        if let httpStatus { info["httpStatus"] = httpStatus }
        return info
    }
}

/// What a provider needs to show the update path. Main actor only.
@MainActor
public struct EmergencyUpdatePresentation {
    #if canImport(UIKit)
        /// The store page is presented over this view controller. Nil: the
        /// provider opens the store URL instead.
        public weak var viewController: UIViewController?

        public init(viewController: UIViewController? = nil) {
            self.viewController = viewController
        }
    #else
        public init() {}
    #endif
}

/// An update adapter: checks whether the store offers a version that
/// satisfies a required version, and shows the way there. It never installs
/// anything and never restarts the app; the app decides when to ask.
///
/// `AppStoreUpdateProvider` is the App Store adapter. Apps distributed some
/// other way implement this protocol with `flow: .custom`.
public protocol EmergencyUpdateProvider: Sendable {
    /// The `update.provider` of runtime reports: `^[a-z][a-z0-9_]{0,31}$`.
    var providerId: String { get }
    var flow: EmergencyUpdateFlow { get }

    /// Whether the store's version is at least [requiredVersion] and newer
    /// than [installedVersion]. Either may be nil, not both.
    func checkAvailability(requiredVersion: String?, installedVersion: String?) async throws(EmergencyUpdateError)
        -> EmergencyUpdateAvailability

    /// Shows the update path for an available update and returns what
    /// happened: `openedStore`, `inProgress`, `declined` or `failed`.
    @MainActor
    func presentUpdate(_ availability: EmergencyUpdateAvailability, presentation: EmergencyUpdatePresentation) async
        -> EmergencyUpdateState
}

/// The `update` object of runtime reports (§7.6): the last thing the update
/// adapter learned in this process.
public struct EmergencyUpdateStatus: Sendable, Equatable {
    public var provider: String
    public var flow: EmergencyUpdateFlow
    public var state: EmergencyUpdateState
    public var availableVersion: String?
    public var requiredVersion: String?

    public init(
        provider: String, flow: EmergencyUpdateFlow, state: EmergencyUpdateState, availableVersion: String? = nil,
        requiredVersion: String? = nil
    ) {
        self.provider = provider
        self.flow = flow
        self.state = state
        self.availableVersion = availableVersion
        self.requiredVersion = requiredVersion
    }
}

// MARK: - Coordinator

/// Runs the configured provider for one emergency client and keeps the last
/// availability and status; each status change goes to [onChange] (the
/// runtime report).
final class EmergencyUpdateCoordinator: @unchecked Sendable {
    let provider: any EmergencyUpdateProvider
    private let installedVersion: String?
    private let onChange: @Sendable (EmergencyUpdateStatus) -> Void
    private let lock = NSLock()
    private var _availability: EmergencyUpdateAvailability?
    private var _status: EmergencyUpdateStatus?

    init(
        provider: any EmergencyUpdateProvider, installedVersion: String?,
        onChange: @escaping @Sendable (EmergencyUpdateStatus) -> Void
    ) {
        self.provider = provider
        self.installedVersion = installedVersion
        self.onChange = onChange
        if !EmergencyRuntimeReport.isProvider(provider.providerId) {
            BugCapsuleLog.warn(
                "emergency: update provider id \"\(provider.providerId)\" does not match ^[a-z][a-z0-9_]{0,31}$; its state is not reported")
        }
    }

    var availability: EmergencyUpdateAvailability? { lock.locked { _availability } }
    var status: EmergencyUpdateStatus? { lock.locked { _status } }

    func checkAvailability(requiredVersion: String?) async throws(EmergencyUpdateError) -> EmergencyUpdateAvailability {
        do {
            let a = try await provider.checkAvailability(requiredVersion: requiredVersion, installedVersion: installedVersion)
            lock.locked { _availability = a }
            record(a.state, availableVersion: a.availableVersion, requiredVersion: requiredVersion)
            return a
        } catch {
            BugCapsuleLog.warn("emergency: update check failed (\(error))")
            record(.failed, availableVersion: nil, requiredVersion: requiredVersion)
            throw error
        }
    }

    /// Shows the update path. Checks first when there is no earlier result
    /// for [requiredVersion]; presents nothing when no update is available.
    @MainActor
    func presentUpdate(requiredVersion: String?, presentation: EmergencyUpdatePresentation) async -> EmergencyUpdateState {
        var a = availability
        if a == nil || a?.requiredVersion != requiredVersion {
            do {
                a = try await checkAvailability(requiredVersion: requiredVersion)
            } catch {
                return .failed
            }
        }
        guard let a, a.isAvailable else { return .notAvailable }
        let state = await provider.presentUpdate(a, presentation: presentation)
        record(state, availableVersion: a.availableVersion, requiredVersion: a.requiredVersion)
        return state
    }

    /// The user said no to the update the app offered.
    func markDeclined() {
        let a = availability
        record(.declined, availableVersion: a?.availableVersion, requiredVersion: a?.requiredVersion)
    }

    private func record(_ state: EmergencyUpdateState, availableVersion: String?, requiredVersion: String?) {
        let s = EmergencyUpdateStatus(
            provider: provider.providerId, flow: provider.flow, state: state, availableVersion: availableVersion,
            requiredVersion: requiredVersion)
        lock.locked { _status = s }
        onChange(s)
    }
}

// MARK: - Public entry point

/// Update adapter of the emergency client: `BugCapsule.emergency.updates`.
///
/// ```swift
/// let d = BugCapsule.emergency.evaluate(featureKey: "checkout.confirm_order")
/// if d.action == .requireUpdate {
///     let a = try await BugCapsule.emergency.updates.checkAvailability(for: d)
///     if a.isAvailable { _ = await BugCapsule.emergency.updates.presentUpdate(from: viewController) }
/// }
/// ```
///
/// Only the guarded feature waits on the update; the rest of the app keeps
/// working, and the app chooses the UI.
@objc(BCEmergencyUpdates)
public final class EmergencyUpdates: NSObject, @unchecked Sendable {
    /// Set once, right after the owner is created.
    weak var emergency: BugCapsuleEmergency?

    override init() {}

    private func coordinator() -> EmergencyUpdateCoordinator? { emergency?.updateCoordinator }

    private static let notConfigured = EmergencyUpdateError(
        .notConfigured, "no update provider: pass updateProvider to EmergencyConfiguration and call initialize")

    /// An update provider is configured and the client is initialized.
    @objc public var isConfigured: Bool { coordinator() != nil }

    /// The last reported update state; nil before the first check.
    public var status: EmergencyUpdateStatus? { coordinator()?.status }

    /// The result of the last successful check.
    public var lastAvailability: EmergencyUpdateAvailability? { coordinator()?.availability }

    /// Asks the provider whether the store offers [requiredVersion] or later
    /// (nil: anything newer than the installed version). The result is
    /// reported (§7.6).
    public func checkAvailability(requiredVersion: String? = nil) async throws(EmergencyUpdateError)
        -> EmergencyUpdateAvailability
    {
        guard let c = coordinator() else { throw Self.notConfigured }
        return try await c.checkAvailability(requiredVersion: requiredVersion)
    }

    /// `checkAvailability(requiredVersion:)` with the decision's
    /// `requiredVersion` (a `REQUIRE_UPDATE` decision).
    public func checkAvailability(for decision: EmergencyDecision) async throws(EmergencyUpdateError)
        -> EmergencyUpdateAvailability
    {
        try await checkAvailability(requiredVersion: decision.requiredVersion)
    }

    /// Shows the update path (the App Store page) when an update is
    /// available, checking first if needed. Returns `openedStore`,
    /// `notAvailable`, `failed`, or what a custom provider reports.
    @MainActor
    public func presentUpdate(requiredVersion: String? = nil, presentation: EmergencyUpdatePresentation) async
        -> EmergencyUpdateState
    {
        guard let c = coordinator() else {
            BugCapsuleLog.warn("emergency: presentUpdate called without an update provider")
            return .failed
        }
        return await c.presentUpdate(
            requiredVersion: requiredVersion ?? c.availability?.requiredVersion, presentation: presentation)
    }

    #if canImport(UIKit)
        /// Shows the App Store page over [viewController] (nil: opens the
        /// store URL). See `presentUpdate(requiredVersion:presentation:)`.
        @MainActor
        public func presentUpdate(requiredVersion: String? = nil, from viewController: UIViewController?) async
            -> EmergencyUpdateState
        {
            await presentUpdate(
                requiredVersion: requiredVersion, presentation: EmergencyUpdatePresentation(viewController: viewController))
        }
    #endif

    /// Reports that the user declined the update the app offered.
    @objc public func markDeclined() {
        coordinator()?.markDeclined()
    }

    // MARK: Objective-C

    /// Objective-C: the last reported state (`available`, `opened_store`, …); nil before the first check.
    @objc public var stateName: String? { status?.state.rawValue }

    /// Objective-C: `checkAvailability(requiredVersion:)`; the completion runs on the main thread.
    @objc(checkAvailabilityWithRequiredVersion:completion:)
    public func checkAvailability(
        requiredVersion: String?, completion: @escaping @Sendable (EmergencyUpdateAvailabilityObject?, NSError?) -> Void
    ) {
        Task {
            do {
                let a = try await checkAvailability(requiredVersion: requiredVersion)
                DispatchQueue.main.async { completion(EmergencyUpdateAvailabilityObject(a), nil) }
            } catch {
                let e = error as NSError
                DispatchQueue.main.async { completion(nil, e) }
            }
        }
    }

    #if canImport(UIKit)
        /// Objective-C: `presentUpdate(requiredVersion:from:)`; the completion
        /// gets the state name on the main thread.
        @objc(presentUpdateWithRequiredVersion:fromViewController:completion:)
        @MainActor
        public func presentUpdate(
            requiredVersion: String?, from viewController: UIViewController?,
            completion: (@MainActor @Sendable (String) -> Void)?
        ) {
            Task { @MainActor in
                let state = await presentUpdate(requiredVersion: requiredVersion, from: viewController)
                completion?(state.rawValue)
            }
        }
    #endif
}

/// Objective-C counterpart of `EmergencyUpdateAvailability`.
@objc(BCEmergencyUpdateAvailability)
public final class EmergencyUpdateAvailabilityObject: NSObject, @unchecked Sendable {
    public let availability: EmergencyUpdateAvailability

    init(_ availability: EmergencyUpdateAvailability) {
        self.availability = availability
    }

    @objc public var isAvailable: Bool { availability.isAvailable }
    @objc public var availableVersion: String? { availability.availableVersion }
    @objc public var requiredVersion: String? { availability.requiredVersion }
    @objc public var storeIdentifier: String? { availability.storeIdentifier }
    @objc public var storeURL: URL? { availability.storeURL }
    /// `available` or `not_available`.
    @objc public var stateName: String { availability.state.rawValue }
}
