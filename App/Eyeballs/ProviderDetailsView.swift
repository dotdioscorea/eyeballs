import SwiftUI

struct ProviderDetailsView: View {
    let details: ProviderDetails
    var breakdownColor: Color = Color(hex: 0x8FC8EC)
    var body: some View {
        ForEach(details.usage ?? []) { item in
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text(item.title).font(.subheadline.weight(.semibold)); Spacer(); if let enabled = item.enabled { Text(enabled ? "Enabled" : "Disabled").font(.caption).foregroundStyle(.secondary) } }
                if let used = item.used { row("Used", item.amount(used)) }
                if item.unlimited == true { row("Allowance", "Unlimited") }
                else {
                    if let limit = item.limit { row("Allowance", item.amount(limit)) }
                    if let remaining = item.remaining { row("Remaining", item.amount(remaining)) }
                }
            }.panel().accessibilityIdentifier("provider-usage-" + item.id)
        }
        ForEach(details.spending) { spend in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(spend.title).font(.subheadline.weight(.semibold))
                    Spacer()
                    if let enabled = spend.enabled { Text(enabled ? "Enabled" : "Disabled").font(.caption).foregroundStyle(.secondary) }
                }
                if let used = spend.used { row("Amount spent", spend.amount(used)) }
                if let limit = spend.limit { row("Spending cap", spend.amount(limit)) }
                if let balance = spend.balance { row("Credit balance", spend.amount(balance)) }
                if let reason = spend.stoppedReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                if let reset = spend.resetsAt { row("Resets", reset.formatted(date: .abbreviated, time: .shortened)) }
            }.panel().accessibilityIdentifier("provider-spend-" + spend.id)
        }
        ForEach(details.breakdowns) { breakdown in
            VStack(alignment: .leading, spacing: 14) {
                Text(breakdown.title).font(.subheadline.weight(.semibold))
                let total = breakdown.rows.reduce(0) { $0 + $1.percent }
                if abs(total - 100) <= 0.5 {
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            ForEach(Array(breakdown.rows.enumerated()), id: \.element.id) { index, item in
                                breakdownColor.opacity(max(0.3, 1 - Double(index) * 0.2)).frame(width: geometry.size.width * item.percent / total)
                            }
                        }.clipShape(Capsule())
                    }.frame(height: 8).accessibilityHidden(true)
                }
                ForEach(Array(breakdown.rows.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 8) {
                        Circle().fill(breakdownColor.opacity(max(0.3, 1 - Double(index) * 0.2))).frame(width: 6, height: 6).accessibilityHidden(true)
                        Text(item.title).foregroundStyle(.secondary)
                        Spacer()
                        Text(item.percent.formatted(.number.precision(.fractionLength(0...1))) + "%").monospacedDigit()
                    }
                    .font(.subheadline)
                }
            }.panel().accessibilityIdentifier("provider-breakdown-" + breakdown.id)
        }
        if !details.models.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Model access").font(.subheadline.weight(.semibold))
                ForEach(details.models) { model in
                    VStack(alignment: .leading, spacing: 4) {
                        row(model.title, model.status)
                        if model.available != true, let date = model.availableAt {
                            Text("Available \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }.panel().accessibilityIdentifier("provider-model-access")
        }
    }
    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        }.font(.subheadline)
    }
}

struct CreditDetailsView: View {
    let details: CreditDetails
    var body: some View {
        if details.unlimited == true { status("Unlimited") }
        else if details.available == false { status("Empty") }
        else if details.available == true { status("Available") }
        if details.overageLimitReached == true { Text("Credit overage limit reached").font(.caption).foregroundStyle(.orange) }
        if details.spendLimitReached == true { Text("Spending limit reached").font(.caption).foregroundStyle(.orange) }
        if let estimate = details.localMessages {
            HStack { Text("Estimated local messages").foregroundStyle(.secondary); Spacer(); Text(estimate.text).monospacedDigit() }.font(.subheadline)
        }
        if let estimate = details.cloudMessages {
            HStack { Text("Estimated cloud messages").foregroundStyle(.secondary); Spacer(); Text(estimate.text).monospacedDigit() }.font(.subheadline)
        }
    }
    private func status(_ value: String) -> some View { HStack { Text("Credit status").foregroundStyle(.secondary); Spacer(); Text(value) }.font(.subheadline) }
}
