import SwiftUI
import Charts

struct HistoryPlotSeries: Identifiable {
    var id: String
    var title: String
    var color: Color
    var segments: [[HistorySeries.Point]]
    var dashPattern: [CGFloat]? = nil
    var hardSegments: [[HistorySeries.Point]] = []
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
    var smooth = false
    var rate = false
    var highlighted: String?
    @State private var viewport: ClosedRange<Date>?
    private var visibleDomain: ClosedRange<Date> { viewport ?? domain }
    private var bounds: ClosedRange<Date> { min(domain.lowerBound, observedDates.min() ?? domain.lowerBound)...domain.upperBound }
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
        var pattern: [CGFloat]
        var hard: Bool
    }
    private var points: [Point] {
        series.flatMap { series in
            (series.segments.map { ($0, false) } + series.hardSegments.map { ($0, true) }).enumerated().flatMap { index, item in
                let segment = item.0
                let visible = HistorySeries.clipped(segment, to: visibleDomain)
                return HistorySeries.renderPoints(visible).enumerated().map { offset, point in
                    Point(id: "\(series.id)-\(index)-\(offset)", seriesID: "\(series.id)-\(index)", date: point.date, value: point.usedPercent, color: series.color.opacity(highlighted != nil && highlighted != series.id ? 0.15 : series.subdued ? 0.55 : 1), isolated: segment.count == 1, subdued: series.subdued, pattern: series.dashPattern ?? (series.dashed ? [5, 3] : []), hard: item.1)
                }
            }
        }
    }
    private var maximum: Double { rate || measure == .amount ? max(1, points.map(\.value).max() ?? 1) * (rate ? 1.1 : 1) : 100 }
    private var observedDates: [Date] { series.flatMap { $0.segments.flatMap { $0.map(\.date) } } }
    private var visibleEvents: [ChartEventGroup] {
        let items = events.flatMap(\.events).filter { visibleDomain.contains($0.date) }.sorted { $0.date < $1.date }
        var groups: [ChartEventGroup] = []
        for event in items {
            if let last = groups.last, event.date.timeIntervalSince(last.date) < visibleDomain.upperBound.timeIntervalSince(visibleDomain.lowerBound) / 14 { groups[groups.count - 1].events.append(event) }
            else { groups.append(.init(events: [event])) }
        }
        return groups
    }
    var body: some View {
        VStack(spacing: 0) {
            if !visibleEvents.isEmpty { eventLane.frame(height: 28) }
            chart.frame(height: height - (visibleEvents.isEmpty ? 0 : 28))
        }.frame(height: height)
            .overlay(alignment: .topTrailing) {
                if viewport != nil { Button("Reset view") { viewport = nil; selectedDate = nil }.font(.caption2).padding(5).background(Theme.card, in: Capsule()).offset(y: -24).accessibilityIdentifier("reset-chart-view") }
            }
            .sheet(item: $selectedEvent) { group in eventDetails(group) }
    }
    private var chart: some View {
        Chart {
            lineMarks
            eventMarks
            selectionMark
        }
        .chartLegend(.hidden)
        .chartXScale(domain: visibleDomain)
        .chartPlotStyle { $0.clipped() }
        .chartYScale(domain: 0...maximum)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { AxisGridLine(); AxisValueLabel(format: visibleDomain.upperBound.timeIntervalSince(visibleDomain.lowerBound) <= 86400 ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day()) } }
        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) { value in
            AxisGridLine()
            AxisValueLabel { if let number = value.as(Double.self) { Text(rate ? number.formatted(.number.precision(.fractionLength(0...1))) + (measure == .amount ? "/h" : " pp/h") : measure == .amount ? number.formatted(.number.precision(.fractionLength(0...1))) : "\(Int(number))%") } }
        } }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let frame = geometry[anchor]
                    ChartGestures(pan: { fraction, ended in
                        selectedDate = nil
                        viewport = ChartViewport.pan(visibleDomain, fraction: fraction, bounds: bounds)
                    }, zoom: { scale, anchor, ended in
                        selectedDate = nil
                        viewport = ChartViewport.zoom(visibleDomain, scale: scale, anchor: anchor, bounds: bounds)
                    }, select: { fraction in
                        selectedDate = HistorySelection.nearest(visibleDomain.lowerBound.addingTimeInterval(visibleDomain.upperBound.timeIntervalSince(visibleDomain.lowerBound) * fraction), dates: observedDates, domain: visibleDomain)
                    }).frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY)
                        .preference(key: PlotBoundsKey.self, value: frame)
                }
            }
        }
        .onPreferenceChange(PlotBoundsKey.self) { plotBounds = $0 }
        .accessibilityIdentifier("history-plot")
        .accessibilityValue("\(Int(visibleDomain.upperBound.timeIntervalSince(visibleDomain.lowerBound))) seconds, ending \(Int(visibleDomain.upperBound.timeIntervalSince1970))")
        .accessibilityAction(named: "Zoom in") { viewport = ChartViewport.zoom(visibleDomain, scale: 2, anchor: 0.5, bounds: bounds) }
        .accessibilityAction(named: "Earlier") { viewport = ChartViewport.pan(visibleDomain, fraction: 0.5, bounds: bounds) }
        .accessibilityAction(named: "Later") { viewport = ChartViewport.pan(visibleDomain, fraction: -0.5, bounds: bounds) }
        .onChange(of: domain) { old, new in selectedDate = nil; viewport = ChartViewport.advanced(viewport, from: old, to: new, bounds: bounds) }
        .onChange(of: measure) { _, _ in selectedDate = nil }
        .onChange(of: series.map(\.id)) { _, _ in selectedDate = nil }
    }
    @ChartContentBuilder private var lineMarks: some ChartContent {
        ForEach(points) { point in
            LineMark(x: .value("Time", point.date), y: .value("Usage", point.value), series: .value("Series", point.seriesID))
                .foregroundStyle(point.color).interpolationMethod(rate ? .stepStart : point.hard || !smooth ? .stepEnd : .monotone)
                .lineStyle(StrokeStyle(lineWidth: point.subdued ? 1 : 2, dash: point.pattern))
            if point.isolated { PointMark(x: .value("Time", point.date), y: .value("Usage", point.value)).foregroundStyle(point.color).symbolSize(16) }
        }
    }
    @ChartContentBuilder private var eventMarks: some ChartContent {
        ForEach(visibleEvents) { group in
            RuleMark(x: .value("Event", group.date)).foregroundStyle(.secondary.opacity(0.25)).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
    }
    private var eventLane: some View {
        GeometryReader { geometry in
            let width = plotBounds.width > 0 ? plotBounds.width : max(1, geometry.size.width - 40)
            ForEach(visibleEvents) { group in
                let fraction = CGFloat(group.date.timeIntervalSince(visibleDomain.lowerBound) / visibleDomain.upperBound.timeIntervalSince(visibleDomain.lowerBound))
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
        if let date = HistorySelection.nearest(selectedDate, dates: observedDates, domain: visibleDomain) {
            RuleMark(x: .value("Selected", date)).foregroundStyle(.secondary)
                .annotation(position: .overlay, alignment: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) { tooltip(date) }
        }
    }
    private func tooltip(_ date: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
            ForEach(tooltipSeries(at: date).prefix(6), id: \.series.id) { row in
                HStack(spacing: 6) {
                    Circle().fill(row.series.color).frame(width: 5, height: 5)
                    Text(row.series.title).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(rate ? HistoryRate.formatted(row.point.usedPercent, unit: measure == .amount ? unit : "pp") : measure.formatted(row.point.usedPercent, unit: unit)).monospacedDigit()
                }
            }
        }.font(.caption2).padding(8).frame(maxWidth: 260).background(Theme.card, in: RoundedRectangle(cornerRadius: 8)).accessibilityIdentifier("chart-tooltip")
    }
    private func tooltipSeries(at date: Date) -> [(series: HistoryPlotSeries, point: HistorySeries.Point)] {
        series.compactMap { series in
            let exact = series.segments.flatMap { $0 }.first { $0.date == date }
            let nearby = series.segments.first { $0.first.map { $0.date <= date } == true && $0.last.map { $0.date >= date } == true }?.last { $0.date <= date && date.timeIntervalSince($0.date) <= 1200 }
            return (exact ?? nearby).map { (series, $0) }
        }.sorted { ($0.point.date == date ? 0 : 1) < ($1.point.date == date ? 0 : 1) }
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
                        VStack(alignment: .leading, spacing: 4) { Text("Recent rate").font(.caption).foregroundStyle(.secondary); Text(HistoryRate.formatted(estimate.perHour, unit: "pp")).font(.title3.monospacedDigit()) }
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
