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
    @State private var heatmapWindow = ""
    @State private var measure = HistoryMeasure.remaining
    @State private var unit = ""
    private var units: [String] { Array(Set(visible.flatMap(\.windows).filter { $0.usedAmount != nil }.compactMap(\.amountUnit))).sorted() }
    private var activeUnit: String { units.contains(unit) ? unit : units.first ?? "" }
    private var visible: [UsageHistorySample] { samples.filter { $0.date >= Date.now.addingTimeInterval(-Double(days) * 86400) } }
    private var windows: [UsageWindow] {
        var seen = Set<String>()
        return visible.reversed().flatMap(\.windows).filter { seen.insert($0.id).inserted && (measure != .amount || $0.amountUnit == activeUnit) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Usage history").font(.headline)
            Picker("History period", selection: $days) { Text("24h").tag(1); Text("7d").tag(7); Text("30d").tag(30); Text("90d").tag(90) }.pickerStyle(.segmented)
            if !units.isEmpty { Picker("Measure", selection: $measure) { ForEach(HistoryMeasure.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented) }
            if measure == .amount { Picker("Units", selection: Binding(get: { activeUnit }, set: { unit = $0 })) { ForEach(units, id: \.self) { Text($0).tag($0) } } }
            if visible.isEmpty { Text("History starts with your next successful refresh.").font(.caption).foregroundStyle(.secondary) }
            else if !visible.flatMap(\.windows).contains(where: { measure.value($0) != nil }) { Text("No readings for this measure.").font(.caption).foregroundStyle(.secondary) }
            else {
                Chart {
                    ForEach(windows) { window in
                        let segments = HistorySeries.segments(samples: visible, windowID: window.id, measure: measure)
                        ForEach(Array(segments.enumerated()), id: \.offset) { segmentIndex, points in
                            ForEach(points) { point in
                                let percent = point.usedPercent
                                LineMark(x: .value("Time", point.date), y: .value("Percent", percent), series: .value("Segment", "\(window.id)-\(segmentIndex)"))
                                    .interpolationMethod(.stepEnd).foregroundStyle(by: .value("Window", window.title))
                                if points.count == 1 { PointMark(x: .value("Time", point.date), y: .value("Percent", percent)).symbolSize(16).foregroundStyle(by: .value("Window", window.title)) }
                            }
                        }
                    }
                    if let selectedDate { RuleMark(x: .value("Selected", selectedDate)).foregroundStyle(.secondary).annotation(position: .top, alignment: .leading) {
                        Text(selectedDate.formatted(date: .abbreviated, time: .shortened)).font(.caption2).padding(5).background(Theme.card)
                    } }
                }.chartYScale(domain: 0...(measure == .amount ? max(1, visible.flatMap(\.windows).compactMap(\.usedAmount).max() ?? 1) : 100)).chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { AxisGridLine(); AxisValueLabel(format: days == 1 ? Date.FormatStyle.dateTime.hour().minute() : Date.FormatStyle.dateTime.month(.abbreviated).day()) } }
                    .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) { value in AxisGridLine(); AxisValueLabel { if let number = value.as(Int.self) { Text(measure == .amount ? "\(number)" : "\(number)%") } } } }
                    .chartXSelection(value: $selectedDate).frame(height: 190)
                Picker("Heatmap metric", selection: $heatmapWindow) {
                    Text("Weekly / primary").tag("")
                    ForEach(windows) { Text($0.title).tag($0.id) }
                }.font(.caption)
                if let window = windows.first(where: { $0.id == heatmapWindow }) ?? windows.first(where: EventDetection.weekly) ?? windows.first {
                    UsageHeatmap(samples: samples, window: window, color: account.color, measure: measure)
                }
            }
        }.panel().onAppear { measure = account.displaySettings.direction == .remaining ? .remaining : .used }
    }
}
enum HistorySeries {
    struct Point: Identifiable {
        var date: Date
        var usedPercent: Double
        var id: Date { date }
    }
    // Lines connect observed readings, including across long gaps and reset drops.
    // Unavailable readings remain breaks instead of being treated as zero.
    static func segments(samples: [UsageHistorySample], windowID: String, measure: HistoryMeasure = .used) -> [[Point]] {
        var result: [[Point]] = []; var current: [Point] = []
        for sample in samples {
            guard let window = sample.windows.first(where: { $0.id == windowID }), let percent = measure.value(window) else {
                if !current.isEmpty { result.append(current); current = [] }; continue
            }
            current.append(Point(date: sample.date, usedPercent: percent))
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
