import Foundation

enum HistoryRate {
    // Rates are interval averages, not instantaneous observations. Gaps longer
    // than six hours, unavailable readings and cycle changes remain breaks.
    static let maximumGap: TimeInterval = 6 * 3600
    struct Interval { var start: Date; var end: Date; var delta: Double }
    static func segments(samples: [UsageHistorySample], windowID: String, measure: HistoryMeasure, unit: String? = nil, events: [AccountEvent] = [], averagingHours: Int = 1) -> [[HistorySeries.Point]] {
        var runs: [[Interval]] = [], run: [Interval] = [], previous: UsageHistorySample?
        let measure: HistoryMeasure = measure == .amount ? .amount : .used
        for sample in samples.sorted(by: { $0.date < $1.date }) {
            defer { previous = sample }
            guard let old = previous, let before = old.windows.first(where: { $0.id == windowID }), let after = sample.windows.first(where: { $0.id == windowID }),
                  let start = measure.value(before), let end = measure.value(after),
                  measure != .amount || (before.amountUnit == unit && after.amountUnit == unit),
                  sample.date.timeIntervalSince(old.date) <= maximumGap,
                  UsageCycle.continues(from: before, at: old.date, to: after, at: sample.date, events: events, previousContext: old.allowanceContext, currentContext: sample.allowanceContext) else {
                if !run.isEmpty { runs.append(run); run = [] }; continue
            }
            run.append(Interval(start: old.date, end: sample.date, delta: max(0, end - start)))
        }
        if !run.isEmpty { runs.append(run) }
        let horizon = Double(max(1, min(12, averagingHours))) * 3600
        return runs.map { intervals in
            var points: [HistorySeries.Point] = []
            var left = 0, totalSeconds = 0.0, totalDelta = 0.0
            for (index, interval) in intervals.enumerated() {
                totalSeconds += interval.end.timeIntervalSince(interval.start); totalDelta += interval.delta
                let cutoff = interval.end.addingTimeInterval(-horizon)
                while left < index && intervals[left].end <= cutoff {
                    totalSeconds -= intervals[left].end.timeIntervalSince(intervals[left].start)
                    totalDelta -= intervals[left].delta; left += 1
                }
                let first = intervals[left]
                let clipped = max(0, cutoff.timeIntervalSince(first.start))
                let seconds = totalSeconds - clipped
                let delta = max(0, totalDelta - first.delta * clipped / first.end.timeIntervalSince(first.start))
                if seconds >= min(900, horizon * 0.25) {
                    let rate = delta / seconds * 3600
                    if index == 0 { points.append(.init(date: first.start, usedPercent: rate)) }
                    points.append(.init(date: interval.end, usedPercent: rate))
                }
            }
            return points
        }.filter { !$0.isEmpty }
    }
    static func formatted(_ value: Double, unit: String) -> String { value.formatted(.number.precision(.fractionLength(0...2))) + " " + unit + "/h" }
}

extension HistorySeries {
    struct PlotData { var segments: [[Point]]; var transitions: [[Point]] }
    static func clipped(_ points: [Point], to domain: ClosedRange<Date>) -> [Point] {
        guard let first = points.firstIndex(where: { $0.date >= domain.lowerBound }), let last = points.lastIndex(where: { $0.date <= domain.upperBound }), first <= last else {
            if let before = points.last(where: { $0.date < domain.lowerBound }), let after = points.first(where: { $0.date > domain.upperBound }) { return [before, after] }
            return []
        }
        return Array(points[max(0, first - 1)...min(points.count - 1, last + 1)])
    }
    static func plot(samples: [UsageHistorySample], windowID: String, measure: HistoryMeasure, unit: String? = nil, events: [AccountEvent] = []) -> PlotData {
        var segments: [[Point]] = [], transitions: [[Point]] = [], current: [Point] = [], previous: UsageHistorySample?
        for sample in samples.sorted(by: { $0.date < $1.date }) {
            defer { previous = sample }
            guard let window = sample.windows.first(where: { $0.id == windowID }), let value = measure.value(window), measure != .amount || unit == nil || window.amountUnit == unit else {
                if !current.isEmpty { segments.append(current); current = [] }; continue
            }
            let point = Point(date: sample.date, usedPercent: value)
            if let previous, let old = previous.windows.first(where: { $0.id == windowID }) {
                let gap = sample.date.timeIntervalSince(previous.date) > HistoryRate.maximumGap
                let changed = AllowanceChanges.contextChanged(previous.allowanceContext, sample.allowanceContext) || AllowanceChanges.windowChanged(old, window)
                if gap || !UsageCycle.continues(from: old, at: previous.date, to: window, at: sample.date, events: events, previousContext: previous.allowanceContext, currentContext: sample.allowanceContext) {
                    if let last = current.last, !gap, !changed { transitions.append([last, point]) }
                    if !current.isEmpty { segments.append(current); current = [] }
                }
            }
            current.append(point)
        }
        if !current.isEmpty { segments.append(current) }
        return PlotData(segments: segments, transitions: transitions)
    }
}
