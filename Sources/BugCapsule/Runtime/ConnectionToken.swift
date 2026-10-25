import Foundation

/// Why an SDK connection token could not be used. `code` is the contract's
/// error code (`invalid_token`, `unsupported_token_version`); `message` says
/// what to do about it.
public struct BugCapsuleTokenError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Code: String, Sendable, Equatable {
        case invalidToken = "invalid_token"
        case unsupportedTokenVersion = "unsupported_token_version"
    }

    public let code: Code
    public let message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(code.rawValue): \(message)" }
}

/// SDK connection token v1: `bcsdk.v1.<base64url JSON {"api", "key"}>`.
///
/// One string from the BugCapsule dashboard carries the API URL and the
/// ingest-only credential. It is client-visible and grants uploads only;
/// the project is derived from the credential, never from the token. A
/// parsed token is exactly a `BugCapsuleBackendConfig` (`url` = `api`,
/// `ingestKey` = `key`). Test vectors:
/// `spec-fixtures/connection-token-v1/vectors.json`.
public enum BugCapsuleConnectionToken {
    /// The token contract version this SDK understands.
    public static let supportedVersion = 1

    /// Parses [token] offline. Never throws and never touches the network.
    public static func parse(_ token: String) -> Result<BugCapsuleBackendConfig, BugCapsuleTokenError> {
        func bad(_ message: String) -> Result<BugCapsuleBackendConfig, BugCapsuleTokenError> {
            .failure(BugCapsuleTokenError(.invalidToken, message))
        }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty {
            return bad("the token is empty; copy it from the BugCapsule dashboard (Project settings → Keys → SDK tokens)")
        }
        if token.hasPrefix("bci_") || token.hasPrefix("bct_") {
            return bad(
                "this is an ingest key, not a connection token: pass it as BugCapsuleBackendConfig(url:ingestKey:), "
                    + "or generate an SDK token in the dashboard")
        }
        if token.hasPrefix("bcs_") {
            return bad("this is a secret key: never ship it in an app. Rotate it and generate an SDK token in the dashboard")
        }
        let prefix = "bcsdk.v"
        guard token.hasPrefix(prefix) else {
            return bad("a connection token starts with \"bcsdk.v1.\"; copy the whole token from the dashboard")
        }
        let rest = token.dropFirst(prefix.count)
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        let afterDigits = rest.dropFirst(digits.count)
        guard !digits.isEmpty, afterDigits.first == "." else {
            return bad("a connection token starts with \"bcsdk.v1.\"; copy the whole token from the dashboard")
        }
        if Int(digits) != supportedVersion {
            return .failure(
                BugCapsuleTokenError(
                    .unsupportedTokenVersion,
                    "token version \(digits) needs a newer BugCapsule iOS SDK (this one understands v\(supportedVersion))"))
        }
        let damaged = "the token is damaged or incomplete; copy it again from the dashboard"
        guard let json = decodeBase64URL(String(afterDigits.dropFirst())) else { return bad(damaged) }
        guard let parsed = try? JSON.parse(json) else { return bad(damaged) }
        guard case .object(let payload) = parsed else { return bad("the token is damaged; copy it again from the dashboard") }
        guard let key = payload["key"]?.stringValue, isIngestCredential(key) else {
            return bad("the token has no valid ingest credential; generate a new token")
        }
        guard let url = apiURL(payload["api"]?.stringValue) else {
            return bad("the token has no valid API URL; generate a new token")
        }
        return .success(BugCapsuleBackendConfig(url: url, ingestKey: key))
    }

    /// RFC 4648 §5 without padding (padding is accepted), as UTF-8 text.
    static func decodeBase64URL(_ s: String) -> String? {
        var body = Substring(s)
        var padding = 0
        while body.hasSuffix("=") {
            body = body.dropLast()
            padding += 1
        }
        guard !body.isEmpty, padding <= 2, body.unicodeScalars.allSatisfy(isBase64URLScalar) else { return nil }
        var b64 = body.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if b64.count % 4 == 1 { return nil }
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64) else { return nil }
        // Strict: invalid UTF-8 is refused, not repaired.
        return String(data: data, encoding: .utf8)
    }

    private static func isBase64URLScalar(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x5F: return true  // A-Z a-z 0-9 - _
        default: return false
        }
    }

    /// `^(bct|bci)_[A-Za-z0-9_-]{16,200}$`
    static func isIngestCredential(_ key: String) -> Bool {
        guard key.hasPrefix("bct_") || key.hasPrefix("bci_") else { return false }
        let body = key.unicodeScalars.dropFirst(4)
        return (16...200).contains(body.count) && body.allSatisfy(isBase64URLScalar)
    }

    /// An absolute http(s) URL without user info, query or fragment;
    /// trailing slashes removed.
    static func apiURL(_ api: String?) -> String? {
        guard let api, !api.isEmpty, api.count <= 2000, let c = URLComponents(string: api),
            let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = c.host, !host.isEmpty,
            c.user == nil, c.password == nil, c.query == nil, c.fragment == nil
        else { return nil }
        var url = api
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }
}

