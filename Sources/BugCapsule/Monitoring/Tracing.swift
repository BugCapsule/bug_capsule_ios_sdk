import Foundation

/// Span / transaction status (monitoring-v1 §8).
public enum SpanStatus: String, Sendable, CaseIterable {
    case ok, cancelled, unknown
    case invalidArgument = "invalid_argument"
    case deadlineExceeded = "deadline_exceeded"
    case notFound = "not_found"
    case alreadyExists = "already_exists"
    case permissionDenied = "permission_denied"
    case resourceExhausted = "resource_exhausted"
    case failedPrecondition = "failed_precondition"
    case aborted
    case outOfRange = "out_of_range"
    case unimplemented
    case internalError = "internal_error"
    case unavailable
    case dataLoss = "data_loss"
    case unauthenticated

    /// OpenTelemetry's HTTP status mapping.
    public static func fromHTTP(_ code: Int) -> SpanStatus {
        switch code {
        case 200..<400: return .ok
        case 400: return .invalidArgument
        case 401: return .unauthenticated
        case 403: return .permissionDenied
        case 404: return .notFound
        case 409: return .alreadyExists
        case 412: return .failedPrecondition
        case 413: return .failedPrecondition
        case 429: return .resourceExhausted
        case 499: return .cancelled
        case 400..<500: return .invalidArgument
        case 501: return .unimplemented
        case 503: return .unavailable
        case 504: return .deadlineExceeded
        case 500..<600: return .internalError
        default: return .unknown
        }
    }
}

func randomHex(bytes: Int) -> String {
    var out = ""
    repeat {
        out = ""
        for _ in 0..<bytes { out += String(format: "%02x", UInt8.random(in: 0...255)) }
    } while out.allSatisfy { $0 == "0" }
    return out
}

/// A timed operation in a trace. Children are created with `startChild`;
/// every span ends with `finish()`. Thread-safe.
public class BugCapsuleSpan: @unchecked Sendable {
    public let traceId: String
    public let spanId: String
    public let parentSpanId: String?
    public let op: String
    public let startTimestamp: Date
    public let sampled: Bool
    let lock = NSRecursiveLock()
    private var _description: String?
    private var _timestamp: Date?
    private var _status: SpanStatus?
    private var _data = JSONObject()
    private var _tags = JSONObject()
    weak var root: BugCapsuleTransaction?

    init(
        traceId: String, spanId: String = randomHex(bytes: 8), parentSpanId: String?, op: String, description: String?,
        sampled: Bool, start: Date = Date()
    ) {
        self.traceId = traceId
        self.spanId = spanId
        self.parentSpanId = parentSpanId
        self.op = op
        _description = description
        self.sampled = sampled
        startTimestamp = start
    }

    public var spanDescription: String? {
        get { lock.locked { _description } }
        set { lock.locked { _description = newValue } }
    }
    public var timestamp: Date? { lock.locked { _timestamp } }
    public var status: SpanStatus? { lock.locked { _status } }
    public var isFinished: Bool { timestamp != nil }
    public var data: JSONObject { lock.locked { _data } }

    /// A child span of this one (same trace and sampling decision).
    @discardableResult
    public func startChild(op: String, description: String? = nil) -> BugCapsuleSpan {
        let child = BugCapsuleSpan(
            traceId: traceId, parentSpanId: spanId, op: op, description: description, sampled: sampled)
        let transaction = (self as? BugCapsuleTransaction) ?? root
        child.root = transaction
        transaction?.adopt(child)
        return child
    }

    public func setData(_ key: String, _ value: Any?) {
        lock.locked { _data[key] = value == nil ? nil : JSONValue(any: value) }
    }

    public func setTag(_ key: String, _ value: String) {
        guard Scope.validTagKey(key) else { return }
        lock.locked { _tags[key] = .string(value.dartPrefix(200)) }
    }

    public func setStatus(_ status: SpanStatus) { lock.locked { _status = status } }

