import XCTest
@testable import Eyeballs

final class DisplayAndHistoryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func account(used: Double? = 25) -> AgentAccount {
        AgentAccount(provider: .codex, snapshot: UsageSnapshot(windows: [UsageWindow(id: "week", title: "Weekly", usedPercent: used, resetsAt: now.addingTimeInterval(302400), duration: 604800)], email: "private@example.com", identity: "private-subject", updatedAt: now))
    }
    func testExistingAccountsDecodeWithRemainingDefault() throws {
        let original = account(); let data = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]); object.removeValue(forKey: "display")
        let decoded = try JSONDecoder().decode(AgentAccount.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.display); XCTAssertEqual(decoded.readings(at: now).first?.percent, 75)
        XCTAssertEqual(decoded.id, original.id); XCTAssertEqual(decoded.snapshot?.identity, "private-subject")
    }
    func testPerRingDirectionsAndTimeUseProviderDuration() {
        var a = account()
        a.display = AccountDisplay(direction: .remaining, rings: [RingDefinition(windowID: "week"), RingDefinition(windowID: "week", kind: .time, direction: .used)])
        let readings = a.readings(at: now)
        XCTAssertEqual(readings.map(\.percent), [75, 50]); XCTAssertEqual(readings[1].caption, "elapsed")
        XCTAssertEqual(a.readings(at: now.addingTimeInterval(302400))[0].percent, 75) // Cached quota is unchanged at reset.
        XCTAssertEqual(a.readings(at: now.addingTimeInterval(302400))[1].percent, 100)
        XCTAssertEqual(a.readings(at: now.addingTimeInterval(-604800))[1].percent, 0)
    }
    func testUnknownQuotaAndTimeRemainUnknown() {
        var a = account(used: nil); a.snapshot?.windows[0].duration = nil
        a.display = AccountDisplay(rings: [RingDefinition(windowID: "week"), RingDefinition(windowID: "week", kind: .time)])
        XCTAssertTrue(a.readings(at: now).allSatisfy { $0.percent == nil })
    }
    func testEmptyConfigurationStaysEmptyAndRoundTrips() throws {
        var a = account(); a.display = AccountDisplay(direction: .used, rings: [])
        let restored = try JSONDecoder().decode(AgentAccount.self, from: JSONEncoder().encode(a))
        XCTAssertTrue(restored.readings().isEmpty); XCTAssertEqual(restored.display, a.display)
    }
    func testSortingKeepsUnavailableLastAndUsesStableTies() {
        var low = account(used: 90); low.label = "Low"
        var high = account(used: 10); high.label = "High"
        var unknown = account(used: nil); unknown.label = "Unknown"
        XCTAssertEqual(AccountSort.mostRemaining.sorted([low, unknown, high]).map(\.title), ["High", "Low", "Unknown"])
        XCTAssertEqual(AccountSort.leastRemaining.sorted([low, unknown, high]).map(\.title), ["Low", "High", "Unknown"])
        XCTAssertEqual(AccountSort.weeklyRemaining.sorted([unknown, low, high]).map(\.title), ["High", "Low", "Unknown"])
    }
    func testWidgetCacheIsAtomicPrivateAndPreservesDisplayChoices() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("summary.json")
        var a = account(); a.notes = "Secret notes"; a.issue = "Error private@example.com"; a.display = AccountDisplay(direction: .used, rings: [RingDefinition(windowID: "week", kind: .time)])
        try WidgetCache.write([a], to: path)
        let raw = String(decoding: try Data(contentsOf: path), as: UTF8.self)
        for secret in ["private@example.com", "private-subject", "Secret notes", "Error private"] { XCTAssertFalse(raw.contains(secret)) }
        XCTAssertEqual(WidgetCache.read(from: path)?.first?.display, a.display)
        try WidgetCache.write([], to: path); XCTAssertEqual(WidgetCache.read(from: path), [])
    }
    func testEntityResolutionPreservesChoiceOrderAndOmitsDeletedAccounts() {
        let a = account(), b = account()
        let result = AccountQuery.resolve([b.id.uuidString.lowercased(), "deleted", a.id.uuidString, b.id.uuidString], accounts: [a, b])
        XCTAssertEqual(result.map(\.id), [b.id.uuidString, a.id.uuidString])
    }
    func testWidgetWeeklyTimePresetAndAmountOverride() {
        let a = account()
        let settings = WidgetMetrics.weekAndTime.settings(for: a, amount: .remaining)
        XCTAssertEqual(a.readings(at: now, settings: settings).map(\.percent), [75, 50])
        XCTAssertEqual(a.readings(at: now, settings: WidgetMetrics.weekAndTime.settings(for: a, amount: .used)).map(\.percent), [25, 50])
    }
    func testHistoryStoresOnlyObservedValuesAndPrunesOldSamples() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageHistoryStore(directory: directory); let a = account(); let snapshot = a.snapshot!
        let old = UsageHistorySample(date: now.addingTimeInterval(-91 * 86400), windows: snapshot.windows)
        let samples = store.append(snapshot, to: [old], now: now)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(store.append(snapshot, to: samples, now: now), samples)
        try store.write(samples, id: a.id); XCTAssertEqual(store.read(a.id, now: now), samples)
        let raw = String(decoding: try Data(contentsOf: directory.appendingPathComponent(a.id.uuidString + ".json")), as: UTF8.self)
        XCTAssertFalse(raw.contains("private@example.com")); XCTAssertFalse(raw.contains("private-subject"))
        try store.remove(a.id); XCTAssertTrue(store.read(a.id, now: now).isEmpty)
    }
    func testHistorySplitsGapsResetsAndUnknownValues() {
        let original = account().snapshot!.windows
        var reset = original; reset[0].resetsAt = now.addingTimeInterval(604800); reset[0].usedPercent = 0
        var unknown = original; unknown[0].usedPercent = nil
        let samples = [UsageHistorySample(date: now, windows: original), UsageHistorySample(date: now.addingTimeInterval(60), windows: original), UsageHistorySample(date: now.addingTimeInterval(8000), windows: original), UsageHistorySample(date: now.addingTimeInterval(8060), windows: reset), UsageHistorySample(date: now.addingTimeInterval(8120), windows: unknown), UsageHistorySample(date: now.addingTimeInterval(8180), windows: reset)]
        XCTAssertEqual(HistorySeries.segments(samples: samples, windowID: "week").map(\.count), [2, 1, 1, 1])
    }
    @MainActor
    func testDebugBundleCannotIncludeAccountIdentityOrPrivateText() throws {
        var a = account(); a.label = "Private label"; a.workstream = "Private workstream"; a.notes = "Private notes"; a.issue = "token=secret"
        let data = try Diagnostics.encode(Diagnostics.bundle(accounts: [a], now: now))
        let raw = String(decoding: data, as: UTF8.self)
        for privateValue in [a.id.uuidString, "Private label", "Private workstream", "Private notes", "private@example.com", "private-subject", "token=secret"] { XCTAssertFalse(raw.contains(privateValue)) }
        XCTAssertTrue(raw.contains("codex"))
        XCTAssertEqual(DiagnosticFailure.category(NSError(domain: "private@example.com token=secret", code: 1)), .other)
    }
}
