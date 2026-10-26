import Foundation

#if canImport(UIKit)
    import QuartzCore
    import UIKit
#endif

/// Slow / frozen frame counters (CADisplayLink) and next-frame callbacks
/// for TTID and app start. Without UIKit, "next frame" is the next main
/// queue turn and nothing is counted.
final class FramesTracker: @unchecked Sendable {
    struct Counts: Sendable, Equatable {
        var total = 0
        var slow = 0
        var frozen = 0
        /// Seconds frames were late in total.
        var delay: Double = 0

        func minus(_ o: Counts) -> Counts {
            Counts(total: total - o.total, slow: slow - o.slow, frozen: frozen - o.frozen, delay: max(delay - o.delay, 0))
        }
    }

    static let frozenThreshold: TimeInterval = 0.7

    private let lock = NSLock()
    private var _counts = Counts()
    private var counting = false
    private var running = false
    private var callbacks: [@Sendable () -> Void] = []
    private var lastTimestamp: CFTimeInterval?
    #if canImport(UIKit)
        // Main thread only.
        nonisolated(unsafe) private var link: CADisplayLink?
    #endif

    var counts: Counts { lock.locked { _counts } }
    var isCounting: Bool { lock.locked { counting && running } }

    /// Classifies one frame of [duration] when [expected] was the refresh interval.
    func record(duration: TimeInterval, expected: TimeInterval) {
        lock.locked {
            _counts.total += 1
            if duration >= Self.frozenThreshold {
                _counts.frozen += 1
                _counts.delay += duration - expected
            } else if expected > 0 && duration > expected * 1.5 {
                _counts.slow += 1
                _counts.delay += duration - expected
            }
        }
    }

    @MainActor
    func start(counting: Bool) {
        lock.locked {
            self.counting = counting
            running = true
        }
        #if canImport(UIKit)
            guard link == nil else { return }
            let l = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        #endif
    }

    func stop() {
        lock.locked { running = false }
        #if canImport(UIKit)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.link?.invalidate(); self.link = nil } }
        #endif
    }

    /// Runs [body] on the main thread after the next frame is presented.
    func onNextFrame(_ body: @escaping @Sendable () -> Void) {
        #if canImport(UIKit)
            let linked = lock.locked { () -> Bool in
                guard running else { return false }
                callbacks.append(body)
                return true
            }
            if linked { return }
        #endif
        DispatchQueue.main.async { body() }
    }

    #if canImport(UIKit)
        fileprivate func tick(timestamp: CFTimeInterval, target: CFTimeInterval) {
            let (pending, previous, count) = lock.locked { () -> ([@Sendable () -> Void], CFTimeInterval?, Bool) in
                let p = callbacks
                callbacks = []
                let prev = lastTimestamp
                lastTimestamp = timestamp
                return (p, prev, counting && running)
            }
            if count, let previous {
                record(duration: timestamp - previous, expected: max(target - timestamp, 0.001))
            }
            for cb in pending { cb() }
        }

        private final class DisplayLinkTarget: NSObject {
            weak var owner: FramesTracker?
            init(_ owner: FramesTracker) { self.owner = owner }
            @objc func tick(_ link: CADisplayLink) {
                owner?.tick(timestamp: link.timestamp, target: link.targetTimestamp)
            }
        }
    #endif
}

/// App hang watchdog (monitoring-v1 §11, 2 s on iOS): pings the main queue
/// from a background thread; when the ping waits longer than the threshold
/// while in the foreground, every thread's stack is sampled (main first)
/// and reported once per hang.
final class AppHangTracker: @unchecked Sendable {
    let threshold: TimeInterval
    private let mainThread: UInt32
    private let isForeground: @Sendable () -> Bool
    private let onHang: @Sendable ([ThreadSample]) -> Void
    private let lock = NSLock()
    private var running = false

    init(
        threshold: TimeInterval, mainThread: UInt32, isForeground: @escaping @Sendable () -> Bool,
        onHang: @escaping @Sendable ([ThreadSample]) -> Void
    ) {
        self.threshold = threshold
        self.mainThread = mainThread
        self.isForeground = isForeground
        self.onHang = onHang
    }

    var isRunning: Bool { lock.locked { running } }

    func start() {
        lock.locked { running = true }
        let thread = Thread { [self] in loop() }
        thread.name = "com.bugcapsule.app-hang"
        thread.qualityOfService = .utility
        thread.start()
    }

    func stop() { lock.locked { running = false } }

    /// All threads; main sampled on its own when the sampler missed it.
    private func sample() -> [ThreadSample] {
        var samples = NativeCrashHandler.sampleThreads()
        if !samples.contains(where: { $0.isMain }) {
            samples.insert(
                ThreadSample(
                    index: 0, name: "main", crashed: false, current: true, isMain: true,
                    frames: NativeCrashHandler.backtrace(ofThread: mainThread)), at: 0)
        }
        return samples
    }

    private func loop() {
        while isRunning {
            if !isForeground() {
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            let responded = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { responded.signal() }
            if responded.wait(timeout: .now() + threshold) == .timedOut {
                if isRunning && isForeground() {
                    onHang(sample())
                }
                // One report per hang: wait for the main thread to come back.
                responded.wait()
            }
            Thread.sleep(forTimeInterval: min(0.5, threshold / 2))
        }
    }
}
