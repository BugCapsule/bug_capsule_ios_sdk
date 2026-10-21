import Foundation

/// Simulated shop backend running inside the app, registered as a
/// `URLProtocol` *below* BugCapsule's own protocol.
///
/// From the app's point of view it behaves like a real backend: latency
/// varies and data differs between calls. That nondeterminism is what makes
/// the planted bugs hard to reproduce, and what BugCapsule records. During
/// replay the SDK serves the recorded responses and this server is never
/// reached (strict network).
final class FakeShopServer: URLProtocol, @unchecked Sendable {
    static let host = "shop.bugcapsule.com"

    nonisolated(unsafe) static let catalog: [[String: Any]] = [
        ["sku": "mug", "name": "Swift mug", "price": 12.5],
        ["sku": "tee", "name": "BugCapsule tee", "price": 24.0],
        ["sku": "cap", "name": "Capsule cap", "price": 18.0],
        ["sku": "sticker", "name": "Sticker pack", "price": 4.0],
        ["sku": "hoodie", "name": "UIKit hoodie", "price": 55.0],
        ["sku": "backpack", "name": "Simulator backpack", "price": 79.0],
        ["sku": "jacket", "name": "Release jacket", "price": 120.0],
    ]

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private let state = CancelState()

    final class CancelState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    override func startLoading() {
        let path = request.url?.path ?? "/"
        let (minMs, maxMs, status, body) = Self.respond(path)
        let data = try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let delay = Double(Int.random(in: minMs..<maxMs)) / 1000
        let client = self.client
        let url = request.url!
        let state = self.state
        let me = self
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            if state.isCancelled { return }
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json", "Content-Length": "\(data.count)"])!
            client?.urlProtocol(me, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(me, didLoad: data)
            client?.urlProtocolDidFinishLoading(me)
        }
    }

    override func stopLoading() { state.cancel() }

    static func respond(_ path: String) -> (Int, Int, Int, Any) {
        switch path {
        case "/api/cart":
            let items = catalog.shuffled().prefix(Int.random(in: 1...3)).map { p -> [String: Any] in
                var item = p
                item["qty"] = Int.random(in: 1...2)
                return item
            }
            return (80, 400, 200, ["cartId": "c_\(Int.random(in: 1000...99999))", "items": items])
        case "/api/checkout":
            return (150, 500, 200, ["orderId": "o_\(Int.random(in: 1000...99999))", "status": "paid"])
        case "/api/profile":
            return (100, 600, 200, ["name": "Sam", "tier": ["gold", "silver"].randomElement()!])
        case "/api/recommendations":
            let picks = catalog.shuffled().prefix(3).map { $0["name"]! }
            return (200, 800, 200, ["items": picks])
        default:
            return (10, 20, 404, ["error": "not found"])
        }
    }
}
