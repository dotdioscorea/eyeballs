import SwiftUI

enum RemainingAllowanceSeries {
    static func segments(_ samples: [UsageHistorySample], metric: String) -> [[HistorySeries.Point]] {
        var result: [[HistorySeries.Point]] = [], current: [HistorySeries.Point] = []
        var previous: UsageHistorySample?
        for sample in samples {
            defer { previous = sample }
            if let previous, AllowanceChanges.contextChanged(previous.allowanceContext, sample.allowanceContext), !current.isEmpty { result.append(current); current = [] }
            guard let count = sample.remainingAllowances?.first(where: { $0.id == metric })?.remaining else {
                if !current.isEmpty { result.append(current); current = [] }; continue
            }
            current.append(.init(date: sample.date, usedPercent: Double(count)))
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

struct RemainingAllowanceHistoryView: View {
    let samples: [UsageHistorySample]
    let account: AgentAccount
    @State private var metric = "pro_search"
    @State private var days = 7
    @State private var end = Date.now
    private var choices: [RemainingAllowance] { account.snapshot?.remainingAllowances?.filter { $0.remaining != nil } ?? [] }
    private var selected: RemainingAllowance? { choices.first { $0.id == metric } ?? choices.first }
    private var domain: ClosedRange<Date> { end.addingTimeInterval(-Double(days) * 86400)...end }
    var body: some View {
        if let selected {
            VStack(alignment: .leading, spacing: 12) {
                AccessibleStack {
                    Text("Remaining").font(.headline)
                    Picker("Remaining allowance", selection: Binding(get: { selected.id }, set: { metric = $0 })) {
                        ForEach(choices) { Text($0.title).tag($0.id) }
                    }.tint(.primary)
                }
                HistoryPeriodPicker(days: $days)
                let segments = RemainingAllowanceSeries.segments(samples, metric: selected.id)
                if !segments.isEmpty {
                    HistoryPlot(series: [.init(id: selected.id, title: selected.title, color: account.color, segments: segments, subdued: false)], domain: domain,
                                measure: .amount, unit: "remaining", events: [], accountNames: [account.id: account.title])
                } else {
                    Text("No readings in this period.").font(.caption).foregroundStyle(.secondary)
                }
            }.panel()
                .onChange(of: samples.last?.date) { _, _ in end = .now }
        }
    }
}
