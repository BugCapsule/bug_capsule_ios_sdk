import Foundation

/// File helpers that never throw into the app: atomic writes (temp file +
/// rename), quiet deletes, cleanup of temp files left by an interrupted write.
enum FileIO {
    static var fm: FileManager { FileManager.default }

    static func writeAtomically(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).\(UInt64(Date().timeIntervalSince1970 * 1_000_000)).tmp")
        do {
            try data.write(to: tmp, options: [])
            let handle = try FileHandle(forWritingTo: tmp)
            try? handle.synchronize()
            try? handle.close()
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            try fm.moveItem(at: tmp, to: url)
        } catch {
            deleteQuietly(tmp)
            throw error
        }
    }

    static func deleteQuietly(_ url: URL) {
        try? fm.removeItem(at: url)
    }

    static func removeTemporaryFiles(in dir: URL) {
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in items where url.pathExtension == "tmp" { deleteQuietly(url) }
    }

    static func ensureDirectory(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func modified(_ url: URL) -> Date {
        ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
            ?? Date(timeIntervalSince1970: 0)
    }

    static func size(_ url: URL) -> Int {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0
    }
}

/// On-device files: saved capsules (the newest 20) and the cached remote
/// config, under `Application Support/bugcapsule` (excluded from backup).
/// Uploads go through `UploadOutbox` (`bugcapsule/outbox`).
public final class CapsuleStore: @unchecked Sendable {
    public static let maxSavedCaptures = 20
    public let root: URL
    private let lock = NSLock()

