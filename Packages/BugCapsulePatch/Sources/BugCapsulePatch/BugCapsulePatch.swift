#if os(iOS)
import BcpatchRuntime
import Foundation

/// The contract of a module, without its Swift types.
public struct PatchContract: Sendable {
    public let id: String
    public let inputSchema: String
    public let outputSchema: String

    public init(id: String, inputSchema: String, outputSchema: String) {
        self.id = id
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
    }
}

/// What the installed binary can render for a surface; part of the base capability hash.
public struct PatchSurfaceContract: Sendable {
    public let id: String
    public let components: [String]
    public let actions: [String]
    /// Actions a layout must keep. A layout dropping one is refused.
    public let requiredActions: [String]
    public let assets: [String]

    public init(id: String, components: [String], actions: [String], requiredActions: [String] = [], assets: [String] = []) {
        self.id = id
        self.components = components
        self.actions = actions
        self.requiredActions = requiredActions
        self.assets = assets
    }
}

/// A module the app ships a fallback for, and that patches may replace. The
/// schemas are canonical type text (`int`, `dec(2)`, `rec(a:int,b:str)`); a
/// patch must implement exactly these to activate.
public struct PatchModule<Input, Output> {
    public let contract: PatchContract
    public let encode: (Input) -> Any
    public let decode: (Any) throws -> Output
    /// The bundled implementation. Runs whenever no patch applies or one fails.
    public let fallback: (Input) -> Output

    public init(
        id: String,
        inputSchema: String,
        outputSchema: String,
        encode: @escaping (Input) -> Any,
        decode: @escaping (Any) throws -> Output,
        fallback: @escaping (Input) -> Output
    ) {
        contract = PatchContract(id: id, inputSchema: inputSchema, outputSchema: outputSchema)
        self.encode = encode
        self.decode = decode
        self.fallback = fallback
    }
}

public enum PatchSource: String, Sendable {
    case patched, bundled
}

public struct PatchResult<Output> {
    public let value: Output
    public let source: PatchSource
    /// Why the bundled implementation ran: `not_patched` or an error code.
    public let reason: String?
}

/// Identity of the installed binary and where its patches come from.
public struct PatchConfig: Sendable {
    public var storeDir: String
    public var projectId: String
    public var applicationId: String
    public var environment: String
    public var distributionProfile: String
    /// Generated at build time; never the marketing version.
    public var baseBuildId: String
    /// Stable pseudonymous id for cohort assignment.
    public var installationId: String
    /// Pinned `bcpk.v1.…` keys.
    public var trustRoots: [String]
    public var platform: String

    public init(
        storeDir: String,
        projectId: String,
        applicationId: String,
        environment: String,
        distributionProfile: String,
        baseBuildId: String,
        installationId: String,
        trustRoots: [String],
        platform: String = "ios"
    ) {
        self.storeDir = storeDir
        self.projectId = projectId
        self.applicationId = applicationId
        self.environment = environment
        self.distributionProfile = distributionProfile
        self.baseBuildId = baseBuildId
        self.installationId = installationId
        self.trustRoots = trustRoots
        self.platform = platform
    }
}

/// Replay pinning: the archived files an attempt loads, read-only and offline.
/// A nil `bundlePath` is the bare base.
public struct PatchReplay: Sendable {
    public var bundlePath: String?
    public var keyringPath: String?
    public var keyringSignaturePath: String?

    public init(bundlePath: String? = nil, keyringPath: String? = nil, keyringSignaturePath: String? = nil) {
        self.bundlePath = bundlePath
        self.keyringPath = keyringPath
        self.keyringSignaturePath = keyringSignaturePath
    }
}

public struct PatchError: Error, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

private enum Op {
    static let status: UInt32 = 1
    static let stage: UInt32 = 2
    static let channel: UInt32 = 3
    static let keyring: UInt32 = 4
    static let healthy: UInt32 = 5
    static let fault: UInt32 = 6
    static let eval: UInt32 = 7
    static let asset: UInt32 = 8
    static let receipts: UInt32 = 9
    static let ack: UInt32 = 10
    static let surface: UInt32 = 13
}

/// The runtime as the app sees it. One generation is pinned at `open` for the
/// life of the process: staging never changes running behavior. This replaces
/// `PatchModule`s only; compiled Swift and Objective-C are never replaced.
public final class BugCapsulePatch: @unchecked Sendable {
    private var engine: OpaquePointer?

    /// Why this build runs fallbacks only; nil when the runtime is up.
    public private(set) var unavailableReason: String?

    /// Moves this handle onto `pinned`, so everything already holding it runs
    /// the replay pin and nothing keeps the live store.
    func adoptReplay(_ pinned: BugCapsulePatch) {
        if let engine { bcp_close(engine) }
        engine = pinned.engine
        unavailableReason = pinned.unavailableReason
        pinned.engine = nil
    }

    public var available: Bool { engine != nil }

    private init(engine: OpaquePointer?, unavailableReason: String?) {
        self.engine = engine
        self.unavailableReason = unavailableReason
    }

    deinit {
        if let engine { bcp_close(engine) }
    }

