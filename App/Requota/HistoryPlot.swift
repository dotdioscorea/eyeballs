import SwiftUI
import Charts

struct HistoryPlotSeries: Identifiable {
    var id: String
    var title: String
    var color: Color
    var segments: [[HistorySeries.Point]]
    var provider: Provider? = nil
    var dashPattern: [CGFloat]? = nil
    var hardSegments: [[HistorySeries.Point]] = []
    var bridgeSegments: [[HistorySeries.Point]] = []
    var subdued = false
    var dashed = false
}

struct HistoryPlot: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var textSize
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
    private let renderSeries: [HistoryPlotSeries]
    private let observedDates: [Date]
    private let revision: Int
    init(series: [HistoryPlotSeries], domain: ClosedRange<Date>, measure: HistoryMeasure, unit: String = "", events: [ChartEventGroup] = [], accountNames: [UUID: String] = [:], height: CGFloat = 200, smooth: Bool = false, rate: Bool = false, highlighted: String? = nil) {
        self.series = series; self.domain = domain; self.measure = measure; self.unit = unit
        self.events = events; self.accountNames = accountNames; self.height = height
        self.smooth = smooth; self.rate = rate; self.highlighted = highlighted
        renderSeries = series.map { item in
            var result = item
            if smooth && !rate { result.segments = item.segments.map { ChartSmoothing.curve(ChartSmoothing.points($0, amount: measure == .amount)) } }
            return result
        }
        observedDates = series.flatMap { $0.segments.flatMap { $0.map(\.date) } }.sorted()
        var hash = Hasher(); hash.combine(smooth); hash.combine(rate); hash.combine(measure); hash.combine(unit)
        for item in series {
            hash.combine(item.id); hash.combine(item.color); hash.combine(item.dashPattern); hash.combine(item.subdued)
            for segment in item.segments + item.hardSegments + item.bridgeSegments {
                hash.combine(segment.count)
                for point in segment { hash.combine(point.date); hash.combine(point.usedPercent) }
            }
        }
        for event in events { hash.combine(event.id) }
        revision = hash.finalize()
    }
    @State private var focusedID: String?
    private var focus: String? { focusedID ?? highlighted }
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
    fileprivate struct Point: Identifiable {
        var id: String
        var seriesID: String
        var date: Date
        var value: Double
        var color: Color
        var isolated: Bool
        var subdued: Bool
        var pattern: [CGFloat]
        var hard: Bool
        var bridge: Bool
    }
    private var uncachedPoints: [Point] {
        renderSeries.flatMap { series in
            (series.segments.map { ($0, false, false) } + series.hardSegments.map { ($0, true, false) } + series.bridgeSegments.map { ($0, false, true) }).enumerated().flatMap { index, item in
                let segment = item.1 && item.0.count == 2 ? [item.0[0], HistorySeries.Point(date: item.0[1].date, usedPercent: item.0[0].usedPercent), item.0[1]] : item.0
                let visible = HistorySeries.clipped(segment, to: visibleDomain)
                return HistorySeries.renderPoints(visible).enumerated().map { offset, point in
                    Point(id: "\(series.id)-\(index)-\(offset)", seriesID: "\(series.id)-\(index)", date: point.date, value: point.usedPercent, color: series.color.opacity(focus != nil && focus != series.id ? 0.15 : item.2 ? 0.3 : series.subdued ? 0.55 : 1), isolated: segment.count == 1, subdued: series.subdued, pattern: series.dashPattern ?? (series.dashed ? [5, 3] : []), hard: item.1, bridge: item.2)
                }
            }
        }
    }
    private struct RenderKey: Equatable { var revision: Int; var domain: ClosedRange<Date>; var focus: String? }
    private struct RenderCache { var key: RenderKey; var points: [Point]; var maximum: Double; var events: [ChartEventGroup] }
    @State private var cachedRender: RenderCache?
    private var renderKey: RenderKey { .init(revision: revision, domain: visibleDomain, focus: focus) }
    private func makeRender() -> RenderCache {
        let points = uncachedPoints
        return .init(key: renderKey, points: points, maximum: rate || measure == .amount ? max(1, points.map(\.value).max() ?? 1) * (rate ? 1.1 : 1) : 100, events: uncachedEvents)
    }
    private var render: RenderCache { if let cachedRender, cachedRender.key == renderKey { return cachedRender }; return makeRender() }
    private var points: [Point] { render.points }
    private var maximum: Double { render.maximum }
    private var visibleEvents: [ChartEventGroup] { render.events }
    private var plotHeight: CGFloat { textSize.isAccessibilitySize ? max(340, height) : height }
    private var eventHeight: CGFloat { textSize.isAccessibilitySize ? 44 : 28 }

    private var uncachedEvents: [ChartEventGroup] {
        let items = events.flatMap(\.events).filter { visibleDomain.contains($0.date) }.sorted { $0.date < $1.date }
        var groups: [ChartEventGroup] = []
        for event in items {
            if let last = groups.last, event.date.timeIntervalSince(last.date) < visibleDomain.upperBound.timeIntervalSince(visibleDomain.lowerBound) / 14 { groups[groups.count - 1].events.append(event) }
            else { groups.append(.init(events: [event])) }
        }
        return groups
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                if !events.isEmpty { eventLane.frame(height: eventHeight) }
                chart.frame(height: plotHeight - (events.isEmpty ? 0 : eventHeight))
            }.frame(height: plotHeight)
                .overlay(alignment: .topTrailing) {
                    if viewport != nil { Button("Reset view") { viewport = nil; selectedDate = nil }.font(.caption2).padding(5).background(Theme.card, in: Capsule()).offset(y: -24).accessibilityIdentifier("reset-chart-view") }
                }
            readout
        }.onAppear { cachedRender = makeRender() }.onChange(of: renderKey) { _, _ in cachedRender = makeRender() }.sheet(item: $selectedEvent) { group in eventDetails(group) }
    }
    private var chart: some View {
        HistoryTrace(points: points, events: visibleEvents, domain: visibleDomain, maximum: maximum, rate: rate, smooth: smooth, amount: measure == .amount, revision: revision, focus: focus).equatable()
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let frame = geometry[anchor]
                    if let date = selectedDate {
                        let fraction = date.timeIntervalSince(visibleDomain.lowerBound) / visibleDomain.upperBound.timeIntervalSince(visibleDomain.lowerBound)
                        Rectangle().fill(.white.opacity(0.55)).frame(width: 1, height: frame.height).position(x: frame.minX + frame.width * fraction, y: frame.midY).allowsHitTesting(false)
                    }
                    ChartGestures(pan: { fraction, ended in
                        selectedDate = nil
                        let next = ChartViewport.pan(visibleDomain, fraction: fraction, bounds: bounds); viewport = next == domain ? nil : next
                    }, zoom: { scale, anchor, ended in
                        selectedDate = nil
                        let next = ChartViewport.zoom(visibleDomain, scale: scale, anchor: anchor, bounds: bounds); viewport = next == domain ? nil : next
                    }, select: { fraction in
                        selectedDate = visibleDomain.lowerBound.addingTimeInterval(visibleDomain.upperBound.timeIntervalSince(visibleDomain.lowerBound) * fraction)
                    }).frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY)
                        .preference(key: PlotBoundsKey.self, value: frame)
                    ChartGestures(pan: { fraction, _ in
                        selectedDate = nil
                        let next = ChartViewport.pan(visibleDomain, fraction: fraction, bounds: bounds)
                        viewport = next == domain ? nil : next
                    }, zoom: { scale, anchor, _ in
                        selectedDate = nil
                        let next = ChartViewport.zoom(visibleDomain, scale: scale, anchor: anchor, bounds: bounds)
                        viewport = next == domain ? nil : next
                    }, select: { _ in }, inspect: false)
                        .frame(width: frame.width, height: max(44, geometry.size.height - frame.maxY)).position(x: frame.midX, y: frame.maxY + max(44, geometry.size.height - frame.maxY) / 2)
                        .accessibilityIdentifier("chart-timeline").accessibilityLabel("Drag timeline to move through history")
                }
            }
        }
        .onPreferenceChange(PlotBoundsKey.self) { plotBounds = $0 }
        .accessibilityIdentifier("history-plot")
        .accessibilityValue("\(Int(visibleDomain.upperBound.timeIntervalSince(visibleDomain.lowerBound))) seconds, ending \(Int(visibleDomain.upperBound.timeIntervalSince1970))")
        .accessibilityAction(named: "Zoom in") { viewport = ChartViewport.zoom(visibleDomain, scale: 2, anchor: 0.5, bounds: bounds) }
        .accessibilityAction(named: "Earlier") { viewport = ChartViewport.pan(visibleDomain, fraction: 0.5, bounds: bounds) }
        .accessibilityAction(named: "Later") { viewport = ChartViewport.pan(visibleDomain, fraction: -0.5, bounds: bounds) }
        .onChange(of: domain) { old, new in viewport = ChartViewport.advanced(viewport, from: old, to: new, bounds: bounds); if selectedDate.map({ !visibleDomain.contains($0) }) == true { selectedDate = nil } }
        .onChange(of: measure) { _, _ in selectedDate = nil }
        .onChange(of: series.map(\.id)) { _, ids in if let focusedID, !ids.contains(focusedID) { self.focusedID = nil } }
    }
    private var eventLane: some View {
        GeometryReader { geometry in
            let width = plotBounds.width > 0 ? plotBounds.width : max(1, geometry.size.width - 40)
            ForEach(visibleEvents) { group in
                let fraction = CGFloat(group.date.timeIntervalSince(visibleDomain.lowerBound) / visibleDomain.upperBound.timeIntervalSince(visibleDomain.lowerBound))
                let x: CGFloat = min(plotBounds.minX + width - 14, max(plotBounds.minX + 14, plotBounds.minX + fraction * width))
                eventButton(group).position(x: x, y: eventHeight / 2)
            }
        }
    }
    private func eventButton(_ group: ChartEventGroup) -> some View {
        Button { selectedDate = nil; selectedEvent = group } label: {
            HStack(spacing: 2) { Image(systemName: group.events[0].kind.symbol); if group.events.count > 1 { Text("\(group.events.count)") } }
                .font(textSize.isAccessibilitySize ? .caption2 : .system(size: 11, weight: .medium)).padding(5).background(Theme.card, in: RoundedRectangle(cornerRadius: 4)).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(group.events.map { $0.kind.title }.joined(separator: ", ")).accessibilityIdentifier("chart-event-\(group.events[0].kind.rawValue)")
    }
    private var inspectionDate: Date { selectedDate ?? observedDates.filter { visibleDomain.contains($0) }.max() ?? visibleDomain.upperBound }
    private var readout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(selectedDate == nil ? (viewport == nil ? "Latest readings" : "Readings in view") : inspectionDate.formatted(.dateTime.month(.abbreviated).day().hour().minute())).font(.caption).foregroundStyle(.secondary).monospacedDigit().accessibilityIdentifier("chart-selected-date")
                Spacer()
                if selectedDate != nil { Button { selectedDate = nil } label: { Image(systemName: "xmark").font(.caption).frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("Clear chart selection") }
            }
            LazyVGrid(columns: sizeClass == .regular && !textSize.isAccessibilitySize ? [GridItem(.adaptive(minimum: 240), spacing: 16)] : [GridItem(.flexible())], alignment: .leading, spacing: 10) {
                ForEach(series) { item in
                    let date = selectedDate ?? item.segments.flatMap { $0 }.last(where: { visibleDomain.contains($0.date) })?.date ?? inspectionDate
                    let source = ChartReadings.at(date, segments: item.segments, stepped: !rate && !smooth)
                    let curve = renderSeries.first(where: { $0.id == item.id })?.segments ?? item.segments
                    let drawn = ChartReadings.at(date, segments: smooth && !rate ? curve : item.segments, stepped: !rate && !smooth)
                    let reading = drawn.map { value in ChartReading(value: value.value, estimated: source?.estimated != false || abs((source?.value ?? value.value) - value.value) > 0.001) }
                    Button { focusedID = focusedID == item.id ? nil : item.id } label: {
                        AccessibleStack(spacing: 8) {
                            HStack(spacing: 8) {
                            Path { path in path.move(to: .init(x: 0, y: 3)); path.addLine(to: .init(x: 24, y: 3)) }.stroke(item.color, style: StrokeStyle(lineWidth: 2, dash: item.dashPattern ?? (item.dashed ? [5, 3] : []))).frame(width: 24, height: 6)
                            if let provider = item.provider { ProviderLogo(provider: provider, color: item.color, size: 13) }
                            Text(item.title).font(.caption).foregroundStyle(.secondary).lineLimit(textSize.isAccessibilitySize ? nil : 1)
                            }
                            if !textSize.isAccessibilitySize { Spacer(minLength: 4) }
                            Text(reading.map { ($0.estimated || rate ? "~" : "") + (rate ? HistoryRate.formatted($0.value, unit: measure == .amount ? unit : "pp") : measure.formatted($0.value, unit: unit)) } ?? "—").font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(.primary)
                        }.padding(sizeClass == .regular ? 10 : 0).background(sizeClass == .regular ? Color.white.opacity(0.035) : .clear, in: RoundedRectangle(cornerRadius: 9)).contentShape(Rectangle()).opacity(focus == nil || focus == item.id ? 1 : 0.4)
                    }.buttonStyle(.plain).accessibilityIdentifier("chart-reading-" + item.id).accessibilityValue(focus == item.id ? "Highlighted" : "Visible")
                }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("chart-readout")
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

private struct HistoryTrace: View, Equatable {
    @Environment(\.dynamicTypeSize) private var textSize
    var points: [HistoryPlot.Point]
    var events: [ChartEventGroup]
    var domain: ClosedRange<Date>
    var maximum: Double
    var rate: Bool
    var smooth: Bool
    var amount: Bool
    var revision: Int
    var focus: String?
    static func == (a: Self, b: Self) -> Bool { a.revision == b.revision && a.domain == b.domain && a.rate == b.rate && a.smooth == b.smooth && a.amount == b.amount && a.focus == b.focus }
    var body: some View {
        Chart {
            ForEach(points) { point in
                LineMark(x: .value("Time", point.date), y: .value("Usage", point.value), series: .value("Series", point.seriesID))
                    .foregroundStyle(point.color).interpolationMethod(rate || smooth || point.bridge || point.hard ? .linear : .stepEnd)
                    .lineStyle(StrokeStyle(lineWidth: point.bridge || point.subdued ? 1 : 2, dash: point.pattern))
                if point.isolated { PointMark(x: .value("Time", point.date), y: .value("Usage", point.value)).foregroundStyle(point.color).symbolSize(16) }
            }
            ForEach(events) { group in RuleMark(x: .value("Event", group.date)).foregroundStyle(.secondary.opacity(0.25)).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3])) }
        }.chartLegend(.hidden).chartXScale(domain: domain).chartPlotStyle { $0.clipped() }.chartYScale(domain: 0...maximum)
            .chartXAxis {
                if textSize.isAccessibilitySize {
                    AxisMarks(values: [domain.lowerBound.addingTimeInterval(domain.upperBound.timeIntervalSince(domain.lowerBound) / 2)]) { tick in
                        AxisGridLine()
                        AxisValueLabel { if let date = tick.as(Date.self) { Text(date.formatted(domain.upperBound.timeIntervalSince(domain.lowerBound) <= 86400 ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day())).fixedSize() } }
                    }
                } else { AxisMarks(values: .automatic(desiredCount: 3)) { tick in
                AxisGridLine()
                AxisValueLabel { if let date = tick.as(Date.self) { Text(date.formatted(domain.upperBound.timeIntervalSince(domain.lowerBound) <= 86400 ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day())).fixedSize(horizontal: false, vertical: true).frame(minHeight: 36) } }
                } }
            }
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: textSize.isAccessibilitySize ? 3 : 4)) { value in
                AxisGridLine()
                AxisValueLabel { if let number = value.as(Double.self) { Text(rate ? number.formatted(.number.precision(.fractionLength(0...1))) + (amount ? "/h" : " pp/h") : amount ? number.formatted(.number.precision(.fractionLength(0...1))) : "\(Int(number))%") } }
            } }
    }
}

