import XCTest
@testable import Requota

final class ChartRefinementTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_791_072_000)
    func sample(_ hours: Double, used: Double?, reset: Double = 168, duration: Double = 604800) -> UsageHistorySample {
        .init(date: now.addingTimeInterval(hours * 3600), windows: [.init(id: "week", title: "Weekly", usedPercent: used, resetsAt: now.addingTimeInterval(reset * 3600), duration: duration)])
    }
    func testSparseLevelTraceUsesBridgeWithoutInventingAReadingOrResetPlateau() {
        let data = HistorySeries.plot(samples: [sample(0, used: 10), sample(12, used: 40)], windowID: "week", measure: .used)
        XCTAssertEqual(data.bridges.count, 1); XCTAssertEqual(data.bridges[0].map(\.usedPercent), [10, 40]); XCTAssertTrue(data.transitions.isEmpty)
        XCTAssertNil(ChartReadings.at(now.addingTimeInterval(6 * 3600), segments: data.segments))
        let unknown = HistorySeries.plot(samples: [sample(0, used: 10), sample(6, used: nil), sample(12, used: 40)], windowID: "week", measure: .used)
        XCTAssertTrue(unknown.bridges.isEmpty)
        var upgraded = sample(12, used: 40); upgraded.allowanceContext = "Max"
        var old = sample(0, used: 10); old.allowanceContext = "Pro"
        XCTAssertTrue(HistorySeries.plot(samples: [old, upgraded], windowID: "week", measure: .used).bridges.isEmpty)
    }
    func testTierChangesAndUnobservedResetsAreNotConnectedOrCountedAsActivity() {
        var a = sample(0, used: 10); a.allowanceContext = "Max"
        var b = sample(1, used: 70); b.allowanceContext = "Pro"
        let plot = HistorySeries.plot(samples: [a,b], windowID: "week", measure: .used)
        XCTAssertEqual(plot.segments.count, 2); XCTAssertTrue(plot.bridges.isEmpty); XCTAssertTrue(plot.transitions.isEmpty)
        XCTAssertTrue(HeatmapData.buckets(samples: [a,b], windowID: "week", measure: .used, period: .daily, date: now, mode: .activity).allSatisfy { $0.value == nil })
        let resetGap = HistorySeries.plot(samples: [sample(0, used: 90, reset: 5), sample(12, used: 20, reset: 17)], windowID: "week", measure: .used)
        XCTAssertTrue(resetGap.bridges.isEmpty); XCTAssertEqual(resetGap.segments.count, 2)
    }
    func testPartiallyCoveredRateWindowWeightsOnlyObservedIntervals() {
        let rates = HistoryRate.segments(samples: [sample(0, used: 0), sample(0.5, used: 5), sample(1.5, used: 25)], windowID: "week", measure: .used, averagingHours: 1)
        XCTAssertEqual(rates.last?.last?.usedPercent, 20)
        let resetHole = HistoryRate.segments(samples: [sample(0, used: 0), sample(0.25, used: 5), sample(0.75, used: 0), sample(1, used: 5)], windowID: "week", measure: .used, averagingHours: 1)
        XCTAssertEqual(resetHole.last?.last?.usedPercent, 20)
    }
    func testRateSpansFiveHourResetsWithoutCountingDropAsBurn() {
        var reads: [UsageHistorySample] = []
        for index in 0...60 { reads.append(sample(Double(index) / 4, used: Double(index % 20) * 5, reset: Double(index / 20 + 1) * 5, duration: 18000)) }
        let data = HistoryRate.segments(samples: reads, windowID: "week", measure: .used, averagingHours: 6)
        XCTAssertEqual(data.count, 1)
        XCTAssertTrue(data[0].allSatisfy { abs($0.usedPercent - 20) < 0.0001 })
        XCTAssertGreaterThan(data[0].last!.date.timeIntervalSince(data[0].first!.date), 5 * 3600)
        XCTAssertTrue(HistoryRate.segments(samples: [sample(0, used: 10), sample(0.25, used: 20)], windowID: "week", measure: .used, averagingHours: 12).isEmpty)
    }
    func testSmoothingRemovesQuantizationNotchesWhilePreservingZeroAndFullPlateaus() {
        let original = (0...100).map { index in HistorySeries.Point(date: now.addingTimeInterval(Double(index) * 60), usedPercent: floor(Double(index) / 2)) }
        let simplified = ChartSmoothing.points(original)
        XCTAssertLessThan(simplified.count, original.count / 4)
        XCTAssertEqual(simplified.first?.usedPercent, 0); XCTAssertEqual(simplified.last?.usedPercent, 50)
        for point in original {
            if let reading = ChartReadings.at(point.date, segments: [simplified]) { XCTAssertLessThanOrEqual(abs(reading.value - point.usedPercent), 0.75) }
        }
        let limits = [0.0, 0, 20, 100, 100, 100].enumerated().map { HistorySeries.Point(date: now.addingTimeInterval(Double($0.offset) * 60), usedPercent: $0.element) }
        let result = ChartSmoothing.points(limits)
        XCTAssertEqual(ChartReadings.at(limits[1].date, segments: [result])?.value, 0)
        XCTAssertEqual(ChartReadings.at(limits[4].date, segments: [result])?.value, 100)
    }
    func testExplicitSmoothCurveIsBoundedContinuousAndKeepsFlatQuotaEdges() {
        let original = [0.0, 0, 20, 21, 80, 100, 100].enumerated().map { HistorySeries.Point(date: now.addingTimeInterval(Double($0.offset) * 60), usedPercent: $0.element) }
        let curve = ChartSmoothing.curve(original)
        XCTAssertTrue(curve.allSatisfy { (0...100).contains($0.usedPercent) })
        XCTAssertTrue(zip(curve, curve.dropFirst()).allSatisfy { $0.usedPercent <= $1.usedPercent })
        XCTAssertEqual(ChartReadings.at(now.addingTimeInterval(30), segments: [curve])?.value, 0)
        XCTAssertEqual(ChartReadings.at(now.addingTimeInterval(330), segments: [curve])?.value, 100)
        for point in original { XCTAssertEqual(ChartReadings.at(point.date, segments: [curve])?.value, point.usedPercent) }
        let reverse = original.map { HistorySeries.Point(date: $0.date, usedPercent: 100 - $0.usedPercent) }
        XCTAssertTrue(zip(ChartSmoothing.curve(reverse), ChartSmoothing.curve(reverse).dropFirst()).allSatisfy { $0.usedPercent >= $1.usedPercent })
        let patterns = (0..<60).map { ChartDashPattern.pattern($0) }
        XCTAssertEqual(Set(patterns).count, 60)
    }
    func testContinuousReadoutInterpolatesStoredSamplesButDoesNotCrossResetOrUnknown() {
        let a = HistorySeries.Point(date: now, usedPercent: 10), b = HistorySeries.Point(date: now.addingTimeInterval(3600), usedPercent: 20)
        XCTAssertEqual(ChartReadings.at(now.addingTimeInterval(1800), segments: [[a,b]])?.value, 15)
        XCTAssertEqual(ChartReadings.at(now.addingTimeInterval(1800), segments: [[a,b]], stepped: true)?.value, 10)
        XCTAssertEqual(ChartReadings.at(a.date, segments: [[a,b]])?.estimated, false)
        XCTAssertEqual(ChartReadings.at(now.addingTimeInterval(1800), segments: [[a,b]])?.estimated, true)
        XCTAssertNil(ChartReadings.at(now.addingTimeInterval(1800), segments: [[a],[b]]))
    }
    func testHeatmapAmortizationConservesConsumptionAcrossHourAndDayBoundaries() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: now)
        var a = sample(0, used: 10); a.date = start.addingTimeInterval(1800)
        var b = sample(0, used: 30); b.date = start.addingTimeInterval(5400)
        let hourly = HeatmapData.buckets(samples: [a,b], windowID: "week", measure: .used, period: .daily, date: start, calendar: calendar, mode: .activity)
        XCTAssertEqual(hourly[0].value, 10); XCTAssertEqual(hourly[1].value, 10); XCTAssertNil(hourly[2].value)
        a.date = start.addingTimeInterval(-3600); b.date = start.addingTimeInterval(3600)
        let days = HeatmapData.buckets(samples: [a,b], windowID: "week", measure: .used, period: .monthly, date: start, calendar: calendar, mode: .activity)
        XCTAssertEqual(days.compactMap(\.value).reduce(0,+), 20, accuracy: 0.0001)
        b.windows[0].usedPercent = 0
        XCTAssertTrue(HeatmapData.buckets(samples: [a,b], windowID: "week", measure: .used, period: .daily, date: start, calendar: calendar, mode: .activity).allSatisfy { $0.value == nil })
    }
    func testCombinedHeatmapKeepsUnknownAndZeroDistinctAndUsesOneWindowPerAccount() {
        let cells = [HeatmapBucket(id: 0, label: "0", date: now, value: 10), .init(id: 1, label: "1", date: now, value: nil)]
        var other = cells; other[0].value = 20; other[1].value = 0
        XCTAssertEqual(CombinedActivity.combine([cells,other], amount: false).map(\.value), [15,0])
        XCTAssertEqual(CombinedActivity.combine([cells,other], amount: true).map(\.value), [30,0])
        XCTAssertNil(CombinedActivity.combine([cells], amount: false)[1].value)
        let account = AgentAccount(provider: .claude, snapshot: .init(windows: sample(0, used: 10).windows))
        let weekly = ActivitySeries(id: "weekly", account: account, window: account.snapshot!.windows[0], samples: [], events: [])
        var model = weekly; model.id = "model"; model.window.id = "model"
        var short = weekly; short.id = "short"; short.window.duration = 18000; short.window.title = "5-hour"
        XCTAssertEqual(CombinedActivity.uniqueAccounts([model,short,weekly], windowClass: .weekly).map(\.id), ["weekly"])
    }
    func testCopilotAdditionalBudgetAndUnlimitedUsageStaySeparateFromIncludedQuota() throws {
        let raw: [String: Any] = ["token_based_billing": true, "quota_snapshots": ["premium_interactions": ["entitlement": "1500", "credits_used": "1500", "percent_remaining": 0, "overage_count": 40, "overage_entitlement": 100, "overage_permitted": true], "chat": ["unlimited": true, "credits_used": "2.5"]]]
        let snapshot = try UsageParser.copilot(raw)
        XCTAssertEqual(snapshot.windows.first { $0.id == "additional-budget" }?.usedPercent, 40)
        XCTAssertEqual(snapshot.details?.usage?.first { $0.id == "copilot-overage" }?.remaining, 60)
        XCTAssertEqual(snapshot.details?.usage?.first { $0.id == "copilot-chat" }?.used, 2.5)
        XCTAssertEqual(snapshot.details?.usage?.first { $0.id == "copilot-chat" }?.unlimited, true)
        XCTAssertFalse(snapshot.windows.contains { $0.id == "chat" })
    }
    func testGeminiReportedAmountsAndGrokSpendingHaveNoInventedAllowance() throws {
        let gemini = try UsageParser.gemini(["buckets": [["modelId": "gemini", "tokenType": "REQUESTS", "remainingAmount": "123", "remainingFraction": 0.5]]])
        XCTAssertEqual(gemini.remainingAllowances?.first?.remaining, 123)
        XCTAssertNil(gemini.windows.first?.usedAmount); XCTAssertNil(gemini.windows.first?.limitAmount)
        let grok = try UsageParser.grok(["config": ["creditUsagePercent": 100, "onDemandUsed": ["val": "1234"]]])
        XCTAssertEqual(grok.details?.spending.first?.used, 12.34)
        XCTAssertNil(grok.details?.spending.first?.limit)
    }
    func testBalanceAndProviderCountersAreRetainedWithoutCopyingModelCatalogues() throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = UsageHistoryStore(directory: location)
        defer { try? FileManager.default.removeItem(at: location) }
        var details = ProviderDetails(); details.models = [.init(id: "model", title: "Model", available: true)]; details.spending = [.init(id: "extra", title: "Extra", used: 2, currency: "USD")]
        let first = UsageSnapshot(creditBalance: "10", updatedAt: now, details: details)
        var next = first; next.updatedAt = now.addingTimeInterval(60); next.creditBalance = "9"
        let readings = store.append(next, to: store.append(first, to: [], now: now), now: next.updatedAt)
        XCTAssertEqual(readings.last?.creditBalance, "9"); XCTAssertTrue(readings.last?.providerDetails?.models.isEmpty == true)
        XCTAssertEqual(readings.last?.providerDetails?.spending.first?.used, 2)
        try store.write(readings, id: UUID())
        let old = Data(#"{"date":0,"windows":[]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(UsageHistorySample.self, from: old).creditBalance)
    }
}
