import XCTest
@testable import Requota

final class AllowanceTransitionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_971_200)
    func window(used: Double = 70, limit: Double = 100) -> UsageWindow {
        UsageWindow(id: "week", title: "Weekly", usedPercent: used, resetsAt: now.addingTimeInterval(86400), duration: 604800, usedAmount: used, limitAmount: limit, amountUnit: "credits")
    }
    func testPlanChangeDoesNotBecomeAnEarlyOrBankedResetUse() {
        let old = UsageSnapshot(windows: [window()], plan: "Pro", updatedAt: now.addingTimeInterval(-60), allowanceContext: "pro")
        let new = UsageSnapshot(windows: [window(used: 0, limit: 1000)], plan: "Max 20×", updatedAt: now, allowanceContext: "max20")
        let events = EventDetection.compare(accountID: UUID(), previous: old, current: new).events
        XCTAssertEqual(events.map(\.kind), [.allowanceChanged]); XCTAssertEqual(events.first?.detail, "Pro → Max 20×")
        XCTAssertFalse(ResetNotificationRules().announces(.allowanceChanged))
    }
    func testUnknownPlanAndMissingMetricDoNotInventTierChanges() {
        let old = UsageSnapshot(windows: [window()], updatedAt: now.addingTimeInterval(-60))
        let new = UsageSnapshot(windows: [], plan: "Max", updatedAt: now)
        XCTAssertFalse(AllowanceChanges.snapshotChanged(old, new))
        XCTAssertTrue(EventDetection.compare(accountID: UUID(), previous: old, current: new).events.isEmpty)
    }
    func testOrdinaryCalendarMonthLengthChangeIsNotATierChange() {
        var old = window(); var new = old
        old.duration = 30 * 86400; new.duration = 31 * 86400
        XCTAssertFalse(AllowanceChanges.windowChanged(old, new))
        new.duration = 7 * 86400
        XCTAssertTrue(AllowanceChanges.windowChanged(old, new))
    }
    func testPlanAndLimitChangesBreakSeriesForecastAndActivity() {
        var first = UsageHistorySample(date: now.addingTimeInterval(-3600), windows: [window(used: 20)], allowanceContext: "pro")
        var last = UsageHistorySample(date: now, windows: [window(used: 30)], allowanceContext: "max")
        XCTAssertEqual(HistorySeries.segments(samples: [first, last], windowID: "week").count, 2)
        XCTAssertNil(BurnRate.estimate(samples: [first, last], windowID: "week", hours: 1, now: now))
        let cells = HeatmapData.buckets(samples: [first, last], windowID: "week", measure: .used, period: .monthly, date: now, mode: .activity)
        XCTAssertTrue(cells.allSatisfy { $0.value == nil })
        first.allowanceContext = nil; last.allowanceContext = nil; last.windows[0].limitAmount = 1000
        XCTAssertEqual(HistorySeries.segments(samples: [first, last], windowID: "week").count, 2)
        XCTAssertNil(BurnRate.estimate(samples: [first, last], windowID: "week", hours: 1, now: now))
    }
    func testDifferentAmountUnitsNeverShareAChartSeries() {
        let first = UsageHistorySample(date: now.addingTimeInterval(-3600), windows: [window(used: 20)])
        var last = UsageHistorySample(date: now, windows: [window(used: 30)]); last.windows[0].amountUnit = "requests"
        let segments = HistorySeries.segments(samples: [first, last], windowID: "week", measure: .amount, unit: "requests")
        XCTAssertEqual(segments.count, 1); XCTAssertEqual(segments[0].count, 1); XCTAssertEqual(segments[0][0].usedPercent, 30)
        let buckets = HeatmapData.buckets(samples: [first, last], windowID: "week", measure: .amount, period: .monthly, date: now, unit: "requests")
        XCTAssertEqual(buckets.compactMap(\.value), [30])
    }
    func testClaudeLiveProfileTierFieldsKeepMaxTiersDistinctWithoutIdentityData() throws {
        let raw: [String: Any] = ["organization": ["organization_type": "claude_max", "rate_limit_tier": "default_claude_max_20x", "uuid": "private-org", "name": "private-name"]]
        let twenty = UsageParser.claudePlan(raw)
        XCTAssertEqual(twenty.plan, "Max 20×"); XCTAssertEqual(twenty.context?.count, 64)
        let five = UsageParser.claudePlan(["organization": ["organization_type": "claude_max", "rate_limit_tier": "default_claude_max_5x"]])
        XCTAssertEqual(five.plan, "Max 5×"); XCTAssertNotEqual(twenty.context, five.context)
        let same = UsageParser.claudePlan(["organization": ["organization_type": "claude_max", "rate_limit_tier": "default_claude_max_20x", "uuid": "other", "name": "other"]])
        XCTAssertEqual(twenty.context, same.context); XCTAssertNil(UsageParser.claudePlan([:]).plan)
    }
    func testModelNamesSurviveCompactTitlesAndOldHistoryStillDecodes() throws {
        let model = UsageWindow(id: "opus", title: "Opus weekly", usedPercent: 12, duration: 604800)
        XCTAssertEqual(model.shortTitle, "Opus weekly")
        XCTAssertEqual(UsageWindow(id: "review", title: "Code review", duration: 18000).shortTitle, "Code review")
        let first = UsageHistorySample(date: now, windows: [window()])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any]); object.removeValue(forKey: "allowanceContext")
        XCTAssertNil(try JSONDecoder().decode(UsageHistorySample.self, from: JSONSerialization.data(withJSONObject: object)).allowanceContext)
    }
}

