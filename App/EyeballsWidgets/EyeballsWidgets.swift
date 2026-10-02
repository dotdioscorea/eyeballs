import SwiftUI
import WidgetKit
import AppIntents

struct AccountEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Account"
    static var defaultQuery = AccountQuery()
    var id: String
    var title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct AccountQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [AccountEntity] { values.filter { identifiers.contains($0.id) } }
    func suggestedEntities() async throws -> [AccountEntity] { values }
    private var values: [AccountEntity] { WidgetCache.read().map { AccountEntity(id: $0.id.uuidString, title: "\($0.provider.name) · \($0.title)") } }
}

struct AccountIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose an account"
    static var description = IntentDescription("Keep an eye on one AI account.")
    @Parameter(title: "Account") var account: AccountEntity?
}

struct UsageEntry: TimelineEntry {
    var date: Date
    var accounts: [AgentAccount]
}

struct AccountTimeline: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { UsageEntry(date: .now, accounts: Array(DemoAccounts.accounts.prefix(1))) }
    func snapshot(for configuration: AccountIntent, in context: Context) async -> UsageEntry { entry(configuration) }
    func timeline(for configuration: AccountIntent, in context: Context) async -> Timeline<UsageEntry> {
        let value = entry(configuration)
        let reset = value.accounts.compactMap(\.nextReset).min() ?? .distantFuture
        let next = min(reset, .now.addingTimeInterval(15 * 60))
        return Timeline(entries: [value, UsageEntry(date: next, accounts: value.accounts)], policy: .after(next))
    }
    private func entry(_ configuration: AccountIntent) -> UsageEntry {
        let accounts = WidgetCache.read()
        let selected: [AgentAccount]
        if let id = configuration.account?.id { selected = accounts.filter { $0.id.uuidString == id } }
        else { selected = Array(accounts.filter(\.favorite).prefix(1)) }
        return UsageEntry(date: .now, accounts: selected)
    }
}

struct OverviewTimeline: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { UsageEntry(date: .now, accounts: DemoAccounts.accounts) }
    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) { completion(entry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let current = entry()
        let next = min(current.accounts.compactMap(\.nextReset).min() ?? .distantFuture, Date.now.addingTimeInterval(15 * 60))
        completion(Timeline(entries: [current, UsageEntry(date: next, accounts: current.accounts)], policy: .after(next)))
    }
    private func entry() -> UsageEntry { UsageEntry(date: .now, accounts: Array(WidgetCache.read().filter(\.favorite).prefix(3))) }
}

struct AccountWidgetView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        Group {
            if let account = entry.accounts.first {
                if family == .accessoryCircular {
                    if let percent = account.snapshot?.windows.first?.safePercent {
                    Gauge(value: percent / 100) {
                        Text(account.provider.name.prefix(1))
                    } currentValueLabel: { Text("\(Int(percent))") }.gaugeStyle(.accessoryCircular).tint(account.provider.color)
                    } else {
                        ZStack { Circle().stroke(.secondary, style: StrokeStyle(lineWidth: 3, dash: [2, 3])); Text("—") }
                            .accessibilityLabel("\(account.title): usage not reported")
                    }
                } else if family == .accessoryRectangular {
                    VStack(alignment: .leading) { Text(account.title).font(.headline); Text(status(account)).font(.caption) }
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack { ProviderMark(provider: account.provider, size: 22); Text(account.title).font(.caption.weight(.semibold)).lineLimit(1); Spacer() }
                        HStack(spacing: 18) {
                            UsageRing(windows: account.snapshot?.windows ?? [], color: account.provider.color, size: family == .systemSmall ? 76 : 100, lineWidth: 6)
                            if family == .systemMedium {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(account.provider.name).font(.headline)
                                    ForEach((account.snapshot?.windows ?? []).prefix(2)) { window in Text("\(window.title) · \(window.safePercent.map { "\(Int($0))%" } ?? "—")").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }.frame(maxWidth: .infinity)
                        Text(status(account)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else { VStack(alignment: .leading, spacing: 8) { Image(systemName: "eye").foregroundStyle(Color(hex: 0xB9F577)); Text("Connect an account").font(.headline); Text("Open Eyeballs to get started.").font(.caption).foregroundStyle(.secondary) } }
        }
        .widgetURL(entry.accounts.first.map { URL(string: "eyeballs://account/\($0.id)")! } ?? URL(string: "eyeballs://accounts")!)
        .containerBackground(Color(hex: 0x1B1E1B), for: .widget)
    }
    private func status(_ account: AgentAccount) -> String {
        if account.needsLogin { return "Reconnect in Eyeballs" }
        if let snapshot = account.snapshot, snapshot.isStale(at: entry.date) {
            return "Checked \(snapshot.updatedAt.formatted(date: .omitted, time: .shortened)) · refresh"
        }
        if let reset = account.nextReset { return "Resets in \(ResetText.relative(reset, now: entry.date))" }
        return "Usage not reported"
    }
}

struct OverviewWidgetView: View {
    let entry: UsageEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("eyeballs").font(.system(.subheadline, design: .rounded, weight: .semibold)); Spacer(); Text("YOUR ACCOUNTS").font(.system(size: 9, weight: .medium)).tracking(1).foregroundStyle(.secondary) }
            if entry.accounts.isEmpty { Text("Favorite your accounts in Eyeballs to see them here.").font(.subheadline).foregroundStyle(.secondary) }
            else {
                HStack(spacing: 12) {
                    ForEach(entry.accounts) { account in
                        Link(destination: URL(string: "eyeballs://account/\(account.id)")!) {
                            VStack(spacing: 7) {
                                UsageRing(windows: account.snapshot?.windows ?? [], color: account.provider.color, size: 68, lineWidth: 5)
                                Text(account.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Text(account.snapshot?.isStale(at: entry.date) == true ? "Refresh needed" : account.nextReset.map { ResetText.relative($0, now: entry.date) } ?? "—").font(.system(size: 9)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }.containerBackground(Color(hex: 0x1B1E1B), for: .widget)
    }
}

@main
struct EyeballsWidgets: WidgetBundle {
    var body: some Widget {
        AccountWidget()
        OverviewWidget()
    }
}
struct AccountWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "EyeballsAccount", intent: AccountIntent.self, provider: AccountTimeline()) { AccountWidgetView(entry: $0) }
            .configurationDisplayName("An account at a glance").description("Usage rings and the next reset for one account.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}
struct OverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EyeballsOverview", provider: OverviewTimeline()) { OverviewWidgetView(entry: $0) }
            .configurationDisplayName("All eyes on your accounts").description("Your favorite accounts, side by side.").supportedFamilies([.systemMedium])
    }
}
