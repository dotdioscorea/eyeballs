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
    static func buckets(samples: [UsageHistorySample], windowID: String, measure: HistoryMeasure, period: HeatmapPeriod, date: Date, calendar: Calendar = .current, mode: HeatmapMode = .level, events: [AccountEvent] = [], unit: String? = nil) -> [HeatmapBucket] {
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
            guard let bucket = index(sample.date) else { continue }
            if mode == .level { groups[bucket, default: []].append(value); continue }
            guard let old = previous, UsageCycle.continues(from: old.1, at: old.0, to: window, at: sample.date, events: events, previousContext: old.3, currentContext: sample.allowanceContext) else { continue }
            // A delta belongs to this cell only if its interval is inside the cell,
            // or crosses a boundary by no more than twenty minutes. Never distribute
            // a long unobserved interval across hours or days.
            guard index(old.0) == bucket || sample.date.timeIntervalSince(old.0) <= 1200 else { continue }
            groups[bucket, default: []].append(max(0, value - old.2))
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
                Picker("Activity display", selection: $mode) { ForEach(HeatmapMode.allCases) { Text($0.title).tag($0) } }.font(.caption).tint(.secondary)
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
    @State private var showingMethod = false
    private var cells: [HeatmapBucket] { HeatmapData.buckets(samples: samples, windowID: window.id, measure: measure, period: period, date: date, mode: mode, events: events, unit: measure == .amount ? window.amountUnit : nil) }
    private var scale: Double { mode == .activity || measure == .amount ? max(1, cells.compactMap(\.value).max() ?? 1) : 100 }
    private var unit: String { measure == .amount ? window.amountUnit ?? "Amount" : mode == .activity ? "% points used" : measure.title }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            grid
            HStack(spacing: 6) {
                if let selected {
                    Text(selected.date.formatted(period == .monthly ? .dateTime.day().month(.abbreviated) : .dateTime.weekday(.abbreviated).hour()))
                    Spacer()
                    Text(selected.value.map { $0.formatted(.number.precision(.fractionLength(0...1))) + (measure == .amount ? " " + (window.amountUnit ?? "") : mode == .activity ? " pp" : "%") } ?? "No observation").monospacedDigit()
                } else {
                    Text(unit); Spacer(); Text("0"); LinearGradient(colors: [color.opacity(0.12), color], startPoint: .leading, endPoint: .trailing).frame(width: 42, height: 4); Text(scale.formatted(.number.precision(.fractionLength(0...1))))
                }
                Button { showingMethod = true } label: { Image(systemName: "info.circle") }.accessibilityLabel("How activity is measured")
            }.font(.caption2).foregroundStyle(.secondary)
        }.onChange(of: period) { _, _ in selected = nil }.onChange(of: date) { _, _ in selected = nil }.onChange(of: measure) { _, _ in selected = nil }.onChange(of: mode) { _, _ in selected = nil }.onChange(of: window.id) { _, _ in selected = nil }
            .alert("Activity", isPresented: $showingMethod) { Button("OK", role: .cancel) {} } message: { Text("Consumption uses increases between readings within the same allowance cycle. Reset drops are excluded. Outlined cells have no observation; empty cells are in the future. Quota level shows the average reported level instead. Percentages cannot be compared as token counts.") }
    }
    @ViewBuilder private var grid: some View {
        if period == .daily {
            VStack(spacing: 4) { HStack(spacing: 3) { ForEach(cells) { cell in heatCell(cell, label: false).frame(height: 30) } }; hourTicks }
        } else if period == .weekly {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(0..<7) { day in
                        if cells.count > day * 24 { Text(cells[day * 24].date.formatted(.dateTime.weekday(.abbreviated).day())).font(.system(size: 9)).frame(height: 17) }
                    }
                }
                VStack(spacing: 4) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 24), spacing: 3) { ForEach(cells) { cell in heatCell(cell, label: false).frame(height: 17) } }
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
                        if slot < offset { Color.clear.frame(height: 29) }
                        else { heatCell(cells[slot - offset], label: true).frame(height: 29) }
                    }
                }
            }
        }
    }
    private var hourTicks: some View { HStack { Text("00"); Spacer(); Text("06"); Spacer(); Text("12"); Spacer(); Text("18"); Spacer(); Text("23") }.font(.system(size: 9)).foregroundStyle(.secondary) }
    private func heatCell(_ cell: HeatmapBucket, label: Bool) -> some View {
        let future = cell.date > Date.now
        let fill: Color = future ? .clear : cell.value.map { $0 == 0 ? .white.opacity(0.06) : color.opacity(0.12 + min(1, $0 / scale) * 0.88) } ?? .clear
        return Button { selected = cell } label: {
            RoundedRectangle(cornerRadius: 3).fill(fill)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(!future && cell.value == nil ? Color.white.opacity(0.12) : .clear, lineWidth: 1))
                .overlay { if label { Text(cell.label).font(.system(size: 10)).foregroundStyle(.white.opacity(future ? 0.2 : cell.value == nil ? 0.4 : 0.9)) } }
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(selected?.id == cell.id ? .white : .clear, lineWidth: 1))
        }.buttonStyle(.plain).disabled(future).accessibilityIdentifier("heatmap-cell-\(period.rawValue)-\(cell.id)").accessibilityLabel("\(cell.date.formatted(date: .abbreviated, time: period == .monthly ? .omitted : .shortened)), \(cell.value.map { String(format: "%.1f", $0) + " " + unit } ?? "No observation")")
    }
}

