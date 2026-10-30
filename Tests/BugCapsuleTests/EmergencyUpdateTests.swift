import Foundation
import XCTest

@testable import BugCapsule

/// An update provider with a fixed store version (`custom` flow).
final class FakeUpdateProvider: EmergencyUpdateProvider, @unchecked Sendable {
    let providerId: String
    let flow = EmergencyUpdateFlow.custom
    let storeVersion: String
    let result: EmergencyUpdateState
    let checked = Counter()
    let presented = Counter()

    init(providerId: String = "fake_store", storeVersion: String = "2.5.0", result: EmergencyUpdateState = .inProgress) {
        self.providerId = providerId
        self.storeVersion = storeVersion
        self.result = result
    }

    func checkAvailability(requiredVersion: String?, installedVersion: String?) async throws(EmergencyUpdateError)
        -> EmergencyUpdateAvailability
    {
        checked.increment()
        return try AppStoreUpdateProvider.availability(
            listing: .init(version: storeVersion, trackId: 1, trackViewURL: nil), requiredVersion: requiredVersion,
            installedVersion: installedVersion)
    }

    @MainActor
    func presentUpdate(_ availability: EmergencyUpdateAvailability, presentation: EmergencyUpdatePresentation) async
        -> EmergencyUpdateState
    {
        presented.increment()
        return result
    }
}

final class EmergencyUpdateTests: XCTestCase {
    let app = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
    var dir: URL!
    var clock: TestClock!
    var signer: EmergencySigner!
    var backend: EmergencyTestBackend!

    override func setUp() async throws {
        dir = tempDirectory()
        clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        signer = EmergencySigner()
        backend = try EmergencyTestBackend(app: app)
    }

    override func tearDown() async throws {
        backend.stop()
        await BugCapsuleEmergency.shared.resetForTesting()
    }