struct BurnRateView: View {
    @Environment(\.dynamicTypeSize) private var textSize
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
                AccessibleStack {
                    Text("Burn rate").font(.headline)
                    if !textSize.isAccessibilitySize { Spacer() }
                    Picker("Burn rate metric", selection: Binding(get: { window.id }, set: { windowID = $0 })) { ForEach(available) { Text($0.shortTitle).tag($0.id) } }.tint(.primary)
                }
                Picker("Burn rate period", selection: $hours) { Text("1h").tag(1); Text("6h").tag(6); Text("12h").tag(12) }.modifier(AccessiblePickerStyle())
                if let estimate = BurnRate.estimate(samples: samples, windowID: window.id, hours: hours, events: events) {
                    AccessibleStack {
                        VStack(alignment: .leading, spacing: 4) { Text("Recent rate").font(.caption).foregroundStyle(.secondary); Text(HistoryRate.formatted(estimate.perHour, unit: "pp")).font(.title3.monospacedDigit()) }
                        if !textSize.isAccessibilitySize { Spacer() }
                        VStack(alignment: textSize.isAccessibilitySize ? .leading : .trailing, spacing: 4) { Text("Time to zero").font(.caption).foregroundStyle(.secondary); Text(limitTitle(estimate.limit)).font(.title3.monospacedDigit()) }
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
