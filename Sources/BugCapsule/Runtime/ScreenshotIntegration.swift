import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Explicit, opt-in diagnostic frames. The provider must mask secrets BEFORE returning PNG bytes;
/// return nil on sensitive screens. Invoke capture after rendering, before writing a capsule.
/// No timer, crash-handler UI work or replay input. All budgets are per session.
public final class ScreenshotIntegration: BugCapsuleIntegration, @unchecked Sendable {
    public let name = "screenshots"
    private let enabled: Bool
    private let minIntervalMs: Int
    private let maxFrames: Int
    private let maxFrameBytes: Int
    private let maxTotalBytes: Int
    private let captureRedactedPng: @MainActor @Sendable () throws -> Data?
    @MainActor private weak var session: BugCapsuleSession?
    @MainActor private var last: Int?
    @MainActor private var count = 0
    @MainActor private var bytes = 0
    @MainActor private var busy = false

    public init(enabled: Bool = false, minIntervalMs: Int = 1000, maxFrames: Int = 20,
                maxFrameBytes: Int = 262144, maxTotalBytes: Int = 2097152,
                captureRedactedPng: @escaping @MainActor @Sendable () throws -> Data?) {
        self.enabled = enabled
        self.minIntervalMs = max(1000, minIntervalMs)
        self.maxFrames = max(1, min(20, maxFrames))
        self.maxFrameBytes = max(1, min(262144, maxFrameBytes))
        self.maxTotalBytes = max(1, min(2097152, maxTotalBytes))
        self.captureRedactedPng = captureRedactedPng
    }

    public func setUp(_ session: BugCapsuleSession) {
        onMainSync { self.session = session; last = nil; count = 0; bytes = 0 }
    }

    @MainActor @discardableResult public func capture() -> Bool {
        guard enabled, let s = session, s.isRecording, !s.isReplaying, !busy,
              count < maxFrames, bytes < maxTotalBytes else { return false }
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState == .active else { return false }
        #endif
        let t = s.now()
        if let last, t - last < minIntervalMs { return false }
        last = t; busy = true
        defer { busy = false }
        do {
            guard let png = try captureRedactedPng(), s.isRecording, !s.isReplaying,
                  png.count >= 24, png.count <= maxFrameBytes, bytes + png.count <= maxTotalBytes else { return false }
            let raw = [UInt8](png)
            guard Array(raw.prefix(8)) == [137,80,78,71,13,10,26,10] else { return false }
            func intAt(_ i: Int) -> Int { (0..<4).reduce(0) { ($0 << 8) | Int(raw[i + $1]) } }
            let width = intAt(16), height = intAt(20)
            guard (1...2048).contains(width), (1...2048).contains(height) else { return false }
            func kindAt(_ i: Int) -> String { String(bytes: raw[(i+4)..<(i+8)], encoding: .ascii) ?? "" }
            guard intAt(8) == 13, kindAt(8) == "IHDR" else { return false }
            var pos = 8, hasData = false, ended = false
            let allowed = ["IHDR", "PLTE", "tRNS", "IDAT", "IEND", "sRGB", "gAMA", "cHRM", "pHYs", "sBIT"]
            while pos + 12 <= raw.count {
                let size = intAt(pos), kind = kindAt(pos)
                guard size <= raw.count - pos - 12, allowed.contains(kind) else { return false }
                if kind == "IDAT" { hasData = true }
                pos += size + 12
                if kind == "IEND" { guard size == 0 else { return false }; ended = true; break }
            }
            guard hasData, ended, pos == raw.count else { return false }
            s.record("screenshot", ["schema": .int(1), "mimeType": .string("image/png"), "privacy": .string("reviewed"),
                "capturedAtT": .int(t), "width": .int(width), "height": .int(height), "base64": .string(png.base64EncodedString())])
            count += 1; bytes += png.count
            return true
        } catch { return false }
    }

    #if canImport(UIKit)
    /// Encodes an application-owned, already redacted raster. Does not capture windows or secure fields.
    @MainActor public static func pngFromRedactedImage(_ image: UIImage) -> Data? {
        guard let cg = image.cgImage, (1...2048).contains(cg.width), (1...2048).contains(cg.height),
              let data = image.pngData(), data.count <= 262144 else { return nil }
        let raw = [UInt8](data)
        var out = Data(raw.prefix(8)), pos = 8
        let allowed = ["IHDR", "PLTE", "tRNS", "IDAT", "IEND", "sRGB", "gAMA", "cHRM", "pHYs", "sBIT"]
        while pos + 12 <= raw.count {
            let size = (0..<4).reduce(0) { ($0 << 8) | Int(raw[pos + $1]) }
            guard size <= raw.count - pos - 12 else { return nil }
            let kind = String(bytes: raw[(pos+4)..<(pos+8)], encoding: .ascii) ?? ""
            let end = pos + size + 12
            if allowed.contains(kind) { out.append(contentsOf: raw[pos..<end]) }
            pos = end
        }
        return out
    }
    #endif
}
