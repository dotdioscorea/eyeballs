import SwiftUI
import Charts

struct HistoryPlotSeries: Identifiable {
    var id: String
    var title: String
    var color: Color
    var segments: [[HistorySeries.Point]]
    var subdued = false
    var dashed = false
}

struct HistoryPlot: View {
    let series: [HistoryPlotSeries]
    let domain: ClosedRange<Date>
    let measure: HistoryMeasure
    var unit = ""
    var events: [ChartEventGroup] = []
    var accountNames: [UUID: String] = [:]
    var height: CGFloat = 200
    @State private var selectedDate: Date?
    @State private var selectedEvent: ChartEventGroup?
    @State private var plotBounds = CGRect.zero
    private struct PlotBoundsKey: PreferenceKey {
        static var defaultValue = CGRect.zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
    }
    private struct Point: Identifiable {
        var id: String
        var seriesID: String
        var date: Date
        var value: Double
        var color: Color
        var isolated: Bool
        var subdued: Bool
        var dashed: Bool
    }
    private var points: [Point] {
        series.flatMap { series in
            series.segments.enumerated().flatMap { index, segment in
                HistorySeries.renderPoints(segment.filter { domain.contains($0.date) }).map { point in
                    Point(id: "\(series.id)-\(index)-\(point.date.timeIntervalSince1970)", seriesID: "\(series.id)-\(index)", date: point.date, value: point.usedPercent, color: series.color.opacity(series.subdued ? 0.55 : 1), isolated: segment.count == 1, subdued: series.subdued, dashed: series.dashed)
                }
            }
        }
    }
    private var maximum: Double { measure == .amount ? max(1, points.map(\.value).max() ?? 1) : 100 }
    private var observedDates: [Date] { series.flatMap { $0.segments.flatMap { $0.map(\.date) } } }
    private var selection: Binding<Date?> {
        Binding(get: { selectedDate }, set: { selectedDate = HistorySelection.nearest($0, dates: observedDates, domain: domain) })
    }
    var body: some View {
        VStack(spacing: 0) {
            if !events.isEmpty { eventLane.frame(height: 28) }
            chart.frame(height: height - (events.isEmpty ? 0 : 28))
        }.frame(height: height)
            .sheet(item: $selectedEvent) { group in eventDetails(group) }
    }
    private var chart: some View {
        Chart {
            lineMarks
            eventMarks
            selectionMark
        }
        .chartLegend(.hidden)
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...maximum)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { AxisGridLine(); AxisValueLabel(format: domain.upperBound.timeIntervalSince(domain.lowerBound) <= 86400 ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day()) } }
        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) { value in
            AxisGridLine()
            AxisValueLabel { if let number = value.as(Double.self) { Text(measure == .amount ? number.formatted(.number.precision(.fractionLength(0...1))) : "\(Int(number))%") } }
        } }
        .chartXSelection(value: selection)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame { Color.clear.preference(key: PlotBoundsKey.self, value: geometry[anchor]) }
            }.allowsHitTesting(false)
        }
        .onPreferenceChange(PlotBoundsKey.self) { plotBounds = $0 }
        .accessibilityIdentifier("history-plot")
        .onChange(of: domain) { _, _ in selectedDate = nil }
        .onChange(of: measure) { _, _ in selectedDate = nil }
        .onChange(of: series.map(\.id)) { _, _ in selectedDate = nil }
    }
    @ChartContentBuilder private var lineMarks: some ChartContent {
        ForEach(points) { point in
            LineMark(x: .value("Time", point.date), y: .value("Usage", point.value), series: .value("Series", point.seriesID))
                .foregroundStyle(point.color).interpolationMethod(.stepEnd)
                .lineStyle(StrokeStyle(lineWidth: point.subdued ? 1 : 2, dash: point.dashed ? [5, 3] : []))
            if point.isolated { PointMark(x: .value("Time", point.date), y: .value("Usage", point.value)).foregroundStyle(point.color).symbolSize(16) }
        }
    }
    @ChartContentBuilder private var eventMarks: some ChartContent {
        ForEach(events) { group in
            RuleMark(x: .value("Event", group.date)).foregroundStyle(.secondary.opacity(0.25)).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
    }
    private var eventLane: some View {
        GeometryReader { geometry in
            let width = plotBounds.width > 0 ? plotBounds.width : max(1, geometry.size.width - 40)
            ForEach(events) { group in
                let fraction = CGFloat(group.date.timeIntervalSince(domain.lowerBound) / domain.upperBound.timeIntervalSince(domain.lowerBound))
                let x: CGFloat = min(plotBounds.minX + width - 14, max(plotBounds.minX + 14, plotBounds.minX + fraction * width))
                eventButton(group).position(x: x, y: 14)
            }
        }
    }
    private func eventButton(_ group: ChartEventGroup) -> some View {
        Button { selectedDate = nil; selectedEvent = group } label: {
            HStack(spacing: 2) { Image(systemName: group.events[0].kind.symbol); if group.events.count > 1 { Text("\(group.events.count)") } }
                .font(.system(size: 11, weight: .medium)).padding(5).background(Theme.card, in: RoundedRectangle(cornerRadius: 4)).frame(minWidth: 28, minHeight: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(group.events.map { $0.kind.title }.joined(separator: ", ")).accessibilityIdentifier("chart-event-\(group.events[0].kind.rawValue)")
    }
    @ChartContentBuilder private var selectionMark: some ChartContent {
        if let date = HistorySelection.nearest(selectedDate, dates: observedDates, domain: domain) {
            RuleMark(x: .value("Selected", date)).foregroundStyle(.secondary)
                .annotation(position: .overlay, alignment: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) { tooltip(date) }
        }
    }
    private func tooltip(_ date: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
            ForEach(series.prefix(6)) { series in
                if let point = series.segments.flatMap({ $0 }).first(where: { $0.date == date }) {
                    HStack(spacing: 6) {
                        Circle().fill(series.color).frame(width: 5, height: 5)
                        Text(series.title).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(measure.formatted(point.usedPercent, unit: unit)).monospacedDigit()
                    }
                }
            }
        }.font(.caption2).padding(8).frame(maxWidth: 260).background(Theme.card, in: RoundedRectangle(cornerRadius: 8)).accessibilityIdentifier("chart-tooltip")
    }
    private func eventDetails(_ group: ChartEventGroup) -> some View {
        NavigationStack {
            List(group.events) { event in
                VStack(alignment: .leading, spacing: 6) {
                    Label(event.kind.title, systemImage: event.kind.symbol).font(.headline)
                    if let account = accountNames[event.accountID] { Text(account).font(.subheadline) }
                    Text(event.date.formatted(date: .abbreviated, time: .shortened)).font(.subheadline)
                    if !event.detail.isEmpty { Text(event.detail).font(.caption).foregroundStyle(.secondary) }
                    if event.detectedAt != event.date { Text("Detected \(event.detectedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 4)
            }.navigationTitle("Events").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selectedEvent = nil } } }
        }.presentationDetents([.medium, .large])
    }
}

struct BurnRateView: View {
    let samples: [UsageHistorySample]
    let windows: [UsageWindow]
    var events: [AccountEvent] = []
    @State private var windowID = ""
    @State private var hours = 6
    private var available: [UsageWindow] { windows.filter { $0.safePercent != nil } }
    private var active: UsageWindow? { available.first(where: { $0.id == windowID }) ?? available.first(where: EventDetection.weekly) ?? available.first }
    var body: some View {
        if let window = active {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Burn rate").font(.headline)
                    Spacer()
                    Picker("Burn rate metric", selection: Binding(get: { window.id }, set: { windowID = $0 })) { ForEach(available) { Text($0.shortTitle).tag($0.id) } }.tint(.primary)
                }
                Picker("Burn rate period", selection: $hours) { Text("1h").tag(1); Text("6h").tag(6); Text("12h").tag(12) }.pickerStyle(.segmented)
                if let estimate = BurnRate.estimate(samples: samples, windowID: window.id, hours: hours, events: events) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) { Text("Recent rate").font(.caption).foregroundStyle(.secondary); Text(String(format: "%.1f%% / h", estimate.perHour)).font(.title3.monospacedDigit()) }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) { Text("Time to zero").font(.caption).foregroundStyle(.secondary); Text(limitTitle(estimate.limit)).font(.title3.monospacedDigit()) }
                    }
                } else { Text("Not enough recent history.").font(.caption).foregroundStyle(.secondary) }
            }.accessibilityIdentifier("burn-rate")
        }
    }
    private func limitTitle(_ limit: BurnEstimate.Limit) -> String {
        switch limit {
        case .exhausted: return "Exhausted"
        case .noChange: return "—"
        case .resetsFirst: return "Resets first"
        case .reachesZero(let seconds):
            if seconds < 7200 { return "~\(max(5, Int((seconds / 300).rounded()) * 5))m" }
            if seconds < 48 * 3600 { return "~\(Int((seconds / 3600).rounded()))h" }
            if seconds > 7 * 86400 { return ">7d" }
            return "~\(Int((seconds / 86400).rounded()))d"
        }
    }
}