    /// Ends the span (later calls are ignored).
    public func finish(status: SpanStatus? = nil, at end: Date = Date()) {
        let first = lock.locked { () -> Bool in
            if _timestamp != nil { return false }
            _timestamp = max(end, startTimestamp)
            if let status { _status = status } else if _status == nil { _status = .ok }
            return true
        }
        if first { didFinish() }
    }

    func didFinish() {}

    /// `00-<traceId>-<spanId>-<01|00>`.
    public var traceparent: String { "00-\(traceId)-\(spanId)-\(sampled ? "01" : "00")" }

    var json: JSONValue {
        lock.locked {
            var o: JSONObject = [
                "spanId": .string(spanId), "parentSpanId": parentSpanId.map { .string($0) } ?? .null,
                "traceId": .string(traceId), "op": .string(op.dartPrefix(200)),
                "description": _description.map { .string($0.dartPrefix(2000)) } ?? .null,
                "startTimestamp": .string(ISODate.format(startTimestamp)),
                "timestamp": .string(ISODate.format(_timestamp ?? Date())), "status": .string((_status ?? .ok).rawValue),
            ]
            if !_data.isEmpty { o["data"] = .object(_data) }
            if !_tags.isEmpty { o["tags"] = .object(_tags) }
            return .object(o)
        }
    }

    var tagsJSON: JSONObject { lock.locked { _tags } }

    /// The span `startSpan` made active for the current task.
    @TaskLocal static var taskActive: BugCapsuleSpan?
}

/// The root span of a trace segment, sent as a `transaction` item when it
/// finishes (if sampled).
public final class BugCapsuleTransaction: BugCapsuleSpan, @unchecked Sendable {
    public let name: String
    /// Sample rate the decision was made with (baggage, server extrapolation).
    public let sampleRate: Double
    private var children: [BugCapsuleSpan] = []
    private var measurements = JSONObject()
    private var droppedChildren = 0
    var onFinish: [@Sendable (BugCapsuleTransaction) -> Void] = []
    /// Finished without being sent.
    var discarded = false
    weak var tracer: Tracer?

    init(
        name: String, op: String, traceId: String, parentSpanId: String?, sampled: Bool, sampleRate: Double,
        start: Date = Date()
    ) {
        self.name = name
        self.sampleRate = sampleRate
        super.init(traceId: traceId, parentSpanId: parentSpanId, op: op, description: nil, sampled: sampled, start: start)
    }

    func adopt(_ child: BugCapsuleSpan) {
        lock.locked {
            if children.count < 1000 { children.append(child) } else { droppedChildren += 1 }
        }
    }

    var openChildren: [BugCapsuleSpan] { lock.locked { children.filter { !$0.isFinished } } }
    var allChildren: [BugCapsuleSpan] { lock.locked { children } }

    /// `measurements.<name> = {value, unit}` (`millisecond`, `none`, ...).
    public func setMeasurement(_ name: String, value: Double, unit: String = "none") {
        lock.locked { measurements[name] = ["value": .double(value), "unit": .string(unit)] }
    }

    func measurement(_ name: String) -> Double? { lock.locked { measurements[name]?["value"]?.doubleValue } }

    override func didFinish() {
        let hooks = lock.locked { onFinish }
        for h in hooks { h(self) }
        tracer?.finished(self)
    }

    /// The `transaction` item payload (children finished or not are sent as they are).
    func payload() -> JSONObject {
        lock.locked {
            var o: JSONObject = [
                "eventId": .string(uuidV4()), "traceId": .string(traceId), "spanId": .string(spanId),
                "parentSpanId": parentSpanId.map { .string($0) } ?? .null, "name": .string(name.dartPrefix(200)),
                "op": .string(op), "startTimestamp": .string(ISODate.format(startTimestamp)),
                "timestamp": .string(ISODate.format(timestamp ?? Date())), "status": .string((status ?? .ok).rawValue),
            ]
            o["tags"] = .object(tagsJSON)
            if !measurements.isEmpty { o["measurements"] = .object(measurements) }
            o["spans"] = .array(children.map(\.json))
            var extra = data
            if droppedChildren > 0 { extra["droppedSpans"] = .int(droppedChildren) }
            if !extra.isEmpty { o["extra"] = .object(extra) }
            return o
        }
    }
}