    public static func defaultRoot() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("bugcapsule", isDirectory: true)
    }

    /// Opens (creating) the store and removes temp files left by a crash.
    public init(root: URL) throws {
        self.root = root
        try FileIO.ensureDirectory(capturesDirectory)
        try FileIO.ensureDirectory(outboxDirectory)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var r = root
        try? r.setResourceValues(values)
        FileIO.removeTemporaryFiles(in: capturesDirectory)
        FileIO.removeTemporaryFiles(in: root)
    }

    public var capturesDirectory: URL { root.appendingPathComponent("captures", isDirectory: true) }
    public var outboxDirectory: URL { root.appendingPathComponent("outbox", isDirectory: true) }
    var configFile: URL { root.appendingPathComponent("remote_config.json") }

    /// Saves atomically and keeps the newest `maxSavedCaptures`.
    @discardableResult
    public func save(capsuleId: String, bytes: Data) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        let url = capturesDirectory.appendingPathComponent("\(capsuleId).bugcapsule")
        try FileIO.writeAtomically(bytes, to: url)
        for old in savedCapturesLocked().dropFirst(Self.maxSavedCaptures) { FileIO.deleteQuietly(old) }
        return url
    }

    /// Newest first.
    public func savedCaptures() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return savedCapturesLocked()
    }

    private func savedCapturesLocked() -> [URL] {
        let items = (try? FileIO.fm.contentsOfDirectory(at: capturesDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return items.filter { $0.pathExtension == "bugcapsule" }.sorted { FileIO.modified($0) > FileIO.modified($1) }
    }

    /// Kill switch: nothing captured before it may leave the device later.
    public func clearSavedCaptures() {
        lock.lock()
        defer { lock.unlock() }
        for f in savedCapturesLocked() { FileIO.deleteQuietly(f) }
    }

    lazy var configCache: RemoteConfigCache = FileConfigCache(file: configFile)
}

struct FileConfigCache: RemoteConfigCache {
    let file: URL

    func read(scope: String) -> RemoteCaptureConfig? {
        guard let data = try? Data(contentsOf: file), let json = try? JSON.parse(data),
            json["scope"]?.stringValue == scope, let config = json["config"]?.objectValue
        else { return nil }
        return try? RemoteCaptureConfig(json: config)
    }

    func write(scope: String, config: RemoteCaptureConfig) throws {
        let doc: JSONValue = ["scope": .string(scope), "config": config.json]
        try FileIO.writeAtomically(JSON.encodeData(doc), to: file)
    }
}

public struct OutboxEntry: Sendable {
    public let file: URL
    public let capsuleId: String
    public let enqueuedAt: Date
    public let size: Int
}

/// Capsules waiting for upload, as `<enqueuedAtMs>_<capsuleId>.bugcapsule`.
///
/// * Bounds: `OutboxLimits`; a capsule larger than `maxBytes` is never
///   queued, otherwise the oldest capsules are evicted first.
/// * Writes are atomic; temp files are removed on open; disk-full and other
///   I/O errors drop the capsule and never reach the app.
/// * Upload: oldest first, one at a time (flushes are serialized). A
///   retryable failure stops the pass and backs off 30 s → 1 h with ±20 %
///   jitter (or `Retry-After`); rejections and corrupt files are deleted.
public actor UploadOutbox {
    public nonisolated let directory: URL
    public nonisolated let limits: OutboxLimits
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double
    private var flushing: Task<UploadResult?, Never>?
    private var closed = false
    private var failures = 0
    public private(set) var retryAt: Date?
    private var attempts: [String: Int] = [:]

    public init(
        directory: URL, limits: OutboxLimits = OutboxLimits(), now: @escaping @Sendable () -> Date = { Date() },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.directory = directory
        self.limits = limits
        self.now = now
        self.random = random
        try? FileIO.ensureDirectory(directory)
        FileIO.removeTemporaryFiles(in: directory)
    }

    /// Applies the limits (call once after opening).
    public func open() { enforceLimits() }

    public func entries() -> [OutboxEntry] { Self.entries(in: directory) }

    static func entries(in directory: URL) -> [OutboxEntry] {
        let items = (try? FileIO.fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        var out: [OutboxEntry] = []
        for url in items {
            let name = url.lastPathComponent
            guard name.hasSuffix(".bugcapsule") else { continue }
            let stem = String(name.dropLast(".bugcapsule".count))
            var at: Date
            var id = stem
            if let us = stem.firstIndex(of: "_"), let ms = Int64(stem[..<us]) {
                at = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
                id = String(stem[stem.index(after: us)...])
            } else {
                at = FileIO.modified(url)
            }
            guard !id.isEmpty, id.count <= 100, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
            else { continue }
            out.append(OutboxEntry(file: url, capsuleId: id, enqueuedAt: at, size: FileIO.size(url)))
        }
        return out.sorted { $0.enqueuedAt < $1.enqueuedAt }
    }

    /// Synchronous write used by the crash handler (no actor hop: the
    /// process is about to die). Limits are enforced on the next open.
    @discardableResult
    nonisolated static func writeSynchronously(directory: URL, capsuleId: String, bytes: Data, now: Date = Date()) -> Bool {
        do {
            try FileIO.ensureDirectory(directory)
            let url = directory.appendingPathComponent("\(Int64(now.timeIntervalSince1970 * 1000))_\(capsuleId).bugcapsule")
            try FileIO.writeAtomically(bytes, to: url)
            return true
        } catch {
            return false
        }
    }

    /// Queues a capsule. False when not queued (closed, too large, I/O error).
    public func enqueue(capsuleId: String, bytes: Data) -> Bool {
        if closed || bytes.count > limits.maxBytes { return false }
        let url = directory.appendingPathComponent("\(Int64(now().timeIntervalSince1970 * 1000))_\(capsuleId).bugcapsule")
        do {
            try FileIO.writeAtomically(bytes, to: url)
        } catch {
            BugCapsuleLog.warn("could not queue capsule \(capsuleId): \(error.localizedDescription)")
            return false
        }
        enforceLimits()
        return FileIO.fm.fileExists(atPath: url.path)
    }

    private func enforceLimits() {
        let all = entries()
        let cutoff = now().addingTimeInterval(-limits.maxAge)
        var count = all.count
        var bytes = all.reduce(0) { $0 + $1.size }
        for e in all {
            let expired = e.enqueuedAt < cutoff
            if !expired && count <= limits.maxCount && bytes <= limits.maxBytes { continue }
            FileIO.deleteQuietly(e.file)
            count -= 1
            bytes -= e.size
        }
    }

    /// Deletes every queued capsule (kill switch). Returns how many.
    @discardableResult
    public func purge() -> Int {
        let all = entries()
        for e in all { FileIO.deleteQuietly(e.file) }
        return all.count
    }

    /// Uploads queued capsules oldest first while `allowed` holds. Returns
    /// the result for `onlyId` when given.
    public func flush(
        upload: @escaping @Sendable (Data) async -> UploadResult, allowed: @escaping @Sendable () async -> Bool,
        onlyId: String? = nil
    ) async -> UploadResult? {
        while let running = flushing { _ = await running.value }
        let task = Task { await self.flushOnce(upload: upload, allowed: allowed, onlyId: onlyId) }
        flushing = task
        let result = await task.value
        flushing = nil
        return result
    }

    private func flushOnce(
        upload: @Sendable (Data) async -> UploadResult, allowed: @Sendable () async -> Bool, onlyId: String?
    ) async -> UploadResult? {
        var mine: UploadResult?
        if let retryAt, now() < retryAt {
            return onlyId == nil ? nil : UploadResult(.retryLater, message: "queued")
        }
        // Stable: oldest first among entries with the same failure count.
        let queue = entries().enumerated().sorted { a, b in
            let fa = attempts[a.element.capsuleId] ?? 0
            let fb = attempts[b.element.capsuleId] ?? 0
            return fa != fb ? fa < fb : a.offset < b.offset
        }.map(\.element)
        for entry in queue {
            if closed { break }
            if !(await allowed()) { break }
            guard let bytes = try? Data(contentsOf: entry.file) else { continue }
            if !Gzip.isGzip(bytes) {
                BugCapsuleLog.warn("dropping corrupt queued capsule \(entry.capsuleId)")
                FileIO.deleteQuietly(entry.file)
                continue
            }
            let result = await upload(bytes)
            if entry.capsuleId == onlyId { mine = result }
            if result.status == .retryLater {
                attempts[entry.capsuleId, default: 0] += 1
                failures += 1
                var delay = min(30 * pow(2, Double(min(failures - 1, 7))), 3600)
                if let after = result.retryAfter, after > delay { delay = after }
                retryAt = now().addingTimeInterval(delay * (0.8 + random() * 0.4))
                break
            }
            failures = 0
            retryAt = nil
            attempts[entry.capsuleId] = nil
            if result.status == .rejected {
                BugCapsuleLog.warn("upload of \(entry.capsuleId) rejected: \(result.message ?? "")")
            }
            FileIO.deleteQuietly(entry.file)
        }
        if onlyId != nil && mine == nil { mine = UploadResult(.retryLater, message: "queued") }
        return mine
    }

    /// Stops after the current upload; later enqueues are refused.
    public func close() async {
        closed = true
        if let running = flushing { _ = await running.value }
    }
}

enum BugCapsuleLog {
    static func info(_ message: String) { NSLog("[bugcapsule] %@", message) }
    static func warn(_ message: String) { NSLog("[bugcapsule] %@", message) }
}
