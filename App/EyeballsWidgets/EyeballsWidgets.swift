import SwiftUI
import WidgetKit
import AppIntents

struct UsageEntry: TimelineEntry {
    var date: Date
    var accounts: [AgentAccount]
    var amount: WidgetAmount = .account
    var metrics: WidgetMetrics = .account
    var layout: WidgetLayout = .bars
    func readings(_ account: AgentAccount) -> [MetricReading] { account.readings(at: date, settings: metrics.settings(for: account, amount: amount)) }
    static var placeholder: UsageEntry {
        let now = Date.now
        let windows = [UsageWindow(id: "session", title: "5-hour", usedPercent: 30, resetsAt: now.addingTimeInterval(10800), duration: 18000), UsageWindow(id: "week", title: "Weekly", usedPercent: 45, resetsAt: now.addingTimeInterval(345600), duration: 604800)]
        return UsageEntry(date: now, accounts: [AgentAccount(provider: .codex, label: "Account", snapshot: UsageSnapshot(windows: windows))])
    }
    var timeline: Timeline<UsageEntry> {
        // Frequent timestamp entries update time rings without moving provider usage.
        let dates = (1...15).map { date.addingTimeInterval(Double($0) * 60) }
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
            selected = choices.compactMap { choice in accounts.first { $0.id.uuidString == choice.id } }
        } else { selected = accounts.filter(\.favorite) }
        return UsageEntry(date: .now, accounts: configuration.sort.sorted(selected), amount: configuration.amount, metrics: configuration.metrics, layout: configuration.layout)
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
                    if let percent = readings.first?.percent {
                        Gauge(value: percent / 100) { Text(readings.first?.caption ?? "") } currentValueLabel: { Text("\(Int(percent.rounded()))") }
                            .gaugeStyle(.accessoryCircular).tint(account.provider.color)
                    } else { Text("—").accessibilityLabel("Usage unavailable") }
                } else if family == .accessoryRectangular {
                    VStack(alignment: .leading, spacing: 3) { Text(account.title).font(.headline); Text("\(readings.first?.title ?? account.provider.name) · \(readings.first?.value ?? "—") \(readings.first?.caption ?? "")").font(.caption); Text(widgetStatus(account, at: entry.date)).font(.caption2) }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(account.title).font(.caption.weight(.semibold)).lineLimit(1); Spacer(); if family == .systemMedium { Text(account.provider.name).font(.caption2).foregroundStyle(.secondary) } }
                        HStack(spacing: 16) {
                            UsageRing(readings: readings, color: account.provider.color, size: family == .systemSmall ? 75 : 92, lineWidth: readings.count > 2 ? 4 : 6)
                            if family == .systemMedium { MetricLegend(readings: readings, color: account.provider.color) }
                        }.frame(maxWidth: .infinity)
                        Text(widgetStatus(account, at: entry.date)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else { WidgetEmptyView() }
        }.widgetURL(entry.accounts.first.map { accountURL($0) } ?? URL(string: "eyeballs://accounts")!)
            .containerBackground(Color(hex: 0x1B1E1B), for: .widget)
    }
}
struct OverviewWidgetView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family
    private var limit: Int {
        if entry.layout == .rings { return family == .systemSmall ? 1 : family == .systemMedium ? 3 : 6 }
        return family == .systemSmall ? 2 : family == .systemMedium ? 4 : 10
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("eyeballs").font(.system(size: 11, weight: .semibold, design: .rounded)); Spacer(); if entry.accounts.count > limit { Text("+\(entry.accounts.count - limit)").font(.system(size: 9)).foregroundStyle(.secondary) } }
            if entry.accounts.isEmpty { WidgetEmptyView() }
            else if entry.layout == .bars {
                VStack(spacing: family == .systemLarge ? 10 : 7) {
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
                                UsageRing(readings: entry.readings(account), color: account.provider.color, size: family == .systemSmall ? 76 : 62, lineWidth: entry.readings(account).count > 2 ? 3 : 5)
                                Text(account.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                                Text(widgetStatus(account, at: entry.date)).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }.frame(maxHeight: .infinity, alignment: .center)
            }
        }.widgetURL(URL(string: "eyeballs://accounts")!).containerBackground(Color(hex: 0x1B1E1B), for: .widget)
    }
}
struct CompactWidgetRow: View {
    let account: AgentAccount
    let readings: [MetricReading]
    let date: Date
    var small: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(account.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 2)
                Text(account.needsLogin ? "Reconnect" : account.provider.name).font(.system(size: 8)).foregroundStyle(account.needsLogin ? .orange : .secondary).lineLimit(1)
            }
            if readings.isEmpty { Text(account.snapshot?.creditBalance ?? "No metrics selected").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1) }
            else {
                HStack(spacing: 7) {
                    ForEach(Array(readings.prefix(small ? 2 : 4).enumerated()), id: \.element.id) { index, reading in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 2) {
                                Text(shortTitle(reading)).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(reading.value).monospacedDigit().fixedSize()
                            }.font(.system(size: 8)).foregroundStyle(.secondary)
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(MetricColor.color(index, base: account.provider.color).opacity(0.15))
                                    if let percent = reading.percent { Capsule().fill(MetricColor.color(index, base: account.provider.color)).frame(width: geometry.size.width * percent / 100) }
                                }
                            }.frame(height: 4)
                        }
                    }
                }
            }
            if small { Text(widgetStatus(account, at: date)).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1) }
        }.accessibilityElement(children: .combine)
    }
    private func shortTitle(_ reading: MetricReading) -> String {
        let period = reading.window?.duration == 18000 ? "5h" : reading.window?.title.localizedCaseInsensitiveContains("weekly") == true ? "Week" : reading.window?.title ?? "—"
        return "\(period) \(reading.caption)"
    }
}
struct WidgetEmptyView: View {
    var body: some View { VStack(alignment: .leading, spacing: 8) { Text("No accounts").font(.headline); Text("Open Eyeballs to add an account.").font(.caption).foregroundStyle(.secondary) } }
}
private func accountURL(_ account: AgentAccount) -> URL { URL(string: "eyeballs://account/\(account.id)")! }
private func widgetStatus(_ account: AgentAccount, at date: Date) -> String {
    if account.needsLogin { return "Reconnect in Eyeballs" }
    if let snapshot = account.snapshot, snapshot.isStale(at: date) { return "Updated \(snapshot.updatedAt.formatted(date: .omitted, time: .shortened)) · stale" }
    if let reset = account.snapshot?.windows.compactMap(\.resetsAt).min() { return "Reset in \(ResetText.relative(reset, now: date))" }
    return account.snapshot.map { "Updated \($0.updatedAt.formatted(date: .omitted, time: .shortened))" } ?? "No reading"
}
@main
struct EyeballsWidgets: WidgetBundle {
    var body: some Widget { AccountWidget(); OverviewWidget() }
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
