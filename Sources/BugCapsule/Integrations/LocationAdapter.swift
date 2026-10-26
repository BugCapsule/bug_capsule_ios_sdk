import Foundation

/// A location fix as the app sees it.
public struct BugCapsuleLocationFix: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    /// Horizontal accuracy in meters.
    public var accuracy: Double

    public init(latitude: Double, longitude: Double, accuracy: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
    }

    var wire: [String: Any?] { ["lat": latitude, "lon": longitude, "accuracy": accuracy] }

    init?(wire: Any?) {
        guard let d = wire as? [String: Any?], let lat = Self.number(d["lat"] ?? nil),
            let lon = Self.number(d["lon"] ?? nil), let accuracy = Self.number(d["accuracy"] ?? nil)
        else { return nil }
        self.init(latitude: lat, longitude: lon, accuracy: accuracy)
    }

    private static func number(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d
        case let i as Int: return Double(i)
        default: return nil
        }
    }
}

/// What the app's location code provides (wrap `CLLocationManager` in it):
/// the example adapter records and replays it without location permission
/// or hardware in replay.
public protocol BugCapsuleLocationProvider: AnyObject, Sendable {
    func currentLocation() async throws -> BugCapsuleLocationFix
    /// Starts updates; returns the function that stops them.
    func startUpdates(
        accuracy: String, _ handler: @escaping @Sendable (Result<BugCapsuleLocationFix, Error>) -> Void
    ) throws -> @Sendable () -> Void
    /// Not recorded by the adapter (it runs live and is reported as an
    /// `operation.unsupported` gap): an example of an explicit gap.
    func heading() async throws -> Double
}

extension BugCapsuleLocationProvider {
    public func heading() async throws -> Double { 0 }
}

/// Example native adapter (capsule-v2 §4.3) over `BugCapsuleLocationProvider`:
/// `location.current` (call) and `location.updates` (subscription) are
/// recorded and replayed; `location.heading` is deliberately unsupported.
///
/// ```swift
/// let location = BugCapsuleLocationAdapter(provider: MyCoreLocationProvider())
/// BugCapsule.start(config, integrations: [BugCapsuleNativeIntegration(location)])
/// let fix = try await location.currentLocation()
/// let updates = location.updates { fix in ... }
/// updates.cancel()
/// ```
public final class BugCapsuleLocationAdapter: BugCapsuleNativeAdapter, @unchecked Sendable {
    public static let adapterId = "bugcapsule-ios.example.location"

    public let descriptor = BugCapsuleAdapterDescriptor(
        dependencyId: "location", adapter: BugCapsuleLocationAdapter.adapterId, adapterVersion: sdkVersion, schema: 1,
        operations: ["location.current", "location.updates"],
        tested: [BugCapsuleTestedPackage("BugCapsuleLocationProvider", "1")])

    private let provider: BugCapsuleLocationProvider
    private let lock = NSLock()
    private var _bridge: BugCapsuleNativeBridge?

    public init(provider: BugCapsuleLocationProvider) { self.provider = provider }

    public func attach(_ bridge: BugCapsuleNativeBridge) { lock.locked { _bridge = bridge } }

    private var bridge: BugCapsuleNativeBridge { lock.locked { _bridge } ?? .detached(descriptor) }

    /// Answers come from a capsule (the provider is not called).
    public var isReplaying: Bool { bridge.isReplaying }

    public struct DecodingError: Error {}

    public func currentLocation() async throws -> BugCapsuleLocationFix {
        let provider = self.provider
        let wire = try await bridge.call("location.current") { try await provider.currentLocation().wire }
        guard let fix = BugCapsuleLocationFix(wire: wire) else { throw DecodingError() }
        return fix
    }

    public func updates(
        accuracy: String = "best", onFix: @escaping @Sendable (BugCapsuleLocationFix) -> Void,
        onError: @escaping @Sendable (Error) -> Void = { _ in }
    ) throws -> BugCapsuleNativeSubscription {
        let provider = self.provider
        return try bridge.subscribe(
            "location.updates", args: ["accuracy": accuracy],
            onEvent: { wire in
                if let fix = BugCapsuleLocationFix(wire: wire) { onFix(fix) } else { onError(DecodingError()) }
            }, onError: onError
        ) { sink in
            try provider.startUpdates(accuracy: accuracy) { result in
                switch result {
                case .success(let fix): sink.event(fix.wire)
                case .failure(let e): sink.error(e)
                }
            }
        }
    }

    /// Unsupported by this adapter: live while capturing (gap
    /// `operation.unsupported`), fails as unrecorded in replay.
    public func heading() async throws -> Double {
        let provider = self.provider
        let value = try await bridge.call("location.heading") { try await provider.heading() }
        return value as? Double ?? 0
    }
}
