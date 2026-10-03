import Foundation
import SwiftUI
import Charts

struct UsageHistorySample: Codable, Equatable, Identifiable {
    var date: Date
    var windows: [UsageWindow]
    var allowanceContext: String?
    var remainingAllowances: [RemainingAllowance]?
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
        let sample = UsageHistorySample(date: snapshot.updatedAt, windows: snapshot.windows, allowanceContext: snapshot.allowanceContext ?? snapshot.plan, remainingAllowances: snapshot.remainingAllowances)
        if let last = samples.last {
            guard sample.date > last.date else { return samples }
            // Coalesce an unchanged tail while preserving its starting point.
            // Otherwise repeated quick refreshes can erase the evidence of zero burn.
            if samples.count > 1 {
                let anchor = samples[samples.count - 2]
                if last.windows == sample.windows, anchor.windows == sample.windows,
                   last.remainingAllowances == sample.remainingAllowances, anchor.remainingAllowances == sample.remainingAllowances,
                   last.allowanceContext == sample.allowanceContext, anchor.allowanceContext == sample.allowanceContext,
                   sample.date.timeIntervalSince(anchor.date) < 300 { samples.removeLast() }
            }
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
    var events: [AccountEvent] = []
    @State private var days = 7
    @State private var rangeEnd = Date.now
    @State private var hiddenWindows = Set<String>()
    @State private var heatmapWindow = ""
    @State private var measure = HistoryMeasure.remaining
    @State private var unit = ""
    private var domain: ClosedRange<Date> { rangeEnd.addingTimeInterval(-Double(days) * 86400)...rangeEnd }
    private var visible: [UsageHistorySample] { samples.filter { domain.contains($0.date) } }
    private var units: [String] { Array(Set(samples.flatMap(\.windows).filter { $0.usedAmount != nil }.compactMap(\.amountUnit))).sorted() }
    private var activeUnit: String { units.contains(unit) ? unit : units.first ?? "" }
    private var windows: [UsageWindow] {
        var seen = Set<String>()
        return (account.snapshot?.windows ?? []) + samples.reversed().flatMap(\.windows).filter { window in
            !(account.snapshot?.windows.contains { $0.id == window.id } ?? false) && seen.insert(window.id).inserted
        }
    }
    private var plottedWindows: [UsageWindow] { windows.filter { !hiddenWindows.contains($0.id) && (measure != .amount || $0.amountUnit == activeUnit) } }
    private var series: [HistoryPlotSeries] {
        plottedWindows.map { window in
            HistoryPlotSeries(id: window.id, title: window.shortTitle, color: account.usageColor(for: window.id), segments: HistorySeries.segments(samples: visible, windowID: window.id, measure: measure, unit: measure == .amount ? activeUnit : nil), subdued: days >= 7 && window.duration.map { $0 <= 21600 } == true)
        }
    }
    var body: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("Usage history").font(.headline); Spacer(); HistoryMeasureMenu(measure: $measure, unit: $unit, units: units) }
                HistoryPeriodPicker(days: $days)
                if series.flatMap({ $0.segments.flatMap { $0 } }).isEmpty { Text(plottedWindows.isEmpty ? "Choose a metric." : "History starts with successful refreshes.").font(.caption).foregroundStyle(.secondary) }
                else {
                    HistoryPlot(series: series, domain: domain, measure: measure, unit: activeUnit,
                                events: ChartEvents.groups(events: events, windows: plottedWindows, domain: domain), accountNames: [account.id: account.title])
                }
                if !windows.isEmpty { windowLegend }
                if !windows.isEmpty { Divider(); BurnRateView(samples: samples, windows: windows, events: events) }
            }.panel()
            if let window = windows.first(where: { $0.id == heatmapWindow }) ?? windows.first(where: EventDetection.weekly) ?? windows.first {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Activity").font(.headline)
                        Spacer()
                        Picker("Activity metric", selection: Binding(get: { window.id }, set: { heatmapWindow = $0 })) { ForEach(windows) { Text($0.shortTitle).tag($0.id) } }.tint(.primary)
                    }
                    UsageHeatmap(samples: samples, window: window, color: account.usageColor(for: window.id), events: events)
                }.panel()
            }
        }.onAppear { rangeEnd = .now; measure = account.displaySettings.direction == .remaining ? .remaining : .used }
            .onChange(of: samples.last?.date) { _, _ in rangeEnd = .now }
    }
    private var windowLegend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(windows.filter { measure != .amount || $0.amountUnit == activeUnit }) { window in
                    Button { if hiddenWindows.contains(window.id) { hiddenWindows.remove(window.id) } else { hiddenWindows.insert(window.id) } } label: {
                        HStack(spacing: 5) { Circle().fill(account.usageColor(for: window.id)).frame(width: 6, height: 6); Text(window.shortTitle) }.font(.caption).opacity(hiddenWindows.contains(window.id) ? 0.35 : 1)
                    }.buttonStyle(.plain).accessibilityValue(hiddenWindows.contains(window.id) ? "Hidden" : "Visible")
                }
            }
        }
    }
}
enum HistorySeries {
    struct Point: Identifiable {
        var date: Date
        var usedPercent: Double
        var id: Date { date }
    }
    // Bound render cost on long histories, preserving endpoints and each bin's
    // observed extrema. The full samples remain available for selection/analysis.
    static func renderPoints(_ points: [Point], maximum: Int = 600) -> [Point] {
        guard maximum >= 4, points.count > maximum else { return points }
        let width = Int(ceil(Double(points.count) / Double(maximum / 4)))
        var result: [Point] = []
        for start in stride(from: 0, to: points.count, by: width) {
            let group = Array(points[start..<min(points.count, start + width)])
            let candidates = [group.first!, group.min(by: { $0.usedPercent < $1.usedPercent })!, group.max(by: { $0.usedPercent < $1.usedPercent })!, group.last!]
            var seen = Set<Date>()
            result.append(contentsOf: candidates.filter { seen.insert($0.date).inserted }.sorted { $0.date < $1.date })
        }
        return result
    }
    // Lines connect observed readings, including across long gaps and reset drops.
    // Unavailable readings remain breaks instead of being treated as zero.
    static func segments(samples: [UsageHistorySample], windowID: String, measure: HistoryMeasure = .used, unit: String? = nil) -> [[Point]] {
        var result: [[Point]] = []; var current: [Point] = []
        var previous: UsageHistorySample?
        for sample in samples {
            defer { previous = sample }
            guard let window = sample.windows.first(where: { $0.id == windowID }), let percent = measure.value(window), measure != .amount || unit == nil || window.amountUnit == unit else {
                if !current.isEmpty { result.append(current); current = [] }; continue
            }
            if let previous, AllowanceChanges.contextChanged(previous.allowanceContext, sample.allowanceContext) || previous.windows.first(where: { $0.id == windowID }).map({ AllowanceChanges.windowChanged($0, window) }) == true {
                if !current.isEmpty { result.append(current); current = [] }
            }
            current.append(Point(date: sample.date, usedPercent: percent))
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
