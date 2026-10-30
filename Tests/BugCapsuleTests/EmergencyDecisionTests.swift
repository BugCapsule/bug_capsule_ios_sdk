import Foundation
import XCTest

@testable import BugCapsule

private let feature = "checkout.confirm_order"
private let app = "7c9e6679-7425-40de-944b-e07fc1f90ae7"

/// §7.8: the shared vectors, and the tracker on its own.
final class EmergencyDecisionTrackerTests: XCTestCase {
    private let block = EmergencyDecision(
        featureKey: feature, allowed: false, action: .block, reasonCode: "INCIDENT", documentRevision: 42, source: .policy)

    private func vectors() throws -> JSONValue {
        try loadJSON(TestPaths.fixtures.appendingPathComponent("emergency-v1/replay-decisions.json"))
    }

    func testSubjectTagVectors() throws {
        let cases = try XCTUnwrap(try vectors()["subjectTags"]?.arrayValue)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            XCTAssertEqual(emergencySubjectTag(try XCTUnwrap(c["subject"]?.stringValue)), c["tag"]?.stringValue)
        }
    }

    func testLookupVectors() throws {
        let v = try vectors()
        let events = try XCTUnwrap(v["events"]?.arrayValue).map { BugCapsuleEvent(json: $0.objectValue!) }
        let script = EmergencyDecisionScript(events: events)
        let cases = try XCTUnwrap(v["cases"]?.arrayValue)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let name = c["name"]?.stringValue ?? "?"
            let got = script.lookup(
                key: try XCTUnwrap(c["key"]?.stringValue), subjectTag: c["subject"]?.stringValue.map(emergencySubjectTag),
                t: try XCTUnwrap(c["t"]?.intValue))
            guard let expected = c["expect"]?.objectValue else {
                XCTAssertNil(got, name)
                continue
            }
            let d = try XCTUnwrap(got, name)
            XCTAssertEqual(d.source, .replay, name)
            for (field, value) in expected {
                switch field {
                case "allowed": XCTAssertEqual(d.allowed, value.boolValue, name)
                case "action": XCTAssertEqual(d.action.rawValue, value.stringValue, name)
                case "reasonCode": XCTAssertEqual(d.reasonCode, value.stringValue, name)
                case "policyId": XCTAssertEqual(d.policyId, value.stringValue, name)
                case "policyRevision": XCTAssertEqual(d.policyRevision, value.intValue, name)
                case "documentRevision": XCTAssertEqual(d.documentRevision, value.intValue, name)
                case "message": XCTAssertEqual(d.publicUserMessage, value.stringValue, name)
                case "requiredVersion": XCTAssertEqual(d.requiredVersion, value.stringValue, name)
                case "fallback": XCTAssertEqual(d.fallback, value.stringValue, name)
                case "fallbackAvailable": XCTAssertEqual(d.fallbackAvailable, value.boolValue, name)
                default: XCTFail("\(name): unknown field \(field)")
                }
            }
        }
    }

    func testAnEntryNeverBlocksForAnUnknownAction() {
        let script = EmergencyDecisionScript(events: [
            BugCapsuleEvent(seq: 1, t: 0, type: EventTypes.emergencyDecision, data: ["key": "a.b", "action": "FUTURE"]),
            BugCapsuleEvent(seq: 2, t: 0, type: EventTypes.emergencyDecision, data: ["key": "a.b"]),
            BugCapsuleEvent(seq: 3, t: 0, type: EventTypes.emergencyDecision, data: ["key": 7, "action": "BLOCK"]),
            BugCapsuleEvent(seq: 4, t: 0, type: "emergency.other", data: ["key": "a.b", "action": "BLOCK"]),
        ])
        XCTAssertNil(script.lookup(key: "a.b", subjectTag: nil, t: 10))
    }

    func testIdleCompressionIgnoresDecisions() {
        let inputs = [
            BugCapsuleEvent(seq: 1, t: 1000, type: EventTypes.action, data: ["id": "a"]),
            BugCapsuleEvent(seq: 2, t: 301_000, type: EventTypes.action, data: ["id": "b"]),
        ]
        let rewrites = stride(from: 30_000, to: 301_000, by: 30_000).enumerated().map { i, t in
            BugCapsuleEvent(seq: 10 + i, t: t, type: EventTypes.emergencyDecision, data: ["key": "a.b", "action": "BLOCK"])
        }
        let plain = IdleCompressor(events: inputs).idleSince(from: 1000, to: 301_000)
        XCTAssertEqual(plain, 1000)
        XCTAssertEqual(IdleCompressor(events: inputs + rewrites).idleSince(from: 1000, to: 301_000), plain)
        // Anything else in the gap still counts.
        let log = BugCapsuleEvent(seq: 3, t: 200_000, type: EventTypes.log, data: ["message": "m"])
        XCTAssertEqual(IdleCompressor(events: inputs + rewrites + [log]).idleSince(from: 1000, to: 301_000), 200_000)
    }

    func testWritesADecisionOnlyWhenItChanges() {
        let t = EmergencyDecisionTracker()
        let pair = EmergencyDecisionTracker.Pair(key: feature, tag: nil)
        XCTAssertEqual(t.track(block, subject: nil), .changed(pair))
        XCTAssertEqual(t.track(block, subject: nil), .unchanged)
        var next = block
        next.documentRevision = 43
        XCTAssertEqual(t.track(next, subject: nil), .changed(pair), "any field is a change")
        next.source = .stalePolicy
        XCTAssertEqual(t.track(next, subject: nil), .changed(pair))
        XCTAssertEqual(t.latest(of: pair), next)
        XCTAssertEqual(t.pairs, [pair])
    }

    func testSubjectsAreTrackedApartAndNeverWritten() throws {
        let t = EmergencyDecisionTracker()
        guard case .changed(let a) = t.track(block, subject: "user-1") else { return XCTFail("not written") }
        XCTAssertEqual(a.tag, "748982dd71b97baf")
        XCTAssertNotEqual(t.track(block, subject: "user-2"), .unchanged)
        XCTAssertEqual(t.track(block, subject: "user-1"), .unchanged)
        XCTAssertEqual(t.pairs.count, 2)
        let data = EmergencyDecisionTracker.eventData(block, tag: a.tag)
        XCTAssertEqual(data["subject"], "748982dd71b97baf")
        XCTAssertFalse(JSON.encode(.object(data)).contains("user-1"))
    }

    func testEventDataMatchesTheContract() {
        let d = EmergencyDecision(
            featureKey: "feed.home", allowed: false, action: .useSafeFallback, reasonCode: "R", policyId: "p-1",
            policyRevision: 3, documentRevision: 4, publicUserMessage: "m", requiredVersion: "2.0.0", fallback: "cached",
            fallbackAvailable: true, source: .stalePolicy)
        XCTAssertEqual(
            EmergencyDecisionTracker.eventData(d, tag: "t"),
            [
                "key": "feed.home", "subject": "t", "action": "USE_SAFE_FALLBACK", "source": "stale_policy", "reasonCode": "R",
                "policyId": "p-1", "policyRevision": 3, "documentRevision": 4, "message": "m", "requiredVersion": "2.0.0",
                "fallback": "cached", "fallbackAvailable": true,
            ])
        let allow = EmergencyDecision(featureKey: "a.b", allowed: true, action: .allow, source: .policy)
        XCTAssertEqual(EmergencyDecisionTracker.eventData(allow, tag: nil), ["key": "a.b", "action": "ALLOW", "source": "policy"])
    }

    func testPastTheLimitItWritesNothingAndIsIncomplete() {
        let t = EmergencyDecisionTracker(maxPairs: 1)
        XCTAssertNotEqual(t.track(block, subject: "user-1"), .unchanged)
        XCTAssertTrue(t.complete)
        XCTAssertEqual(t.track(block, subject: "user-2"), .limitReached)
        XCTAssertFalse(t.complete)
        XCTAssertEqual(t.track(block, subject: "user-3"), .unchanged, "said once")
        XCTAssertEqual(t.pairs.count, 1)
        // A pair it already holds keeps working.
        var next = block
        next.documentRevision = 43
        XCTAssertNotEqual(t.track(next, subject: "user-1"), .unchanged)
    }

    func testTheDefaultLimitIs256Pairs() {
        let t = EmergencyDecisionTracker()
        for i in 0..<256 { XCTAssertNotEqual(t.track(block, subject: "s\(i)"), .unchanged) }
        XCTAssertTrue(t.complete)
        XCTAssertEqual(t.track(block, subject: "s256"), .limitReached)
    }

    func testTagsAreCachedSoEvaluationsDoNotHashEachTime() {
        let hashes = Counter()
        let t = EmergencyDecisionTracker(hash: {
            hashes.increment()
            return emergencySubjectTag($0)
        })
        for _ in 0..<1000 {
            _ = t.track(block, subject: "user-1")
            XCTAssertEqual(t.tag(of: "user-1"), "748982dd71b97baf")
        }
        XCTAssertEqual(hashes.value, 1)
    }

    func testTheTagCacheIsBounded() {
        let hashes = Counter()
        let t = EmergencyDecisionTracker(maxPairs: 4, hash: {
            hashes.increment()
            return $0
        })
        for i in 0..<5 { _ = t.tag(of: "s\(i)") }
        XCTAssertEqual(hashes.value, 5)
        _ = t.tag(of: "s4")
        XCTAssertEqual(hashes.value, 5, "the newest stays")
        _ = t.tag(of: "s0")
        XCTAssertEqual(hashes.value, 6, "the rest were dropped")
    }

    func testConcurrentTrackingKeepsOneEntryPerPair() {
        let t = EmergencyDecisionTracker()
        let changes = Counter()
        let block = self.block
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            for n in 0..<2000 where t.track(block, subject: "s\((i + n) % 16)") != .unchanged { changes.increment() }
        }
        XCTAssertEqual(changes.value, 16)
        XCTAssertEqual(t.pairs.count, 16)
    }
}