struct ChartsView: View {
    @EnvironmentObject private var store: AccountStore
    @State private var selected = Set<String>()
    @State private var choosing = false
    @State private var customSelection = false
    @State private var days = 7
    @State private var rangeEnd = Date.now
    @State private var measure = HistoryMeasure.remaining
    @State private var kind = HistoryChartKind.lines
    @AppStorage("chart-smooth") private var smooth = false
    @State private var averagingHours = 1
    @State private var highlighted: String?
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
    private var available: [Series] { store.accounts.flatMap { account in (account.snapshot?.windows ?? []).map { Series(account: account, window: $0) } } }
    private var visible: [Series] {
        available.filter { series in
            let chosen = !customSelection ? series.window.id == (series.account.window(for: .weekly) ?? series.account.snapshot?.windows.first)?.id : selected.contains(series.id)
            return chosen && (measure != .amount || series.window.amountUnit == activeUnit && series.window.usedAmount != nil)
        }
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
                dashPattern: pattern(for: series), hardSegments: kind == .rate ? [] : data.transitions,
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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Chart type", selection: $kind) { ForEach(HistoryChartKind.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                HStack {
                    Button { choosing = true } label: { HStack(spacing: 5) { Image(systemName: "slider.horizontal.3"); Text("Accounts & metrics") }.font(.caption) }.accessibilityIdentifier("chart-accounts")
                    Spacer()
                    HistoryMeasureMenu(measure: $measure, unit: $unit, units: units, activity: kind == .rate || (heatmaps && heatmapMode == .activity))
                }
                if visible.isEmpty { Text("No metrics selected.").font(.subheadline).foregroundStyle(.secondary) }
                else if heatmaps { activityCharts }
                else {
                    HistoryPeriodPicker(days: $days)
                    HistoryLineOptions(smooth: $smooth, rate: kind == .rate, averagingHours: $averagingHours)
                    VStack(alignment: .leading, spacing: 14) {
                        if plots.flatMap({ $0.segments.flatMap { $0 } }).isEmpty { Text("History starts with successful refreshes.").font(.caption).foregroundStyle(.secondary) }
                        else { HistoryPlot(series: plots, domain: domain, measure: measure, unit: activeUnit, events: events, accountNames: names, height: 280, smooth: smooth, rate: kind == .rate, highlighted: highlighted) }
                        ChartLegendLayout {
                            ForEach(visible) { series in
                                Button { highlighted = highlighted == series.id ? nil : series.id } label: {
                                    HStack(spacing: 6) {
                                        Path { path in path.move(to: .init(x: 0, y: 3)); path.addLine(to: .init(x: 20, y: 3)) }.stroke(series.account.color, style: StrokeStyle(lineWidth: 2, dash: pattern(for: series))).frame(width: 20, height: 6)
                                        Text(series.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }.opacity(highlighted == nil || highlighted == series.id ? 1 : 0.4)
                                }.buttonStyle(.plain).accessibilityLabel(series.title).accessibilityValue(highlighted == series.id ? "Highlighted" : "Visible")
                            }
                        }.accessibilityIdentifier("chart-legend")
                    }.panel()
                }
            }.padding(16).frame(maxWidth: 750).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Charts").navigationBarTitleDisplayMode(.inline).refreshable { await store.refreshAll(); rangeEnd = .now }
            .sheet(isPresented: $choosing) { selectionSheet }
            .onAppear { rangeEnd = .now }
            .onChange(of: store.accounts.compactMap { $0.snapshot?.updatedAt }.max()) { _, _ in rangeEnd = .now }
            .onChange(of: kind) { _, value in if measure == .remaining && (value == .rate || (value == .activity && heatmapMode == .activity)) { measure = .used } }
            .onChange(of: heatmapMode) { _, value in if value == .activity && measure == .remaining { measure = .used } }
    }
    private func pattern(for series: Series) -> [CGFloat] {
        let peers = store.accounts.filter { $0.provider == series.account.provider }.sorted { $0.id.uuidString < $1.id.uuidString }
        let rank = peers.firstIndex { $0.id == series.account.id } ?? 0
        let patterns: [[CGFloat]] = [[], [7, 3], [2, 3], [8, 3, 2, 3], [10, 3, 2, 3, 2, 3]]
        let main = series.window.id == (series.account.window(for: .weekly) ?? series.account.snapshot?.windows.first)?.id
        return main ? patterns[rank % patterns.count] : patterns[(rank + 1) % patterns.count] + [2, 2]
    }
    private var activityCharts: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Picker("Activity display", selection: $heatmapMode) { ForEach(HeatmapMode.allCases) { Text($0.title).tag($0) } }.font(.caption).tint(.secondary); Spacer() }
            HeatmapControls(period: $heatmapPeriod, date: $heatmapDate)
            ForEach(visible) { series in
                VStack(alignment: .leading, spacing: 12) {
                    Text(series.title).font(.subheadline.weight(.semibold))
                    HeatmapGrid(samples: store.histories[series.account.id] ?? [], window: series.window, color: series.account.color, measure: measure, period: heatmapPeriod, date: heatmapDate, mode: heatmapMode, events: store.events.filter { $0.accountID == series.account.id })
                }.panel()
            }
        }
    }
    private var selectionSheet: some View {
        NavigationStack {
            List {
                Button("Weekly / primary for all accounts") { selected = []; customSelection = false }
                ForEach(store.accounts) { account in
                    Section(account.title) {
                        ForEach(available.filter { $0.account.id == account.id }) { series in
                            Toggle(series.window.title, isOn: Binding(get: { !customSelection ? series.window.id == (series.account.window(for: .weekly) ?? series.account.snapshot?.windows.first)?.id : selected.contains(series.id) }, set: { value in
                                if !customSelection { selected = Set(available.filter { $0.window.id == ($0.account.window(for: .weekly) ?? $0.account.snapshot?.windows.first)?.id }.map(\.id)); customSelection = true }
                                if value { selected.insert(series.id) } else { selected.remove(series.id) }
                            }))
                        }
                    }
                }
            }.navigationTitle("Chart accounts").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { choosing = false } } }
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
    @State private var info = false
    var body: some View {
        HStack {
            if rate {
                Menu {
                    Picker("Rate averaging", selection: $averagingHours) { Text("1h average").tag(1); Text("6h average").tag(6); Text("12h average").tag(12) }
                } label: { HStack(spacing: 4) { Text("\(averagingHours)h average"); Image(systemName: "chevron.down").font(.system(size: 8)) }.font(.caption) }
            } else { Toggle("Smooth", isOn: $smooth).font(.caption).fixedSize().accessibilityIdentifier("chart-smooth") }
            Spacer()
            Button { info = true } label: { Image(systemName: "info.circle") }.accessibilityLabel("Chart information")
        }.tint(Theme.accent)
            .alert(rate ? "Burn rate" : "Usage lines", isPresented: $info) { Button("OK", role: .cancel) {} } message: {
                Text(rate ? "Rates average consumption between readings. Gaps up to 6 hours are spread evenly; longer gaps and resets are excluded. Averages need at least 15 minutes of readings. pp/h means percentage points per hour, not tokens." : "Pinch to zoom, drag to move through time, and hold to inspect readings. Smooth curves keep reported values and 0%/100% endpoints. Resets stay as steps; gaps over 6 hours remain empty.")
            }
    }
}
