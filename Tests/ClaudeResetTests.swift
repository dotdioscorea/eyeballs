import XCTest
@testable import Requota

final class ClaudeResetTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_791_133_200)
    func payload(remaining: Int = 1, used: Double = 75, paused: Bool = false, usable: Bool = false) -> [String: Any] {
        ["five_hour": ["utilization": used, "resets_at": now.addingTimeInterval(3600).timeIntervalSince1970],
         "seven_day": ["utilization": used, "resets_at": now.addingTimeInterval(86400).timeIntervalSince1970],
         "cedar_ember": ["eligible": true, "grants": [["id": "private-redemption-handle", "label": "private-label",
             "resets_left": remaining, "resets_total": 1, "starts_at": now.addingTimeInterval(-86400).timeIntervalSince1970,
             "ends_at": now.addingTimeInterval(7 * 86400).timeIntervalSince1970, "paused": paused,
             "usable_now": usable, "clears": ["five_hour", "seven_day"]]]]]
    }
    func testLiveGrantShapeKeepsWaitingResetsExpiryAndSpentBaselineWithoutRedemptionHandle() throws {
        let snapshot = try UsageParser.claude(payload(), now: now)
        XCTAssertEqual(snapshot.bankedResets?.first?.count, 1)
        XCTAssertEqual(snapshot.bankedResets?.first?.expiresAt, now.addingTimeInterval(7 * 86400))
        XCTAssertEqual(snapshot.bankedResets?.first?.usableNow, false)
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private-redemption-handle")); XCTAssertFalse(encoded.contains("private-label"))
        let spent = try UsageParser.claude(payload(remaining: 0), now: now)
        XCTAssertEqual(spent.bankedResets, [])
        XCTAssertEqual(spent.resetInventory?.grants.first?.remaining, 0)
        XCTAssertEqual(spent.resetInventory?.grants.first?.total, 1)
        XCTAssertEqual(try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(spent)), spent)
    }
    func testUnknownAndMalformedGrantsDoNotBecomeZeroAvailable() throws {
        var raw = payload()
        raw["cedar_ember"] = NSNull()
        XCTAssertNil(try UsageParser.claude(raw, now: now).bankedResets)
        raw["cedar_ember"] = ["eligible": false, "ineligible_reason": "surface", "grants": []]
        XCTAssertNil(try UsageParser.claude(raw, now: now).resetInventory)
        for invalid in [true, -1, 1.5, 101, "1"] as [Any] {
            raw["cedar_ember"] = ["eligible": true, "grants": [["resets_left": invalid, "paused": false]]]
            XCTAssertNil(try UsageParser.claude(raw, now: now).resetInventory)
        }
        raw["cedar_ember"] = ["eligible": true, "grants": [["resets_left": 1, "paused": false, "ends_at": "invalid"]]]
        XCTAssertNil(try UsageParser.claude(raw, now: now).resetInventory)
        raw["cedar_ember"] = ["eligible": true, "grants": []]
        XCTAssertEqual(try UsageParser.claude(raw, now: now).bankedResets, [])
    }
    func testGrantUseIsDetectedAfterUsageHasResumedAndOnlyOnce() throws {
        let id = UUID()
        let old = EventDetection.compare(accountID: id, previous: nil, current: try UsageParser.claude(payload(), now: now)).snapshot
        let next = try UsageParser.claude(payload(remaining: 0, used: 12), now: now.addingTimeInterval(600))
        let result = EventDetection.compare(accountID: id, previous: old, current: next)
        XCTAssertEqual(result.events.filter { $0.kind == .bankedUsed }.map(\.count), [1])
        XCTAssertEqual(result.events.filter { $0.kind == .earlyReset }.count, 2)
        XCTAssertTrue(result.events.allSatisfy { !$0.inferred })
        let again = try UsageParser.claude(payload(remaining: 0, used: 15), now: now.addingTimeInterval(1200))
        XCTAssertTrue(EventDetection.compare(accountID: id, previous: result.snapshot, current: again).events.isEmpty)
        // A spent grant at first connection has no observed use time.
        XCTAssertTrue(EventDetection.compare(accountID: id, previous: nil, current: next).events.isEmpty)
    }
    func testReportedGrantUseSurvivesAHighBurnRateWithNoVisibleUsageDrop() throws {
        let old = try UsageParser.claude(payload(used: 20), now: now)
        let next = try UsageParser.claude(payload(remaining: 0, used: 40), now: now.addingTimeInterval(600))
        let result = EventDetection.compare(accountID: UUID(), previous: old, current: next)
        XCTAssertEqual(result.events.filter { $0.kind == .bankedUsed }.count, 1)
        XCTAssertEqual(result.events.filter { $0.kind == .earlyReset }.count, 2)
    }
    func testUnavailableInventoryRetainsBaselineAndPauseIsNotUse() throws {
        let id = UUID()
        let old = EventDetection.compare(accountID: id, previous: nil, current: try UsageParser.claude(payload(), now: now)).snapshot
        var raw = payload(used: 80); raw["cedar_ember"] = NSNull()
        let missing = EventDetection.compare(accountID: id, previous: old, current: try UsageParser.claude(raw, now: now.addingTimeInterval(60)))
        XCTAssertEqual(missing.snapshot.resetInventory, old.resetInventory)
        XCTAssertEqual(missing.snapshot.bankedResets, old.bankedResets)
        XCTAssertTrue(missing.events.isEmpty)
        let spent = try UsageParser.claude(payload(remaining: 0, used: 15), now: now.addingTimeInterval(120))
        XCTAssertEqual(EventDetection.compare(accountID: id, previous: missing.snapshot, current: spent).events.filter { $0.kind == .bankedUsed }.count, 1)
        let paused = try UsageParser.claude(payload(used: 80, paused: true), now: now.addingTimeInterval(60))
        XCTAssertTrue(EventDetection.compare(accountID: id, previous: old, current: paused).events.isEmpty)
    }
    func testEarlyResetInferenceAllowsReconsumptionButIgnoresSmallCorrectionsAndTierChanges() {
        let id = UUID()
        let window = UsageWindow(id: "seven_day", title: "Weekly", usedPercent: 90, resetsAt: now.addingTimeInterval(86400), duration: 604800)
        let old = UsageSnapshot(windows: [window], plan: "Max", updatedAt: now)
        var next = old; next.updatedAt = now.addingTimeInterval(600); next.windows[0].usedPercent = 12
        let events = EventDetection.compare(accountID: id, previous: old, current: next).events
        XCTAssertEqual(events.map(\.kind), [.earlyReset]); XCTAssertTrue(events[0].inferred)
        next.windows[0].usedPercent = 86
        XCTAssertTrue(EventDetection.compare(accountID: id, previous: old, current: next).events.isEmpty)
        next.windows[0].usedPercent = 12; next.plan = "Pro"
        XCTAssertEqual(EventDetection.compare(accountID: id, previous: old, current: next).events.map(\.kind), [.allowanceChanged])
    }
    func testOptInQueryFallsBackOnlyWhenUnsupported() async throws {
        let credential = AccountCredential(provider: .claude, issuer: ProviderAuth.issuer(.claude), clientID: ProviderAuth.claudeClientID, subject: "test", hostID: "test", accessToken: "dummy-token", scopes: ["user:profile"], expiresAt: .distantFuture)
        var requests: [URLRequest] = []
        _ = try await UsageClient.claudeUsage(credential: credential) { request in
            requests.append(request)
            let status = requests.count == 1 ? 400 : 200
            return (Data(#"{"five_hour":{}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.query, "cedar_ember=1"); XCTAssertNil(requests[1].url?.query)
        XCTAssertTrue(requests[0].value(forHTTPHeaderField: "User-Agent")!.contains("Requota"))
        for status in [401, 403, 429, 500] {
            var count = 0
            do {
                _ = try await UsageClient.claudeUsage(credential: credential) { request in
                    count += 1
                    return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
                }
                XCTFail("Expected provider error")
            } catch { XCTAssertEqual(count, 1) }
        }
    }
    func testExpiredAndFutureGrantsDoNotCreateUseEvents() throws {
        let id = UUID()
        let old = EventDetection.compare(accountID: id, previous: nil, current: try UsageParser.claude(payload(), now: now)).snapshot
        let expired = try UsageParser.claude(payload(remaining: 0, used: 80), now: now.addingTimeInterval(8 * 86400))
        let events = EventDetection.compare(accountID: id, previous: old, current: expired).events
        XCTAssertEqual(events.filter { $0.kind == .bankedExpired }.count, 1)
        XCTAssertFalse(events.contains { $0.kind == .bankedUsed })
        var raw = payload()
        raw["cedar_ember"] = ["eligible": true, "grants": [["resets_left": 2, "resets_total": 2, "paused": false, "starts_at": now.addingTimeInterval(3600).timeIntervalSince1970]]]
        XCTAssertEqual(try UsageParser.claude(raw, now: now).bankedResets, [])
    }
    func testDebugReportIncludesResetParsingAndComparisonWithoutPrivateGrantData() throws {
        let raw = payload()
        let snapshot = try UsageParser.claude(raw, now: now)
        let diagnostic = UsageParsingDiagnostic.make(provider: .claude, raw: raw, snapshot: snapshot)
        XCTAssertEqual(diagnostic.resetResponse, .parsed)
        let encoded = try JSONEncoder().encode(diagnostic)
        XCTAssertEqual(try JSONDecoder().decode(UsageParsingDiagnostic.self, from: encoded).resetResponse, .parsed)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("private"))
        let spent = try UsageParser.claude(payload(remaining: 0, used: 12), now: now.addingTimeInterval(600))
        let events = EventDetection.compare(accountID: UUID(), previous: snapshot, current: spent).events
        let comparison = ResetComparisonDiagnostic.make(previous: snapshot, current: spent, events: events)
        XCTAssertEqual(comparison.previousGrantRemaining, 1); XCTAssertEqual(comparison.currentGrantRemaining, 0)
        XCTAssertEqual(comparison.previousWeeklyUsed, 75); XCTAssertEqual(comparison.currentWeeklyUsed, 12)
        XCTAssertTrue(comparison.events.contains(.bankedUsed))
    }
}

@MainActor
final class ClaudeResetPersistenceTests: XCTestCase {
    func testObservedUsePersistsAcrossRelaunchAndSeparateClaudeAccounts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = ClaudeResetTests()
        let now = Date.now
        var firstCredential = Fixture.credential("claude-one"); firstCredential.provider = .claude
        firstCredential.issuer = ProviderAuth.issuer(.claude); firstCredential.clientID = ProviderAuth.claudeClientID
        var secondCredential = firstCredential; secondCredential.subject = "claude-two"
        var old = try UsageParser.claude(fixture.payload(), now: now)
        old.identity = firstCredential.registrationIdentity
        var next = try UsageParser.claude(fixture.payload(remaining: 0, used: 12), now: now.addingTimeInterval(1))
        next.identity = firstCredential.registrationIdentity
        let first = AgentAccount(provider: .claude, label: "First", snapshot: old)
        var other = old; other.identity = secondCredential.registrationIdentity
        let second = AgentAccount(provider: .claude, label: "Second", snapshot: other)
        let vault = MemoryVault(); let location = directory.appendingPathComponent("accounts.json")
        let store = AccountStore(location: location, vault: vault, integratesWithSystem: false, fetcher: { account, _ in account.id == first.id ? next : old })
        try store.connect(first, credential: firstCredential); try store.connect(second, credential: secondCredential)
        await store.refresh(first.id)
        XCTAssertEqual(store.events.filter { $0.kind == .bankedUsed }.map(\.accountID), [first.id])
        let restored = AccountStore(location: location, vault: vault, integratesWithSystem: false)
        XCTAssertEqual(restored.accounts.first?.snapshot?.resetInventory?.grants.first?.remaining, 0)
        XCTAssertEqual(restored.accounts.last?.snapshot?.resetInventory?.grants.first?.remaining, 1)
        XCTAssertEqual(restored.events.filter { $0.kind == .bankedUsed }.count, 1)
    }
}