/// §7.8 through the real recording and replay paths: a signed document from a
/// loopback backend, a started session, capsules decoded from disk.
@MainActor
final class EmergencyDecisionCaptureTests: XCTestCase {
    var dir: URL!
    var signer: EmergencySigner!
    var backend: EmergencyTestBackend!
    var clock: TestClock!

    override func setUp() async throws {
        await BugCapsuleEmergency.shared.resetForTesting()
        await BugCapsule.resetForTesting()
        dir = tempDirectory()
        signer = EmergencySigner()
        backend = try EmergencyTestBackend(app: app)
        clock = TestClock(Date())
    }

    override func tearDown() async throws {
        backend.stop()
        await BugCapsuleEmergency.shared.resetForTesting()
        await BugCapsule.resetForTesting()
    }

    /// A real document blocking [feature], served, fetched and verified.
    func initializeGuards(
        message: String = "Temporarily unavailable.", ttl: TimeInterval = 3600, provider: (any EmergencyUpdateProvider)? = nil
    ) async {
        serve(revision: 5, message: message, ttl: ttl)
        var c = EmergencyConfiguration(
            trustAnchor: signer.anchor(app: app), backend: backend.backend, appVersion: "2.4.1", updateProvider: provider)
        let clock = self.clock!
        c.testHooks = EmergencyTestHooks(
            storageDirectory: dir.appendingPathComponent("emergency"), now: { clock.now }, autoSchedule: false,
            observeLifecycle: false)
        BugCapsule.emergency.initialize(c)
        await BugCapsule.emergency.refreshPolicies()
        XCTAssertEqual(BugCapsule.emergency.status.revision, 5)
    }

