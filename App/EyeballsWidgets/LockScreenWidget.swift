import SwiftUI
import WidgetKit
import AppIntents

struct LockScreenTimeline: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LockScreenEntry { .init(date: .now, account: UsageEntry.placeholder.accounts.first) }
    func snapshot(for configuration: LockScreenIntent, in context: Context) async -> LockScreenEntry { entry(configuration) }
    func timeline(for configuration: LockScreenIntent, in context: Context) async -> Timeline<LockScreenEntry> {
        await BackgroundRefreshScheduler.requestFromWidget(accounts: WidgetCache.read())
        let entry = entry(configuration)
        let cutoff = entry.date.addingTimeInterval(86400)
        let ticks = stride(from: 5, through: 1440, by: 15).map { entry.date.addingTimeInterval(Double($0) * 60) }
        // Switch the relative deadline to "Reset due" at the known deadline,
        // without waiting for another fetch or implying a fresh usage reading.
        let deadlines = (entry.account?.snapshot?.windows ?? []).compactMap(\.resetsAt).filter { $0 > entry.date && $0 <= cutoff }
        let entries = [entry] + Set(ticks + deadlines).sorted().map { timestamp in var next = entry; next.date = timestamp; return next }
        return Timeline(entries: entries, policy: .after(entry.date.addingTimeInterval(900)))
    }
    private func entry(_ configuration: LockScreenIntent) -> LockScreenEntry {
        let accounts = WidgetCache.read()
        let selected = configuration.account.map { choice in accounts.first { $0.id.uuidString == choice.id } } ?? accounts.first(where: \.favorite)
        return .init(date: .now, account: selected, metric: configuration.metric, amount: configuration.amount)
    }
}
struct LockScreenWidgetView: View {
    var entry: LockScreenEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        LockScreenAccessoryContent(entry: entry, family: family)
            .widgetURL(entry.account.map { URL(string: "eyeballs://account/\($0.id.uuidString)")! } ?? URL(string: "eyeballs://accounts")!)
            .containerBackground(.clear, for: .widget)
    }
}
struct LockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "RequotaLockScreen", intent: LockScreenIntent.self, provider: LockScreenTimeline()) { LockScreenWidgetView(entry: $0) }
            .configurationDisplayName("Lock Screen account")
            .description("One account’s usage, reset time or credits.")
            .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
