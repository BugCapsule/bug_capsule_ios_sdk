import BugCapsule
import Foundation

struct CartItem: Codable, Identifiable, Equatable {
    var sku: String
    var name: String
    var price: Double
    var qty: Int
    var id: String { sku }
}

struct CartResponse: Decodable {
    var cartId: String
    var items: [CartItem]
}

struct Profile: Decodable {
    var name: String
    var tier: String
}

struct Recommendations: Decodable {
    var items: [String]
}

struct CheckoutResponse: Decodable {
    var orderId: String
    var status: String
}

/// URLSession networking through an instrumented configuration: BugCapsule's
/// protocol first, the in-process fake server below it.
final class ShopAPI: Sendable {
    static let network = BugCapsuleURLSession(rules: [
        // Checkout bodies carry a timestamp and nonce that differ on every run.
        EndpointRule("POST", "/api/checkout", ignoreBodyFields: ["timestamp", "nonce"])
    ])
    static let shared = ShopAPI()

    let session: URLSession
    let base = URL(string: "https://\(FakeShopServer.host)")!

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeShopServer.self] + (config.protocolClasses ?? [])
        BugCapsule.instrument(config)  // inserts BugCapsuleURLProtocol above FakeShopServer
        session = URLSession(configuration: config)
    }

    func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer demo-session-token-123456", forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Completion-handler style (used by the UIKit home screen).
    func get<T: Decodable & Sendable>(_ path: String, as: T.Type, completion: @escaping @Sendable (Result<T, Error>) -> Void) {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        session.dataTask(with: req) { data, _, error in
            if let error { return completion(.failure(error)) }
            do { completion(.success(try JSONDecoder().decode(T.self, from: data ?? Data()))) } catch { completion(.failure(error)) }
        }.resume()
    }

    func post<T: Decodable>(_ path: String, json: [String: Any], as: T.Type) async throws -> T {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