/// Sampling, the active span and trace propagation (monitoring-v1 §8).
final class Tracer: @unchecked Sendable {
    private let lock = NSLock()
    private weak var monitoring: Monitoring?
    private let random: @Sendable () -> Double
    /// Trace continued from `continueTrace` or started for this run when no
    /// transaction is active ("tracing without performance").
    private var propagationTraceId = randomHex(bytes: 16)
    private var incoming: (parentSpanId: String, sampled: Bool?)?

    init(monitoring: Monitoring, random: @escaping @Sendable () -> Double) {
        self.monitoring = monitoring
        self.random = random
    }

    var activeSpan: BugCapsuleSpan? {
        if let s = BugCapsuleSpan.taskActive, !s.isFinished { return s }
        guard let s = monitoring?.currentScope.span, !s.isFinished else { return nil }
        return s
    }

    /// The decision for a new root: the app's sampler, else the incoming
    /// decision, else the effective rate (app rate, or the remote rate when
    /// the app set neither a sampler nor a rate).
    func sample(name: String, op: String, parentSampled: Bool?) -> (Bool, Double) {
        guard let monitoring else { return (false, 0) }
        if let sampler = monitoring.options.tracesSampler,
            let rate = sampler(SamplingContext(name: name, op: op, parentSampled: parentSampled))
        {
            let r = min(max(rate, 0), 1)
            return (random() < r, r)
        }
        if let parentSampled { return (parentSampled, parentSampled ? 1 : 0) }
        let r = monitoring.tracesSampleRate
        return (r > 0 && random() < r, r)
    }

    func startTransaction(name: String, op: String, bindToScope: Bool, start: Date = Date()) -> BugCapsuleTransaction {
        let (traceId, parent, parentSampled): (String, String?, Bool?) = lock.locked {
            if let incoming {
                // The continued trace applies to the next root only.
                self.incoming = nil
                return (propagationTraceId, incoming.parentSpanId, incoming.sampled)
            }
            return (randomHex(bytes: 16), nil, nil)
        }
        let (sampled, rate) = sample(name: name, op: op, parentSampled: parentSampled)
        let t = BugCapsuleTransaction(
            name: name, op: op, traceId: traceId, parentSpanId: parent, sampled: sampled, sampleRate: rate, start: start)
        t.tracer = self
        lock.locked { propagationTraceId = traceId }
        if bindToScope { monitoring?.scope.span = t }
        return t
    }

    func finished(_ transaction: BugCapsuleTransaction) {
        guard let monitoring else { return }
        if monitoring.scope.span === transaction { monitoring.scope.span = nil }
        monitoring.send(transaction)
    }

    func continueTrace(traceparent: String, baggage: String?) {
        let parts = traceparent.trimmingCharacters(in: .whitespaces).split(separator: "-").map(String.init)
        guard parts.count >= 3, parts[1].count == 32, parts[2].count == 16 else { return }
        var sampled: Bool?
        if parts.count >= 4 { sampled = parts[3] == "01" }
        if sampled == nil, let baggage {
            for entry in baggage.split(separator: ",") {
                let kv = entry.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2 && kv[0] == "bugcapsule-sampled" { sampled = kv[1] == "true" }
            }
        }
        lock.locked {
            propagationTraceId = parts[1].lowercased()
            incoming = (parts[2].lowercased(), sampled)
        }
    }

    /// `traceparent` for a custom client: the active span's, else the
    /// propagation trace with a fresh span id.
    func traceparent(spanId: String? = nil) -> String {
        if let span = activeSpan {
            return "00-\(span.traceId)-\(spanId ?? span.spanId)-\(span.sampled ? "01" : "00")"
        }
        let (traceId, sampled) = lock.locked { (propagationTraceId, incoming?.sampled) }
        return "00-\(traceId)-\(spanId ?? randomHex(bytes: 8))-\(sampled == true ? "01" : "00")"
    }

