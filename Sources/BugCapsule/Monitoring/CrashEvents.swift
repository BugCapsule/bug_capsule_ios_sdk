import Foundation

/// `event.threads` (monitoring-v1 §2) and the events built from native
/// crash reports and hang samples, shared by monitoring and
/// `BugCapsuleCrashBridge`.
enum CrashEvents {
    static let maxThreads = 100
    static let maxThreadFrames = 100
    /// The backend accepts up to 512 KiB of `threads` JSON.
    static let maxThreadsBytes = 448 * 1024

    /// `threads` for [samples] (frames oldest first, as in `exception`) and
    /// the images their frames use. Main is named `main` when unnamed.
    static func threads(
        _ samples: [ThreadSample], stack: StackBuilder, resolve: (UInt64) -> DebugImage?,
        symbol: (UInt64, DebugImage) -> String? = { a, _ in Symbolicator.function(at: a) }
    ) -> (threads: [JSONValue], images: [DebugImage]) {
        var out: [JSONValue] = []
        var used: [String: DebugImage] = [:]
        for sample in samples.prefix(maxThreads) {
            let (frames, images) = stack.frames(
                Array(sample.frames.prefix(maxThreadFrames)), firstIsPC: true, resolve: resolve, symbol: symbol)
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

    /// Keeps [threads] under [maxBytes]: other threads lose their oldest
    /// frames first, then the last of them are dropped; the crashed or
    /// current thread is cut last.
    static func fit(_ threads: [JSONValue], maxBytes: Int = maxThreadsBytes) -> [JSONValue] {
        func size(_ t: [JSONValue]) -> Int { JSON.encodeData(.array(t)).count }
        func isKey(_ t: JSONValue) -> Bool { t["crashed"]?.boolValue == true || t["current"]?.boolValue == true }
        func keepingInnermost(_ t: JSONValue, _ n: Int) -> JSONValue {
            guard var o = t.objectValue, let frames = o["stacktrace"]?["frames"]?.arrayValue, frames.count > n else { return t }
            o["stacktrace"] = StackBuilder.stacktrace(Array(frames.suffix(n)))
            return .object(o)
        }
        var out = threads
        guard size(out) > maxBytes else { return out }
        var limit = maxThreadFrames / 2
        while size(out) > maxBytes && limit >= 8 {
            out = out.map { isKey($0) ? $0 : keepingInnermost($0, limit) }
            limit /= 2
        }
        while size(out) > maxBytes, let i = out.lastIndex(where: { !isKey($0) }) { out.remove(at: i) }
        limit = maxThreadFrames / 2
        while size(out) > maxBytes && limit >= 1 {
            out = out.map { keepingInnermost($0, limit) }
            limit /= 2
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
            draft.threads = [["id": 0, "crashed": true, "current": true, "stacktrace": StackBuilder.stacktrace(frames)]]
        } else {
            let (threads, threadImages) = Self.threads(r.threads, stack: stack, resolve: resolve, symbol: symbol)
            draft.threads = threads
            draft.images = merge(images, threadImages)
        }
        return draft
    }

    /// The `error` event for an app hang: the main thread's stack as the
    /// exception, main first among the threads.
    static func hangDraft(_ samples: [ThreadSample], threshold: TimeInterval, stack: StackBuilder) -> EventDraft {
        var ordered = samples.filter(\.isMain) + samples.filter { !$0.isMain }
        if !ordered.isEmpty && ordered[0].isMain { ordered[0].current = true }
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
