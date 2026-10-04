import Foundation

enum HistorySelection {
    static func nearest(_ date: Date?, dates: [Date], domain: ClosedRange<Date>) -> Date? {
        guard let date else { return nil }
        let bounded = min(domain.upperBound, max(domain.lowerBound, date))
        let candidates = dates.filter { domain.contains($0) }
        guard let nearest = candidates.min(by: { abs($0.timeIntervalSince(bounded)) < abs($1.timeIntervalSince(bounded)) }) else { return nil }
        // Do not place a tooltip on an unobserved part of a long gap.
        let tolerance = max(1200, domain.upperBound.timeIntervalSince(domain.lowerBound) / 80)
        return abs(nearest.timeIntervalSince(bounded)) <= tolerance ? nearest : nil
    }
}

enum UsageCycle {
    static func continues(from old: UsageWindow, at oldDate: Date, to new: UsageWindow, at date: Date, events: [AccountEvent] = [], previousContext: String? = nil, currentContext: String? = nil) -> Bool {
        guard date > oldDate else { return false }
        if AllowanceChanges.contextChanged(previousContext, currentContext) || AllowanceChanges.windowChanged(old, new) { return false }
        if let before = old.safePercent, let after = new.safePercent, after < before - 0.5 { return false }
        if let before = old.usedAmount, let after = new.usedAmount, after < before { return false }
        if let reset = old.resetsAt, reset > oldDate, reset <= date { return false }
        if let before = old.resetsAt, let after = new.resetsAt, abs(after.timeIntervalSince(before)) > 300 { return false }
        return !events.contains {
            [.weeklyReset, .earlyReset, .bankedUsed, .allowanceChanged].contains($0.kind) && $0.date > oldDate && $0.date <= date &&
            ($0.windowID.map { $0 == new.id } ?? $0.window.map { $0 == new.title } ?? true)
        }
    }
}

struct BurnEstimate: Equatable {
    enum Limit: Equatable { case exhausted, noChange, resetsFirst, reachesZero(TimeInterval) }
    var perHour: Double
    var limit: Limit
}
enum BurnRate {
    static func estimate(samples: [UsageHistorySample], windowID: String, hours: Int, events: [AccountEvent] = [], now: Date = .now) -> BurnEstimate? {
        let horizon = Double(max(1, min(24, hours))) * 3600
        var cycle: [(Date, UsageWindow, String?)] = []
        for sample in samples.sorted(by: { $0.date < $1.date }) where sample.date >= now.addingTimeInterval(-horizon) && sample.date <= now {
            guard let window = sample.windows.first(where: { $0.id == windowID }), window.safePercent != nil else { cycle = []; continue }
            if let previous = cycle.last, !UsageCycle.continues(from: previous.1, at: previous.0, to: window, at: sample.date, events: events, previousContext: previous.2, currentContext: sample.allowanceContext) { cycle = [] }
            cycle.append((sample.date, window, sample.allowanceContext))
        }
        guard let first = cycle.first, let last = cycle.last, let start = first.1.safePercent, let used = last.1.safePercent,
              now.timeIntervalSince(last.0) <= 1800, last.0.timeIntervalSince(first.0) >= max(1200, horizon * 0.4) else { return nil }
        let rate = max(0, used - start) / (last.0.timeIntervalSince(first.0) / 3600)
        if used >= 100 { return BurnEstimate(perHour: rate, limit: .exhausted) }
        if rate < 0.01 { return BurnEstimate(perHour: 0, limit: .noChange) }
        let untilZero = (100 - used) / rate * 3600
        if let reset = last.1.resetsAt, reset <= now.addingTimeInterval(untilZero) { return BurnEstimate(perHour: rate, limit: .resetsFirst) }
        return BurnEstimate(perHour: rate, limit: .reachesZero(untilZero))
    }
}

struct ChartEventGroup: Identifiable {
    var events: [AccountEvent]
    var date: Date { events[0].date }
    var id: String { events.map(\.id).joined(separator: ":") }
}
enum ChartEvents {
    static func groups(events: [AccountEvent], windows: [UsageWindow], domain: ClosedRange<Date>) -> [ChartEventGroup] {
        let relevant = events.filter { event in
            guard domain.contains(event.date), event.kind != .parsingFailure else { return false }
            if let id = event.windowID { return windows.contains { $0.id == id } }
            if let title = event.window { return windows.contains { $0.title == title } }
            return !windows.isEmpty
        }.sorted { $0.date < $1.date }
        let spacing = domain.upperBound.timeIntervalSince(domain.lowerBound) / 14
        var result: [ChartEventGroup] = []
        for event in relevant {
            if let last = result.last, event.date.timeIntervalSince(last.date) < spacing { result[result.count - 1].events.append(event) }
            else { result.append(ChartEventGroup(events: [event])) }
        }
        return result
    }
}
