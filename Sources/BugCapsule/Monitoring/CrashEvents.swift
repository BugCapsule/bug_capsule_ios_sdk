import Foundation

/// `event.threads` (monitoring-v1 §2) and the events built from native
/// crash reports and hang samples, shared by monitoring and
/// `BugCapsuleCrashBridge`.
enum CrashEvents {
    static let maxThreads = 100
    /// The crashed (or hung) thread keeps as many frames as an exception.
    static let maxCrashedFrames = 250
    static let maxThreadFrames = 40
    static let maxTotalFrames = 1_500
    /// The backend rejects the whole event above 512 KiB of `threads`.
    static let maxThreadsBytes = 448 * 1024

    /// `threads` for [samples]: the crashed (or hung) thread first, then
    /// main, then the others in task order; frames oldest first, as in
    /// `exception`; within the limits of `fit`. Also the images their frames
    /// use. Main is named `main` when unnamed.
    static func threads(
        _ samples: [ThreadSample], stack: StackBuilder, resolve: (UInt64) -> DebugImage?,
        symbol: (UInt64, DebugImage) -> String? = { a, _ in Symbolicator.function(at: a) }
    ) -> (threads: [JSONValue], images: [DebugImage]) {
        let ordered = samples.enumerated().sorted { a, b in
            func rank(_ s: ThreadSample) -> Int { s.crashed ? 0 : s.isMain ? 1 : 2 }
            return (rank(a.element), a.offset) < (rank(b.element), b.offset)
        }.map(\.element)
        var out: [JSONValue] = []
        var used: [String: DebugImage] = [:]
        var budget = maxTotalFrames
        for sample in ordered.prefix(maxThreads) {
            // Innermost first here: the prefix keeps the newest frames.
            let take = min(sample.frames.count, sample.crashed ? maxCrashedFrames : maxThreadFrames, max(budget, 0))
            budget -= take
            let (frames, images) = stack.frames(
                Array(sample.frames.prefix(take)), firstIsPC: true, resolve: resolve, symbol: symbol)
            for image in images { used[image.debugId] = image }
            var t: JSONObject = [
                "id": .int(sample.index), "crashed": .bool(sample.crashed), "current": .bool(sample.current),
                "stacktrace": StackBuilder.stacktrace(frames),
            ]
            if let name = sample.name ?? (sample.isMain ? "main" : nil) { t["name"] = .string(name.dartPrefix(200)) }
            out.append(.object(t))
        }
        return (fit(out), used.values.sorted { $0.loadAddress < $1.loadAddress })
    }

    /// Keeps any `threads` list within the backend's limits: at most
    /// `maxThreads`, the newest `maxCrashedFrames` frames of a crashed
    /// thread and `maxThreadFrames` of the others, `maxTotalFrames` in all
    /// (crashed threads served first), then the last threads other than the
    /// crashed one go until the JSON fits `maxBytes`.
    static func fit(_ threads: [JSONValue], maxBytes: Int = maxThreadsBytes) -> [JSONValue] {
        var out = Array(threads.prefix(maxThreads))
        var budget = maxTotalFrames
        let order = out.indices.sorted { (out[$0]["crashed"]?.boolValue == true ? 0 : 1, $0) < (out[$1]["crashed"]?.boolValue == true ? 0 : 1, $1) }
        for i in order {
            guard var o = out[i].objectValue, let frames = o["stacktrace"]?["frames"]?.arrayValue else { continue }
            let cap = o["crashed"]?.boolValue == true ? maxCrashedFrames : maxThreadFrames
            let keep = min(frames.count, cap, max(budget, 0))
            budget -= keep
            // Oldest first: keep the newest.
            if keep < frames.count {
                o["stacktrace"] = StackBuilder.stacktrace(Array(frames.suffix(keep)))
                out[i] = .object(o)
            }
        }
        // The last other thread goes first; a crashed thread only when nothing else is left.
        while out.count > 1 && JSON.encodeData(.array(out)).count > maxBytes {
            out.remove(at: out.lastIndex { $0["crashed"]?.boolValue != true } ?? out.count - 1)
        }
        return out
    }

    /// The `fatal` event for a native crash report: exception from the
    /// crashing thread, every thread written, and the scope, release and
    /// environment of the process that crashed.
    static func draft(from r: NativeCrashReport, stack: StackBuilder) -> EventDraft {
        let d = r.description
        let resolve: (UInt64) -> DebugImage? = { addr in r.images.last { $0.loadAddress <= addr && $0.contains(addr) } }
        let symbol: (UInt64, DebugImage) -> String? = { addr, image in
            guard let current = DebugImageCache.shared.image(debugId: image.debugId) else { return nil }
            return Symbolicator.function(at: addr &- image.loadAddress &+ current.loadAddress)
        }
        let (frames, images) = stack.frames(r.frames, firstIsPC: true, resolve: resolve, symbol: symbol)
        let value = StackBuilder.exceptionValue(
            type: d.type, value: d.value, module: nil, mechanism: d.mechanism, handled: false, frames: frames, data: d.data)
        var draft = EventDraft(level: .fatal, exceptionValues: [value], images: images, timestamp: r.time)
        var template = r.context ?? [:]
        if let release = r.release, !release.isEmpty { template["release"] = .string(release) }
        if let environment = r.environment, !environment.isEmpty { template["environment"] = .string(environment) }
        draft.template = template
        draft.hint = EventHint(fromPreviousLaunch: true)
        if r.threads.isEmpty {
            draft.threads = fit([["id": 0, "crashed": true, "current": true, "stacktrace": StackBuilder.stacktrace(frames)]])
        } else {
            // The crashed thread with the full exception stack (the threads section keeps 100 frames).
            let samples = r.threads.map { t -> ThreadSample in
                var t = t
                if t.crashed && !r.frames.isEmpty { t.frames = r.frames }
                return t
            }
            let (threads, threadImages) = Self.threads(samples, stack: stack, resolve: resolve, symbol: symbol)
            draft.threads = threads
            draft.images = merge(images, threadImages)
        }
        return draft
    }

    /// The `error` event for an app hang: the main thread's stack as the
    /// exception; main is the hung (`crashed`) thread, listed first (the
    /// watchdog that sampled it is not listed).
    static func hangDraft(_ samples: [ThreadSample], threshold: TimeInterval, stack: StackBuilder) -> EventDraft {
        let ordered = samples.map { s -> ThreadSample in
            var s = s
            s.crashed = s.isMain
            s.current = false
            return s
        }
        let resolve: (UInt64) -> DebugImage? = { DebugImageCache.shared.image(containing: $0) }
        let main = ordered.first { $0.isMain }?.frames ?? []
        let (frames, images) = stack.frames(main, firstIsPC: true, resolve: resolve)
        let ms = Int(threshold * 1000)
        let value = StackBuilder.exceptionValue(
            type: "App Hanging", value: "App hanging for at least \(ms) ms.", module: nil, mechanism: "app_hang",
            handled: false, frames: frames)
        var d = EventDraft(level: .error, exceptionValues: [value], images: images)
        let (threads, threadImages) = Self.threads(ordered, stack: stack, resolve: resolve)
        d.threads = threads
        d.images = merge(images, threadImages)
        return d
    }

    static func merge(_ a: [DebugImage], _ b: [DebugImage]) -> [DebugImage] {
        var byId: [String: DebugImage] = [:]
        for image in a + b { byId[image.debugId] = image }
        return byId.values.sorted { $0.loadAddress < $1.loadAddress }
    }
}
