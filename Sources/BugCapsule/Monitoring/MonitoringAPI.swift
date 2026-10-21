import Foundation

/// Monitoring API (monitoring-v1 §11). Every call is a no-op before
/// `BugCapsule.start`, in replay, and when monitoring is disabled.
extension BugCapsule {
    private static var monitoring: Monitoring? { BugCapsuleSession.current?.monitoring }

    // MARK: capture

    /// Sends an error event (and, when recording, captures a capsule for
    /// it like `report(error:)`). Returns the event id.
    @discardableResult
    public static func captureException(_ error: Error, options: CaptureOptions = CaptureOptions()) -> String? {
        BugCapsuleSession.current?.reportError(error, options: options)
    }

    /// `captureException` for an `NSException` the app caught.
    @discardableResult
    public static func captureException(_ exception: NSException, options: CaptureOptions = CaptureOptions()) -> String? {
        BugCapsuleSession.current?.reportException(exception, options: options)
    }

    /// Sends a message event (no capsule). Returns the event id.
    @discardableResult
    public static func captureMessage(_ message: String, level: MonitoringLevel = .info) -> String? {
        guard let m = monitoring else { return nil }
        return m.capture(m.messageDraft(message, level: level))
    }

    /// Sends user feedback, optionally about an event (`associatedEventId`,
    /// e.g. `lastEventId()`). Returns the feedback id, or nil when the
    /// message is empty or monitoring is off.
    @discardableResult
    public static func captureFeedback(
        message: String, name: String? = nil, email: String? = nil, associatedEventId: String? = nil,
        url: String? = nil, tags: [String: String] = [:], capsuleId: String? = nil
    ) -> String? {
        monitoring?.captureFeedback(
            message: message, name: name, email: email, eventId: associatedEventId, url: url, tags: tags,
            capsuleId: capsuleId)
    }

    /// The id of the last event sent (after sampling and `beforeSend`).
    public static func lastEventId() -> String? { monitoring?.lastEventId }

    // MARK: scope

    /// The scope captures use right now (inside `withScope`: the temporary one).
    public static var scope: Scope? { monitoring?.currentScope }

    public static func setUser(_ user: BugCapsuleUser?) { monitoring?.currentScope.setUser(user) }
    public static func setTag(_ key: String, _ value: String?) { monitoring?.currentScope.setTag(key, value) }
    public static func setTags(_ tags: [String: String]) { monitoring?.currentScope.setTags(tags) }
    public static func setExtra(_ key: String, _ value: Any?) { monitoring?.currentScope.setExtra(key, value) }
    public static func setExtras(_ extras: [String: Any]) { monitoring?.currentScope.setExtras(extras) }
    public static func setContext(_ name: String, _ value: [String: Any]?) {
        monitoring?.currentScope.setContext(name, value)
    }
    public static func setLevel(_ level: MonitoringLevel?) { monitoring?.currentScope.setLevel(level) }
    public static func setFingerprint(_ fingerprint: [String]?) { monitoring?.currentScope.setFingerprint(fingerprint) }

    public static func addBreadcrumb(_ breadcrumb: Breadcrumb) {
        guard let m = monitoring, m.isActive else { return }
        var b = breadcrumb
        if let message = b.message { b.message = BugCapsuleSession.current?.redactor.scrubText(message) ?? message }
        m.addBreadcrumb(b)
    }

    public static func clearBreadcrumbs() { monitoring?.currentScope.clearBreadcrumbs() }

    /// Edits the global scope.
    public static func configureScope(_ body: (Scope) -> Void) {
        guard let m = monitoring else { return }
        body(m.scope)
    }

    /// Runs [body] with a temporary copy of the current scope: captures
    /// inside it (on this task / thread) use the copy.
    public static func withScope<T>(_ body: (Scope) throws -> T) rethrows -> T {
        guard let m = monitoring else { return try body(Scope()) }
        let copy = m.currentScope.copy()
        return try Scope.$pushed.withValue(copy) { try body(copy) }
    }

