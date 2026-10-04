import SwiftUI
import Charts

// Amounts are provider-reported counters. Percentages never imply token counts.
enum HistoryMeasure: String, CaseIterable, Identifiable {
    case remaining, used, amount
    var id: Self { self }
    var title: String { switch self { case .remaining: return "Remaining %"; case .used: return "Used %"; case .amount: return "Amount used" } }
    func value(_ window: UsageWindow) -> Double? {
        if self == .amount { return window.usedAmount.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
        return window.safePercent.map { self == .remaining ? 100 - $0 : $0 }
    }
    func formatted(_ value: Double, unit: String = "") -> String {
        self == .amount ? value.formatted(.number.precision(.fractionLength(0...2))) + (unit.isEmpty ? "" : " " + unit) : "\(Int(value.rounded()))%"
    }
}
struct HistoryMeasureMenu: View {
    @Binding var measure: HistoryMeasure
    @Binding var unit: String
    var units: [String]
    var activity = false
    var body: some View {
        Menu {
            Picker("Measure", selection: $measure) {
                if !activity { Text("Remaining %").tag(HistoryMeasure.remaining) }
                Text(activity ? "Allowance used" : "Used %").tag(HistoryMeasure.used)
                if !units.isEmpty { Text("Amount used").tag(HistoryMeasure.amount) }
            }
            if measure == .amount {
                Picker("Units", selection: Binding(get: { units.contains(unit) ? unit : units.first ?? "" }, set: { unit = $0 })) { ForEach(units, id: \.self) { Text($0).tag($0) } }
            }
        } label: {
            HStack(spacing: 4) { Text(measure == .amount ? (units.contains(unit) ? unit : units.first ?? "Amount") : activity ? "Allowance used" : measure.title); Image(systemName: "chevron.down").font(.system(size: 8)) }.font(.caption).foregroundStyle(Theme.accent)
        }
    }
}
struct HistoryPeriodPicker: View {
    @Binding var days: Int
    var body: some View { Picker("History period", selection: $days) { Text("24h").tag(1); Text("7d").tag(7); Text("30d").tag(30); Text("90d").tag(90) }.pickerStyle(.segmented) }
}
enum HeatmapPeriod: String, CaseIterable, Identifiable {
    case daily, weekly, monthly
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var component: Calendar.Component { switch self { case .daily: return .day; case .weekly: return .weekOfYear; case .monthly: return .month } }
}
enum HeatmapMode: String, CaseIterable, Identifiable {
    case activity, level
    var id: Self { self }
    var title: String { self == .activity ? "Consumption" : "Quota level" }
}
struct HeatmapBucket: Identifiable, Equatable {
    var id: Int
    var label: String
    var date: Date
    var value: Double?
}
enum HeatmapData {
    static func monthOffset(date: Date, calendar: Calendar = .current) -> Int {
        guard let start = calendar.dateInterval(of: .month, for: date)?.start else { return 0 }
        return (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
    }
    static func buckets(samples: [UsageHistorySample], windowID: String, measure: HistoryMeasure, period: HeatmapPeriod, date: Date, calendar: Calendar = .current, mode: HeatmapMode = .level, events: [AccountEvent] = [], unit: String? = nil, maximumGap: TimeInterval? = nil) -> [HeatmapBucket] {
        guard let interval = calendar.dateInterval(of: period.component, for: date) else { return [] }
        let count = period == .daily ? 24 : period == .weekly ? 7 * 24 : calendar.range(of: .day, in: .month, for: date)?.count ?? 31
        func index(_ date: Date) -> Int? {
            guard date >= interval.start, date < interval.end else { return nil }
            let hour = calendar.component(.hour, from: date)
            let day = calendar.dateComponents([.day], from: interval.start, to: calendar.startOfDay(for: date)).day ?? 0
            let value = period == .daily ? hour : period == .weekly ? day * 24 + hour : calendar.component(.day, from: date) - 1
            return (0..<count).contains(value) ? value : nil
        }
        let signal: HistoryMeasure = mode == .activity && measure != .amount ? .used : measure
        var groups = [Int: [Double]]()
        var previous: (Date, UsageWindow, Double, String?)?
        for sample in samples.sorted(by: { $0.date < $1.date }) {
            guard let window = sample.windows.first(where: { $0.id == windowID }), let value = signal.value(window), measure != .amount || unit == nil || window.amountUnit == unit else { previous = nil; continue }
            defer { previous = (sample.date, window, value, sample.allowanceContext) }
            if mode == .level { if let bucket = index(sample.date) { groups[bucket, default: []].append(value) }; continue }
            guard let old = previous, UsageCycle.continues(from: old.1, at: old.0, to: window, at: sample.date, events: events, previousContext: old.3, currentContext: sample.allowanceContext) else { continue }
            let elapsed = sample.date.timeIntervalSince(old.0)
            guard elapsed <= min(maximumGap ?? (period == .monthly ? HistoryRate.maximumGap : 7200), old.1.duration.flatMap { $0 > 0 ? $0 : nil } ?? HistoryRate.maximumGap) else { continue }
            let delta = max(0, value - old.2)
            var cursor = max(old.0, interval.start)
            let end = min(sample.date, interval.end)
            while cursor < end {
                let boundary = calendar.dateInterval(of: period == .monthly ? .day : .hour, for: cursor)?.end ?? end
                let stop = min(end, boundary)
                guard stop > cursor else { break }
                if let bucket = index(cursor) { groups[bucket, default: []].append(delta * stop.timeIntervalSince(cursor) / elapsed) }
                cursor = stop
            }
        }
        return (0..<count).map { index in
            let day = period == .weekly ? index / 24 : period == .monthly ? index : 0
            let dayDate = calendar.date(byAdding: .day, value: day, to: interval.start) ?? interval.start
            let bucketDate = period == .monthly ? dayDate : calendar.date(bySettingHour: index % 24, minute: 0, second: 0, of: dayDate) ?? dayDate
            let value = groups[index].map { values in mode == .activity ? values.reduce(0, +) : values.reduce(0, +) / Double(values.count) }
            return HeatmapBucket(id: index, label: period == .monthly ? String(index + 1) : String(index % 24), date: bucketDate, value: value)
        }
    }
}
struct HeatmapControls: View {
    @Binding var period: HeatmapPeriod
    @Binding var date: Date
    private var interval: DateInterval? { Calendar.current.dateInterval(of: period.component, for: date) }
    private var title: String {
        guard let interval else { return "" }
        if period == .monthly { return date.formatted(.dateTime.month(.wide).year()) }
        if period == .daily { return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }
        return interval.start.formatted(.dateTime.day().month(.abbreviated)) + " – " + interval.end.addingTimeInterval(-1).formatted(.dateTime.day().month(.abbreviated))
    }
    var body: some View {
        VStack(spacing: 10) {
            Picker("Activity period", selection: $period) { ForEach(HeatmapPeriod.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            HStack {
                Button { move(-1) } label: { Image(systemName: "chevron.left").padding(4) }.accessibilityLabel("Previous period")
                Spacer(); Text(title).font(.caption); Spacer()
                Button { move(1) } label: { Image(systemName: "chevron.right").padding(4) }.accessibilityLabel("Next period").disabled(interval.map { $0.end > .now } ?? true)
            }
        }
    }
    private func move(_ delta: Int) { date = Calendar.current.date(byAdding: period.component, value: delta, to: date) ?? date }
}
struct UsageHeatmap: View {
    let samples: [UsageHistorySample]
    let window: UsageWindow
    let color: Color
    var events: [AccountEvent] = []
    @State private var period = HeatmapPeriod.weekly
    @State private var date = Date.now
    @State private var mode = HeatmapMode.activity
    @State private var measure = HistoryMeasure.used
    @State private var unit = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HeatmapModeMenu(mode: $mode)
                Spacer()
                HistoryMeasureMenu(measure: $measure, unit: $unit, units: window.usedAmount != nil ? [window.amountUnit ?? "Amount"] : [], activity: mode == .activity)
            }
            HeatmapControls(period: $period, date: $date)
            HeatmapGrid(samples: samples, window: window, color: color, measure: measure, period: period, date: date, mode: mode, events: events)
        }.onChange(of: mode) { _, value in if value == .activity && measure == .remaining { measure = .used } }
            .onChange(of: window.id) { _, _ in if measure == .amount && window.usedAmount == nil { measure = .used } }
    }
}
struct HeatmapGrid: View {
    let samples: [UsageHistorySample]
    let window: UsageWindow
    let color: Color
    let measure: HistoryMeasure
    let period: HeatmapPeriod
    let date: Date
    let mode: HeatmapMode
    var events: [AccountEvent] = []
    @State private var selected: HeatmapBucket?
    private var cells: [HeatmapBucket] { HeatmapData.buckets(samples: samples, windowID: window.id, measure: measure, period: period, date: date, mode: mode, events: events, unit: measure == .amount ? window.amountUnit : nil) }
    private var scale: Double { mode == .activity || measure == .amount ? max(1, cells.compactMap(\.value).max() ?? 1) : 100 }
    private var unit: String { measure == .amount ? window.amountUnit ?? "Amount" : mode == .activity ? "% points used" : measure.title }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HeatmapTiles(cells: cells, period: period, date: date, color: color, scale: scale, selectedID: selected?.id) { selected = $0 }
            HStack(spacing: 6) {
                if let selected {
                    Text(selected.date.formatted(period == .monthly ? .dateTime.day().month(.abbreviated) : .dateTime.weekday(.abbreviated).hour()))
                    Spacer()
                    Text(selected.value.map { $0.formatted(.number.precision(.fractionLength(0...1))) + (measure == .amount ? " " + (window.amountUnit ?? "") : mode == .activity ? " pp" : "%") } ?? "No observation").monospacedDigit()
                } else {
                    Text(unit); Spacer(); Text("0"); LinearGradient(colors: [color.opacity(0.12), color], startPoint: .leading, endPoint: .trailing).frame(width: 42, height: 4); Text(scale.formatted(.number.precision(.fractionLength(0...1))))
                }
            }.font(.caption2).foregroundStyle(.secondary)
        }.onChange(of: period) { _, _ in selected = nil }.onChange(of: date) { _, _ in selected = nil }.onChange(of: measure) { _, _ in selected = nil }.onChange(of: mode) { _, _ in selected = nil }.onChange(of: window.id) { _, _ in selected = nil }
    }
}
struct HeatmapTiles: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    var cells: [HeatmapBucket]
    var period: HeatmapPeriod
    var date: Date
    var color: Color
    var scale: Double
    var selectedID: Int?
    var select: (HeatmapBucket) -> Void
    var body: some View { grid }
    @ViewBuilder private var grid: some View {
        if period == .daily {
            VStack(spacing: 4) { HStack(spacing: 3) { ForEach(cells) { cell in heatCell(cell, label: false).frame(height: 30) } }; hourTicks }
        } else if period == .weekly {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(0..<7) { day in
                        if cells.count > day * 24 { Text(cells[day * 24].date.formatted(.dateTime.weekday(.abbreviated).day())).font(.system(size: sizeClass == .regular ? 11 : 9)).frame(height: sizeClass == .regular ? 24 : 17) }
                    }
                }
                VStack(spacing: 4) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 24), spacing: 3) { ForEach(cells) { cell in heatCell(cell, label: false).frame(height: sizeClass == .regular ? 24 : 17) } }
                    hourTicks
                }
            }
        } else {
            let offset = HeatmapData.monthOffset(date: date)
            let weekdays = Calendar.current.veryShortStandaloneWeekdaySymbols
            VStack(spacing: 5) {
                HStack(spacing: 5) { ForEach(0..<7) { day in Text(weekdays[(Calendar.current.firstWeekday - 1 + day) % 7]).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity) } }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 5) {
                    // One ID space for all grid slots, including leading blanks.
                    ForEach(0..<(offset + cells.count), id: \.self) { slot in
                        if slot < offset { Color.clear.frame(height: sizeClass == .regular ? 52 : 29) }
                        else { heatCell(cells[slot - offset], label: true).frame(height: sizeClass == .regular ? 52 : 29) }
                    }
                }
            }
        }
    }
    private var hourTicks: some View { HStack { Text("00"); Spacer(); Text("06"); Spacer(); Text("12"); Spacer(); Text("18"); Spacer(); Text("23") }.font(.system(size: 9)).foregroundStyle(.secondary) }
    private func heatCell(_ cell: HeatmapBucket, label: Bool) -> some View {
        let future = cell.date > Date.now
        let fill: Color = future ? .clear : cell.value.map { $0 == 0 ? .white.opacity(0.06) : color.opacity(0.12 + min(1, $0 / scale) * 0.88) } ?? .clear
        return Button { select(cell) } label: {
            RoundedRectangle(cornerRadius: 3).fill(fill)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(!future && cell.value == nil ? Color.white.opacity(0.12) : .clear, lineWidth: 1))
                .overlay { if label { Text(cell.label).font(.system(size: sizeClass == .regular ? 13 : 10)).foregroundStyle(!future && (cell.value ?? 0) / scale > 0.5 ? Color.black.opacity(0.85) : Color.white.opacity(future ? 0.2 : cell.value == nil ? 0.4 : 0.9)) } }
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(selectedID == cell.id ? .white : .clear, lineWidth: 1))
        }.buttonStyle(.plain).disabled(future).accessibilityIdentifier("heatmap-cell-\(period.rawValue)-\(cell.id)").accessibilityLabel("\(cell.date.formatted(date: .abbreviated, time: period == .monthly ? .omitted : .shortened)), \(cell.value.map { String(format: "%.1f", $0) } ?? "No observation")")
    }
}

