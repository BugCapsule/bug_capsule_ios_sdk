import Foundation

/// Capsules of crashed processes, built on a later launch from their crash
/// journal (crash-capsules §2).
extension BugCapsuleSession {
    static let crashNativeReason =
        "the app died in native code or was killed; replay re-runs the steps and checks for the same crash"

    /// Sends the fatal event [draft] of an earlier process with a capsule
    /// built from its [journal] when one can be built (then `capsuleId` is
    /// set and `manifest.monitoring` names the event). The journal is
    /// deleted afterwards. Synchronous: call off the main thread. Returns
    /// the event id.
    @discardableResult
    func captureCrash(_ draft: EventDraft, journal: URL, crashTime: Date?, monitoring m: Monitoring) -> String? {
        defer { FileIO.deleteQuietly(journal) }
        let (store, allowed) = lock.locked { (self.store, self.capsulesAllowedLocked) }
        let contents = allowed ? CrashJournalContents.load(journal) : nil
        let capsuleId = uuidV4()
        guard var payload = m.prepare(draft, capsuleId: contents == nil ? nil : capsuleId) else { return nil }
        if let contents, let store, payload["capsuleId"] == .string(capsuleId), let eventId = payload["eventId"]?.stringValue {
            let link = CapsuleMonitoringLink(
                eventId: eventId, release: payload["release"]?.stringValue ?? m.release,
                environment: payload["environment"]?.stringValue ?? m.environment)
            if !saveCrashCapsule(contents, draft: draft, crashTime: crashTime, link: link, capsuleId: capsuleId, store: store) {
                payload["capsuleId"] = nil
            }
        }
        return m.send(payload, draft: draft, synchronous: true)
    }

    private var capsulesAllowedLocked: Bool { config.enabled && !remoteDisabled && !killed }

    /// Builds, saves and queues the capsule (synchronously: it is in the
    /// outbox before the event is sent). False when none could be built.
    private func saveCrashCapsule(
        _ contents: CrashJournalContents, draft: EventDraft, crashTime: Date?, link: CapsuleMonitoringLink,
        capsuleId: String, store: CapsuleStore
    ) -> Bool {
        let (maxBytes, outbox) = lock.locked { (maxCapsuleBytes, self.outbox) }
        guard
            let (capsule, bytes) = buildCrashCapsule(
                contents, draft: draft, crashTime: crashTime, link: link, capsuleId: capsuleId, maxBytes: maxBytes)
        else { return false }
        do {
            try store.save(capsuleId: capsuleId, bytes: bytes)
        } catch {
            BugCapsuleLog.warn("could not save crash capsule: \(error)")
            return false
        }
        if let outbox {
            guard bytes.count <= config.outboxLimits.maxBytes else { return false }
            UploadOutbox.writeSynchronously(directory: outbox.directory, capsuleId: capsuleId, bytes: bytes)
        }
        BugCapsuleLog.info(
            "captured \(capsuleId) from the crash journal of process \(contents.pid.map(String.init) ?? "?") "
                + "(\(capsule.manifest.failure?.signature ?? "crash"), \(capsule.manifest.eligibility.status.rawValue))")
        return true
    }

    /// The capsule and its bytes: from the launch checkpoint when the
    /// journal still covers it, else (or when that is over [maxBytes]) from
    /// the newest periodic checkpoint; nil when neither fits or is valid.
    func buildCrashCapsule(
        _ contents: CrashJournalContents, draft: EventDraft, crashTime: Date?, link: CapsuleMonitoringLink,
        capsuleId: String, maxBytes: Int
    ) -> (Capsule, Data)? {
        for periodicOnly in [false, true] {
            guard let window = contents.window(periodicOnly: periodicOnly) else { continue }
            if periodicOnly && window.checkpoint.kind != .periodic { break }
            guard
                let capsule = crashCapsule(
                    contents, window: window, draft: draft, crashTime: crashTime, link: link, capsuleId: capsuleId)
            else { return nil }
            if let problem = validateCapsuleDocument(CapsuleCodec.toJSON(capsule)) {
                BugCapsuleLog.warn("crash capsule \(capsuleId) failed validation, not written: \(problem)")
                return nil
            }
            guard let bytes = try? CapsuleCodec.encode(capsule) else { return nil }
            if bytes.count <= maxBytes { return (capsule, bytes) }
            BugCapsuleLog.info("crash capsule from the \(window.checkpoint.kind.rawValue) checkpoint is \(bytes.count) bytes, limit \(maxBytes)")
            if window.checkpoint.kind == .periodic { break }
        }
        return nil
    }