    /// `withScope` for async work.
    public static func withScope<T>(
        isolation: isolated (any Actor)? = #isolation, _ body: (Scope) async throws -> T
    ) async rethrows -> T {
        guard let m = monitoring else { return try await body(Scope()) }
        let copy = m.currentScope.copy()
        return try await Scope.$pushed.withValue(copy) { try await body(copy) }
    }

    // MARK: tracing

    /// Starts a transaction (root span). With [bindToScope], it is the active
    /// span: HTTP spans and events attach to it until it finishes.
    public static func startTransaction(name: String, op: String, bindToScope: Bool = false) -> BugCapsuleTransaction? {
        monitoring?.startTransaction(name: name, op: op, bindToScope: bindToScope)
    }

    /// Runs [body] in a span: a child of the active span, or a new
    /// transaction when none is active. The span is active inside [body]
    /// (for this task, and on the scope so URLSession requests made from
    /// other threads attach to it) and finished after it (`internal_error`
    /// when it throws).
    public static func startSpan<T>(name: String, op: String, _ body: (BugCapsuleSpan?) throws -> T) rethrows -> T {
        guard let m = monitoring, m.isActive else { return try body(nil) }
        let span = m.beginSpan(name: name, op: op)
        defer { m.endSpanScope(span) }
        do {
            let r = try BugCapsuleSpan.$taskActive.withValue(span) { try body(span) }
            span.finish()
            return r
        } catch {
            span.finish(status: .internalError)
            throw error
        }
    }

    /// `startSpan` for async work.
    public static func startSpan<T>(
        name: String, op: String, isolation: isolated (any Actor)? = #isolation,
        _ body: (BugCapsuleSpan?) async throws -> T
    ) async rethrows -> T {
        guard let m = monitoring, m.isActive else { return try await body(nil) }
        let span = m.beginSpan(name: name, op: op)
        defer { m.endSpanScope(span) }
        do {
            let r = try await BugCapsuleSpan.$taskActive.withValue(span) { try await body(span) }
            span.finish()
            return r
        } catch {
            span.finish(status: .internalError)
            throw error
        }
    }

    /// The span HTTP spans would attach to now.
    public static var activeSpan: BugCapsuleSpan? { monitoring?.tracer.activeSpan }

    /// `traceparent` for a custom HTTP client.
    public static func getTraceparent() -> String? { monitoring?.tracer.traceparent() }

    /// `baggage` for a custom HTTP client ([existing] entries are kept).
    public static func getBaggage(existing: String? = nil) -> String? { monitoring?.tracer.baggage(existing: existing) }

    /// Continues an incoming trace: the next transaction joins it and
    /// inherits its sampling decision.
    public static func continueTrace(traceparent: String, baggage: String? = nil) {
        monitoring?.tracer.continueTrace(traceparent: traceparent, baggage: baggage)
    }

    /// Starts a screen load (`ui.load` transaction with TTID) for screens
    /// not shown through an observed navigation controller (modals, tabs).
    @MainActor
    public static func screenWillAppear(_ name: String) { monitoring?.screenWillAppear(name) }

    /// Ends the current screen's time to full display (with
    /// `enableTimeToFullDisplayTracing`).
    @MainActor
    public static func reportFullyDisplayed() { monitoring?.reportFullyDisplayed() }

    // MARK: sessions

    /// Starts a new release-health session (ending the current one).
    public static func startSession() { monitoring?.health?.start() }

    /// Ends the current session as `exited`.
    public static func endSession() { monitoring?.health?.end() }

    // MARK: flush

    /// Sends queued events, sessions, transactions and feedback. False when
    /// [timeout] passed first.
    @discardableResult
    public static func flush(timeout: TimeInterval = 5) async -> Bool {
        guard let m = monitoring else { return true }
        return await m.flush(timeout: timeout)
    }

    /// Flushes, then stops the SDK (capture and monitoring).
    public static func close(timeout: TimeInterval = 5) async {
        await flush(timeout: timeout)
        await BugCapsuleSession.current?.dispose()
        BugCapsuleSession.current = nil
    }
}