    func serve(revision: Int, message: String = "Temporarily unavailable.", ttl: TimeInterval = 3600) {
        let doc = emergencyDocument(
            app: app, revision: revision, issuedAt: clock.now, expiresAt: clock.now.addingTimeInterval(ttl),
            policies: [emergencyPolicy(id: "p-\(revision)", key: feature, message: .string(message))])
        backend.serve(signer.envelope(doc))
    }

    func start(
        maxEvents: Int = 20000, enabled: Bool = true, redactKeys: [String] = [],
        hook: (@Sendable (String, JSONObject) throws -> JSONObject?)? = nil
    ) {
        BugCapsule.start(
            BugCapsuleConfig(
                appVersion: "1.0", appBuild: "7", mode: .qa, enabled: enabled, gitSha: "abc123", gitDirty: false,
                maxEvents: maxEvents, autoCaptureOnFailure: false, redactKeys: redactKeys, beforeRecord: hook),
            overrides: BugCapsuleTestOverrides(
                storageDirectory: dir.appendingPathComponent("capture"), transport: FakeTransport(), captureSettleDelay: 0.05))
    }

    func captured() async throws -> (Capsule, String) {
        let r = await BugCapsule.capture()
        let bytes = try Data(contentsOf: try XCTUnwrap(r?.file))
        let capsule = try CapsuleCodec.decode(bytes)
        XCTAssertNil(validateCapsuleDocument(CapsuleCodec.toJSON(capsule)))
        return (capsule, String(decoding: try Gzip.decompress(bytes, maxBytes: 10_000_000), as: UTF8.self))
    }

    func decisions(_ c: Capsule) -> [BugCapsuleEvent] { c.events.filter { $0.type == EventTypes.emergencyDecision } }

    /// `header.json` of this process's crash journal, as on disk.
    func journalCapability() throws -> String? {
        let journal = try XCTUnwrap(BugCapsuleSession.current?.journalForTesting)
        journal.flushSynchronously()
        let header = try loadJSON(journal.headerFile)
        return header["capabilities"]?[emergencyDecisionsCapability]?.stringValue
    }

    // MARK: recording

    func testABlockedFeatureIsInTheCapsuleOnce() async throws {
        await initializeGuards()
        start()
        for _ in 0..<50 {
            XCTAssertEqual(BugCapsule.emergency.evaluate(featureKey: feature).action, .block)
        }
        let (c, _) = try await captured()
        let d = try XCTUnwrap(decisions(c).first)
        XCTAssertEqual(decisions(c).count, 1)
        XCTAssertEqual(
            d.data,
            [
                "key": .string(feature), "action": "BLOCK", "source": "policy", "reasonCode": "INCIDENT", "policyId": "p-5",
                "policyRevision": 1, "documentRevision": 5, "message": "Temporarily unavailable.",
            ])
        XCTAssertEqual(c.manifest.capability("emergency.decisions"), "supported")
        XCTAssertEqual(try journalCapability(), "supported")
    }

    func testADecisionMadeBeforeRecordingStartedIsWritten() async throws {
        await initializeGuards()
        XCTAssertFalse(BugCapsule.emergency.evaluate(featureKey: feature).allowed)
        start()
        _ = BugCapsule.emergency.evaluate(featureKey: feature)  // unchanged
        let (c, _) = try await captured()
        XCTAssertEqual(decisions(c).map { $0.data["action"] }, ["BLOCK"])
    }

    func testADecisionBeforeInitializeIsWrittenToo() async throws {
        XCTAssertTrue(BugCapsule.emergency.evaluate(featureKey: "feed.home").allowed)
        start()
        let (c, _) = try await captured()
        XCTAssertEqual(decisions(c).map { $0.data["source"] }, ["failure_mode"])
        XCTAssertEqual(decisions(c).first?.data["reasonCode"], "POLICY_UNAVAILABLE")
    }

    func testAChangedDecisionIsWrittenAgain() async throws {
        await initializeGuards()
        start()
        _ = BugCapsule.emergency.evaluate(featureKey: feature)
        clock.advance(1)
        serve(revision: 6)
        await BugCapsule.emergency.refreshPolicies()
        _ = BugCapsule.emergency.evaluate(featureKey: feature)
        _ = BugCapsule.emergency.evaluate(featureKey: feature)
        let (c, _) = try await captured()
        XCTAssertEqual(decisions(c).map { $0.data["documentRevision"] }, [5, 6])
    }

    func testGetPolicyIsAnEvaluationToo() async throws {
        await initializeGuards()
        start()
        XCTAssertEqual(BugCapsule.emergency.getPolicy(feature)?.policyId, "p-5")
        let (c, _) = try await captured()
        XCTAssertEqual(decisions(c).count, 1)
    }

    func testASubjectIsWrittenOnlyAsItsTag() async throws {
        await initializeGuards()
        start()
        _ = BugCapsule.emergency.evaluate(featureKey: feature, subject: "user-1")
        _ = BugCapsule.emergency.evaluate(featureKey: feature, subject: "user-2")
        _ = BugCapsule.emergency.evaluate(featureKey: feature, subject: "user-1")
        let (c, raw) = try await captured()
        XCTAssertEqual(decisions(c).map { $0.data["subject"] }, ["748982dd71b97baf", "5baa2f291d4eb976"])
        XCTAssertFalse(raw.contains("user-1"))
        XCTAssertFalse(raw.contains("user-2"))
    }

    func testAnAppWithNoGuardsSaysItRecordedNone() async throws {
        start()
        let (c, _) = try await captured()
        XCTAssertTrue(decisions(c).isEmpty)
        XCTAssertEqual(c.manifest.capability("emergency.decisions"), "supported")
    }

