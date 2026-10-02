import Foundation
import SwiftUI
import Charts

struct UsageHistorySample: Codable, Equatable, Identifiable {
    var date: Date
    var windows: [UsageWindow]
    var id: Date { date }
}
struct UsageHistoryStore {
    let directory: URL
    static let retention: TimeInterval = 90 * 86400
    func read(_ id: UUID, now: Date = .now) -> [UsageHistorySample] {
        let file = location(id)
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 20_000_000,
              let data = try? Data(contentsOf: file), let samples = try? JSONDecoder().decode([UsageHistorySample].self, from: data) else { return [] }
        return samples.filter { $0.date >= now.addingTimeInterval(-Self.retention) }.sorted { $0.date < $1.date }
    }
    func append(_ snapshot: UsageSnapshot, to samples: [UsageHistorySample], now: Date = .now) -> [UsageHistorySample] {
        guard snapshot.updatedAt <= now.addingTimeInterval(60), snapshot.updatedAt >= now.addingTimeInterval(-Self.retention) else { return samples }
        var samples = samples.filter { $0.date >= now.addingTimeInterval(-Self.retention) }
        let sample = UsageHistorySample(date: snapshot.updatedAt, windows: snapshot.windows)
        if let last = samples.last {
            guard sample.date > last.date else { return samples }
            // Closely spaced identical reads add no detail; retain their latest timestamp.
            if last.windows == sample.windows, sample.date.timeIntervalSince(last.date) < 300 { samples.removeLast() }
        }
        samples.append(sample)
        return Array(samples.suffix(12_000))
    }
    func write(_ samples: [UsageHistorySample], id: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(samples).write(to: location(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func remove(_ id: UUID) throws {
        let file = location(id)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    private func location(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
}
struct UsageHistoryView: View {
    let samples: [UsageHistorySample]
    let account: AgentAccount
    @State private var days = 7
    @State private var selectedDate: Date?
    private var visible: [UsageHistorySample] { samples.filter { $0.date >= Date.now.addingTimeInterval(-Double(days) * 86400) } }
    private var windows: [UsageWindow] {
        var seen = Set<String>()
        return visible.reversed().flatMap(\.windows).filter { seen.insert($0.id).inserted }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Usage history").font(.headline)
            Picker("History period", selection: $days) { Text("24h").tag(1); Text("7d").tag(7); Text("30d").tag(30); Text("90d").tag(90) }.pickerStyle(.segmented)
            if visible.isEmpty { Text("History starts with your next successful refresh.").font(.caption).foregroundStyle(.secondary) }
            else if !visible.flatMap(\.windows).contains(where: { $0.safePercent != nil }) { Text("No usage percentages reported yet.").font(.caption).foregroundStyle(.secondary) }
            else {
                Chart {
                    ForEach(windows) { window in
                        let segments = HistorySeries.segments(samples: visible, windowID: window.id)
                        ForEach(Array(segments.enumerated()), id: \.offset) { segmentIndex, points in
                            ForEach(points) { point in
                                let percent = account.displaySettings.direction == .remaining ? 100 - point.usedPercent : point.usedPercent
                                LineMark(x: .value("Time", point.date), y: .value("Percent", percent), series: .value("Segment", "\(window.id)-\(segmentIndex)"))
                                    .interpolationMethod(.stepEnd).foregroundStyle(by: .value("Window", window.title))
                                PointMark(x: .value("Time", point.date), y: .value("Percent", percent)).symbolSize(12).foregroundStyle(by: .value("Window", window.title))
                            }
                        }
                    }
                    if let selectedDate { RuleMark(x: .value("Selected", selectedDate)).foregroundStyle(.secondary).annotation(position: .top, alignment: .leading) {
                        Text(selectedDate.formatted(date: .abbreviated, time: .shortened)).font(.caption2).padding(5).background(Theme.card)
                    } }
                }.chartYScale(domain: 0...100).chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                    .chartYAxis { AxisMarks(values: [0, 50, 100]) { value in AxisGridLine(); AxisValueLabel { if let number = value.as(Int.self) { Text("\(number)%") } } } }
                    .chartXSelection(value: $selectedDate).frame(height: 190)
                Text("\(account.displaySettings.direction == .remaining ? "Remaining" : "Used") · \(visible.count) readings · gaps over 2h aren’t joined").font(.caption2).foregroundStyle(.secondary)
            }
        }.panel()
    }
}
enum HistorySeries {
    struct Point: Identifiable {
        var date: Date
        var usedPercent: Double
        var id: Date { date }
    }
    // Separate resets, unavailable values and long gaps. Never draw a line across
    // unobserved hours or manufacture a quota reset between real readings.
    static func segments(samples: [UsageHistorySample], windowID: String) -> [[Point]] {
        var result: [[Point]] = []; var current: [Point] = []
        var lastReset: Date?
        for sample in samples {
            guard let window = sample.windows.first(where: { $0.id == windowID }), let percent = window.safePercent else {
                if !current.isEmpty { result.append(current); current = [] }; lastReset = nil; continue
            }
            if let last = current.last, sample.date.timeIntervalSince(last.date) > 7200 || window.resetsAt != lastReset || percent < last.usedPercent {
                result.append(current); current = []
            }
            current.append(Point(date: sample.date, usedPercent: percent)); lastReset = window.resetsAt
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
