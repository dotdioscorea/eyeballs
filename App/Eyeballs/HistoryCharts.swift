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
}
enum HeatmapPeriod: String, CaseIterable, Identifiable {
    case daily, weekly, monthly
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var component: Calendar.Component { switch self { case .daily: return .day; case .weekly: return .weekOfYear; case .monthly: return .month } }
}
struct HeatmapBucket: Identifiable, Equatable {
    var id: Int
    var label: String
    var date: Date
    var value: Double?
}
enum HeatmapData {
    static func buckets(samples: [UsageHistorySample], windowID: String, measure: HistoryMeasure, period: HeatmapPeriod, date: Date, calendar: Calendar = .current) -> [HeatmapBucket] {
        guard let interval = calendar.dateInterval(of: period.component, for: date) else { return [] }
        let count = period == .daily ? 24 : period == .weekly ? 7 * 24 : calendar.range(of: .day, in: .month, for: date)?.count ?? 31
        var groups = [Int: [Double]]()
        for sample in samples where interval.contains(sample.date) && sample.date < interval.end {
            guard let window = sample.windows.first(where: { $0.id == windowID }), let value = measure.value(window) else { continue }
            let hour = calendar.component(.hour, from: sample.date)
            let day = calendar.dateComponents([.day], from: interval.start, to: calendar.startOfDay(for: sample.date)).day ?? 0
            let index = period == .daily ? hour : period == .weekly ? day * 24 + hour : calendar.component(.day, from: sample.date) - 1
            if (0..<count).contains(index) { groups[index, default: []].append(value) }
        }
        return (0..<count).map { index in
            let day = period == .weekly ? index / 24 : period == .monthly ? index : 0
            let bucketDate = calendar.date(byAdding: .day, value: day, to: interval.start) ?? interval.start
            let value = groups[index].map { $0.reduce(0, +) / Double($0.count) }
            return HeatmapBucket(id: index, label: period == .monthly ? String(index + 1) : String(index % 24), date: bucketDate, value: value)
        }
    }
}
struct UsageHeatmap: View {
    let samples: [UsageHistorySample]
    let window: UsageWindow
    let color: Color
    var measure: HistoryMeasure = .used
    @State private var period = HeatmapPeriod.weekly
    @State private var date = Date.now
    @State private var selected: HeatmapBucket?
    var body: some View {
        let cells = HeatmapData.buckets(samples: samples, windowID: window.id, measure: measure, period: period, date: date)
        let scale = measure == .amount ? max(1, cells.compactMap(\.value).max() ?? 1) : 100
        VStack(alignment: .leading, spacing: 10) {
            Picker("Heatmap period", selection: $period) { ForEach(HeatmapPeriod.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            HStack {
                Button { move(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous period")
                Spacer()
                Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption)
                Spacer()
                Button { move(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next period").disabled(Calendar.current.dateInterval(of: period.component, for: date)?.contains(.now) == true)
            }
            if period == .weekly {
                HStack(spacing: 3) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(0..<7) { day in Text(cells[day * 24].date.formatted(.dateTime.weekday(.abbreviated))).font(.system(size: 9)).frame(height: 15) }
                    }
                    VStack(spacing: 3) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 24), spacing: 3) {
                            ForEach(cells) { cell in heatCell(cell, scale: scale, label: false).frame(height: 15) }
                        }
                        HStack { Text("00"); Spacer(); Text("06"); Spacer(); Text("12"); Spacer(); Text("18"); Spacer(); Text("23") }.font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: period == .daily ? 6 : 7), spacing: 5) {
                    ForEach(cells) { cell in heatCell(cell, scale: scale, label: true).frame(height: 30) }
                }
            }
            HStack {
                Text(measure == .amount ? window.amountUnit ?? "Amount used" : measure.title)
                Spacer()
                if let selected { Text(selected.value.map { measure == .amount ? String(format: "%.1f", $0) : "\(Int($0.rounded()))%" } ?? "No reading").monospacedDigit() }
                else { Text("0"); LinearGradient(colors: [color.opacity(0.15), color], startPoint: .leading, endPoint: .trailing).frame(width: 60, height: 5); Text(measure == .amount ? String(format: "%.0f", scale) : "100%") }
            }.font(.caption2).foregroundStyle(.secondary)
        }.onChange(of: period) { _, _ in selected = nil }.onChange(of: measure) { _, _ in selected = nil }
    }
    private func heatCell(_ cell: HeatmapBucket, scale: Double, label: Bool) -> some View {
        Button { selected = cell } label: {
            RoundedRectangle(cornerRadius: 3).fill(cell.value.map { color.opacity(0.15 + min(1, $0 / scale) * 0.85) } ?? Color.white.opacity(0.04))
                .overlay { if label { Text(cell.label).font(.system(size: 10)).foregroundStyle(.white.opacity(cell.value == nil ? 0.35 : 0.9)) } }
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(selected?.id == cell.id ? .white : .clear, lineWidth: 1))
        }.buttonStyle(.plain).accessibilityLabel("\(cell.date.formatted(date: .abbreviated, time: .omitted)), \(period == .monthly ? "" : cell.label + ":00, ")\(cell.value.map { String(format: "%.1f", $0) } ?? "No reading")")
    }
    private func move(_ delta: Int) { date = Calendar.current.date(byAdding: period.component, value: delta, to: date) ?? date; selected = nil }
}