    func testTheEventGoesThroughRedactionAndTheHook() async throws {
        await initializeGuards(message: "Paused for token=abcdef123456")
        let seen = EventLog()
        start(hook: { type, data in
            if type == EventTypes.emergencyDecision { seen.append(data) }
            var d = data
            if type == EventTypes.emergencyDecision { d["policyId"] = "from-hook" }
            return d
        })
        _ = BugCapsule.emergency.evaluate(featureKey: feature)
        let (c, raw) = try await captured()
        XCTAssertEqual(seen.items.first?["message"], "Paused for token=[REDACTED]", "redacted before the hook")
        XCTAssertEqual(decisions(c).first?.data["message"], "Paused for token=[REDACTED]")
        XCTAssertEqual(decisions(c).first?.data["policyId"], "from-hook")
        XCTAssertFalse(raw.contains("abcdef123456"))
        XCTAssertEqual(c.manifest.capability("emergency.decisions"), "supported", "key and action are intact")
    }

    func testAKeyTheAppRedactsIsRedacted() async throws {
        await initializeGuards()
        start(redactKeys: ["reasonCode"])
        _ = BugCapsule.emergency.evaluate(featureKey: feature)
        let (c, _) = try await captured()
        XCTAssertEqual(decisions(c).first?.data["reasonCode"], "[REDACTED]")
        XCTAssertEqual(c.manifest.capability("emergency.decisions"), "supported")
    }

    func testARedactedKeyCountsAsDropped() async throws {
        await initializeGuards()
        start(redactKeys: ["key"])
        XCTAssertEqual(BugCapsule.emergency.evaluate(featureKey: feature).action, .block)
        XCTAssertEqual(try journalCapability(), "partial")
        let (c, _) = try await captured()
        XCTAssertTrue(decisions(c).isEmpty)
        XCTAssertEqual(c.manifest.capability("emergency.decisions"), "partial")
    }

    func testARedactedActionCountsAsDropped() async throws {
        await initializeGuards()
        start(redactKeys: ["action"])
        _ = BugCapsule.emergency.evaluate(featureKey: feature)
        let (c, _) = try await captured()
        XCTAssertTrue(decisions(c).isEmpty)
        XCTAssertEqual(c.manifest.capability("emergency.decisions"), "partial")
    }

    func testARedactedSubjectCountsAsDropped() async throws {
        await initializeGuards()
        start(redactKeys: ["subject"])
        _ = BugCapsule.emergency.evaluate(featureKey: feature)  // no subject: nothing to redact
        XCTAssertEqual(BugCapsule.emergency.decisionsCapability, "supported")
        _ = BugCapsule.emergency.evaluate(featureKey: feature, subject: "user-1")
        XCTAssertEqual(try journalCapability(), "partial")
        let (c, _) = try await captured()
        XCTAssertEqual(decisions(c).map { $0.data["subject"] }, [nil])
        XCTAssertEqual(c.manifest.capability("emergency.decisions"), "partial")
    }

    func testAHookThatChangesTheActionCountsAsDropped() async throws {
        await initializeGuards()
        start(hook: { type, data in
            guard type == EventTypes.emergencyDecision else { return data }
            var d = data
            d["action"] = "ALLOW"
            return d
        })
        XCTAssertEqual(BugCapsule.emergency.evaluate(featureKey: feature).action, .block)
        let (c, _) = try await captured()
        XCTAssertTrue(decisions(c).isEmpty, "a replay must not see an ALLOW the user didn't")
        XCTAssertEqual(c.manifest.capability("emergency.decisions"), "partial")
    }

    func testRemoteRedactionOfTheSubjectDropsOnlyDecisionsWithOne() async throws {
        await initializeGuards()
        start()
        _ = BugCapsule.emergency.evaluate(featureKey: feature)
        _ = BugCapsule.emergency.evaluate(featureKey: feature, subject: "user-1")
        XCTAssertEqual(try journalCapability(), "supported")
        let session = try XCTUnwrap(BugCapsuleSession.current)
        session.applyRemote(nil, RemoteCaptureConfig(redactKeys: ["subject"], fetchedAtMs: epochMs()))
        XCTAssertEqual(try journalCapability(), "partial", "the journal header follows")
        let (c, raw) = try await captured()
        XCTAssertEqual(decisions(c).map { $0.data["subject"] }, [nil])
        XCTAssertFalse(raw.contains(Redactor.placeholder))
        XCTAssertEqual(c.manifest.capability("emergency.decisions"), "partial")
    }

    func testRemoteRedactionOfOtherFieldsKeepsBufferedDecisions() async throws {
        await initializeGuards()
        start()
        _ = BugCapsule.emergency.evaluate(featureKey: feature)
        let session = try XCTUnwrap(BugCapsuleSession.current)
        session.applyRemote(nil, RemoteCaptureConfig(redactKeys: ["reasonCode"], fetchedAtMs: epochMs()))
        let (c, _) = try await captured()
        XCTAssertEqual(decisions(c).map { $0.data["reasonCode"] }, ["[REDACTED]"])
        XCTAssertEqual(c.manifest.capability("emergency.decisions"), "supported")
    }

    func testRemoteRedactionOfTheKeyDropsBufferedDecisions() async throws {
        await initializeGuards()
        start()
        _ = BugCapsule.emergency.evaluate(featureKey: feature)
        let session = try XCTUnwrap(BugCapsuleSession.current)
        session.applyRemote(nil, RemoteCaptureConfig(redactKeys: ["key"], fetchedAtMs: epochMs()))
        XCTAssertEqual(try journalCapability(), "partial")
        let (c, _) = try await captured()
        XCTAssertTrue(decisions(c).isEmpty)
        XCTAssertEqual(c.manifest.capability("emergency.decisions"), "partial")
    }