    /// Opens the store and selects this process's generation. Never throws:
    /// without a usable runtime every `call` uses the fallback.
    public static func open(config: PatchConfig, modules: [PatchContract], surfaces: [PatchSurfaceContract] = [], replay: PatchReplay? = nil) -> BugCapsulePatch {
        guard bcp_abi_version() == 1 else {
            return BugCapsulePatch(engine: nil, unavailableReason: "abi_mismatch")
        }
        var doc: [String: Any] = [
            "storeDir": config.storeDir,
            "projectId": config.projectId,
            "applicationId": config.applicationId,
            "environment": config.environment,
            "platform": config.platform,
            "distributionProfile": config.distributionProfile,
            "baseBuildId": config.baseBuildId,
            "installationId": config.installationId,
            "trustRoots": config.trustRoots,
            "modules": modules.map { ["id": $0.id, "input": $0.inputSchema, "output": $0.outputSchema] },
            "surfaces": surfaces.map {
                ["id": $0.id, "components": $0.components, "actions": $0.actions, "requiredActions": $0.requiredActions, "assets": $0.assets] as [String: Any]
            },
        ]
        if let replay {
            var r: [String: Any] = ["bundlePath": replay.bundlePath as Any? ?? NSNull()]
            if let k = replay.keyringPath, let s = replay.keyringSignaturePath {
                r["keyringPath"] = k
                r["keyringSignaturePath"] = s
            }
            doc["replay"] = r
        }
        guard let json = try? JSONSerialization.data(withJSONObject: doc) else {
            return BugCapsulePatch(engine: nil, unavailableReason: "bad_config")
        }
        var handle: OpaquePointer?
        var out = BcpBuf(ptr: nil, len: 0)
        let status = json.withUnsafeBytes { raw in
            bcp_open(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &handle, &out)
        }
        do {
            _ = try BugCapsulePatch.take(status, out)
            return BugCapsulePatch(engine: handle, unavailableReason: nil)
        } catch let e as PatchError {
            return BugCapsulePatch(engine: nil, unavailableReason: e.code)
        } catch {
            return BugCapsulePatch(engine: nil, unavailableReason: "internal")
        }
    }

    /// Runs the patched module when there is one, else the bundled fallback.
    /// Never throws for a patch failure.
    public func call<Input, Output>(_ module: PatchModule<Input, Output>, _ input: Input, timeoutMs: UInt64 = 50) -> PatchResult<Output> {
        guard engine != nil else {
            return PatchResult(value: module.fallback(input), source: .bundled, reason: unavailableReason)
        }
        do {
            let body = try JSONSerialization.data(withJSONObject: module.encode(input), options: [.fragmentsAllowed])
            let answer = try invoke(Op.eval, Data(module.contract.id.utf8), body, timeoutMs)
            guard let doc = try JSONSerialization.jsonObject(with: answer) as? [String: Any], let output = doc["output"] else {
                throw PatchError(code: "bad_output", message: "no output")
            }
            return PatchResult(value: try module.decode(output), source: .patched, reason: nil)
        } catch let e as PatchError {
            return PatchResult(value: module.fallback(input), source: .bundled, reason: e.code)
        } catch {
            return PatchResult(value: module.fallback(input), source: .bundled, reason: "bad_output")
        }
    }

    public func status() throws -> [String: Any] { try json(Op.status) }

    /// Verifies a `.bcpatch` and makes it the next launch's candidate.
    @discardableResult public func stage(_ bundle: Data) throws -> [String: Any] { try json(Op.stage, bundle) }

    /// Applies signed channel metadata; the answer says what to do next.
    @discardableResult public func applyChannel(_ document: Data, signature: Data) throws -> [String: Any] { try json(Op.channel, document, signature) }

    @discardableResult public func applyKeyring(_ document: Data, signature: Data) throws -> [String: Any] { try json(Op.keyring, document, signature) }

    /// Call after the first usable screen and module smoke checks. Downloading is not health.
    @discardableResult public func markHealthy(_ checkpoint: String) throws -> [String: Any] { try json(Op.healthy, Data(checkpoint.utf8)) }

    /// Reports a fault attributed to the running patch, such as a crash.
    @discardableResult public func reportFault(_ kind: String) throws -> [String: Any] { try json(Op.fault, Data(kind.utf8)) }

    public func receipts() throws -> [String: Any] { try json(Op.receipts) }

    @discardableResult public func ackReceipts(upTo: UInt64) throws -> [String: Any] { try json(Op.ack, n: upTo) }

    /// A patched asset, or nil when this generation does not override `id`.
    public func asset(_ id: String) -> Data? { try? invoke(Op.asset, Data(id.utf8)) }

    /// The patched document for a registered surface, or nil to use the bundled layout.
    public func surface(_ id: String) -> [String: Any]? {
        (try? invoke(Op.surface, Data(id.utf8))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private func json(_ op: UInt32, _ a: Data = Data(), _ b: Data = Data(), n: UInt64 = 0) throws -> [String: Any] {
        guard let doc = try JSONSerialization.jsonObject(with: invoke(op, a, b, n)) as? [String: Any] else {
            throw PatchError(code: "internal", message: "not an object")
        }
        return doc
    }

    private func invoke(_ op: UInt32, _ a: Data, _ b: Data = Data(), _ n: UInt64 = 0) throws -> Data {
        guard let engine else { throw PatchError(code: "unavailable", message: unavailableReason ?? "closed") }
        var out = BcpBuf(ptr: nil, len: 0)
        let status = a.withUnsafeBytes { ra in
            b.withUnsafeBytes { rb in
                bcp_call(engine, op, ra.bindMemory(to: UInt8.self).baseAddress, ra.count, rb.bindMemory(to: UInt8.self).baseAddress, rb.count, n, &out)
            }
        }
        return try BugCapsulePatch.take(status, out)
    }

    private static func take(_ status: Int32, _ out: BcpBuf) throws -> Data {
        let bytes = out.ptr.map { Data(bytes: $0, count: out.len) } ?? Data()
        bcp_buf_free(out)
        guard status == 0 else {
            let e = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
            throw PatchError(code: e?["code"] as? String ?? "internal", message: e?["message"] as? String ?? "")
        }
        return bytes
    }
}

#endif