    func baggage(existing: String? = nil) -> String {
        guard let monitoring else { return existing ?? "" }
        let span = activeSpan
        let traceId = span?.traceId ?? lock.locked { propagationTraceId }
        let sampled = span?.sampled ?? (lock.locked { incoming?.sampled } ?? false)
        let rate = (span as? BugCapsuleTransaction)?.sampleRate ?? span?.root?.sampleRate ?? monitoring.tracesSampleRate
        let ours = [
            "bugcapsule-trace_id=\(traceId)", "bugcapsule-release=\(Self.encode(monitoring.release))",
            "bugcapsule-environment=\(Self.encode(monitoring.environment))",
            "bugcapsule-sample_rate=\(JSON.formatDouble(rate))", "bugcapsule-sampled=\(sampled)",
        ]
        var kept: [String] = []
        for entry in (existing ?? "").split(separator: ",") {
            let e = entry.trimmingCharacters(in: .whitespaces)
            if e.isEmpty || e.hasPrefix("bugcapsule-") { continue }
            kept.append(e)
        }
        return (kept + ours).joined(separator: ",")
    }

    private static let baggageValueChars: CharacterSet = {
        var c = CharacterSet.alphanumerics
        c.insert(charactersIn: "-._~@+:/")
        return c
    }()

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: baggageValueChars) ?? value
    }

    /// Substring targets, or `/regex/`.
    static func matches(_ url: String, targets: [String]) -> Bool {
        for t in targets where !t.isEmpty {
            if t.count >= 2 && t.hasPrefix("/") && t.hasSuffix("/") {
                let pattern = String(t.dropFirst().dropLast())
                if let re = try? NSRegularExpression(pattern: pattern),
                    re.firstMatch(in: url, range: NSRange(location: 0, length: (url as NSString).length)) != nil
                {
                    return true
                }
            } else if url.contains(t) {
                return true
            }
        }
        return false
    }

    // MARK: HTTP

    struct HTTPSpan: @unchecked Sendable {
        let span: BugCapsuleSpan?
        let headers: [String: String]
    }

    /// Starts an `http.client` span under the active span and computes the
    /// propagation headers for [request] (never overwriting `traceparent`).
    func startHTTP(_ request: URLRequest, redactor: Redactor) -> HTTPSpan {
        guard let monitoring, let url = request.url?.absoluteString else { return HTTPSpan(span: nil, headers: [:]) }
        let method = (request.httpMethod ?? "GET").uppercased()
        var span: BugCapsuleSpan?
        if monitoring.options.enableNetworkTracing, let parent = activeSpan {
            let redacted = redactor.redactURL(url)
            let path = URLComponents(string: redacted).map { c -> String in
                var p = "\(c.scheme ?? "")://\(c.host ?? "")"
                if let port = c.port { p += ":\(port)" }
                return p + c.path
            } ?? redacted
            let s = parent.startChild(op: "http.client", description: "\(method) \(path)")
            s.setData("url", redacted)
            s.setData("http.request.method", method)
            span = s
        }
        var headers: [String: String] = [:]
        if Self.matches(url, targets: monitoring.tracePropagationTargets) {
            if request.value(forHTTPHeaderField: "traceparent") == nil {
                headers["traceparent"] = traceparent(spanId: span?.spanId)
            }
            headers["baggage"] = baggage(existing: request.value(forHTTPHeaderField: "baggage"))
        }
        return HTTPSpan(span: span, headers: headers)
    }

    static func finishHTTP(_ span: BugCapsuleSpan?, status: Int?, error: Error?) {
        guard let span else { return }
        if let status, status > 0 { span.setData("http.response.status_code", status) }
        if let error {
            let code = (error as NSError).code
            span.finish(status: code == NSURLErrorCancelled ? .cancelled : code == NSURLErrorTimedOut ? .deadlineExceeded : .internalError)
        } else {
            span.finish(status: SpanStatus.fromHTTP(status ?? 0))
        }
    }
}
