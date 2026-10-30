import BugCapsulePatch
import Darwin
import Foundation
import CoreFoundation
import UIKit

/// Opt-in lab measurements; never runs in an app that lacks the request file.
enum PerformanceHarness {
    // Malformed requests still enter the benchmark validator and fail closed.
    static func enabled(exchange: URL) -> Bool {
        let file = exchange.appendingPathComponent("benchmark-config.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        guard let data = try? Data(contentsOf: file),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let value = object["enabled"] as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return true }
        return value.boolValue
    }
    static let entryNs = DispatchTime.now().uptimeNanoseconds
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func machine() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
    static func rss() -> [String: Any] {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let code = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return code == KERN_SUCCESS ? ["residentBytes": info.resident_size, "processMaxResidentBytes": info.resident_size_max] : ["error": code]
    }
    static func summary(_ values: [UInt64]) -> [String: Any] {
        let sorted = values.sorted()
        func p(_ n: Int) -> UInt64 { sorted[max(0, (sorted.count * n + 99) / 100 - 1)] }
        return ["samplesNs": values, "p50Ns": p(50), "p95Ns": p(95), "p99Ns": p(99), "maxNs": sorted.last!]
    }
    static func write(_ record: [String: Any], exchange: URL) {
        do {
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted])
            try data.write(to: exchange.appendingPathComponent("benchmark-result.json"), options: .atomic)
        } catch { print("benchmark result write failed: \(error)") }
    }
    static func firstFrame(exchange: URL) {
        guard enabled(exchange: exchange) else { return }
        let file = exchange.appendingPathComponent("benchmark-result.json")
        guard let data = try? Data(contentsOf: file),
              var record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              record["appCodeToFirstAppearanceNs"] == nil else { return }
        record["appCodeToFirstAppearanceNs"] = now() - entryNs
        record["rssAtFirstAppearance"] = rss()
        write(record, exchange: exchange)
    }
    struct Result<T> { let value: T; let patch: BugCapsulePatch?; let source: String; let firstNs: UInt64 }
    static func run<I, O>(exchange: URL, module: PatchModule<I, O>, input: I,
                          open: () -> BugCapsulePatch, output: (O) -> [String: String]) throws -> Result<O> {
        let request = try JSONSerialization.jsonObject(with: Data(contentsOf: exchange.appendingPathComponent("benchmark-config.json"))) as? [String: Any]
        guard let request, let mode = request["mode"] as? String, ["baseline", "runtime"].contains(mode),
              let expected = request["expectedOutput"] as? [String: String],
              let expectedSource = request["expectedSource"] as? String,
              let runId = request["runId"] as? String, !runId.isEmpty else {
            throw NSError(domain: "benchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "mode, runId, expectedOutput and expectedSource are required"])
        }
        let startupFlag = request["startupOnly"] as? NSNumber
        let startupOnly = startupFlag.map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
        #if targetEnvironment(simulator)
        let physical = false
        #else
        let physical = true
        #endif
        #if DEBUG
        let buildMode = "debug"
        #else
        let buildMode = "release"
        #endif
        var record: [String: Any] = ["schemaVersion": 1, "runId": runId, "mode": mode, "runtime": "native_ios",
            "at": ISO8601DateFormatter().string(from: Date()), "physicalDevice": physical, "buildMode": buildMode,
            "deviceModel": UIDevice.current.model, "machine": machine(), "osVersion": UIDevice.current.systemVersion,
            "bundleId": Bundle.main.bundleIdentifier ?? "unknown", "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown",
            "thermalStateBefore": ProcessInfo.processInfo.thermalState.rawValue, "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "scope": startupOnly ? "startup_probe" : "evaluation_samples",
            "warmupCount": startupOnly ? 0 : 20, "sampleCount": startupOnly ? 0 : 200, "rssBeforeOpen": rss(), "latencyVerdict": "not_configured",
            "measurementScope": "first call is first in process, not guaranteed cold filesystem; residentBytes are snapshots; processMaxResidentBytes is process-lifetime high-water, not runtime allocation delta or app budget; first-appearance callback interval starts in app code, not process launch or display presentation"]
        let start = now()
        let patch = mode == "runtime" ? open() : nil
        if mode == "runtime" { record["runtimeOpenNs"] = now() - start }
        else { record["runtimeOpenNs"] = NSNull() }
        record["rssAfterOpen"] = rss()
        record["statusBefore"] = patch.flatMap { try? $0.status() } ?? [:]
        var reasons: [String: Int] = [:]
        func evaluate() throws -> (O, UInt64, String) {
            let before = now()
            let value: O
            let source: String
            let reason: String?
            if let patch {
                let r = patch.call(module, input)
                value = r.value; source = r.source.rawValue; reason = r.reason
            } else {
                value = module.fallback(input); source = "direct_bundled"; reason = nil
            }
            let elapsed = now() - before
            guard source == expectedSource && output(value) == expected else {
                throw NSError(domain: "benchmark", code: 2, userInfo: [NSLocalizedDescriptionKey: "unexpected source/output: \(source) \(output(value))"])
            }
            if let allowed = request["expectedReasons"] as? [String], !allowed.contains(reason ?? "none") {
                throw NSError(domain: "benchmark", code: 3, userInfo: [NSLocalizedDescriptionKey: "unexpected fallback reason: \(reason ?? "none")"])
            }
            reasons[reason ?? "none", default: 0] += 1
            return (value, elapsed, source)
        }
        do {
            if let patch, !patch.available {
                throw NSError(domain: "benchmark", code: 4, userInfo: [NSLocalizedDescriptionKey: "runtime unavailable"])
            }
            let first = try evaluate()
            record["firstCallNs"] = first.1
            for _ in 0..<(startupOnly ? 0 : 20) { _ = try evaluate() }
            var samples: [UInt64] = []
            for _ in 0..<(startupOnly ? 0 : 200) { samples.append(try evaluate().1) }
            if !startupOnly { record["evaluation"] = summary(samples) }
            record["output"] = expected; record["source"] = first.2; record["reasonCounts"] = reasons
            record["rssAfterEvaluation"] = rss()
            if let patch {
                let before = now()
                do { _ = try patch.markHealthy("benchmark_output_verified"); record["markHealthyNs"] = now() - before }
                catch { record["markHealthyError"] = "\(error)" }
                record["statusAfter"] = (try? patch.status()) ?? [:]
            }
            record["thermalStateAfter"] = ProcessInfo.processInfo.thermalState.rawValue
            record["correctness"] = "passed"
            if !startupOnly, let budgets = request["budgetsNs"] as? [String: NSNumber], !budgets.isEmpty {
                let stats = summary(samples)
                var comparisons: [String: Any] = [:]
                for key in ["p50Ns", "p95Ns", "p99Ns", "maxNs"] {
                    if let budget = budgets[key], budget.doubleValue > 0, let measured = stats[key] as? UInt64 {
                        comparisons[key] = ["limitNs": budget, "measuredNs": measured, "passed": measured <= budget.uint64Value]
                    }
                }
                record["budgetComparisons"] = comparisons
                record["latencyVerdict"] = comparisons.isEmpty ? "not_configured" : "see_user_limits"
            }
            write(record, exchange: exchange)
            return Result(value: first.0, patch: patch, source: first.2, firstNs: first.1)
        } catch {
            record["correctness"] = "failed"; record["error"] = "\(error)"; record["reasonCounts"] = reasons
            write(record, exchange: exchange)
            throw error
        }
    }
}

