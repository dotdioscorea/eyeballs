import SwiftUI
import WidgetKit
import AppIntents

struct UsageEntry: TimelineEntry {
    var date: Date
    var accounts: [AgentAccount]
    var amount: WidgetAmount = .account
    var metrics: WidgetMetrics = .account
    var layout: WidgetLayout = .bars
    var rows: WidgetRows = .automatic
    func readings(_ account: AgentAccount) -> [MetricReading] { account.readings(at: date, settings: metrics.settings(for: account, amount: amount)) }
    static var placeholder: UsageEntry {
        let now = Date.now
        let windows = [UsageWindow(id: "session", title: "5-hour", usedPercent: 30, resetsAt: now.addingTimeInterval(10800), duration: 18000), UsageWindow(id: "week", title: "Weekly", usedPercent: 45, resetsAt: now.addingTimeInterval(345600), duration: 604800)]
        return UsageEntry(date: now, accounts: [AgentAccount(provider: .codex, label: "Account", snapshot: UsageSnapshot(windows: windows))])
    }
    var timeline: Timeline<UsageEntry> {
        // Cover a full day so time rings and stale labels still advance when iOS
        // delays the requested reload. Entries do not invent provider readings.
        let minutes = Array(stride(from: 5, through: 60, by: 5)) + Array(stride(from: 90, through: 1440, by: 30))
        let dates = minutes.map { date.addingTimeInterval(Double($0) * 60) }
        let entries = [self] + dates.map { timestamp in var entry = self; entry.date = timestamp; return entry }
        return Timeline(entries: entries, policy: .after(date.addingTimeInterval(15 * 60)))
    }
}
struct AccountTimeline: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { .placeholder }
    func snapshot(for configuration: AccountIntent, in context: Context) async -> UsageEntry { entry(configuration) }
    func timeline(for configuration: AccountIntent, in context: Context) async -> Timeline<UsageEntry> { entry(configuration).timeline }
    private func entry(_ configuration: AccountIntent) -> UsageEntry {
        let accounts = WidgetCache.read()
        let selected: [AgentAccount]
        if let id = configuration.account?.id.flatMapUUID { selected = accounts.filter { $0.id == id } }
        else { selected = Array(accounts.filter(\.favorite).prefix(1)) }
        return UsageEntry(date: .now, accounts: selected, amount: configuration.amount, metrics: configuration.metrics)
    }
}
private extension String { var flatMapUUID: UUID? { UUID(uuidString: self) } }
struct OverviewTimeline: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { .placeholder }
    func snapshot(for configuration: OverviewIntent, in context: Context) async -> UsageEntry { entry(configuration) }
    func timeline(for configuration: OverviewIntent, in context: Context) async -> Timeline<UsageEntry> { entry(configuration).timeline }
    private func entry(_ configuration: OverviewIntent) -> UsageEntry {
        let accounts = WidgetCache.read()
        let selected: [AgentAccount]
        if let choices = configuration.accounts, !choices.isEmpty {
            selected = choices.compactMap { choice in accounts.first { $0.id == UUID(uuidString: choice.id) } }
        } else { selected = accounts.filter(\.favorite) }
        return UsageEntry(date: .now, accounts: configuration.sort.sorted(selected), amount: configuration.amount, metrics: configuration.metrics, layout: configuration.layout, rows: configuration.rows)
    }
}
struct RowsTimeline: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { .placeholder }
    func snapshot(for configuration: RowsIntent, in context: Context) async -> UsageEntry { entry(configuration) }
    func timeline(for configuration: RowsIntent, in context: Context) async -> Timeline<UsageEntry> { entry(configuration).timeline }
    private func entry(_ configuration: RowsIntent) -> UsageEntry {
        let accounts = WidgetCache.read()
        let selected = configuration.accounts.flatMap { $0.isEmpty ? nil : $0 }?.compactMap { choice in accounts.first { $0.id == UUID(uuidString: choice.id) } } ?? accounts.filter(\.favorite)
        return UsageEntry(date: .now, accounts: configuration.sort.sorted(selected), amount: configuration.amount, metrics: configuration.metrics, rows: configuration.rows)
    }
}
struct AccountWidgetView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        Group {
            if let account = entry.accounts.first {
                let readings = entry.readings(account)
                if family == .accessoryCircular {
                    if let percent = readings.primary?.percent {
                        Gauge(value: percent / 100) { Text(readings.primary?.caption ?? "") } currentValueLabel: { Text("\(Int(percent.rounded()))") }
                            .gaugeStyle(.accessoryCircular).tint(account.color)
                    } else if let allowance = account.primaryAllowance {
                        VStack(spacing: 2) {
                            if let count = allowance.remaining { Text(count.formatted()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5); Text("left").font(.caption2) }
                            else { Image(systemName: allowance.available == true ? "checkmark" : allowance.available == false ? "minus" : "questionmark") }
                        }.accessibilityLabel(allowance.summary)
                    }
                    else if let balance = account.snapshot?.creditBalance {
                        VStack(spacing: 2) { Text(balance).font(.caption.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.5); Text("Credits").font(.system(size: 9)) }
                            .accessibilityLabel("Credits: " + balance)
                    }
                    else { Text("—").accessibilityLabel("Usage unavailable") }
                } else if family == .accessoryRectangular {
                    VStack(alignment: .leading, spacing: 3) { Text(account.title).font(.headline); Text(account.allowanceSummary ?? readings.primary.map { "\($0.title) · \($0.value) \($0.caption)" } ?? account.snapshot?.creditBalance.map { "Credits: " + $0 } ?? "Usage unavailable").font(.caption); Text(widgetStatus(account, at: entry.date, readings: entry.readings(account))).font(.caption2) }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { ProviderLogo(provider: account.provider, color: account.color, size: 16); Text(account.title).font(.caption.weight(.semibold)).lineLimit(1); Spacer(); if family == .systemMedium { Text(account.provider.name).font(.caption2).foregroundStyle(.secondary) } }
                        HStack(spacing: 16) {
                            if !readings.isEmpty { UsageRing(readings: readings, color: account.color, size: family == .systemSmall ? 75 : 92, lineWidth: readings.count > 2 ? 4 : 6) }
                            else if let allowances = account.snapshot?.remainingAllowances { RemainingAllowancesView(allowances: Array(allowances.prefix(family == .systemSmall ? 2 : 4)), dense: true) }
                            else { Text(account.snapshot?.creditBalance.map { "Credits: \($0)" } ?? account.emptyMetricMessage).font(.caption).foregroundStyle(.secondary) }
                            if family == .systemMedium { MetricLegend(readings: readings, color: account.color) }
                        }.frame(maxWidth: .infinity)
                        Text(widgetStatus(account, at: entry.date, readings: entry.readings(account))).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else { WidgetEmptyView() }
        }.widgetURL(entry.accounts.first.map { accountURL($0) } ?? URL(string: "eyeballs://accounts")!)
            .environment(\.colorScheme, .dark).containerBackground(Color(hex: 0x1B1E1B), for: .widget)
    }
}
struct OverviewWidgetView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family
    private var limit: Int {
        if entry.layout == .rings { return family == .systemSmall ? 1 : family == .systemMedium ? 3 : 6 }
        let capacity = family == .systemSmall ? 3 : family == .systemMedium ? 6 : 12
        return min(capacity, entry.rows.count ?? capacity)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: entry.layout == .bars ? 5 : 8) {
            if entry.layout == .rings || entry.accounts.count > limit {
                HStack { if entry.layout == .rings { Text("Requota").font(.system(size: 11, weight: .semibold, design: .rounded)) }; Spacer(); if entry.accounts.count > limit { Text("+\(entry.accounts.count - limit)").font(.system(size: 9)).foregroundStyle(.secondary) } }
            }
            if entry.accounts.isEmpty { WidgetEmptyView() }
            else if entry.layout == .bars {
                VStack(spacing: 3) {
                    ForEach(entry.accounts.prefix(limit)) { account in
                        Link(destination: accountURL(account)) { CompactWidgetRow(account: account, readings: entry.readings(account), date: entry.date, small: family == .systemSmall) }
                    }
                }.frame(maxHeight: .infinity, alignment: .top)
            } else {
                let columns = family == .systemSmall ? 1 : 3
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: columns), spacing: 15) {
                    ForEach(entry.accounts.prefix(limit)) { account in
                        Link(destination: accountURL(account)) {
                            VStack(spacing: 6) {
                                if !entry.readings(account).isEmpty { UsageRing(readings: entry.readings(account), color: account.color, size: family == .systemSmall ? 76 : 62, lineWidth: entry.readings(account).count > 2 ? 3 : 5) }
                                else if let balance = account.snapshot?.creditBalance {
                                    VStack(spacing: 3) { Text(balance).font(.caption.monospacedDigit()); Text("Credits").font(.system(size: 8)).foregroundStyle(.secondary) }
                                        .frame(height: family == .systemSmall ? 76 : 62)
                                }
                                else if let allowance = account.primaryAllowance { VStack(spacing: 3) { Text(allowance.remaining.map { $0.formatted() } ?? allowance.value).font(.title2.monospacedDigit()); Text(allowance.title + (allowance.remaining != nil ? " left" : "")).font(.system(size: 8)).foregroundStyle(.secondary) }.frame(height: family == .systemSmall ? 76 : 62) }
                                HStack(spacing: 3) { ProviderLogo(provider: account.provider, color: account.color, size: 12); Text(account.title).font(.system(size: 10, weight: .medium)).lineLimit(1) }
                                Text(widgetStatus(account, at: entry.date, readings: entry.readings(account))).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }.frame(maxHeight: .infinity, alignment: .center)
            }
        }.widgetURL(URL(string: "eyeballs://accounts")!).environment(\.colorScheme, .dark).containerBackground(Color(hex: 0x1B1E1B), for: .widget)
    }
}
struct CompactWidgetRow: View {
    let account: AgentAccount
    let readings: [MetricReading]
    let date: Date
    var small: Bool
    var body: some View {
        Group {
            if small {
                VStack(alignment: .leading, spacing: 2) {
                    name
                    bars
                }
            } else {
                HStack(spacing: 7) {
                    HStack(spacing: 4) {
                        ProviderLogo(provider: account.provider, color: account.color, size: 12)
                        Text(account.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    }.frame(width: 86, alignment: .leading)
                    bars
                }.frame(minHeight: 20)
            }
        }.accessibilityElement(children: .combine)
    }
    private var name: some View {
        HStack {
            ProviderLogo(provider: account.provider, color: account.color, size: 12)
            Text(account.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 2)
            Text(account.needsLogin ? "Reconnect" : account.provider.name).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
    private var bars: some View {
        Group {
            if readings.isEmpty, let allowance = account.primaryAllowance {
                HStack(spacing: 3) {
                    Text(allowance.title).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(allowance.value).font(.system(size: 10, weight: .semibold)).monospacedDigit().lineLimit(1).fixedSize()
                }
            } else if readings.isEmpty {
                Text(account.snapshot?.creditBalance.map { "Credits: \($0)" } ?? account.emptyMetricMessage).font(.system(size: 9))
                    .foregroundStyle(account.needsLogin || account.snapshot?.isStale(at: date) == true ? .orange : .secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading).accessibilityHint(widgetStatus(account, at: date, readings: readings))
            }
            else {
                HStack(spacing: 7) {
                    ForEach(Array(readings.prefix(small ? 2 : 4).enumerated()), id: \.element.id) { index, reading in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 2) {
                                Text(shortTitle(reading)).font(.system(size: 8)).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(reading.value).font(.system(size: 10, weight: .semibold)).monospacedDigit().lineLimit(1).fixedSize().foregroundStyle(.primary)
                            }.foregroundStyle(account.needsLogin ? .orange : account.snapshot?.isStale(at: date) == true ? .orange.opacity(0.8) : .secondary)
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(MetricColor.color(index, base: account.color).opacity(0.15))
                                    if let percent = reading.percent { Capsule().fill(MetricColor.color(index, base: account.color)).frame(width: geometry.size.width * percent / 100) }
                                }
                            }.frame(height: 4)
                        }
                    }
                }
            }
        }
    }
    private func shortTitle(_ reading: MetricReading) -> String {
        let period = reading.window?.duration == 18000 ? "5h" : reading.window?.title.localizedCaseInsensitiveContains("weekly") == true ? "Week" : reading.window?.title ?? "—"
        return reading.definition.kind == .time ? (period == "Week" ? "Wk t" : period + " t") : (period == "Week" ? "Wk" : period)
    }
}
struct WidgetEmptyView: View {
    var body: some View { VStack(alignment: .leading, spacing: 8) { Text("No accounts").font(.headline); Text("Open Requota to add an account.").font(.caption).foregroundStyle(.secondary) } }
}
private func accountURL(_ account: AgentAccount) -> URL { URL(string: "eyeballs://account/\(account.id)")! }
private func widgetStatus(_ account: AgentAccount, at date: Date, readings: [MetricReading]) -> String {
    if account.needsLogin { return "Reconnect in Requota" }
    if let snapshot = account.snapshot, snapshot.isStale(at: date) { return "Updated \(snapshot.updatedAt.formatted(date: .omitted, time: .shortened)) · stale" }
    if let credit = account.snapshot?.creditBalance, !account.exhaustedWindows.isEmpty { return "Credits: \(credit) · allowance exhausted" }
    if let window = account.displayedResetWindow(for: readings), let reset = window.resetsAt { return "\(window.shortTitle) reset in \(ResetText.relative(reset, now: date))" }
    return account.snapshot.map { "Updated \($0.updatedAt.formatted(date: .omitted, time: .shortened))" } ?? "No reading"
}
@main
struct EyeballsWidgets: WidgetBundle {
    var body: some Widget { AccountWidget(); AccountRowsWidget(); OverviewWidget() }
}
struct AccountRowsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "EyeballsRows", intent: RowsIntent.self, provider: RowsTimeline()) { OverviewWidgetView(entry: $0) }.configurationDisplayName("Account rows").description("Up to six accounts in a medium widget or twelve in a large widget. Tap a row to open its account.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
struct AccountWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "EyeballsAccount", intent: AccountIntent.self, provider: AccountTimeline()) { AccountWidgetView(entry: $0) }
            .configurationDisplayName("Account").description("Configurable usage and time rings.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}
struct OverviewWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "EyeballsOverview", intent: OverviewIntent.self, provider: OverviewTimeline()) { OverviewWidgetView(entry: $0) }
            .configurationDisplayName("Accounts").description("Choose accounts, compact bars or rings, metrics and sorting.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