    /// The capsule the in-memory recorder would have written at the crash,
    /// from the journal's header, [window] and the fatal event [draft].
    func crashCapsule(
        _ contents: CrashJournalContents, window: (checkpoint: Checkpoint, events: [BugCapsuleEvent], hasGap: Bool),
        draft: EventDraft, crashTime: Date?, link: CapsuleMonitoringLink, capsuleId: String
    ) -> Capsule? {
        let h = contents.header
        let checkpoint = window.checkpoint
        let events = window.events
        let lastT = events.last?.t ?? checkpoint.t
        // Session clock → anchor: a crash before the first window has no
        // anchor; the last journaled event stands in for it.
        let anchorT = h["anchorT"]?.intValue ?? lastT
        let startMs = h["wallClockAtStartMs"]?.intValue ?? (checkpoint.wallClockMs - checkpoint.t)
        let wallAtAnchor =
            h["anchorT"]?.intValue != nil ? (h["session"]?["wallClockAtAnchorMs"]?.intValue ?? startMs + anchorT) : startMs + anchorT
        let lastShifted = lastT - anchorT
        var t = lastShifted
        var gapMs: Int?
        if let crashTime {
            let crashT = Int((crashTime.timeIntervalSince1970 * 1000).rounded(.down)) - wallAtAnchor
            gapMs = max(crashT - lastShifted, 0)
            t = max(crashT, lastShifted)
        }
        guard let failure = CrashFailure.failure(from: draft, t: t, scrub: redactor.scrubText) else { return nil }

        let eligibility = EligibilityBuilder()
        let source = h["source"]?.objectValue ?? JSONObject()
        if source["gitSha"]?.stringValue == nil {
            eligibility.missing("build.gitSha", "BUGCAPSULE_GIT_SHA was not set at build time")
        } else if source["dirty"]?.boolValue == true {
            eligibility.missing("build.gitSha", "built from a tree with uncommitted changes")
        }
        if window.hasGap {
            eligibility.missing(
                "events.window", "events between the checkpoint and the window were evicted; raise window or maxEvents")
        }
        let pointers = events.filter { $0.type == EventTypes.pointer }.count
        if pointers > 0 && !events.contains(where: { $0.type == EventTypes.action }) {
            eligibility.missing(
                "capability.input.pointer.replay",
                "only pointer input was recorded (\(pointers) events); iOS replays semantic actions, not touches")
        }
        let recorded = RecordedWindow(checkpoint: checkpoint, events: events, droppedEvents: 0, hasGap: window.hasGap)
        for integration in integrations { integration.describeEligibility(eligibility, window: recorded) }
        let declared = (h["dependencies"]?.arrayValue ?? []).compactMap { $0.objectValue.map(CapsuleDependency.init(json:)) }
        let dependencies = InteractionRuntime.selectDependencies(
            declared, events: events, checkpoint: checkpoint, eligibility: eligibility)
        eligibility.missing("crash.native", Self.crashNativeReason)

        var m = JSONObject()
        for key in ["mode", "app", "source", "sdk", "stateSchemaVersion", "platform", "integrations", "redaction", "runtime", "capabilities"] {
            if let v = h[key] { m[key] = v }
        }
        var session = h["session"]?.objectValue ?? JSONObject()
        session["wallClockAtAnchorMs"] = .int(wallAtAnchor)
        session["durationMs"] = .int(max(t, lastShifted, 0))
        m["session"] = .object(session)
        var manifest = CapsuleManifest(json: m, specVersion: 2)
        var labels = (h["labels"]?.objectValue ?? JSONObject()).compactMap { k, v in v.stringValue.map { (k, $0) } }
            .filter { $0.0 != "source" && $0.0 != "crash.mechanism" }
        labels.append(("source", "crash_journal"))
        labels.append(("crash.mechanism", failure.crash?["mechanism"]?.stringValue ?? "signal"))
        manifest.capsuleId = capsuleId
        manifest.createdAt = Date()
        manifest.failure = failure
        manifest.eligibility = eligibility.build()
        manifest.eventCount = events.count
        manifest.droppedEvents = 0
        manifest.checkpointKind = checkpoint.kind
        manifest.labels = Array(labels.suffix(100))
        manifest.monitoring = link
        manifest.dependencies = dependencies
        manifest.journalGapMs = gapMs
        return Capsule(manifest: manifest, checkpoint: checkpoint.shifted(anchorT), events: events.map { $0.shifted(anchorT) })
    }
}