    func waitUntil(_ timeout: TimeInterval = 5, _ cond: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func configuration(
        provider: (any EmergencyUpdateProvider)? = FakeUpdateProvider(), interval: TimeInterval = 0.5,
        replaying: Bool = false
    ) -> EmergencyConfiguration {
        var c = EmergencyConfiguration(
            trustAnchor: signer.anchor(app: app), backend: backend.backend, appVersion: "2.4.1", updateProvider: provider)
        let clock = self.clock!
        c.testHooks = EmergencyTestHooks(
            storageDirectory: dir, now: { clock.now }, random: { 0.5 }, autoSchedule: false, isReplaying: { replaying },
            observeLifecycle: false, runtimeReportInterval: interval)
        return c
    }

    func envelope(revision: Int) -> JSONValue {
        let doc = emergencyDocument(
            app: app, revision: revision, issuedAt: clock.now, expiresAt: clock.now.addingTimeInterval(3600),
            policies: [emergencyPolicy(id: "p-\(revision)", key: "checkout.confirm_order")])
        return signer.envelope(doc)
    }

    var runtimeReports: [JSONValue] { backend.receipts.filter { $0["status"] == "RUNTIME" } }

    func status(_ state: EmergencyUpdateState, available: String? = "2.5.0") -> EmergencyUpdateStatus {
        EmergencyUpdateStatus(
            provider: "app_store", flow: .storePage, state: state, availableVersion: available, requiredVersion: "2.5.0")
    }

    // MARK: runtime reports (§7.6)

    func testRuntimeReportCarriesTheHighestRevisionAndTheUpdateObject() async throws {
        let r = EmergencyRuntime(configuration: configuration()) { _ in }
        // Before any document: revision 0.
        r.setUpdateStatus(status(.available))
        await waitUntil { self.runtimeReports.count == 1 }
        let first = try XCTUnwrap(runtimeReports.first)
        XCTAssertEqual(first["revision"], 0)
        XCTAssertTrue(first["errorCode"]?.isNull ?? false)
        XCTAssertEqual(first["platform"], "NATIVE_IOS")
        XCTAssertEqual(first["installationId"]?.stringValue, r.installationId)
        XCTAssertEqual(first["appVersion"], "2.4.1")
        let runtime = try XCTUnwrap(first["runtime"]?.objectValue)
        XCTAssertEqual(runtime.keys, ["update"], "never a hotfix object on iOS")
        let update = try XCTUnwrap(runtime["update"]?.objectValue)
        XCTAssertEqual(Set(update.keys), ["provider", "flow", "state", "availableVersion", "requiredVersion"])
        XCTAssertEqual(update["provider"], "app_store")
        XCTAssertEqual(update["flow"], "store_page")
        XCTAssertEqual(update["state"], "available")
        XCTAssertEqual(update["availableVersion"], "2.5.0")
        XCTAssertEqual(update["requiredVersion"], "2.5.0")
        let req = try XCTUnwrap(backend.server.requests.first { $0.path.contains("/receipts") })
        XCTAssertEqual(req.path, "/v1/apps/\(app)/emergency/receipts")

        // After revision 9 is accepted, the next report names it; APPLIED carries the latest runtime.
        backend.serve(envelope(revision: 9))
        await r.refresh(.manual)
        await waitUntil { self.backend.receipts.contains { $0["status"] == "APPLIED" } }
        let applied = try XCTUnwrap(backend.receipts.first { $0["status"] == "APPLIED" })
        XCTAssertEqual(applied["runtime"]?["update"]?["state"], "available")
        r.setUpdateStatus(status(.openedStore))
        await waitUntil { self.runtimeReports.count == 2 }
        XCTAssertEqual(runtimeReports.last?["revision"], 9)
        XCTAssertEqual(runtimeReports.last?["runtime"]?["update"]?["state"], "opened_store")
        r.dispose()
    }

    func testReportsCoalesceWithinTheIntervalAndNeverRepeatTheLastObject() async throws {
        let r = EmergencyRuntime(configuration: configuration(interval: 0.5)) { _ in }
        func states() -> [JSONValue?] { runtimeReports.map { $0["runtime"]?["update"]?["state"] } }
        r.setUpdateStatus(status(.available))  // sent at once
        await waitUntil { self.runtimeReports.count == 1 }
        r.setUpdateStatus(status(.failed))  // within the interval: waits
        r.setUpdateStatus(status(.openedStore))  // replaces it
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(runtimeReports.count, 1, "nothing before the interval ends")
        await waitUntil { self.runtimeReports.count == 2 }
        // Changes within the next interval that end on the last report's object send nothing.
        r.setUpdateStatus(status(.declined))
        r.setUpdateStatus(status(.openedStore))
        try? await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(states(), ["available", "opened_store"], "only the latest object of an interval")
        // Setting the reported object again is no change.
        r.setUpdateStatus(status(.openedStore))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(runtimeReports.count, 2)
        // An object reported earlier, but not last, is sent again (after the interval, at once).
        r.setUpdateStatus(status(.available))
        await waitUntil(1) { self.runtimeReports.count == 3 }
        XCTAssertEqual(states(), ["available", "opened_store", "available"])
        // Several RUNTIME receipts for one revision (exempt from the receipt dedupe).
        XCTAssertEqual(runtimeReports.map { $0["revision"] }, [0, 0, 0])
        r.dispose()
    }

    func testNothingIsReportedInReplay() async throws {
        let r = EmergencyRuntime(configuration: configuration(replaying: true)) { _ in }
        r.setUpdateStatus(status(.available))
        r.setUpdateStatus(status(.openedStore))
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(backend.server.requests.count, 0)
        XCTAssertNotNil(r.latestRuntimeObject)
        r.dispose()
    }

    func testInvalidProviderIdIsNeverSent() async throws {
        let r = EmergencyRuntime(configuration: configuration(provider: FakeUpdateProvider(providerId: "Bad-Id"))) { _ in }
        _ = try await r.updates?.checkAvailability(requiredVersion: "2.5.0")
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(runtimeReports.count, 0)
        XCTAssertEqual(r.updates?.status?.state, .available)
        r.dispose()
    }

    func testNoProviderNoReports() async throws {
        let r = EmergencyRuntime(configuration: configuration(provider: nil)) { _ in }
        XCTAssertNil(r.updates)
        backend.serve(envelope(revision: 2))
        await r.refresh(.manual)
        await waitUntil { self.backend.receipts.count == 1 }
        XCTAssertNil(backend.receipts.first?["runtime"], "no runtime key without an adapter")
        r.dispose()
    }

    func testRuntimeObjectValidation() {
        let valid = EmergencyRuntimeReport.object(update: status(.openedStore))
        XCTAssertNil(EmergencyRuntimeReport.validate(valid))
        XCTAssertNil(EmergencyRuntimeReport.validate([:]))
        let long = String(repeating: "9", count: 65)
        let truncated = EmergencyRuntimeReport.object(
            update: EmergencyUpdateStatus(provider: "app_store", flow: .storePage, state: .available, availableVersion: long))
        XCTAssertEqual(truncated["update"]?["availableVersion"], .null, "a version over 64 characters is sent as null")
        XCTAssertNil(EmergencyRuntimeReport.validate(truncated))

        var hotfix = valid
        hotfix["hotfix"] = ["provider": "shorebird", "available": false]
        XCTAssertNotNil(EmergencyRuntimeReport.validate(hotfix))
        func with(_ key: String, _ value: JSONValue?) -> JSONObject {
            var u = valid["update"]!.objectValue!
            u[key] = value
            return ["update": .object(u)]
        }
        XCTAssertNotNil(EmergencyRuntimeReport.validate(with("extra", 1)))
        XCTAssertNotNil(EmergencyRuntimeReport.validate(with("provider", "App Store")))
        XCTAssertNotNil(EmergencyRuntimeReport.validate(with("provider", .string(String(repeating: "a", count: 33)))))
        XCTAssertNil(EmergencyRuntimeReport.validate(with("provider", .string(String(repeating: "a", count: 32)))))
        XCTAssertNotNil(EmergencyRuntimeReport.validate(with("flow", "sideload")))
        XCTAssertNotNil(EmergencyRuntimeReport.validate(with("state", "installed")))
        XCTAssertNil(EmergencyRuntimeReport.validate(with("state", "downloaded")))
        XCTAssertNotNil(EmergencyRuntimeReport.validate(with("requiredVersion", .string(long))))
        XCTAssertNotNil(EmergencyRuntimeReport.validate(with("requiredVersion", 3)))
        XCTAssertNil(EmergencyRuntimeReport.validate(with("requiredVersion", .null)))
        XCTAssertNotNil(EmergencyRuntimeReport.validate(["update": "x"]))
        // The Swift enums are the contract's values.
        XCTAssertEqual(
            Set(EmergencyUpdateState.allCases.map(\.rawValue)),
            EmergencyRuntimeReport.updateStates.subtracting(["downloaded"]))
        XCTAssertTrue(EmergencyRuntimeReport.flows.isSuperset(of: EmergencyUpdateFlow.allCases.map(\.rawValue)))
    }

    // MARK: version comparison (§6.3, §7.7)

    func availability(store: String, required: String?, installed: String? = "2.4.1") throws -> Bool {
        try AppStoreUpdateProvider.availability(
            listing: .init(version: store, trackId: 42, trackViewURL: nil), requiredVersion: required,
            installedVersion: installed
        ).isAvailable
    }

    func testAvailabilityUsesTheContractVersionOrder() throws {
        XCTAssertTrue(try availability(store: "2.5.0", required: "2.5.0"))
        XCTAssertTrue(try availability(store: "2.5.1", required: "2.5"))
        XCTAssertTrue(try availability(store: "2.10", required: "2.9.9"), "numeric, not lexical")
        XCTAssertTrue(try availability(store: "2.5.0", required: "v2.5.0+77"), "build metadata is ignored")
        XCTAssertFalse(try availability(store: "2.4.9", required: "2.5.0"))
        XCTAssertFalse(try availability(store: "2.5.0-beta.2", required: "2.5.0"), "a pre-release sorts first")
        XCTAssertTrue(try availability(store: "2.5.0", required: "2.5.0-rc.1"))
        // The store must also be newer than what is installed.
        XCTAssertFalse(try availability(store: "2.5.0", required: "2.4.0", installed: "2.5.0"))
        XCTAssertTrue(try availability(store: "2.5.0", required: nil, installed: "2.4.1"))
        XCTAssertFalse(try availability(store: "2.4.1", required: nil, installed: "2.4.1"))
        // An installed version that does not parse is not compared.
        XCTAssertTrue(try availability(store: "2.5.0", required: "2.5.0", installed: "nightly"))

        let a = try AppStoreUpdateProvider.availability(
            listing: .init(version: "2.5.0", trackId: 42, trackViewURL: nil), requiredVersion: "2.5.0", installedVersion: nil)
        XCTAssertEqual(a.state, .available)
        XCTAssertEqual(a.availableVersion, "2.5.0")
        XCTAssertEqual(a.requiredVersion, "2.5.0")
        XCTAssertEqual(a.storeIdentifier, "42")
        XCTAssertEqual(a.storeURL?.absoluteString, "itms-apps://apps.apple.com/app/id42")

        func code(_ store: String, _ required: String?, _ installed: String?) -> EmergencyUpdateError.Code? {
            do {
                _ = try AppStoreUpdateProvider.availability(
                    listing: .init(version: store, trackId: 1, trackViewURL: nil), requiredVersion: required,
                    installedVersion: installed)
                return nil
            } catch {
                return error.code
            }
        }
        XCTAssertEqual(code("2.5.0", "latest", nil), .invalidVersion)
        XCTAssertEqual(code("2.5 (build 7)", "2.5.0", nil), .invalidVersion)
        XCTAssertEqual(code("2.5.0", nil, nil), .invalidVersion, "nothing to compare with")
        XCTAssertEqual(code("2.5.0", nil, "nightly"), .invalidVersion)
    }

    // MARK: lookup parsing

    func parse(_ body: String) -> Result<AppStoreUpdateProvider.Listing, EmergencyUpdateError> {
        do {
            return .success(try AppStoreUpdateProvider.parseLookup(Data(body.utf8), bundleId: "com.example.app", country: "us"))
        } catch {
            return .failure(error)
        }
    }

    func testParsesTheLookupAnswer() throws {
        let ok = parse(
            #"{"resultCount":1,"results":[{"version":"2.5.0","trackId":1234567890,"trackViewUrl":"https://apps.apple.com/us/app/example/id1234567890?uo=4","bundleId":"com.example.app"}]}"#
        )
        let listing = try ok.get()
        XCTAssertEqual(listing.version, "2.5.0")
        XCTAssertEqual(listing.trackId, 1_234_567_890)
        XCTAssertEqual(listing.trackViewURL?.absoluteString, "https://apps.apple.com/us/app/example/id1234567890?uo=4")
        // Only an https page is kept.
        XCTAssertNil(try parse(#"{"results":[{"version":"1.0","trackId":5,"trackViewUrl":"javascript:x"}]}"#).get().trackViewURL)

        func code(_ body: String) -> EmergencyUpdateError.Code? {
            if case .failure(let e) = parse(body) { return e.code }
            return nil
        }
        XCTAssertEqual(code(#"{"resultCount":0,"results":[]}"#), .notListed)
        XCTAssertEqual(code("<html>"), .invalidResponse)
        XCTAssertEqual(code(#"{"resultCount":0}"#), .invalidResponse)
        XCTAssertEqual(code(#"{"results":[{"trackId":5}]}"#), .invalidResponse)
        XCTAssertEqual(code(#"{"results":[{"version":"","trackId":5}]}"#), .invalidResponse)
        XCTAssertEqual(code(#"{"results":[{"version":"1.0"}]}"#), .invalidResponse)
        XCTAssertEqual(code(#"{"results":[{"version":"1.0","trackId":"5"}]}"#), .invalidResponse)
    }

    func testCountryCodes() {
        XCTAssertEqual(AppStoreUpdateProvider.alpha2("USA"), "us")
        XCTAssertEqual(AppStoreUpdateProvider.alpha2("GBR"), "gb")
        XCTAssertEqual(AppStoreUpdateProvider.alpha2("deu"), "de")
        XCTAssertEqual(AppStoreUpdateProvider.alpha2("XKS"), "xk")
        XCTAssertEqual(AppStoreUpdateProvider.alpha2("GB"), "gb")
        XCTAssertEqual(AppStoreUpdateProvider.alpha2(" fr "), "fr")
        XCTAssertNil(AppStoreUpdateProvider.alpha2("ZZZ"))
        XCTAssertNil(AppStoreUpdateProvider.alpha2("419"))
        XCTAssertNil(AppStoreUpdateProvider.alpha2("U1"))
        XCTAssertNil(AppStoreUpdateProvider.alpha2(""))
        XCTAssertEqual(AppStoreUpdateProvider.alpha3to2.count, 251)
        XCTAssertEqual(Set(AppStoreUpdateProvider.alpha3to2.values).count, 250)
    }

    // MARK: lookup over HTTP

    func lookupServer(_ respond: @escaping @Sendable (TestHTTPServer.Request) -> TestHTTPServer.Response) throws
        -> TestHTTPServer
    {
        try TestHTTPServer(handler: respond)
    }

    func provider(_ server: TestHTTPServer, country: String? = "gb", timeout: TimeInterval = 5) -> AppStoreUpdateProvider {
        AppStoreUpdateProvider(
            bundleId: "com.example.app", country: country, endpoint: URL(string: "\(server.baseURL)/lookup")!,
            timeout: timeout)
    }

    func check(_ p: AppStoreUpdateProvider, required: String? = "2.5.0") async -> Result<
        EmergencyUpdateAvailability, EmergencyUpdateError
    > {
        do {
            return .success(try await p.checkAvailability(requiredVersion: required, installedVersion: "2.4.1"))
        } catch {
            return .failure(error)
        }
    }

    func testLookupRequestAndAnswer() async throws {
        let body = #"{"resultCount":1,"results":[{"version":"2.5.0","trackId":99,"trackViewUrl":"https://apps.apple.com/gb/app/x/id99"}]}"#
        let server = try lookupServer { _ in .init(status: 200, headers: ["Content-Type": "text/javascript"], body: Data(body.utf8)) }
        defer { server.stop() }
        let a = try await check(provider(server, country: "GBR")).get()
        XCTAssertTrue(a.isAvailable)
        XCTAssertEqual(a.storeIdentifier, "99")
        XCTAssertEqual(a.storeURL?.absoluteString, "https://apps.apple.com/gb/app/x/id99")
        let req = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/lookup?bundleId=com.example.app&country=gb")
        // Not yet at the required version: not available.
        let older = try await check(provider(server), required: "2.6").get()
        XCTAssertFalse(older.isAvailable)
        XCTAssertEqual(older.state, .notAvailable)
    }

    func testLookupFailuresAreTypedAndNeverAvailable() async throws {
        let mode = Locked("500")
        let server = try lookupServer { _ in
            switch mode.value {
            case "500": return .init(status: 500, body: Data("oops".utf8))
            case "empty": return .init(status: 200, body: Data(#"{"resultCount":0,"results":[]}"#.utf8))
            case "slow": return .init(status: 200, body: Data("{}".utf8), delay: 3)
            default: return .init(status: 200, body: Data("not json".utf8))
            }
        }
        defer { server.stop() }
        var r = await check(provider(server))
        XCTAssertEqual(r.failure?.code, .httpError)
        XCTAssertEqual(r.failure?.httpStatus, 500)
        mode.mutate { $0 = "empty" }
        r = await check(provider(server))
        XCTAssertEqual(r.failure?.code, .notListed)
        mode.mutate { $0 = "garbage" }
        r = await check(provider(server))
        XCTAssertEqual(r.failure?.code, .invalidResponse)
        mode.mutate { $0 = "slow" }
        let started = Date()
        r = await check(provider(server, timeout: 0.5))
        XCTAssertEqual(r.failure?.code, .timeout)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
        r = await check(provider(server), required: "soon")
        XCTAssertEqual(r.failure?.code, .invalidVersion)
        // Nothing listens: a network error.
        let closed = try lookupServer { _ in .init(status: 200) }
        closed.stop()
        try? await Task.sleep(nanoseconds: 100_000_000)
        r = await check(provider(closed))
        XCTAssertEqual(r.failure?.code, .networkError)
    }

    // MARK: public API

    func testUpdatesThroughTheEmergencyClientAreReported() async throws {
        let body = #"{"resultCount":1,"results":[{"version":"2.5.0","trackId":99}]}"#
        let store = try lookupServer { _ in .init(status: 200, body: Data(body.utf8)) }
        defer { store.stop() }
        let e = BugCapsuleEmergency()
        XCTAssertFalse(e.updates.isConfigured)
        e.initialize(configuration(provider: provider(store), interval: 0.3))
        XCTAssertTrue(e.updates.isConfigured)
        XCTAssertNil(e.updates.status)
        let decision = EmergencyDecision(
            featureKey: "checkout.confirm_order", allowed: false, action: .requireUpdate, requiredVersion: "2.5.0",
            source: .policy)
        let a = try await e.updates.checkAvailability(for: decision)
        XCTAssertTrue(a.isAvailable)
        XCTAssertEqual(e.updates.status?.state, .available)
        XCTAssertEqual(e.updates.lastAvailability, a)
        XCTAssertEqual(e.updates.stateName, "available")
        await waitUntil { self.runtimeReports.count == 1 }
        let update = try XCTUnwrap(runtimeReports.first?["runtime"]?["update"])
        XCTAssertEqual(update, ["provider": "app_store", "flow": "store_page", "state": "available", "availableVersion": "2.5.0", "requiredVersion": "2.5.0"])
        e.updates.markDeclined()
        XCTAssertEqual(e.updates.status?.state, .declined)
        await waitUntil { self.runtimeReports.count == 2 }
        XCTAssertEqual(runtimeReports.last?["runtime"]?["update"]?["state"], "declined")
        // A failed check is reported as failed and is not "available".
        store.stop()
        do {
            _ = try await e.updates.checkAvailability(requiredVersion: "2.6.0")
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error.code, .networkError)
        }
        XCTAssertEqual(e.updates.status?.state, .failed)
        XCTAssertEqual(e.updates.status?.requiredVersion, "2.6.0")
        await e.resetForTesting()
    }

    @MainActor
    func testPresentUpdateUsesTheProviderOnlyWhenAvailable() async throws {
        let fake = FakeUpdateProvider(storeVersion: "2.5.0", result: .inProgress)
        let e = BugCapsuleEmergency()
        e.initialize(configuration(provider: fake))
        // Checks first, then presents.
        let state = await e.updates.presentUpdate(requiredVersion: "2.5.0", presentation: EmergencyUpdatePresentation())
        XCTAssertEqual(state, .inProgress)
        XCTAssertEqual(fake.presented.value, 1)
        XCTAssertEqual(e.updates.status?.state, .inProgress)
        XCTAssertEqual(e.updates.status?.flow, .custom)
        // The store has nothing newer than 2.6: nothing is shown.
        let none = await e.updates.presentUpdate(requiredVersion: "2.6", presentation: EmergencyUpdatePresentation())
        XCTAssertEqual(none, .notAvailable)
        XCTAssertEqual(fake.presented.value, 1)
        XCTAssertEqual(e.updates.status?.state, .notAvailable)
        await e.resetForTesting()
        // Without a provider nothing is presented and checks fail as not configured.
        let bare = BugCapsuleEmergency()
        let failed = await bare.updates.presentUpdate(presentation: EmergencyUpdatePresentation())
        XCTAssertEqual(failed, .failed)
        do {
            _ = try await bare.updates.checkAvailability()
            XCTFail("expected not_configured")
        } catch {
            XCTAssertEqual(error.code, .notConfigured)
        }
    }

    func testObjectiveCSurface() async throws {
        let e = BugCapsuleEmergency()
        XCTAssertTrue(e.responds(to: NSSelectorFromString("updates")))
        let updates = e.updates
        XCTAssertTrue(updates.responds(to: NSSelectorFromString("checkAvailabilityWithRequiredVersion:completion:")))
        XCTAssertTrue(updates.responds(to: NSSelectorFromString("markDeclined")))
        XCTAssertTrue(updates.responds(to: NSSelectorFromString("stateName")))
        XCTAssertTrue(updates.responds(to: NSSelectorFromString("isConfigured")))
        XCTAssertNotNil(NSClassFromString("BCEmergencyUpdates"))
        XCTAssertNotNil(NSClassFromString("BCEmergencyUpdateAvailability"))
        let providerClass: AnyClass = try XCTUnwrap(NSClassFromString("BCAppStoreUpdateProvider"))
        XCTAssertTrue(providerClass.instancesRespond(to: NSSelectorFromString("initWithBundleId:country:")))
        XCTAssertTrue(
            EmergencyConfigurationObject(trustAnchor: "x").responds(to: NSSelectorFromString("setUpdateProvider:")))

        // Not configured: an NSError in the contract's domain.
        let failed = expectation(description: "not configured")
        updates.checkAvailability(requiredVersion: "2.5.0") { availability, error in
            XCTAssertNil(availability)
            XCTAssertEqual(error?.domain, "BugCapsuleEmergencyUpdateError")
            XCTAssertEqual(error?.userInfo["code"] as? String, "not_configured")
            XCTAssertTrue(Thread.isMainThread)
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 5)

        // Configured from Objective-C with the App Store provider.
        let body = #"{"resultCount":1,"results":[{"version":"2.5.0","trackId":7}]}"#
        let store = try lookupServer { _ in .init(status: 200, body: Data(body.utf8)) }
        defer { store.stop() }
        let config = EmergencyConfigurationObject(trustAnchor: signer.anchor(app: app))
        config.backendURL = backend.backend.url
        config.ingestKey = backend.backend.ingestKey
        config.appVersion = "2.4.1"
        let objcProvider = AppStoreUpdateProvider(bundleId: "com.example.app", country: "us")
        XCTAssertEqual(objcProvider.presentation, .productPage)
        XCTAssertTrue(objcProvider.fallbackToStoreURL)
        config.updateProvider = objcProvider
        XCTAssertTrue(config.swiftValue.updateProvider is AppStoreUpdateProvider)
        // The same configuration, pointed at the local lookup server.
        var swift = config.swiftValue
        swift.updateProvider = provider(store, country: "us")
        swift.testHooks = configuration().testHooks
        e.initialize(swift)
        let checked = expectation(description: "available")
        updates.checkAvailability(requiredVersion: "2.5.0") { availability, error in
            XCTAssertNil(error)
            XCTAssertEqual(availability?.isAvailable, true)
            XCTAssertEqual(availability?.availableVersion, "2.5.0")
            XCTAssertEqual(availability?.storeIdentifier, "7")
            XCTAssertEqual(availability?.stateName, "available")
            checked.fulfill()
        }
        await fulfillment(of: [checked], timeout: 5)
        XCTAssertEqual(updates.stateName, "available")
        updates.markDeclined()
        XCTAssertEqual(updates.stateName, "declined")
        await e.resetForTesting()
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let f) = self { return f }
        return nil
    }
}