@MainActor
final class PersistentTierDisplayTests: XCTestCase {
    func testDowngradeAndUpgradePreserveRingChoicesNamesColoursAndHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = MemoryVault(); let credential = Fixture.credential("tier")
        var account = Fixture.account(credential)
        let model = UsageWindow(id: "model", title: "Opus weekly", usedPercent: 10, resetsAt: .now.addingTimeInterval(86400), duration: 604800)
        account.snapshot?.windows.append(model); account.snapshot?.plan = "Max"
        account.display = AccountDisplay(direction: .used, rings: [RingDefinition(windowID: "model", direction: .remaining), RingDefinition(windowID: "model", kind: .time)])
        account.colorHex = 0xABCDEF
        var lower = account.snapshot!; lower.windows.removeLast(); lower.plan = "Pro"; lower.updatedAt = .now.addingTimeInterval(1)
        let store = AccountStore(location: directory.appendingPathComponent("accounts.json"), vault: vault, integratesWithSystem: false, fetcher: { _, _ in lower })
        try store.connect(account, credential: credential); await store.refresh(account.id)
        let downgraded = try XCTUnwrap(store.accounts.first)
        XCTAssertEqual(downgraded.display?.rings.map(\.id), ["model:usage", "model:time"])
        XCTAssertEqual(downgraded.readings()[0].title, "Opus weekly · unavailable"); XCTAssertNil(downgraded.readings()[0].percent)
        XCTAssertEqual(downgraded.colorHex, 0xABCDEF); XCTAssertEqual(store.events.first?.kind, .allowanceChanged)
        let restored = AccountStore(location: directory.appendingPathComponent("accounts.json"), vault: vault, integratesWithSystem: false)
        XCTAssertEqual(restored.accounts.first?.display, downgraded.display)
        XCTAssertEqual(restored.histories[account.id]?.last?.allowanceContext, "Pro")
        var upgraded = account; upgraded.snapshot?.updatedAt = .now.addingTimeInterval(2)
        try restored.connect(upgraded, credential: credential)
        XCTAssertEqual(restored.accounts.first?.readings()[0].value, "90%")
        XCTAssertEqual(restored.accounts.first?.display?.direction, .used)
        XCTAssertEqual(restored.accounts.first?.colorHex, 0xABCDEF)
    }
}
