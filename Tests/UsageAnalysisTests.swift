import XCTest
@testable import Eyeballs

final class UsageAnalysisTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_971_200)
    func sample(_ hours: Double, _ used: Double?, reset: Date? = nil) -> UsageHistorySample {
        UsageHistorySample(date: now.addingTimeInterval(hours * 3600), windows: [UsageWindow(id: "week", title: "Weekly", usedPercent: used, resetsAt: reset ?? now.addingTimeInterval(604800), duration: 604800)])
    }
    func testSelectionIsBoundedAndSnapsToObservedDates() {
        let domain = now.addingTimeInterval(-86400)...now
        let dates = [now.addingTimeInterval(-3600), now]
        XCTAssertEqual(HistorySelection.nearest(now.addingTimeInterval(10 * 86400), dates: dates, domain: domain), now)
        XCTAssertEqual(HistorySelection.nearest(now.addingTimeInterval(-3550), dates: dates, domain: domain), dates[0])
        XCTAssertNil(HistorySelection.nearest(now.addingTimeInterval(-43200), dates: dates, domain: domain))
        XCTAssertNil(HistorySelection.nearest(now, dates: [now.addingTimeInterval(86400)], domain: domain))
    }
    func testDenseChartRenderingKeepsSpikesResetDropsAndEndpoints() {
        let points = (0..<12000).map { index in HistorySeries.Point(date: now.addingTimeInterval(Double(index)), usedPercent: index == 5555 ? 100 : index == 5556 ? 0 : 20) }
        let rendered = HistorySeries.renderPoints(points)
        XCTAssertLessThanOrEqual(rendered.count, 600)
        XCTAssertEqual(rendered.first?.date, points.first?.date); XCTAssertEqual(rendered.last?.date, points.last?.date)
        XCTAssertTrue(rendered.contains { $0.date == points[5555].date && $0.usedPercent == 100 })
        XCTAssertTrue(rendered.contains { $0.date == points[5556].date && $0.usedPercent == 0 })
        XCTAssertEqual(rendered.map(\.date), rendered.map(\.date).sorted())
    }
    func testRepeatedUnchangedReadsRetainEvidenceForZeroBurn() {
        let store = UsageHistoryStore(directory: FileManager.default.temporaryDirectory)
        var samples: [UsageHistorySample] = []
        for minute in 0...60 {
            let date = now.addingTimeInterval(Double(minute - 60) * 60)
            samples = store.append(UsageSnapshot(windows: sample(0, 20).windows, updatedAt: date), to: samples, now: now)
        }
        XCTAssertEqual(samples.first?.date, now.addingTimeInterval(-3600)); XCTAssertEqual(samples.last?.date, now)
        XCTAssertLessThan(samples.count, 30)
        XCTAssertEqual(BurnRate.estimate(samples: samples, windowID: "week", hours: 1, now: now)?.limit, .noChange)
    }
    func testBurnRateUsesCurrentCycleAndEstimatesExhaustion() throws {
        let result = try XCTUnwrap(BurnRate.estimate(samples: [sample(-1, 20), sample(-0.5, 25), sample(0, 30)], windowID: "week", hours: 1, now: now))
        XCTAssertEqual(result.perHour, 10, accuracy: 0.001)
        XCTAssertEqual(result.limit, .reachesZero(7 * 3600))
        let dueSoon = now.addingTimeInterval(3600)
        XCTAssertEqual(BurnRate.estimate(samples: [sample(-1, 20, reset: dueSoon), sample(0, 30, reset: dueSoon)], windowID: "week", hours: 1, now: now)?.limit, .resetsFirst)
    }
    func testBurnRateDoesNotAverageAcrossResetsMissingReadsOrStaleData() {
        let reads = [sample(-6, 20), sample(-5, 60), sample(-1, 0), sample(0, 5)]
        XCTAssertNil(BurnRate.estimate(samples: reads, windowID: "week", hours: 6, now: now))
        XCTAssertNil(BurnRate.estimate(samples: [sample(-6, 20), sample(-1, nil), sample(0, 40)], windowID: "week", hours: 6, now: now))
        XCTAssertNil(BurnRate.estimate(samples: [sample(-1, 20), sample(-0.51, 30)], windowID: "week", hours: 1, now: now))
        let changed = [sample(-1, 20), sample(0, 30, reset: now.addingTimeInterval(2 * 604800))]
        XCTAssertNil(BurnRate.estimate(samples: changed, windowID: "week", hours: 1, now: now))
    }
    func testBurnRateKeepsZeroAndExhaustedAllowanceDistinct() {
        XCTAssertEqual(BurnRate.estimate(samples: [sample(-1, 20), sample(0, 20)], windowID: "week", hours: 1, now: now), BurnEstimate(perHour: 0, limit: .noChange))
        XCTAssertEqual(BurnRate.estimate(samples: [sample(-1, 90), sample(0, 100)], windowID: "week", hours: 1, now: now)?.limit, .exhausted)
        XCTAssertNil(BurnRate.estimate(samples: [sample(0, 30)], windowID: "week", hours: 1, now: now))
    }
    func testObservedEventsBreakForecastEvenWhenCountersDoNotDrop() {
        let event = AccountEvent(id: "reset", accountID: UUID(), kind: .earlyReset, date: now.addingTimeInterval(-1800), detectedAt: now, window: "Weekly", windowID: "week")
        XCTAssertNil(BurnRate.estimate(samples: [sample(-1, 20), sample(0, 30)], windowID: "week", hours: 1, events: [event], now: now))
    }
    func testActivityCountsIncreasesAndKeepsResetsUnknownAndZeroDistinct() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: now)
        func read(_ minutes: Double, _ used: Double?) -> UsageHistorySample {
            var value = sample(0, used); value.date = start.addingTimeInterval(minutes * 60); return value
        }
        let reads = [read(5, 10), read(20, 15), read(35, 20), read(65, 0), read(80, 0), read(120, nil), read(125, 10), read(140, 13)]
        let cells = HeatmapData.buckets(samples: reads, windowID: "week", measure: .remaining, period: .daily, date: now, calendar: calendar, mode: .activity)
        XCTAssertEqual(cells[0].value, 10); XCTAssertEqual(cells[1].value, 0); XCTAssertEqual(cells[2].value, 3); XCTAssertNil(cells[3].value)
        XCTAssertEqual(calendar.component(.hour, from: cells[2].date), 2)
        let gap = HeatmapData.buckets(samples: [read(5, 10), read(185, 40)], windowID: "week", measure: .used, period: .daily, date: now, calendar: calendar, mode: .activity)
        XCTAssertTrue(gap.allSatisfy { $0.value == nil })
    }
    func testActivityUsesReportedAmountWithoutConvertingPercentages() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: now)
        var first = sample(0, 10); first.date = start.addingTimeInterval(60); first.windows[0].usedAmount = 23
        var second = sample(0, 50); second.date = start.addingTimeInterval(600); second.windows[0].usedAmount = 25
        let cells = HeatmapData.buckets(samples: [first, second], windowID: "week", measure: .amount, period: .daily, date: now, calendar: calendar, mode: .activity)
        XCTAssertEqual(cells[0].value, 2)
        first.windows[0].usedAmount = nil; second.windows[0].usedAmount = nil
        XCTAssertTrue(HeatmapData.buckets(samples: [first, second], windowID: "week", measure: .amount, period: .daily, date: now, calendar: calendar, mode: .activity).allSatisfy { $0.value == nil })
    }
    func testCalendarMonthAlignmentUsesLocalFirstWeekday() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!; calendar.firstWeekday = 2
        let october = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2))!
        XCTAssertEqual(HeatmapData.monthOffset(date: october, calendar: calendar), 3)
        let cells = HeatmapData.buckets(samples: [], windowID: "week", measure: .used, period: .monthly, date: october, calendar: calendar)
        XCTAssertEqual(cells.count, 31); XCTAssertEqual(calendar.component(.day, from: cells[0].date), 1)
        calendar.firstWeekday = 1
        XCTAssertEqual(HeatmapData.monthOffset(date: october, calendar: calendar), 4)
    }
    func testChartEventsAreRelevantClusteredAndOldEventsStillDecode() throws {
        let account = UUID()
        let reset = AccountEvent(id: "reset", accountID: account, kind: .earlyReset, date: now, detectedAt: now, window: "Weekly")
        let banked = AccountEvent(id: "banked", accountID: account, kind: .bankedUsed, date: now, detectedAt: now, count: 1, inferred: true)
        let window = sample(0, 20).windows[0]
        let groups = ChartEvents.groups(events: [reset, banked], windows: [window], domain: now.addingTimeInterval(-604800)...now)
        XCTAssertEqual(groups.count, 1); XCTAssertEqual(groups[0].events.count, 2)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(reset)) as? [String: Any]); object.removeValue(forKey: "windowID")
        let old = try JSONDecoder().decode(AccountEvent.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.windowID); XCTAssertEqual(old.window, "Weekly")
        XCTAssertTrue(ChartEvents.groups(events: [reset], windows: [UsageWindow(id: "session", title: "5-hour window")], domain: now.addingTimeInterval(-604800)...now).isEmpty)
    }
}
