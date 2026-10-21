import Foundation

/// Seeded, thread-safe random number generator (SplitMix64). The session
/// seed is recorded in `manifest.session.seed` and restored in replay, so
/// randomness drawn through `BugCapsule.random` replays identically.
public final class BugCapsuleRandom: RandomNumberGenerator, @unchecked Sendable {
    private var state: UInt64
    private let lock = NSLock()
    public let seed: Int

    public init(seed: Int) {
        self.seed = seed
        state = UInt64(bitPattern: Int64(seed)) &+ 0x9E37_79B9_7F4A_7C15
    }

    public func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in `0..<upperBound`.
    public func nextInt(_ upperBound: Int) -> Int {
        precondition(upperBound > 0)
        var g: any RandomNumberGenerator = self
        return Int.random(in: 0..<upperBound, using: &g)
    }

    /// A value in `[0, 1)`.
    public func nextDouble() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    public func nextBool() -> Bool { next() & 1 == 1 }

    /// A random session seed in `[0, 2^32)` (same range as the Dart SDK).
    static func newSeed() -> Int { Int(UInt32.random(in: .min ... .max)) }
}

/// RFC 4122 version 4 UUID, lower-case.
func uuidV4() -> String { UUID().uuidString.lowercased() }

/// Monotonic seconds (`ProcessInfo.systemUptime`, runtimes-v1 §3).
func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

func epochMs(_ date: Date = Date()) -> Int { Int((date.timeIntervalSince1970 * 1000).rounded(.down)) }
