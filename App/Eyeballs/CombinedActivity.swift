import SwiftUI

struct ActivitySeries: Identifiable {
    var id: String
    var account: AgentAccount
    var window: UsageWindow
    var samples: [UsageHistorySample]
    var events: [AccountEvent]
    var title: String { account.title + " · " + window.shortTitle }
}
enum ActivityWindowClass: String, CaseIterable, Identifiable {
    case weekly, short, monthly, other
    var id: Self { self }
    var title: String { switch self { case .weekly: return "Weekly"; case .short: return "Short"; case .monthly: return "Monthly"; case .other: return "Other" } }
    static func of(_ window: UsageWindow) -> Self {
        if EventDetection.weekly(window) { return .weekly }
        if let duration = window.duration, duration > 0, duration <= 21600 { return .short }
        if window.duration.map({ (27 * 86400.0...32 * 86400.0).contains($0) }) == true || window.title.localizedCaseInsensitiveContains("monthly") { return .monthly }
        return .other
    }
}
enum CombinedActivity {
    static func uniqueAccounts(_ series: [ActivitySeries], windowClass: ActivityWindowClass) -> [ActivitySeries] {
        var seen = Set<UUID>()
        let matching = series.filter { ActivityWindowClass.of($0.window) == windowClass }
        return matching.sorted { a, b in
            let aPrimary = a.window.id == (a.account.window(for: .weekly) ?? a.account.snapshot?.windows.first)?.id
            let bPrimary = b.window.id == (b.account.window(for: .weekly) ?? b.account.snapshot?.windows.first)?.id
            return aPrimary && !bPrimary
        }.filter { seen.insert($0.account.id).inserted }
    }
    static func combine(_ series: [[HeatmapBucket]], amount: Bool) -> [HeatmapBucket] {
        guard let template = series.first else { return [] }
        return template.enumerated().map { index, cell in
            let values = series.compactMap { $0.indices.contains(index) ? $0[index].value : nil }
            var cell = cell
            cell.value = values.isEmpty ? nil : values.reduce(0, +) / (amount ? 1 : Double(values.count))
            return cell
        }
    }
}
struct CombinedActivityView: View {
    var inlineBreakdown = false
    var series: [ActivitySeries]
    var measure: HistoryMeasure
    var unit: String
    var mode: HeatmapMode
    @Binding var period: HeatmapPeriod
    @Binding var date: Date
    @State private var windowClass = ActivityWindowClass.weekly
    private var classes: [ActivityWindowClass] { ActivityWindowClass.allCases.filter { group in series.contains { ActivityWindowClass.of($0.window) == group } } }
    private var activeClass: ActivityWindowClass { classes.contains(windowClass) ? windowClass : classes.first ?? .weekly }
    private var included: [ActivitySeries] { CombinedActivity.uniqueAccounts(series, windowClass: activeClass) }
    @State private var selected: HeatmapBucket?
    @State private var selectedPeriod: HeatmapPeriod?
    private func buckets(_ item: ActivitySeries, period: HeatmapPeriod, date: Date) -> [HeatmapBucket] {
        HeatmapData.buckets(samples: item.samples, windowID: item.window.id, measure: measure, period: period, date: date, mode: mode, events: item.events, unit: measure == .amount ? unit : nil)
    }
    private var cells: [HeatmapBucket] { CombinedActivity.combine(included.map { buckets($0, period: period, date: date) }, amount: measure == .amount && mode == .activity) }
    private var scale: Double { mode == .activity || measure == .amount ? max(1, cells.compactMap(\.value).max() ?? 1) : 100 }
    private var title: String { measure == .amount ? (mode == .activity ? "Total " : "Average ") + unit : mode == .activity ? "Average quota used" : "Average " + measure.title.lowercased() }
    private func value(_ value: Double?) -> String { value.map { $0.formatted(.number.precision(.fractionLength(0...1))) + (measure == .amount ? " " + unit : mode == .activity ? " pp" : "%") } ?? "—" }
    private var focusedCell: HeatmapBucket? {
        selected ?? cells.last(where: { $0.value != nil && $0.date < Calendar.current.startOfDay(for: .now) }) ?? cells.first(where: { $0.value != nil })
    }
    private var calendarSelection: Int? {
        guard let focus = focusedCell else { return nil }
        return cells.first { period == .monthly ? Calendar.current.isDate($0.date, inSameDayAs: focus.date) : $0.date == focus.date }?.id
    }
    private func select(_ cell: HeatmapBucket, period: HeatmapPeriod) { selected = cell; selectedPeriod = period }
    var body: some View {
        Group {
            if inlineBreakdown {
                VStack(alignment: .leading, spacing: 28) {
                    HStack(alignment: .top, spacing: 32) {
                        calendarContent.frame(maxWidth: .infinity)
                        if let cell = focusedCell {
                            VStack(alignment: .leading, spacing: 18) {
                                Text(cell.date.formatted(.dateTime.weekday(.wide).day().month(.wide)) + ((selected == nil ? period : selectedPeriod ?? period) == .monthly ? "" : " · " + cell.date.formatted(.dateTime.hour().minute()))).font(.headline)
                                HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value(cell.value)).monospacedDigit() }.font(.subheadline)
                                let hourly = CombinedActivity.combine(included.map { buckets($0, period: .daily, date: cell.date) }, amount: measure == .amount && mode == .activity)
                                HeatmapTiles(cells: hourly, period: .daily, date: cell.date, color: Theme.accent, scale: max(1, hourly.compactMap(\.value).max() ?? 1), select: { select($0, period: .daily) })
                                Divider()
                                Text(mode == .activity ? "Day consumption" : "Day average").font(.caption).foregroundStyle(.secondary)
                                ForEach(included) { item in accountBreakdown(item, date: cell.date) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        }
                    }
                    if period == .monthly, let cell = focusedCell {
                        Divider()
                        let week = CombinedActivity.combine(included.map { buckets($0, period: .weekly, date: cell.date) }, amount: measure == .amount && mode == .activity)
                        let weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: cell.date)?.start ?? cell.date
                        Text("Week of " + weekStart.formatted(.dateTime.day().month(.wide))).font(.subheadline.weight(.semibold))
                        HeatmapTiles(cells: week, period: .weekly, date: cell.date, color: Theme.accent, scale: max(1, week.compactMap(\.value).max() ?? 1), select: { select($0, period: .weekly) })
                    }
                }
            } else { calendarContent }
        }.accessibilityIdentifier("combined-activity")
            .sheet(item: Binding(get: { inlineBreakdown ? nil : selected }, set: { selected = $0 })) { cell in breakdown(cell) }
            .onChange(of: measure) { _, _ in selected = nil }.onChange(of: mode) { _, _ in selected = nil }.onChange(of: activeClass) { _, _ in selected = nil }.onChange(of: unit) { _, _ in selected = nil }
            .onChange(of: period) { _, _ in selected = nil }.onChange(of: date) { _, _ in selected = nil }.onChange(of: series.map(\.id)) { _, _ in selected = nil }
    }
    private var calendarContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if classes.count > 1 { Picker("Activity windows", selection: Binding(get: { activeClass }, set: { windowClass = $0 })) { ForEach(classes) { Text($0.title).tag($0) } }.pickerStyle(.segmented).accessibilityIdentifier("activity-window-class") }
            HeatmapControls(period: $period, date: $date)
            HeatmapTiles(cells: cells, period: period, date: date, color: Theme.accent, scale: scale, selectedID: calendarSelection) { select($0, period: period) }
            HStack(spacing: 6) {
                Text(title); Spacer(); Text("0")
                LinearGradient(colors: [Theme.accent.opacity(0.12), Theme.accent], startPoint: .leading, endPoint: .trailing).frame(width: 42, height: 4)
                Text(scale.formatted(.number.precision(.fractionLength(0...1))))
            }.font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func dayBuckets(_ item: ActivitySeries, date: Date) -> [HeatmapBucket] {
        HeatmapData.buckets(samples: item.samples, windowID: item.window.id, measure: measure, period: .monthly, date: date, mode: mode, events: item.events, unit: measure == .amount ? unit : nil, maximumGap: period == .monthly ? HistoryRate.maximumGap : 7200)
    }
    private func accountBreakdown(_ item: ActivitySeries, date: Date) -> some View {
        let day = Calendar.current.component(.day, from: date) - 1
        let daily = dayBuckets(item, date: date)
        let number = daily.indices.contains(day) ? daily[day].value : nil
        return HStack(spacing: 10) {
            ProviderLogo(provider: item.account.provider, color: item.account.color, size: 20)
            VStack(alignment: .leading, spacing: 3) { Text(item.account.title); Text(item.account.provider.name + " · " + item.window.shortTitle).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Text(value(number)).monospacedDigit()
        }.font(.subheadline).padding(.vertical, 4)
    }
    private func breakdown(_ cell: HeatmapBucket) -> some View {
        NavigationStack {
            List {
                Section(period == .monthly ? "Selected day" : cell.date.formatted(.dateTime.hour())) { LabeledContent(title, value: value(cell.value)) }
                Section(mode == .activity ? "Day consumption" : "Day average") {
                    LabeledContent("Coverage", value: "\(included.filter { item in let day = Calendar.current.component(.day, from: cell.date) - 1; let data = dayBuckets(item, date: cell.date); return data.indices.contains(day) && data[day].value != nil }.count) of \(included.count) accounts")
                    ForEach(included) { item in
                        accountBreakdown(item, date: cell.date)
                    }
                }
            }.navigationTitle(cell.date.formatted(.dateTime.month(.abbreviated).day())).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selected = nil } } }
        }.presentationDetents([.medium, .large]).accessibilityIdentifier("activity-breakdown")
    }
}