    func testADecisionTheHookDropsMakesTheCapsulePartial() async throws {
        await initializeGuards()
        start(hook: { type, data in type == EventTypes.emergencyDecision ? nil : data })
        XCTAssertEqual(try journalCapability(), "supported")
        XCTAssertEqual(BugCapsule.emergency.evaluate(featureKey: feature).action, .block)
        XCTAssertEqual(try journalCapability(), "partial", "refreshed at once, for a crash that follows")
        let (c, _) = try await captured()
        XCTAssertTrue(decisions(c).isEmpty)
        XCTAssertEqual(c.manifest.capability("emergency.decisions"), "partial")
    }

    func testAHookThatThrowsCostsTheRecordingOnly() async throws {
        struct HookFailure: Error {}
        await initializeGuards()
        start(hook: { type, data in
            if type == EventTypes.emergencyDecision { throw HookFailure() }
            return data
        })
        XCTAssertEqual(BugCapsule.emergency.evaluate(featureKey: feature).action, .block)
        let (c, _) = try await captured()
        XCTAssertEqual(c.manifest.capability("emergency.decisions"), "partial")
    }

    func testAHookMayEvaluateAgain() async throws {
        await initializeGuards()
        start(hook: { type, data in
            if type == EventTypes.emergencyDecision {
                _ = BugCapsule.emergency.evaluate(featureKey: feature)
                _ = BugCapsule.emergency.evaluate(featureKey: "feed.home")
            }
            return data
        })
        _ = BugCapsule.emergency.evaluate(featureKey: feature)
        let (c, _) = try await captured()
        XCTAssertEqual(Set(decisions(c).compactMap { $0.data["key"]?.stringValue }), [feature, "feed.home"])
    }

    func testPastThePairLimitTheCapsuleIsPartial() async throws {
        await initializeGuards()
        start()
        for i in 0..<256 { _ = BugCapsule.emergency.evaluate(featureKey: feature, subject: "s\(i)") }
        XCTAssertEqual(try journalCapability(), "supported")
        XCTAssertFalse(BugCapsule.emergency.evaluate(featureKey: feature, subject: "s256").allowed, "still decided")
        XCTAssertEqual(try journalCapability(), "partial")
        let (c, _) = try await captured()
        XCTAssertEqual(decisions(c).count, 256)
        XCTAssertEqual(c.manifest.capability("emergency.decisions"), "partial")
    }

    func testNothingIsWrittenWithCaptureOff() async throws {
        await initializeGuards()
        start(enabled: false)
        XCTAssertEqual(BugCapsule.emergency.evaluate(featureKey: feature).action, .block)
        XCTAssertNil(BugCapsuleSession.current?.recorderForTesting)
        XCTAssertEqual(BugCapsule.emergency.decisionsCapability, "supported")
    }

    func testEvaluatingFromManyThreadsWritesEachPairOnce() async throws {
        await initializeGuards()
        start()
        await Task.detached {
            DispatchQueue.concurrentPerform(iterations: 8) { i in
                for n in 0..<2000 {
                    let d = BugCapsule.emergency.evaluate(featureKey: feature, subject: "s\((i + n) % 8)")
                    XCTAssertEqual(d.action, .block)
                }
            }
        }.value
        let (c, _) = try await captured()
        XCTAssertEqual(decisions(c).count, 8)
    }

    /// Two threads between tracking and writing: the one with the older
    /// decision writes last. Here the older decision's hook runs the newer one
    /// to the end, which is that order without the timing.
    func testTheLastEventOfAPairIsTheLatestDecision() async throws {
        await initializeGuards(ttl: 60)
        let clock = self.clock!
        let first = Flag()
        start(hook: { type, data in
            if type == EventTypes.emergencyDecision, first.set() {
                clock.advance(3600)  // the document expired: a failure mode decides now
                _ = BugCapsule.emergency.evaluate(featureKey: feature)
            }
            return data
        })
        XCTAssertEqual(BugCapsule.emergency.evaluate(featureKey: feature).action, .block)
        let (c, _) = try await captured()
        XCTAssertEqual(decisions(c).map { $0.data["action"] }, ["ALLOW", "BLOCK", "ALLOW"])
    }

    // MARK: checkpoints

    func testAWindowThatStartsAtAPeriodicCheckpointKnowsTheDecision() async throws {
        await initializeGuards()
        start(maxEvents: 20)
        _ = BugCapsule.emergency.evaluate(featureKey: feature, subject: "user-1")
        _ = BugCapsule.emergency.evaluate(featureKey: feature)
        for i in 0..<5 { BugCapsule.log("before \(i)") }
        BugCapsule.checkpointNow()
        for i in 0..<14 { BugCapsule.log("after \(i)") }
        let session = try XCTUnwrap(BugCapsuleSession.current)
        XCTAssertGreaterThan(session.recorderForTesting?.droppedEvents ?? 0, 2, "the first decisions were evicted")

        let (c, _) = try await captured()
        XCTAssertEqual(c.manifest.checkpointKind, .periodic)
        XCTAssertEqual(decisions(c).count, 2)
        XCTAssertTrue(decisions(c).allSatisfy { $0.data["action"] == "BLOCK" })
        XCTAssertTrue(decisions(c).allSatisfy { $0.seq > c.checkpoint.afterSeq })
        XCTAssertEqual(EmergencyDecisionScript(events: c.events).lookup(key: feature, subjectTag: nil, t: c.checkpoint.t)?.action, .block)

        // The crash journal starts there as well.
        let journal = try XCTUnwrap(session.journalForTesting)
        journal.flushSynchronously()
        let window = try XCTUnwrap(CrashJournalContents.load(journal.directory)?.window(periodicOnly: true))
        XCTAssertEqual(window.checkpoint.kind, .periodic)
        XCTAssertEqual(window.events.filter { $0.type == EventTypes.emergencyDecision }.count, 2)
    }

    func testEachCheckpointRepeatsEveryTrackedDecision() async throws {
        await initializeGuards()
        start()
        _ = BugCapsule.emergency.evaluate(featureKey: feature)
        BugCapsule.checkpointNow()
        BugCapsule.checkpointNow()
        let (c, _) = try await captured()
        XCTAssertEqual(decisions(c).count, 3)
    }