extension BugCapsuleBackendConfig {
    /// The backend configuration a connection token stands for. Throws
    /// `BugCapsuleTokenError` for a token that cannot be used.
    public init(token: String) throws {
        self = try BugCapsuleConnectionToken.parse(token).get()
    }
}

/// How the backend was configured.
public enum BugCapsuleConnectionSource: String, Sendable, Equatable {
    /// `BugCapsuleConfig.token` (SDK connection token).
    case token
    /// An explicit `BugCapsuleConfig.backend` (URL + ingest key).
    case backend
}

/// The SDK's connection to the BugCapsule backend.
public enum BugCapsuleConnectionState: String, Sendable, Equatable {
    /// Not started, or started without a token or backend (local captures only).
    case notConfigured = "not_configured"
    /// The token could not be parsed; the app runs without a backend.
    case invalidToken = "invalid_token"
    /// The token is from a newer contract version than this SDK understands.
    case unsupportedTokenVersion = "unsupported_token_version"
    /// Waiting for the first configuration fetch.
    case connecting
    /// The configuration was fetched in this run.
    case connected
    /// The backend could not be reached (network error, timeout, 5xx/429):
    /// data waits in the outbox and is retried.
    case offline
    /// The backend refused the credential (revoked, expired, unknown).
    /// Capture and uploads are off for this run.
    case rejected
    /// Disabled locally (`enabled: false`) or by the backend's kill switch.
    case disabled
}

/// Connection and instrumentation, for setup checks and support
/// (`BugCapsule.status`).
public struct BugCapsuleStatus: Sendable, Equatable {
    public struct Connection: Sendable, Equatable {
        public var state: BugCapsuleConnectionState
        public var source: BugCapsuleConnectionSource?
        public var apiURL: String?
        /// The token error code or the backend's refusal reason
        /// (`token_revoked`, `token_expired`, ...), or why it is offline.
        public var reason: String?
        /// What to do about it.
        public var message: String?
        /// Confirmation 1: the configuration was fetched in this run (the
        /// URL, credential and network work).
        public var configFetchedAt: Date?
        /// Confirmation 2: the backend accepted data from this run.
        public var firstEventAcceptedAt: Date?
        public var firstCapsuleAcceptedAt: Date?
    }

    /// Connecting is not complete replay instrumentation. These are the
    /// progressive setup steps the SDK can detect.
    public struct Instrumentation: Sendable, Equatable {
        /// This session records a capsule window.
        public var recording: Bool
        /// `BugCapsuleURLSession` is set up and `BugCapsule.instrument(_:)` or
        /// `instrumentSharedSession()` installed the URL protocol.
        public var network: Bool
        /// `BugCapsuleNavigation` is set up and has seen a navigation
        /// controller or a route.
        public var navigation: Bool
        /// `BugCapsuleUserDefaults` is set up, or app state is registered
        /// with `BugCapsule.registerState`.
        public var appState: Bool
        public var frameworks: [String]
        /// Steps not done yet: `network`, `navigation`, `app_state`.
        public var missing: [String]
    }

    public var connection: Connection
    public var instrumentation: Instrumentation

    static let notStarted = BugCapsuleStatus(
        connection: Connection(state: .notConfigured),
        instrumentation: Instrumentation(
            recording: false, network: false, navigation: false, appState: false, frameworks: [],
            missing: ["network", "navigation", "app_state"]))
}

extension BugCapsuleStatus.Connection {
    init(state: BugCapsuleConnectionState) {
        self.init(
            state: state, source: nil, apiURL: nil, reason: nil, message: nil, configFetchedAt: nil, firstEventAcceptedAt: nil,
            firstCapsuleAcceptedAt: nil)
    }
}

/// Notes the first capsule and the first error event the backend accepted
/// (connection confirmation 2) without changing any result.
final class ObservedTransport: BugCapsuleTransport, @unchecked Sendable {
    let base: BugCapsuleTransport
    private let onCapsule: @Sendable () -> Void
    private let onEvent: @Sendable () -> Void

    init(_ base: BugCapsuleTransport, onCapsule: @escaping @Sendable () -> Void, onEvent: @escaping @Sendable () -> Void) {
        self.base = base
        self.onCapsule = onCapsule
        self.onEvent = onEvent
    }

    func fetchConfig() async -> ConfigFetchResult { await base.fetchConfig() }

    func upload(_ bytes: Data) async -> UploadResult {
        let r = await base.upload(bytes)
        if r.status == .uploaded { onCapsule() }
        return r
    }

    func sendEnvelope(_ body: Data, gzipped: Bool) async -> UploadResult {
        let r = await base.sendEnvelope(body, gzipped: gzipped)
        if r.status == .uploaded, Self.containsEvent(body, gzipped: gzipped) { onEvent() }
        return r
    }

    static func containsEvent(_ body: Data, gzipped: Bool) -> Bool {
        guard let raw = gzipped ? try? Gzip.decompress(body, maxBytes: 10 * 1024 * 1024) : body,
            let items = (try? JSON.parse(raw))?["items"]?.arrayValue
        else { return false }
        return items.contains { $0["type"]?.stringValue == "event" }
    }
}