struct ChartsView: View {
    @EnvironmentObject private var store: AccountStore
    @State private var selected = Set<String>()
    @State private var choosing = false
    @State private var customSelection = false
    @State private var days = 7
    @State private var measure = HistoryMeasure.remaining
    @State private var heatmaps = false
    @State private var unit = ""
    private struct Series: Identifiable {
        let account: AgentAccount
        let window: UsageWindow
        var id: String { account.id.uuidString + ":" + window.id }
        var title: String { account.title + " · " + account.provider.name + " · " + window.title }
    }
    private var available: [Series] { store.accounts.flatMap { account in (account.snapshot?.windows ?? []).map { Series(account: account, window: $0) } } }
    private var visible: [Series] {
        available.filter { series in
            let chosen = !customSelection ? series.window.id == (series.account.window(for: .weekly) ?? series.account.snapshot?.windows.first)?.id : selected.contains(series.id)
            return chosen && (measure != .amount || series.window.amountUnit == activeUnit && series.window.usedAmount != nil)
        }
    }
    private var units: [String] { Array(Set(available.filter { $0.window.usedAmount != nil }.compactMap { $0.window.amountUnit })).sorted() }
    private var activeUnit: String { units.contains(unit) ? unit : units.first ?? "" }
    private func samples(_ id: UUID) -> [UsageHistorySample] { (store.histories[id] ?? []).filter { $0.date >= Date.now.addingTimeInterval(-Double(days) * 86400) } }
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Picker("Chart type", selection: $heatmaps) { Text("Lines").tag(false); Text("Heatmaps").tag(true) }.pickerStyle(.segmented)
                    Button { choosing = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("Choose accounts and metrics").accessibilityIdentifier("chart-accounts")
                }
                Picker("Chart measure", selection: $measure) {
                    Text("Remaining %").tag(HistoryMeasure.remaining); Text("Used %").tag(HistoryMeasure.used)
                    if !units.isEmpty { Text("Amount").tag(HistoryMeasure.amount) }
                }.pickerStyle(.segmented)
                if measure == .amount { Picker("Units", selection: Binding(get: { activeUnit }, set: { unit = $0 })) { ForEach(units, id: \.self) { Text($0).tag($0) } } }
                if !heatmaps {
                    Picker("Chart period", selection: $days) { Text("24h").tag(1); Text("7d").tag(7); Text("30d").tag(30); Text("90d").tag(90) }.pickerStyle(.segmented)
                    if visible.isEmpty { Text("No readings for this selection.").foregroundStyle(.secondary) }
                    else { comparisonChart }
                } else {
                    ForEach(visible) { series in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(series.title).font(.subheadline.weight(.semibold))
                            UsageHeatmap(samples: store.histories[series.account.id] ?? [], window: series.window, color: series.account.color, measure: measure)
                        }.panel()
                    }
                }
            }.padding(16).frame(maxWidth: 750).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Charts").navigationBarTitleDisplayMode(.inline).refreshable { await store.refreshAll() }
            .sheet(isPresented: $choosing) { selectionSheet }
    }
    private var comparisonChart: some View {
        let maximum = measure == .amount ? max(1, visible.flatMap { HistorySeries.segments(samples: samples($0.account.id), windowID: $0.window.id, measure: measure).flatMap { $0 }.map(\.usedPercent) }.max() ?? 1) : 100
        return Chart {
            ForEach(visible) { series in
                ForEach(Array(HistorySeries.segments(samples: samples(series.account.id), windowID: series.window.id, measure: measure).enumerated()), id: \.offset) { index, points in
                    ForEach(points) { point in
                        LineMark(x: .value("Time", point.date), y: .value("Usage", point.usedPercent), series: .value("Series", series.id + "-\(index)"))
                            .foregroundStyle(by: .value("Account", series.title)).lineStyle(by: .value("Account", series.title)).interpolationMethod(.stepEnd)
                        if points.count == 1 { PointMark(x: .value("Time", point.date), y: .value("Usage", point.usedPercent)).foregroundStyle(by: .value("Account", series.title)) }
                    }
                }
            }
        }.chartForegroundStyleScale(domain: visible.map(\.title), range: visible.map { $0.account.color }).chartYScale(domain: 0...maximum).chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { AxisGridLine(); AxisValueLabel(format: days == 1 ? Date.FormatStyle.dateTime.hour().minute() : Date.FormatStyle.dateTime.month(.abbreviated).day()) } }.frame(height: 320).panel()
    }
    private var selectionSheet: some View {
        NavigationStack {
            List {
                Button("Weekly / primary for all accounts") { selected = []; customSelection = false }
                ForEach(store.accounts) { account in
                    Section(account.title) {
                        ForEach(available.filter { $0.account.id == account.id }) { series in
                            Toggle(series.window.title, isOn: Binding(get: { visible.contains { $0.id == series.id } }, set: { value in
                                if !customSelection { selected = Set(visible.map(\.id)); customSelection = true }
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