    func testAHookDropAtACheckpointReachesTheJournal() async throws {
        await initializeGuards()
        let drop = Flag()
        start(hook: { type, data in
            type == EventTypes.emergencyDecision && drop.isSet ? nil : data
        })
        _ = BugCapsule.emergency.evaluate(featureKey: feature)
        XCTAssertTrue(drop.set())
        BugCapsule.checkpointNow()
        XCTAssertEqual(try journalCapability(), "partial")
    }

    func testACrashCapsuleFromTheJournalCarriesTheDecisionsAndCapability() async throws {
        await initializeGuards()
        start(hook: { _, data in data["key"] == "feed.home" ? nil : data })
        _ = BugCapsule.emergency.evaluate(featureKey: feature)
        _ = BugCapsule.emergency.evaluate(featureKey: "feed.home")  // dropped
        let session = try XCTUnwrap(BugCapsuleSession.current)
        let journal = try XCTUnwrap(session.journalForTesting)
        journal.flushSynchronously()
        let contents = try XCTUnwrap(CrashJournalContents.load(journal.directory))
        let value: JSONValue = ["type": "SIGSEGV", "value": "bad access", "mechanism": ["type": "signal"]]
        let (c, _) = try XCTUnwrap(
            session.buildCrashCapsule(
                contents, draft: EventDraft(level: .fatal, exceptionValues: [value]), crashTime: nil,
                link: CapsuleMonitoringLink(eventId: "0f0e0d0c0b0a49088706050403020100", release: "r", environment: "qa"),
                capsuleId: "crash-1", maxBytes: 5_000_000))
        XCTAssertEqual(decisions(c).map { $0.data["key"] }, [.string(feature)])
        XCTAssertEqual(c.manifest.capability("emergency.decisions"), "partial")
    }

    // MARK: replay

    /// The guarded path: the bug exists only while the feature is blocked.
    private func pay() {
        if !BugCapsule.emergency.evaluate(featureKey: feature).allowed { BugCapsule.fail("blocked_path") }
    }

    /// A capture of a user hitting the blocked path, from the real recorder.
    private func captureBlockedPath() async throws -> Capsule {
        await initializeGuards()
        start()
        let session = try XCTUnwrap(BugCapsuleSession.current)
        session.setAnchorForTesting(session.now())
        try await Task.sleep(nanoseconds: 20_000_000)
        BugCapsule.action("pay") { [self] in pay() }()
        let (c, _) = try await captured()
        XCTAssertEqual(c.manifest.failure?.signature, "assertion:blocked_path:")
        XCTAssertEqual(decisions(c).count, 1)
        await BugCapsule.resetForTesting()
        return c
    }