/// Lab-only instrumentation around the real transport; no endpoints or secrets.
actor TimedPatchTransport: PatchTransport {
    struct Fetch: Sendable {
        let elapsedNs: UInt64
        let receivedBytes: Int?
        var record: [String: Any] {
            var result: [String: Any] = ["elapsedNs": elapsedNs, "completed": receivedBytes != nil]
            if let receivedBytes { result["receivedBytes"] = receivedBytes }
            return result
        }
    }
    private let inner: any PatchTransport
    private var fetches: [Fetch] = []
    init(_ inner: any PatchTransport) { self.inner = inner }
    func measurements() -> [Fetch] { fetches }
    func fetchChannel(etag: String?) async throws -> SignedChannel? {
        try await inner.fetchChannel(etag: etag)
    }
    func postReceipts(_ batch: Data) async throws { try await inner.postReceipts(batch) }
    func fetchArtifact(digest: String) async throws -> Data {
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let bytes = try await inner.fetchArtifact(digest: digest)
            fetches.append(Fetch(elapsedNs: DispatchTime.now().uptimeNanoseconds - start, receivedBytes: bytes.count))
            return bytes
        } catch {
            fetches.append(Fetch(elapsedNs: DispatchTime.now().uptimeNanoseconds - start, receivedBytes: nil))
            throw error
        }
    }
}