struct ChartsView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @EnvironmentObject private var store: AccountStore
    @State private var selected = Set<String>()
    @State private var choosing = false
    @State private var provider: Provider?
    @State private var customSelection = false
    @State private var days = 7
    @State private var rangeEnd = Date.now
    @State private var measure = HistoryMeasure.remaining
    @State private var kind = HistoryChartKind.lines
    @AppStorage("chart-smooth") private var smooth = false
    @State private var averagingHours = 1
    private var heatmaps: Bool { kind == .activity }
    @State private var unit = ""
    @State private var heatmapPeriod = HeatmapPeriod.weekly
    @State private var heatmapDate = Date.now
    @State private var heatmapMode = HeatmapMode.activity
    private struct Series: Identifiable {
        let account: AgentAccount
        let window: UsageWindow
        var id: String { account.id.uuidString + ":" + window.id }
        var title: String { account.title + " · " + window.shortTitle }
    }
    private var connectedProviders: [Provider] { Provider.allCases.filter { p in store.accounts.contains { $0.provider == p } } }
    private var filteredAccounts: [AgentAccount] { store.accounts.filter { provider == nil || $0.provider == provider } }
    private func compatible(_ series: Series) -> Bool { measure != .amount || (series.window.amountUnit == activeUnit && series.window.usedAmount != nil) }
    private func chosen(_ series: Series) -> Bool { customSelection ? selected.contains(series.id) : series.window.id == (series.account.window(for: .weekly) ?? series.account.snapshot?.windows.first)?.id }
    private func set(_ series: Series, enabled: Bool) {
        if !customSelection { selected = Set(available.filter { chosen($0) }.map(\.id)); customSelection = true }
        if enabled { selected.insert(series.id) } else { selected.remove(series.id) }
    }
    private var available: [Series] { store.accounts.flatMap { account in (account.snapshot?.windows ?? []).map { Series(account: account, window: $0) } } }
    private var visible: [Series] {
        available.filter { (provider == nil || $0.account.provider == provider) && chosen($0) && (measure != .amount || $0.window.amountUnit == activeUnit && $0.window.usedAmount != nil) }
    }
    private var domain: ClosedRange<Date> { rangeEnd.addingTimeInterval(-Double(days) * 86400)...rangeEnd }
    private var units: [String] { Array(Set(available.filter { $0.window.usedAmount != nil }.compactMap { $0.window.amountUnit })).sorted() }
    private var activeUnit: String { units.contains(unit) ? unit : units.first ?? "" }
    private var names: [UUID: String] { Dictionary(uniqueKeysWithValues: store.accounts.map { ($0.id, $0.title) }) }
    private func samples(_ id: UUID) -> [UsageHistorySample] { store.histories[id] ?? [] }
    private var plots: [HistoryPlotSeries] {
        visible.map { series in
            let accountEvents = store.events.filter { $0.accountID == series.account.id }
            let data = HistorySeries.plot(samples: samples(series.account.id), windowID: series.window.id, measure: measure, unit: measure == .amount ? activeUnit : nil, events: accountEvents)
            return HistoryPlotSeries(id: series.id, title: series.title, color: series.account.color,
                segments: kind == .rate ? HistoryRate.segments(samples: samples(series.account.id), windowID: series.window.id, measure: measure, unit: activeUnit, events: accountEvents, averagingHours: averagingHours) : data.segments,
                provider: series.account.provider, dashPattern: pattern(for: series), hardSegments: kind == .rate ? [] : data.transitions, bridgeSegments: kind == .rate ? [] : data.bridges,
                subdued: days >= 7 && series.window.duration.map { $0 <= 21600 } == true,
                dashed: series.window.id != (series.account.window(for: .weekly) ?? series.account.snapshot?.windows.first)?.id)
        }
    }
    private var events: [ChartEventGroup] {
        let relevant = store.accounts.flatMap { account in
            ChartEvents.groups(events: store.events.filter { $0.accountID == account.id }, windows: visible.filter { $0.account.id == account.id }.map(\.window), domain: rangeEnd.addingTimeInterval(-UsageHistoryStore.retention)...rangeEnd).flatMap(\.events)
        }
        return ChartEvents.groups(events: relevant, windows: visible.map(\.window), domain: rangeEnd.addingTimeInterval(-UsageHistoryStore.retention)...rangeEnd)
    }
    init() {
        #if DEBUG
        if SimulatorFixtures.storeCaptureEnabled {
            _customSelection = State(initialValue: true)
            _selected = State(initialValue: Set((1...3).map { String(format: "A9000000-0000-0000-0000-%012d:week", $0) }))
            if SimulatorFixtures.captureScreen == "activity" {
                _kind = State(initialValue: .activity)
                _heatmapPeriod = State(initialValue: .monthly)
                _heatmapDate = State(initialValue: Calendar.current.date(byAdding: .month, value: -1, to: .now)!)
            }
        }
        #endif
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if sizeClass == .regular {
                        HStack(spacing: 24) {
                            Text("Charts").font(.title2.weight(.semibold))
                            chartKindPicker.frame(width: 300)
                            Spacer(minLength: 0)
                        }
                    } else { chartKindPicker }
                    providerFilters
                    DisclosureGroup(isExpanded: $choosing) { selectionControls } label: {
                        Text("Accounts & metrics").font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    }.padding(12).background(Theme.card, in: RoundedRectangle(cornerRadius: 12)).accessibilityIdentifier("chart-accounts")
                    if visible.isEmpty { Text(measure == .amount && available.contains(where: { chosen($0) }) ? "No selected metrics report " + activeUnit + "." : "No metrics selected.").font(.subheadline).foregroundStyle(.secondary) }
                    else if heatmaps { activityCharts(wide: sizeClass == .regular && geometry.size.width >= 800) }
                    else {
                        if sizeClass == .regular {
                            HStack(spacing: 24) {
                                HistoryPeriodPicker(days: $days).frame(maxWidth: 400)
                                Spacer()
                                plotOptions.frame(maxWidth: 280)
                            }
                        } else { HistoryPeriodPicker(days: $days); plotOptions }
                        VStack(alignment: .leading, spacing: 14) {
                            if plots.flatMap({ $0.segments.flatMap { $0 } }).isEmpty { Text("History starts with successful refreshes.").font(.caption).foregroundStyle(.secondary) }
                            else { HistoryPlot(series: plots, domain: domain, measure: kind == .rate && measure == .remaining ? .used : measure, unit: activeUnit, events: events, accountNames: names, height: sizeClass == .regular ? min(650, max(380, geometry.size.height - 320)) : 280, smooth: smooth, rate: kind == .rate) }
                        }.panel()
                    }
                }.padding(.horizontal, sizeClass == .regular ? 32 : 16).padding(.vertical, sizeClass == .regular ? 24 : 16).frame(maxWidth: sizeClass == .regular ? 1280 : 750).frame(maxWidth: .infinity)
            }
        }.background(Theme.background).navigationTitle("Charts").navigationBarTitleDisplayMode(.inline).refreshable { await store.refreshAll(); rangeEnd = .now }
            .onAppear { rangeEnd = .now }
            .onChange(of: store.accounts.compactMap { $0.snapshot?.updatedAt }.max()) { _, _ in rangeEnd = .now }
            .onChange(of: connectedProviders) { _, providers in if let provider, !providers.contains(provider) { self.provider = nil } }

    }
    private var chartKindPicker: some View {
        Picker("Chart type", selection: $kind) { ForEach(HistoryChartKind.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
    }
    private var plotOptions: some View {
        HStack {
            HistoryMeasureMenu(measure: $measure, unit: $unit, units: units, activity: kind == .rate)
            Spacer()
            HistoryLineOptions(smooth: $smooth, rate: kind == .rate, averagingHours: $averagingHours)
        }
    }
    private func pattern(for series: Series) -> [CGFloat] {
        let peers = store.accounts.filter { $0.provider == series.account.provider }.sorted { $0.id.uuidString < $1.id.uuidString }
        let rank = peers.firstIndex { $0.id == series.account.id } ?? 0
        let windows = available.filter { $0.account.id == series.account.id }.sorted { a, b in
            let primary = (series.account.window(for: .weekly) ?? series.account.snapshot?.windows.first)?.id
            if (a.window.id == primary) != (b.window.id == primary) { return a.window.id == primary }
            return a.window.id < b.window.id
        }
        let metric = windows.firstIndex { $0.id == series.id } ?? 0
        return ChartDashPattern.pattern(rank + metric * peers.count)
    }
    private func activityCharts(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HeatmapModeMenu(mode: $heatmapMode)
                Spacer()
                HistoryMeasureMenu(measure: $measure, unit: $unit, units: units, activity: heatmapMode == .activity)
            }
            CombinedActivityView(inlineBreakdown: wide, series: visible.map { item in ActivitySeries(id: item.id, account: item.account, window: item.window, samples: samples(item.account.id), events: store.events.filter { $0.accountID == item.account.id }) }, measure: heatmapMode == .activity && measure == .remaining ? .used : measure, unit: activeUnit, mode: heatmapMode, period: $heatmapPeriod, date: $heatmapDate)
        }.panel()
    }
    private var providerFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                providerButton(nil)
                ForEach(connectedProviders) { providerButton($0) }
            }
        }.accessibilityIdentifier("chart-provider-filters")
    }
    private func providerButton(_ value: Provider?) -> some View {
        Button { provider = value } label: {
            HStack(spacing: 5) {
                if let value { ProviderLogo(provider: value, color: value.color, size: 14) }
                Text(value?.name ?? "All").font(.caption.weight(.medium))
            }.padding(.horizontal, 11).padding(.vertical, 7).foregroundStyle(provider == value ? Theme.accent : .secondary)
                .background(provider == value ? Theme.accent.opacity(0.13) : Theme.card, in: Capsule())
        }.buttonStyle(.plain).accessibilityIdentifier("chart-provider-" + (value?.rawValue ?? "all")).accessibilityValue(provider == value ? "Selected" : "Not selected")
    }
    private var selectionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Weekly / primary") { customSelection = false; selected = [] }
                Spacer()
                Button("None") { selected = []; customSelection = true }
            }.font(.caption).padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(filteredAccounts) { account in
                        let metrics = available.filter { $0.account.id == account.id }
                        let usable = metrics.filter { compatible($0) }
                        let enabled = usable.contains { chosen($0) }
                        VStack(alignment: .leading, spacing: 7) {
                            Button {
                                var next = Set(available.filter { chosen($0) }.map(\.id))
                                if enabled { next.subtract(metrics.map(\.id)) }
                                else if let main = usable.first(where: { $0.window.id == (account.window(for: .weekly) ?? account.snapshot?.windows.first)?.id }) ?? usable.first { next.insert(main.id) }
                                selected = next; customSelection = true
                            } label: {
                                HStack(spacing: 8) {
                                    ProviderLogo(provider: account.provider, color: account.color, size: 18)
                                    Text(account.title).font(.subheadline)
                                    Text(account.provider.name).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Image(systemName: enabled ? "checkmark.circle.fill" : "circle").foregroundStyle(enabled ? Theme.accent : .secondary)
                                }.foregroundStyle(.primary).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(usable.isEmpty).accessibilityIdentifier("chart-account-" + account.id.uuidString).accessibilityValue(enabled ? "On" : "Off")
                            ChartLegendLayout(spacing: 6) {
                                ForEach(metrics) { item in
                                    Button { set(item, enabled: !chosen(item)) } label: {
                                        HStack(spacing: 5) {
                                            Path { path in path.move(to: .init(x: 0, y: 3)); path.addLine(to: .init(x: 28, y: 3)) }.stroke(account.color, style: StrokeStyle(lineWidth: 2, dash: pattern(for: item))).frame(width: 28, height: 6)
                                            Text(item.window.shortTitle).font(.caption2)
                                        }.padding(.horizontal, 8).padding(.vertical, 5).foregroundStyle(chosen(item) ? .primary : .secondary)
                                            .background(chosen(item) ? account.color.opacity(0.16) : Color.white.opacity(0.04), in: Capsule())
                                    }.buttonStyle(.plain).disabled(!compatible(item)).opacity(compatible(item) ? 1 : 0.35).accessibilityIdentifier("chart-metric-" + item.id).accessibilityValue(chosen(item) ? "On" : "Off")
                                }
                            }
                        }
                    }
                }
            }.frame(maxHeight: 230)
        }
    }

}