    private func replay(_ capsule: Capsule, settings: ReplaySettings = ReplaySettings(settleTimeoutMs: 300)) async throws
        -> ReplayReport
    {
        let s = BugCapsuleSession(
            config: BugCapsuleConfig(appVersion: "1.0", appBuild: "7", mode: .qa, gitSha: "abc123"), integrations: [],
            overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory()))
        let engine = try XCTUnwrap(s.startReplayForTesting(capsule: capsule, settings: settings))
        let report = await engine.run()
        await BugCapsule.resetForTesting()
        return report
    }

    func testTheBlockedPathReproducesOnlyWithItsDecision() async throws {
        let capsule = try await captureBlockedPath()
        let requests = backend.server.requests.count

        let faithful = try await replay(capsule)
        XCTAssertEqual(faithful.outcome, .reproduced, "\(faithful.divergences)")
        XCTAssertEqual(faithful.observed?.signature, "assertion:blocked_path:")
        XCTAssertTrue(faithful.divergences.isEmpty, "\(faithful.divergences)")

        // What every replay did before: all features allowed, the bug not reached.
        let without = Capsule(
            manifest: capsule.manifest, checkpoint: capsule.checkpoint,
            events: capsule.events.filter { $0.type != EventTypes.emergencyDecision })
        let allowed = try await replay(without)
        XCTAssertEqual(allowed.outcome, .notReproduced)
        XCTAssertEqual(allowed.eventsDispatched, 1, "the action ran in both")

        XCTAssertEqual(backend.server.requests.count, requests, "no network and no receipts in replay")
    }

    func testReplayWorksWithoutInitialize() async throws {
        let capsule = try await captureBlockedPath()
        await BugCapsuleEmergency.shared.resetForTesting()
        XCTAssertFalse(BugCapsule.emergency.isInitialized)
        let report = try await replay(capsule)
        XCTAssertEqual(report.outcome, .reproduced, "\(report.divergences)")
    }

    private func decision(_ key: String, t: Int, seq: Int, action: String = "BLOCK", subject: String? = nil) -> BugCapsuleEvent {
        var data: JSONObject = ["key": .string(key), "action": .string(action), "source": "policy"]
        if let subject { data["subject"] = .string(subject) }
        return BugCapsuleEvent(seq: seq, t: t, type: EventTypes.emergencyDecision, data: data)
    }

    func testReplayServesTheDecisionAndNoPolicyWithSourceReplay() async throws {
        await initializeGuards()
        var event = decision("feed.home", t: 0, seq: 1, action: "USE_SAFE_FALLBACK")
        event.data["fallback"] = "cached"
        event.data["fallbackAvailable"] = true
        event.data["source"] = "stale_policy"
        let capsule = makeCapsule(events: [event, decision("wallet.send", t: 0, seq: 2, subject: emergencySubjectTag("user-1"))])
        let s = BugCapsuleSession(
            config: BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa), integrations: [],
            overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory()))
        _ = try XCTUnwrap(s.startReplayForTesting(capsule: capsule, settings: ReplaySettings()))

        let d = BugCapsule.emergency.evaluate(featureKey: "feed.home")
        XCTAssertEqual(d.action, .useSafeFallback)
        XCTAssertFalse(d.allowed)
        XCTAssertEqual(d.source, .replay, "the recorded source is not exposed")
        XCTAssertEqual(d.fallback, "cached")
        XCTAssertTrue(d.fallbackAvailable)
        XCTAssertNil(BugCapsule.emergency.getPolicy("feed.home"))

        XCTAssertEqual(BugCapsule.emergency.evaluate(featureKey: "wallet.send", subject: "user-1").action, .block)
        let unknown = BugCapsule.emergency.evaluate(featureKey: feature)
        XCTAssertTrue(unknown.allowed, "not in the capsule, although the live document blocks it")
        XCTAssertEqual(unknown.source, .replay)
        XCTAssertNil(unknown.reasonCode)

        // Replay leaves the tracker alone: nothing to write afterwards.
        await BugCapsule.resetForTesting()
        start()
        let (c, _) = try await captured()
        XCTAssertTrue(decisions(c).isEmpty)
    }

    func testReplayBeforeTheCapsuleIsKnownAllows() async throws {
        // A replay launch whose capsule hasn't loaded: no engine yet.
        var c = EmergencyConfiguration(trustAnchor: signer.anchor(app: app), backend: backend.backend)
        c.testHooks = EmergencyTestHooks(
            storageDirectory: dir.appendingPathComponent("emergency"), autoSchedule: false, isReplaying: { true },
            observeLifecycle: false)
        BugCapsule.emergency.initialize(c)
        let d = BugCapsule.emergency.evaluate(featureKey: feature)
        XCTAssertTrue(d.allowed)
        XCTAssertEqual(d.source, .replay)
        XCTAssertEqual(BugCapsule.emergency.decisionsCapability, "supported")

        // The capsule loaded: the same evaluation gets the recorded decision.
        let capsule = makeCapsule(events: [decision(feature, t: 0, seq: 1)])
        let s = BugCapsuleSession(
            config: BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa), integrations: [],
            overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory()))
        _ = try XCTUnwrap(s.startReplayForTesting(capsule: capsule, settings: ReplaySettings()))
        XCTAssertEqual(BugCapsule.emergency.evaluate(featureKey: feature).action, .block)
    }

    /// What the guard answered inside the capsule's `look` action.
    private func replayedAction(_ capsule: Capsule) async throws -> EmergencyAction? {
        let seen = EventLog()
        BugCapsule.registerAction("look") { _ in
            seen.append(["action": .string(BugCapsule.emergency.evaluate(featureKey: feature).action.rawValue)])
        }
        BugCapsule.registerAction("noop") { _ in }
        let report = try await replay(capsule)
        XCTAssertFalse(report.divergences.contains { $0.type.hasPrefix("action.") }, "\(report.divergences)")
        return seen.items.first?["action"]?.stringValue.flatMap(EmergencyAction.init(rawValue:))
    }

    func testReplayUsesTheEventClockOfALaunchCapsule() async throws {
        let events = [
            decision(feature, t: -500, seq: 1, action: "ALLOW"), decision(feature, t: 100, seq: 2),
            BugCapsuleEvent(seq: 3, t: 150, type: EventTypes.action, data: ["id": "look"]),
            decision(feature, t: 400, seq: 4, action: "ALLOW"),
        ]
        let action = try await replayedAction(makeCapsule(events: events))
        XCTAssertEqual(action, .block)
    }

    func testReplayUsesTheEventClockOfAPeriodicCapsule() async throws {
        let base = 50_000
        let events = [
            decision(feature, t: base + 1, seq: 11, action: "ALLOW"), decision(feature, t: base + 100, seq: 12),
            BugCapsuleEvent(seq: 13, t: base + 150, type: EventTypes.action, data: ["id": "look"]),
            decision(feature, t: base + 400, seq: 14, action: "ALLOW"),
        ]
        let launch = makeCapsule(events: events, checkpointKind: .periodic)
        let capsule = Capsule(
            manifest: launch.manifest,
            checkpoint: Checkpoint(kind: .periodic, t: base, wallClockMs: 1_700_000_000_000, afterSeq: 10, data: JSONObject()),
            events: events)
        let action = try await replayedAction(capsule)
        XCTAssertEqual(action, .block)
    }

    func testAnIdleGapSkippedInReplayCountsOnTheClock() async throws {
        let events = [
            decision(feature, t: 10, seq: 1, action: "ALLOW"),
            BugCapsuleEvent(seq: 2, t: 6000, type: EventTypes.action, data: ["id": "noop"]),
            decision(feature, t: 6100, seq: 3),
            BugCapsuleEvent(seq: 4, t: 6200, type: EventTypes.action, data: ["id": "look"]),
        ]
        let before = Date()
        let action = try await replayedAction(makeCapsule(events: events))
        XCTAssertEqual(action, .block, "only a clock that includes the skip is past t 6100")
        XCTAssertLessThan(Date().timeIntervalSince(before), 4, "the gap was skipped")
    }

    func testAFiveMinuteGapWithCheckpointRewritesIsStillSkipped() async throws {
        var events = [decision(feature, t: 10, seq: 1, action: "ALLOW")]
        for (i, t) in stride(from: 30_000, to: 300_000, by: 30_000).enumerated() {
            events.append(decision(feature, t: t, seq: 2 + i))
        }
        events.append(BugCapsuleEvent(seq: 100, t: 300_000, type: EventTypes.action, data: ["id": "look"]))
        let before = Date()
        let action = try await replayedAction(makeCapsule(events: events))
        XCTAssertEqual(action, .block, "jumped past every entry, and the clock followed")
        XCTAssertLessThan(Date().timeIntervalSince(before), 5, "not in real time")
    }

    func testAnEvaluationBeforeTheAnchorGetsTheEarliestEntry() async throws {
        let capsule = makeCapsule(events: [decision(feature, t: 100, seq: 1), decision(feature, t: 200, seq: 2, action: "ALLOW")])
        let s = BugCapsuleSession(
            config: BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa), integrations: [],
            overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory()))
        _ = try XCTUnwrap(s.startReplayForTesting(capsule: capsule, settings: ReplaySettings()))
        XCTAssertEqual(BugCapsule.emergency.evaluate(featureKey: feature).action, .block)
    }

    // MARK: update adapters in replay

    private func replayRequireUpdate() throws -> EmergencyDecision {
        var event = decision(feature, t: 0, seq: 1, action: "REQUIRE_UPDATE")
        event.data["requiredVersion"] = "2.5.0"
        let s = BugCapsuleSession(
            config: BugCapsuleConfig(appVersion: "1", appBuild: "1", mode: .qa), integrations: [],
            overrides: BugCapsuleTestOverrides(storageDirectory: tempDirectory()))
        _ = try XCTUnwrap(s.startReplayForTesting(capsule: makeCapsule(events: [event]), settings: ReplaySettings()))
        let d = BugCapsule.emergency.evaluate(featureKey: feature)
        XCTAssertEqual(d.action, .requireUpdate)
        XCTAssertEqual(d.requiredVersion, "2.5.0")
        return d
    }

    func testAReplayedRequireUpdateReachesNoProvider() async throws {
        let provider = FakeUpdateProvider()
        await initializeGuards(provider: provider)
        let updates = BugCapsule.emergency.updates
        for _ in 0..<500 where backend.receipts.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(backend.receipts.count, 1, "APPLIED")
        let requests = backend.server.requests.count

        let d = try replayRequireUpdate()
        let replayed = try await updates.checkAvailability(for: d)
        XCTAssertFalse(replayed.isAvailable)
        XCTAssertEqual(replayed.requiredVersion, "2.5.0")
        let state = await updates.presentUpdate(requiredVersion: "2.5.0", presentation: EmergencyUpdatePresentation())
        XCTAssertEqual(state, .notAvailable)
        updates.markDeclined()
        XCTAssertEqual(provider.checked.value, 0)
        XCTAssertEqual(provider.presented.value, 0)
        XCTAssertNil(updates.status)
        XCTAssertNil(updates.lastAvailability)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(backend.server.requests.count, requests, "no runtime report")

        // The same calls outside a replay reach it.
        await BugCapsule.resetForTesting()
        let live = try await updates.checkAvailability(for: d)
        XCTAssertTrue(live.isAvailable)
        XCTAssertEqual(provider.checked.value, 1)
        let shown = await updates.presentUpdate(requiredVersion: "2.5.0", presentation: EmergencyUpdatePresentation())
        XCTAssertEqual(shown, .inProgress)
        XCTAssertEqual(provider.presented.value, 1)
        updates.markDeclined()
        XCTAssertEqual(updates.status?.state, .declined)
    }

    func testAnUpdateCheckedBeforeReplayIsNotShownInReplay() async throws {
        let provider = FakeUpdateProvider()
        await initializeGuards(provider: provider)
        let updates = BugCapsule.emergency.updates
        let live = try await updates.checkAvailability(requiredVersion: "2.5.0")
        XCTAssertTrue(live.isAvailable)

        _ = try replayRequireUpdate()
        let state = await updates.presentUpdate(requiredVersion: "2.5.0", presentation: EmergencyUpdatePresentation())
        XCTAssertEqual(state, .notAvailable)
        XCTAssertEqual(provider.presented.value, 0)
        XCTAssertEqual(provider.checked.value, 1)
    }

    func testAReplayedRequireUpdateMakesNoAppStoreLookup() async throws {
        let body = #"{"resultCount":1,"results":[{"version":"2.5.0","trackId":99,"trackViewUrl":"https://apps.apple.com/us/app/x/id99"}]}"#
        let store = try TestHTTPServer { _ in .init(status: 200, body: Data(body.utf8)) }
        defer { store.stop() }
        let provider = AppStoreUpdateProvider(
            bundleId: "com.example.app", country: "us", endpoint: try XCTUnwrap(URL(string: store.baseURL + "/lookup")), timeout: 2)
        await initializeGuards(provider: provider)
        let updates = BugCapsule.emergency.updates

        let d = try replayRequireUpdate()
        let replayed = try await updates.checkAvailability(for: d)
        XCTAssertFalse(replayed.isAvailable)
        let state = await updates.presentUpdate(requiredVersion: "2.5.0", presentation: EmergencyUpdatePresentation())
        XCTAssertEqual(state, .notAvailable)
        XCTAssertEqual(store.requests.count, 0)

        await BugCapsule.resetForTesting()
        let live = try await updates.checkAvailability(for: d)
        XCTAssertTrue(live.isAvailable)
        XCTAssertEqual(store.requests.count, 1)
    }

    func testACapsuleWithoutTheCapabilityOrWithUnknownEntriesIsNoObstacle() async throws {
        var future = decision(feature, t: 0, seq: 1, action: "SOME_FUTURE_ACTION")
        future.data["extra"] = ["nested": true]
        let capsule = makeCapsule(
            events: [
                future, BugCapsuleEvent(seq: 2, t: 0, type: "emergency.future", data: ["key": .string(feature)]),
                BugCapsuleEvent(seq: 3, t: 50, type: EventTypes.action, data: ["id": "look"]),
            ], capabilities: [])
        XCTAssertNil(validateCapsuleDocument(CapsuleCodec.toJSON(capsule)))
        let action = try await replayedAction(capsule)
        XCTAssertEqual(action, .allow)
    }
}

/// Data handed out of `@Sendable` hooks.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [JSONObject] = []
    var items: [JSONObject] { lock.locked { _items } }
    func append(_ item: JSONObject) { lock.locked { _items.append(item) } }
}
