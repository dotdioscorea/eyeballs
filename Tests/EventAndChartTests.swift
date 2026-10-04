import XCTest
@testable import Requota

final class EventAndChartTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_970_000)
    let id = UUID()
    func snapshot(used: Double = 40, reset: Date? = nil, at: Date? = nil, banked: [BankedReset]? = nil) -> UsageSnapshot {
        UsageSnapshot(windows: [UsageWindow(id: "week", title: "Weekly", usedPercent: used, resetsAt: reset ?? now.addingTimeInterval(3 * 86400), duration: 604800)], updatedAt: at ?? now, bankedResets: banked)
    }
    func testWeeklyResetUsesReportedDeadlineAndDoesNotInventMissedResets() {
        let old = snapshot(reset: now, at: now.addingTimeInterval(-60))
        let current = snapshot(used: 1, reset: now.addingTimeInterval(604800))
        let result = EventDetection.compare(accountID: id, previous: old, current: current)
        XCTAssertEqual(result.events.map(\.kind), [.weeklyReset]); XCTAssertEqual(result.events[0].date, now)
        XCTAssertFalse(result.events[0].inferred)
        XCTAssertTrue(EventDetection.compare(accountID: id, previous: current, current: current).events.isEmpty)
        XCTAssertTrue(EventDetection.compare(accountID: id, previous: nil, current: current).events.isEmpty)
    }
    func testEarlyResetAndBankedUseAreInferredTogetherWhileSmallCorrectionsAreIgnored() {
        let reset = BankedReset(id: "a", title: "Usage reset", firstDetectedAt: now.addingTimeInterval(-86400))
        let previous = snapshot(at: now.addingTimeInterval(-60), banked: [reset])
        let next = snapshot(used: 0, banked: [])
        let result = EventDetection.compare(accountID: id, previous: previous, current: next)
        XCTAssertEqual(result.events.map(\.kind), [.earlyReset, .bankedUsed]); XCTAssertTrue(result.events.allSatisfy(\.inferred))
        XCTAssertTrue(EventDetection.compare(accountID: id, previous: previous, current: snapshot(used: 39, banked: [reset])).events.isEmpty)
        XCTAssertEqual(EventDetection.compare(accountID: id, previous: previous, current: snapshot(used: 45, banked: [])).events.map(\.kind), [.bankedRemoved])
    }
    func testBankedFirstDetectionSurvivesRefreshAndExpiryDoesNotCountAsUse() {
        let reset = BankedReset(id: "a", title: "Usage reset", expiresAt: now.addingTimeInterval(60))
        let first = EventDetection.compare(accountID: id, previous: nil, current: snapshot(banked: [reset]))
        XCTAssertEqual(first.events.map(\.kind), [.bankedDetected]); XCTAssertEqual(first.snapshot.bankedResets?.first?.firstDetectedAt, now)
        let next = EventDetection.compare(accountID: id, previous: first.snapshot, current: snapshot(used: 50, at: now.addingTimeInterval(30), banked: [reset]))
        XCTAssertTrue(next.events.isEmpty); XCTAssertEqual(next.snapshot.bankedResets?.first?.firstDetectedAt, now)
        let expired = EventDetection.compare(accountID: id, previous: next.snapshot, current: snapshot(at: now.addingTimeInterval(90), banked: []))
        XCTAssertEqual(expired.events.map(\.kind), [.bankedExpired]); XCTAssertEqual(expired.events.first?.date, reset.expiresAt)
        let unavailable = EventDetection.compare(accountID: id, previous: next.snapshot, current: snapshot(at: now.addingTimeInterval(90)))
        XCTAssertFalse(unavailable.events.contains { [.bankedExpired, .bankedUsed, .bankedRemoved].contains($0.kind) })
    }
    func testReminderRulesUseKnownWeeklyQuotaAndKnownExpiryOnlyAndBoundTotal() {
        let account = AgentAccount(provider: .codex, label: "Test", snapshot: snapshot(banked: [BankedReset(id: "a", title: "Reset", expiresAt: now.addingTimeInterval(2 * 86400)), BankedReset(id: "unknown", title: "Reset")]))
        let reminders = ResetReminderPlan.make(accounts: [account], rules: ResetNotificationRules(), now: now)
        XCTAssertEqual(reminders.count, 4)
        XCTAssertTrue(reminders.contains { $0.body.contains("60%") }); XCTAssertTrue(reminders.allSatisfy { $0.accountID == account.id && $0.date > now })
        var rules = ResetNotificationRules(); rules.minimumRemaining = 70; rules.bankedExpiry = false
        XCTAssertEqual(ResetReminderPlan.make(accounts: [account], rules: rules, now: now).count, 1)
        let many = (0..<100).map { _ in AgentAccount(provider: .codex, snapshot: account.snapshot) }
        let fullPlan = ResetReminderPlan.make(accounts: many, rules: ResetNotificationRules(), now: now)
        XCTAssertEqual(ReminderLedger.pendingPlan(fullPlan, ledger: [:], now: now).count, 50)
    }
    func testHeatmapsAverageObservedLevelsWithoutFillingMissingHoursOrConfusingZero() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: now)
        let samples = [UsageHistorySample(date: start.addingTimeInterval(3600), windows: snapshot(used: 0).windows), UsageHistorySample(date: start.addingTimeInterval(3700), windows: snapshot(used: 20).windows), UsageHistorySample(date: start.addingTimeInterval(7200), windows: snapshot(used: 0).windows)]
        let cells = HeatmapData.buckets(samples: samples, windowID: "week", measure: .used, period: .daily, date: now, calendar: calendar)
        XCTAssertEqual(cells.count, 24); XCTAssertNil(cells[0].value); XCTAssertEqual(cells[1].value, 10); XCTAssertEqual(cells[2].value, 0)
        XCTAssertEqual(HeatmapData.buckets(samples: samples, windowID: "other", measure: .used, period: .daily, date: now, calendar: calendar).compactMap(\.value), [])
        XCTAssertEqual(HeatmapData.buckets(samples: samples, windowID: "week", measure: .used, period: .weekly, date: now, calendar: calendar).count, 168)
    }
    func testWeeklyNumberHasPriorityEvenWithThreeRingsAndPerRingUsedOverride() {
        let session = UsageWindow(id: "session", title: "5-hour window", usedPercent: 15, resetsAt: now.addingTimeInterval(3600), duration: 18000)
        var account = AgentAccount(provider: .claude, snapshot: snapshot(used: 37))
        account.snapshot?.windows.insert(session, at: 0)
        XCTAssertEqual(account.readings(at: now).count, 3); XCTAssertEqual(account.readings(at: now).primary?.value, "63%")
        account.display = AccountDisplay(rings: [RingDefinition(windowID: "session"), RingDefinition(windowID: "week", direction: .used), RingDefinition(windowID: "week", kind: .time)])
        XCTAssertEqual(account.readings(at: now).primary?.value, "37%")
    }
    func testCountsAreNeverDerivedFromPercentagesAndOldWindowsStillDecode() throws {
        let window = snapshot().windows[0]
        XCTAssertNil(HistoryMeasure.amount.value(window))
        let roundtrip = try JSONDecoder().decode(UsageWindow.self, from: JSONEncoder().encode(window))
        XCTAssertNil(roundtrip.usedAmount)
        let copilot = try UsageParser.copilot(["token_based_billing": true, "quota_snapshots": ["premium_interactions": ["entitlement": 1500, "percent_remaining": 16.8, "credits_used": 1247.0]]])
        XCTAssertEqual(copilot.windows.first?.usedAmount, 1247); XCTAssertEqual(copilot.windows.first?.amountUnit, "AI credits")
    }
}
