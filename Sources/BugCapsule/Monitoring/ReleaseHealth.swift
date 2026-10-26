import Foundation

/// Release-health sessions (monitoring-v1 §7): one per foreground run,
/// ended after `sessionTimeout` in the background. The open session is
/// persisted on every change, so a run the process did not end cleanly is
/// reported on the next launch: `crashed` with a crash report, `abnormal`
/// when it died in the foreground (OOM, watchdog, force-quit), `exited`
/// when it died in the background. The persisted state keeps the release
/// and environment of its run, so a session recovered after an app update
/// is reported for the release that ran it.
final class ReleaseHealth: @unchecked Sendable {
    struct State: Equatable {
        var sid: String
        var did: String
        var seq: Int
        var initSent: Bool
        var started: Date
        var status: String
        var errors: Int
        var foreground: Bool
        var backgroundAt: Date?
        var updated: Date
        /// nil in state files written before they were persisted.
        var release: String?
        var environment: String?

        var json: JSONValue {
            [
                "sid": .string(sid), "did": .string(did), "seq": .int(seq), "initSent": .bool(initSent),
                "started": .string(ISODate.format(started)), "status": .string(status), "errors": .int(errors),
                "foreground": .bool(foreground), "backgroundAt": backgroundAt.map { .string(ISODate.format($0)) } ?? .null,
                "updated": .string(ISODate.format(updated)), "release": release.map { .string($0) } ?? .null,
                "environment": environment.map { .string($0) } ?? .null,
            ]
        }

        init(sid: String, did: String, started: Date, release: String? = nil, environment: String? = nil) {
            self.sid = sid
            self.did = did
            self.release = release
            self.environment = environment
            seq = 0
            initSent = false
            self.started = started
            status = "ok"
            errors = 0
            foreground = true
            updated = started
        }

        init?(json: JSONValue) {
            guard let sid = json["sid"]?.stringValue, let did = json["did"]?.stringValue,
                let started = json["started"]?.stringValue.flatMap(ISODate.parse)
            else { return nil }
            self.sid = sid
            self.did = did
            seq = json["seq"]?.intValue ?? 0
            initSent = json["initSent"]?.boolValue ?? false
            self.started = started
            status = json["status"]?.stringValue ?? "ok"
            errors = json["errors"]?.intValue ?? 0
            foreground = json["foreground"]?.boolValue ?? true
            backgroundAt = json["backgroundAt"]?.stringValue.flatMap(ISODate.parse)
            updated = json["updated"]?.stringValue.flatMap(ISODate.parse) ?? started
            release = json["release"]?.stringValue
            environment = json["environment"]?.stringValue
        }
    }

    private let lock = NSLock()
    private let file: URL?
    private var state: State?
    private let release: String
    private let environment: String
    let timeout: TimeInterval
    /// Receives each session update payload.
    private let emit: @Sendable (JSONObject) -> Void
    private let did: @Sendable () -> String

    init(
        file: URL?, release: String, environment: String, timeout: TimeInterval, did: @escaping @Sendable () -> String,
        emit: @escaping @Sendable (JSONObject) -> Void
    ) {
        self.file = file
        self.release = release
        self.environment = environment
        self.timeout = timeout
        self.did = did
        self.emit = emit
    }

    var current: State? { lock.locked { state } }

    private func persistLocked() {
        guard let file else { return }
        if let state {
            try? FileIO.writeAtomically(JSON.encodeData(state.json), to: file)
        } else {
            FileIO.deleteQuietly(file)
        }
    }

    /// The update payload for [s] (advances `seq` and marks `init`).
    private func updateLocked(_ s: inout State, at time: Date) -> JSONObject {
        s.seq += 1
        let isInit = !s.initSent
        s.initSent = true
        s.updated = time
        return [
            "sid": .string(s.sid), "did": .string(s.did), "seq": .int(s.seq), "init": .bool(isInit),
            "started": .string(ISODate.format(s.started)), "timestamp": .string(ISODate.format(time)),
            "status": .string(s.status), "errors": .int(s.errors),
            "duration": .double(max(time.timeIntervalSince(s.started), 0)), "release": .string(s.release ?? release),
            "environment": .string(s.environment ?? environment), "runtime": "ios",
        ]
    }

    /// The previous launch's open session, closed as `crashed`, `abnormal`
    /// or `exited`. Returns its final update (or nil).
    func recoverPrevious(crashedAt: Date?) -> JSONObject? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        FileIO.deleteQuietly(file)
        guard let json = try? JSON.parse(data), var s = State(json: json), s.status == "ok" || s.status == "crashed"
        else { return nil }
        let end: Date
        if s.status == "crashed" {
            // Written by the in-process crash path; its update may not have been sent.
            end = s.updated
        } else if let crashedAt {
            s.status = "crashed"
            end = max(crashedAt, s.started)
        } else if s.foreground {
            s.status = "abnormal"
            end = s.updated
        } else {
            s.status = "exited"
            end = s.backgroundAt ?? s.updated
        }
        return lock.locked { updateLocked(&s, at: end) }
    }

    /// Starts a new session (ending the running one as `exited`).
    func start(at time: Date = Date()) {
        end(at: time)
        let payload: JSONObject = lock.locked {
            var s = State(sid: uuidV4(), did: did(), started: time, release: release, environment: environment)
            let p = updateLocked(&s, at: time)
            state = s
            persistLocked()
            return p
        }
        emit(payload)
    }

    func end(status: String = "exited", at time: Date = Date()) {
        let payload: JSONObject? = lock.locked {
            guard var s = state else { return nil }
            s.status = status
            let p = updateLocked(&s, at: time)
            state = nil
            persistLocked()
            return p
        }
        if let payload { emit(payload) }
    }

    /// An error event was captured: the first one sends an update (the
    /// session becomes errored when it exits).
    func errorCaptured() {
        let payload: JSONObject? = lock.locked {
            guard var s = state else { return nil }
            s.errors += 1
            if s.errors == 1 {
                let p = updateLocked(&s, at: Date())
                state = s
                persistLocked()
                return p
            }
            state = s
            persistLocked()
            return nil
        }
        if let payload { emit(payload) }
    }

    /// Unhandled crash in process (NSException): final `crashed` update,
    /// returned for a synchronous write.
    func crashedSynchronously(at time: Date = Date()) -> JSONObject? {
        lock.locked {
            guard var s = state else { return nil }
            s.status = "crashed"
            s.errors += 1
            let p = updateLocked(&s, at: time)
            state = nil
            persistLocked()
            return p
        }
    }

    func didEnterBackground(at time: Date = Date()) {
        lock.locked {
            guard var s = state else { return }
            s.foreground = false
            s.backgroundAt = time
            state = s
            persistLocked()
        }
    }

    /// Back in the foreground: the same session when the app was in the
    /// background for less than the timeout, else a new one.
    func willEnterForeground(at time: Date = Date()) {
        let restart: Date?? = lock.locked {
            guard var s = state else { return .some(nil) }
            if let bg = s.backgroundAt, time.timeIntervalSince(bg) >= timeout { return .some(bg) }
            s.foreground = true
            s.backgroundAt = nil
            state = s
            persistLocked()
            return .none
        }
        guard let restart else { return }
        if let endedAt = restart { end(at: endedAt) }
        start(at: time)
    }
}