/// `manifest.failure` of kind `crash` (crash-capsules §3) from a fatal
/// event: the crash report's or MetricKit's exception value.
enum CrashFailure {
    /// The termination reason of a watchdog kill (`0x8badf00d`, "ate bad food").
    static let watchdogCode = "8badf00d"

    static func failure(from draft: EventDraft, t: Int, scrub: (String) -> String = { $0 }) -> FailureRecord? {
        guard let value = draft.exceptionValues?.last, let o = value.objectValue else { return nil }
        let mechanism = o["mechanism"]?["type"]?.stringValue ?? "signal"
        let data = o["mechanism"]?["data"]?.objectValue ?? JSONObject()
        var type = o["type"]?.stringValue ?? "Crash"
        if mechanism == "metrickit",
            data["terminationReason"]?.stringValue?.lowercased().contains(watchdogCode) == true
        {
            type = "ApplicationNotResponding"
        }
        var crash: JSONObject = ["mechanism": .string(mechanism)]
        if let signal = data["signal"]?.intValue { crash["signal"] = .int(signal) }
        if let exception = data["exception"]?.intValue { crash["exception"] = .int(exception) }
        let frames = (o["stacktrace"]?["frames"]?.arrayValue ?? []).reversed()
        if let frame = inAppFrame(Array(frames), images: draft.images) { crash["inAppFrame"] = .string(frame.dartPrefix(1000)) }
        var lines: [String] = []
        for (i, f) in frames.prefix(100).enumerated() {
            let image = f["package"]?.stringValue.map { ($0 as NSString).lastPathComponent } ?? "?"
            lines.append("#\(i) \(f["function"]?.stringValue ?? f["instructionAddr"]?.stringValue ?? "?") (\(image))")
        }
        return FailureRecord.crash(
            type: type, message: o["value"]?.stringValue ?? "", stack: lines.isEmpty ? nil : lines.joined(separator: "\n"),
            crash: crash, t: t, scrub: scrub)
    }

    /// The function of the in-app frame closest to the crash ([frames]
    /// innermost first), when this build can symbolicate it (same binary,
    /// symbols present); app frames carry no name in the event.
    static func inAppFrame(_ frames: [JSONValue], images: [DebugImage]) -> String? {
        guard let f = frames.first(where: { $0["inApp"]?.boolValue == true }) else { return nil }
        if let name = f["function"]?.stringValue { return name }
        guard let addr = f["instructionAddr"]?.stringValue.flatMap(parseHex),
            let imageAddr = f["imageAddr"]?.stringValue.flatMap(parseHex),
            let image = images.first(where: { $0.loadAddress == imageAddr }),
            let live = DebugImageCache.shared.image(debugId: image.debugId)
        else { return nil }
        return Symbolicator.function(at: addr &- imageAddr &+ live.loadAddress)
    }
}
