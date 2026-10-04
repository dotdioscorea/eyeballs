import XCTest
@testable import Requota

final class ChartNavigationAndReminderTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_971_200)
    func sample(_ hours: Double, _ value: Double?, amount: Double? = nil) -> UsageHistorySample {
        .init(date: now.addingTimeInterval(hours * 3600), windows: [.init(id: "week", title: "Weekly", usedPercent: value, resetsAt: now.addingTimeInterval(604800), duration: 604800, usedAmount: amount, amountUnit: "credits")])
    }
    func testPinchKeepsAnchorAndPanCannotEscapeHistory() {
        let bounds = now.addingTimeInterval(-90 * 86400)...now
        let range = now.addingTimeInterval(-7 * 86400)...now
        let zoom = ChartViewport.zoom(range, scale: 2, anchor: 0.25, bounds: bounds)
        XCTAssertEqual(zoom.upperBound.timeIntervalSince(zoom.lowerBound), 3.5 * 86400, accuracy: 0.1)
        XCTAssertEqual(zoom.lowerBound.addingTimeInterval(3.5 * 86400 * 0.25), range.lowerBound.addingTimeInterval(7 * 86400 * 0.25))
        XCTAssertEqual(ChartViewport.pan(zoom, fraction: 10000, bounds: bounds).lowerBound, bounds.lowerBound)
        XCTAssertEqual(ChartViewport.pan(zoom, fraction: -10000, bounds: bounds).upperBound, bounds.upperBound)
        XCTAssertEqual(ChartViewport.zoom(range, scale: 1e10, anchor: 1, bounds: bounds).upperBound.timeIntervalSince(ChartViewport.zoom(range, scale: 1e10, anchor: 1, bounds: bounds).lowerBound), 900)
        XCTAssertEqual(ChartViewport.zoom(range, scale: .nan, anchor: 0, bounds: bounds), range)
    }
    func testNewObservationsPreservePannedViewAndAdvanceFollowingView() {
        let old = now.addingTimeInterval(-7 * 86400)...now
        let new = old.lowerBound.addingTimeInterval(60)...now.addingTimeInterval(60)
        let bounds = now.addingTimeInterval(-90 * 86400)...new.upperBound
        let historical = now.addingTimeInterval(-86400)...now.addingTimeInterval(-3600)
        XCTAssertEqual(ChartViewport.advanced(historical, from: old, to: new, bounds: bounds), historical)
        let following = now.addingTimeInterval(-3600)...now
        XCTAssertEqual(ChartViewport.advanced(following, from: old, to: new, bounds: bounds)?.upperBound, new.upperBound)
        XCTAssertNil(ChartViewport.advanced(historical, from: old, to: now.addingTimeInterval(-86400)...now, bounds: bounds))
    }
    func testBurnRateSpreadsDelayedConsumptionAndWeightsUnequalIntervals() throws {
        let delayed = HistoryRate.segments(samples: [sample(0, 10), sample(3, 40)], windowID: "week", measure: .used)
        XCTAssertEqual(delayed.count, 1)
        XCTAssertTrue(delayed[0].allSatisfy { abs($0.usedPercent - 10) < 0.0001 })
        let unequal = HistoryRate.segments(samples: [sample(0, 0), sample(0.25, 2), sample(1, 5)], windowID: "week", measure: .remaining)
        XCTAssertEqual(try XCTUnwrap(unequal.first?.last?.usedPercent), 5, accuracy: 0.0001)
        let frequent = (0...60).map { sample(Double($0) / 60, Double($0) / 12) }
        XCTAssertEqual(try XCTUnwrap(HistoryRate.segments(samples: frequent, windowID: "week", measure: .used).first?.last?.usedPercent), 5, accuracy: 0.0001)
    }
    func testRateExcludesMissingLongGapsResetAndPlanChangesWithoutLosingZero() {
        XCTAssertTrue(HistoryRate.segments(samples: [sample(0, 10), sample(7, 40)], windowID: "week", measure: .used).isEmpty)
        XCTAssertTrue(HistoryRate.segments(samples: [sample(0, 90), sample(1, 0)], windowID: "week", measure: .used).isEmpty)
        XCTAssertTrue(HistoryRate.segments(samples: [sample(0, 10), sample(1, nil), sample(2, 40)], windowID: "week", measure: .used).isEmpty)
        var changed = sample(1, 20); changed.allowanceContext = "Max"
        var before = sample(0, 10); before.allowanceContext = "Pro"
        XCTAssertTrue(HistoryRate.segments(samples: [before, changed], windowID: "week", measure: .used).isEmpty)
        XCTAssertEqual(HistoryRate.segments(samples: [sample(0, 0), sample(1, 0)], windowID: "week", measure: .used).first?.last?.usedPercent, 0)
        let amounts = HistoryRate.segments(samples: [sample(0, 10, amount: 50), sample(2, 20, amount: 56)], windowID: "week", measure: .amount, unit: "credits")
        XCTAssertEqual(amounts.first?.last?.usedPercent, 3)
        XCTAssertTrue(HistoryRate.segments(samples: [sample(0, 10, amount: 50), sample(2, 20, amount: 56)], windowID: "week", measure: .amount, unit: "tokens").isEmpty)
    }
    func testSmoothSegmentsKeepExactBoundariesAndHardResets() {
        let reads = [sample(0, 0), sample(1, 40), sample(2, 100), sample(3, 0), sample(4, 10), sample(12, 20)]
        let plot = HistorySeries.plot(samples: reads, windowID: "week", measure: .remaining)
        XCTAssertEqual(plot.segments.map { $0.map(\.usedPercent) }, [[100, 60, 0], [100, 90], [80]])
        XCTAssertEqual(plot.transitions.count, 1)
        XCTAssertEqual(plot.transitions[0].map(\.usedPercent), [0, 100])
        XCTAssertEqual(plot.transitions[0].last?.date, reads[3].date)
        let clip = HistorySeries.clipped(plot.segments[0], to: now.addingTimeInterval(1800)...now.addingTimeInterval(5400))
        XCTAssertEqual(clip.map(\.usedPercent), [100, 60, 0])
    }
    func account(_ provider: Provider = .claude, used: Double = 96, resetHours: Double = 12) -> AgentAccount {
        .init(provider: provider, label: "Test", snapshot: .init(windows: [.init(id: "week", title: "Weekly", usedPercent: used, resetsAt: now.addingTimeInterval(resetHours * 3600), duration: 604800)], updatedAt: now))
    }
    func testLowAllowanceCatchUpAndProviderOverrides() throws {
        let low = account(), unused = account(.codex, used: 40)
        let plan = ResetReminderPlan.make(accounts: [low, unused], rules: .init(), now: now)
        XCTAssertTrue(plan.contains { $0.accountID == low.id && $0.id.hasSuffix("-low") && $0.body.contains("4%") && $0.date <= now.addingTimeInterval(2) })
        XCTAssertTrue(plan.contains { $0.accountID == unused.id && $0.id.hasSuffix("-allowance") && $0.date <= now.addingTimeInterval(2) })
        var off = ResetNotificationRules(); off.enabled = false
        let filtered = ResetReminderPlan.make(accounts: [low, unused], rules: .init(), overrides: ["claude": off], now: now)
        XCTAssertTrue(filtered.allSatisfy { $0.accountID == unused.id })
        var rules = ResetNotificationRules(); rules.lowThreshold = 0
        XCTAssertFalse(ResetReminderPlan.make(accounts: [low], rules: rules, now: now).contains { $0.id.hasSuffix("-low") })
        var stale = low; stale.snapshot?.updatedAt = now.addingTimeInterval(-7 * 3600)
        XCTAssertFalse(ResetReminderPlan.make(accounts: [stale], rules: .init(), now: now).contains { $0.id.hasSuffix("-low") })
        var signedOut = low; signedOut.needsLogin = true
        XCTAssertTrue(ResetReminderPlan.make(accounts: [signedOut], rules: .init(), now: now).isEmpty)
    }
    func testReminderLedgerPreventsRepeatedCatchUpAfterRelaunchButAllowsCancelledFuture() throws {
        let plan = ResetReminderPlan.make(accounts: [account()], rules: .init(), now: now)
        let low = try XCTUnwrap(plan.first { $0.id.hasSuffix("-low") })
        let persisted = try JSONDecoder().decode([String: Date].self, from: JSONEncoder().encode([low.id: low.date]))
        XCTAssertFalse(ReminderLedger.shouldAdd(low, ledger: persisted, now: now.addingTimeInterval(60)))
        let future = try XCTUnwrap(plan.first { $0.id.hasSuffix("-reset") })
        let cancelled = ReminderLedger.reconcile([future.id: future.date, low.id: low.date], plan: [], now: now.addingTimeInterval(60))
        XCTAssertNil(cancelled[future.id]); XCTAssertNotNil(cancelled[low.id])
        XCTAssertTrue(ReminderLedger.shouldAdd(future, ledger: cancelled, now: now.addingTimeInterval(60)))
    }
    func testNoResetQuotaRearmsAfterRecoveryAndSentWarningsDoNotOccupyRequestLimit() throws {
        var noReset = account(); noReset.snapshot?.windows[0].resetsAt = nil
        let low = try XCTUnwrap(ResetReminderPlan.make(accounts: [noReset], rules: .init(), now: now).first)
        let fired = [low.id: now.addingTimeInterval(-60)]
        noReset.snapshot?.windows[0].usedPercent = 10
        XCTAssertTrue(ReminderLedger.rearmRecovered(fired, accounts: [noReset], rules: .init(), overrides: [:], now: now).isEmpty)
        noReset.snapshot?.windows[0].usedPercent = nil
        XCTAssertEqual(ReminderLedger.rearmRecovered(fired, accounts: [noReset], rules: .init(), overrides: [:], now: now), fired)
        let plan = (0..<80).map { index in PlannedReminder(id: "test-\(index)", accountID: UUID(), date: now.addingTimeInterval(Double(index + 1)), title: "", body: "") }
        let ledger = Dictionary(uniqueKeysWithValues: plan.prefix(50).map { ($0.id, now.addingTimeInterval(-1)) })
        XCTAssertEqual(ReminderLedger.pendingPlan(plan, ledger: ledger, now: now).count, 30)
    }
    func testExistingNotificationPreferencesMigrateWithoutResettingChoices() throws {
        let old = Data(#"{"weeklyReset":false,"earlyReset":false,"allowanceHours":6,"minimumRemaining":25}"#.utf8)
        let rules = try JSONDecoder().decode(ResetNotificationRules.self, from: old)
        XCTAssertFalse(rules.weeklyReset); XCTAssertFalse(rules.earlyReset)
        XCTAssertEqual(rules.allowanceHours, 6); XCTAssertEqual(rules.minimumRemaining, 25)
        XCTAssertTrue(rules.lowAllowance); XCTAssertEqual(rules.lowThreshold, 10)
    }
    func testLockScreenMetricsUseExactWindowAndConfiguredDirection() throws {
        var account = account(used: 100)
        account.snapshot?.windows.insert(.init(id: "session", title: "5-hour", usedPercent: 25, resetsAt: now.addingTimeInterval(9000), duration: 18000), at: 0)
        XCTAssertEqual(LockScreenMetric.week.reading(for: account, amount: .remaining, at: now)?.value, "0%")
        XCTAssertEqual(LockScreenMetric.week.reading(for: account, amount: .used, at: now)?.value, "100%")
        XCTAssertEqual(LockScreenMetric.sessionTime.reading(for: account, amount: .remaining, at: now)?.value, "50%")
        account.snapshot?.windows.removeAll { $0.id == "session" }
        XCTAssertNil(LockScreenMetric.session.reading(for: account, amount: .remaining, at: now))
    }
}
