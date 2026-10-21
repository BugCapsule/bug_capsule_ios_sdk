import Foundation

/// Data applied to every event, transaction and feedback captured while it
/// is current: user, tags, extras, contexts, level, fingerprint,
/// breadcrumbs and the active span. Thread-safe.
///
/// `BugCapsule.configureScope` edits the global scope; `BugCapsule.withScope`
/// runs a closure with a temporary copy that captures inside it use.
public final class Scope: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var _user: BugCapsuleUser?
    private var _tags = JSONObject()
    private var _extra = JSONObject()
    private var _contexts = JSONObject()
    private var _level: MonitoringLevel?
    private var _fingerprint: [String]?
    private var _breadcrumbs: [Breadcrumb] = []
    private var _span: BugCapsuleSpan?
    var maxBreadcrumbs: Int
    /// Called after every change (crash context sync).
    var onChange: (@Sendable () -> Void)?

    init(maxBreadcrumbs: Int = 100) { self.maxBreadcrumbs = maxBreadcrumbs }

    static let tagKey = try! NSRegularExpression(pattern: "^[A-Za-z0-9_.:-]{1,32}$")

    static func validTagKey(_ key: String) -> Bool {
        Scope.tagKey.firstMatch(in: key, range: NSRange(location: 0, length: (key as NSString).length)) != nil
    }

    private func changed<T>(_ body: () -> T) -> T {
        let r = lock.locked(body)
        onChange?()
        return r
    }

    public var user: BugCapsuleUser? { lock.locked { _user } }
    public var tags: [String: String] {
        lock.locked {
            var out: [String: String] = [:]
            for (k, v) in _tags { out[k] = v.stringValue }
            return out
        }
    }
    public var level: MonitoringLevel? { lock.locked { _level } }
    public var fingerprint: [String]? { lock.locked { _fingerprint } }
    public var breadcrumbs: [Breadcrumb] { lock.locked { _breadcrumbs } }
    /// The span HTTP spans and captured events attach to.
    public var span: BugCapsuleSpan? {
        get { lock.locked { _span } }
        set { changed { _span = newValue } }
    }

    public func setUser(_ user: BugCapsuleUser?) { changed { _user = user } }

    /// Keys: 1-32 of `[A-Za-z0-9_.:-]` (others are ignored); values ≤200.
    public func setTag(_ key: String, _ value: String?) {
        guard Scope.validTagKey(key) else {
            BugCapsuleLog.warn("tag \"\(key)\" ignored: keys are 1-32 of [A-Za-z0-9_.:-]")
            return
        }
        changed {
            if let value { _tags[key] = .string(value.dartPrefix(200)) } else { _tags[key] = nil }
        }
    }

    public func setTags(_ tags: [String: String]) {
        for k in tags.keys.sorted() { setTag(k, tags[k]) }
    }

    public func setExtra(_ key: String, _ value: Any?) {
        changed { _extra[key] = value == nil ? nil : JSONValue(any: value) }
    }

    public func setExtras(_ extras: [String: Any]) {
        for k in extras.keys.sorted() { setExtra(k, extras[k]) }
    }

    /// A named context object (`contexts.<name>`); nil removes it.
    public func setContext(_ name: String, _ value: [String: Any]?) {
        changed { _contexts[name] = value.map { JSONValue(any: $0) } }
    }

    public func setLevel(_ level: MonitoringLevel?) { changed { _level = level } }

    public func setFingerprint(_ fingerprint: [String]?) {
        changed { _fingerprint = fingerprint.map { Array($0.prefix(10).map { $0.dartPrefix(200) }) } }
    }

    public func addBreadcrumb(_ crumb: Breadcrumb) {
        changed {
            _breadcrumbs.append(crumb)
            if _breadcrumbs.count > maxBreadcrumbs { _breadcrumbs.removeFirst(_breadcrumbs.count - maxBreadcrumbs) }
        }
    }

    public func clearBreadcrumbs() { changed { _breadcrumbs = [] } }

    public func clear() {
        changed {
            _user = nil
            _tags = JSONObject()
            _extra = JSONObject()
            _contexts = JSONObject()
            _level = nil
            _fingerprint = nil
            _breadcrumbs = []
            _span = nil
        }
    }

    func copy() -> Scope {
        lock.locked {
            let s = Scope(maxBreadcrumbs: maxBreadcrumbs)
            s._user = _user
            s._tags = _tags
            s._extra = _extra
            s._contexts = _contexts
            s._level = _level
            s._fingerprint = _fingerprint
            s._breadcrumbs = _breadcrumbs
            s._span = _span
            return s
        }
    }

    struct Snapshot {
        var user: BugCapsuleUser?
        var tags: JSONObject
        var extra: JSONObject
        var contexts: JSONObject
        var level: MonitoringLevel?
        var fingerprint: [String]?
        var breadcrumbs: [Breadcrumb]
        var span: BugCapsuleSpan?
    }

    func snapshot() -> Snapshot {
        lock.locked {
            Snapshot(
                user: _user, tags: _tags, extra: _extra, contexts: _contexts, level: _level, fingerprint: _fingerprint,
                breadcrumbs: _breadcrumbs, span: _span)
        }
    }

    // The scope `withScope` pushed for the current task / thread.
    @TaskLocal static var pushed: Scope?
}
