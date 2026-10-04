import SwiftUI
import WidgetKit

struct LockScreenEntry: TimelineEntry {
    var date: Date
    var account: AgentAccount?
    var metric: LockScreenMetric = .primary
    var amount: WidgetAmount = .account
    var reading: MetricReading? { account.flatMap { metric.reading(for: $0, amount: amount, at: date) } }
    var value: String {
        guard let account, !account.needsLogin else { return "—" }
        if let reading { return reading.value + " " + reading.caption }
        if metric == .credits || metric == .primary {
            if metric == .primary, let allowance = account.allowanceSummary { return allowance }
            if let credits = account.snapshot?.formattedCreditBalance { return credits + " credits" }
        }
        return "Unavailable"
    }
    var compactValue: String {
        guard let account, !account.needsLogin else { return "—" }
        if let reading { return reading.value }
        if metric == .credits || metric == .primary {
            if metric == .primary, let allowance = account.primaryAllowance {
                return allowance.remaining.map { $0.formatted() } ?? (allowance.available == true ? "Yes" : allowance.available == false ? "No" : "—")
            }
            return account.snapshot?.formattedCreditBalance ?? "—"
        }
        return "—"
    }
    var title: String {
        if let reading { return (reading.window?.shortTitle ?? "Usage") + (reading.definition.kind == .time ? " time" : "") }
        if metric == .credits { return "Credits" }
        if metric == .primary, let allowance = account?.primaryAllowance { return allowance.title }
        if metric == .primary, account?.snapshot?.formattedCreditBalance != nil { return "Credits" }
        return "Usage"
    }
    var inlineValue: String { reading != nil ? title + " " + value : value }
}
struct LockScreenAccessoryContent: View {
    var entry: LockScreenEntry
    var family: WidgetFamily
    var body: some View {
        Group {
            if let account = entry.account {
                switch family {
                case .accessoryCircular:
                    if !account.needsLogin, let percent = entry.reading?.percent {
                        GeometryReader { geometry in
                            let diameter = min(geometry.size.width, geometry.size.height)
                            ZStack {
                                Circle().stroke(.primary.opacity(0.22), lineWidth: 5)
                                Circle().trim(from: 0, to: max(0, min(1, percent / 100)))
                                    .stroke(.primary, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                                Text("\(Int(percent.rounded()))%").font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                                    .lineLimit(1).minimumScaleFactor(0.7).padding(.horizontal, 5)
                            }.padding(3).frame(width: diameter, height: diameter)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        VStack(spacing: 2) {
                            Text(entry.compactValue).font(.system(size: 12, weight: .semibold)).monospacedDigit().lineLimit(2).minimumScaleFactor(0.6)
                            Text(account.needsLogin ? "Sign in" : entry.title).font(.system(size: 9)).lineLimit(1)
                        }
                    }
                case .accessoryInline:
                    Text("\(entry.inlineValue) · \(account.title)").lineLimit(1)
                default:
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.title).font(.headline).lineLimit(1)
                        Text(entry.inlineValue).font(.caption).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                        if account.needsLogin { Text("Sign in to update").font(.caption2) }
                        else if !account.exhaustedWindows.isEmpty, let balance = account.snapshot?.formattedCreditBalance { Text("Credits: " + balance).font(.caption2).lineLimit(1) }
                        else if let reset = entry.reading?.window?.resetsAt {
                            if reset <= entry.date { Text("Reset due").font(.caption2) }
                            else { Text("Reset \(reset, style: .relative)").font(.caption2).lineLimit(1) }
                        }
                        else if let updated = account.snapshot?.updatedAt { Text("Updated \(updated, style: .time)").font(.caption2).lineLimit(1) }
                    }
                }
            } else { Text("Choose account").font(.caption) }
        }.widgetAccentable()
            .accessibilityLabel(entry.account.map { "\($0.title), \(entry.title), \(entry.value)" } ?? "Choose an account in widget settings")
    }
}