enum HistoryChartKind: String, CaseIterable, Identifiable {
    case lines, rate, activity
    var id: String { rawValue }
    var title: String { switch self { case .lines: return "Lines"; case .rate: return "Rate"; case .activity: return "Activity" } }
}
struct HistoryLineOptions: View {
    @Binding var smooth: Bool
    var rate: Bool
    @Binding var averagingHours: Int
    var body: some View {
        if rate {
            Menu {
                Picker("Rate averaging", selection: $averagingHours) { Text("1h average").tag(1); Text("6h average").tag(6); Text("12h average").tag(12) }
            } label: { HStack(spacing: 4) { Text("\(averagingHours)h average"); Image(systemName: "chevron.down").font(.system(size: 8)) }.font(.caption).padding(.vertical, 6) }.tint(Theme.accent)
        } else {
            Button { smooth.toggle() } label: {
                Label("Smooth", systemImage: "waveform.path").font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 6)
                    .foregroundStyle(smooth ? Theme.accent : .secondary).background(smooth ? Theme.accent.opacity(0.13) : Color.white.opacity(0.05), in: Capsule())
            }.buttonStyle(.plain).accessibilityIdentifier("chart-smooth").accessibilityValue(smooth ? "On" : "Off").accessibilityAddTraits(smooth ? .isSelected : [])
        }
    }
}

struct HeatmapModeMenu: View {
    @Binding var mode: HeatmapMode
    var body: some View {
        Menu { Picker("Activity display", selection: $mode) { ForEach(HeatmapMode.allCases) { Text($0.title).tag($0) } } } label: {
            HStack(spacing: 4) { Text(mode.title); Image(systemName: "chevron.down").font(.system(size: 8)) }.font(.caption).foregroundStyle(.secondary)
        }
    }
}
enum ChartDashPattern {
    static func pattern(_ ordinal: Int) -> [CGFloat] {
        let patterns: [[CGFloat]] = [[], [8, 4], [2, 4], [10, 4, 2, 4], [6, 3], [1, 3], [12, 4], [4, 5], [8, 3, 1, 3], [3, 3], [14, 3, 2, 3], [5, 2, 1, 2], [10, 5], [2, 6], [6, 4, 2, 4], [12, 3, 1, 3]]
        if patterns.indices.contains(ordinal) { return patterns[ordinal] }
        return [CGFloat(3 + ordinal / 12), 3, CGFloat(1 + ordinal % 12), 3, 1, 3]
    }
}
