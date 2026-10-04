import SwiftUI

struct ResetTimelineView: View {
    @EnvironmentObject private var store: AccountStore
    struct Event: Identifiable {
        var account: AgentAccount
        var window: UsageWindow
        var date: Date
        var id: String { account.id.uuidString + window.id }
    }
    private var events: [Event] {
        store.accounts.flatMap { account in
            (account.snapshot?.windows ?? []).compactMap { window in window.resetsAt.map { Event(account: account, window: window, date: $0) } }
        }.sorted { $0.date < $1.date }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if events.isEmpty { ContentUnavailableView("No reset times", systemImage: "clock", description: Text("Connect an account to see its next resets here.")) }
                else {
                    VStack(spacing: 0) {
                        ForEach(events) { event in
                            HStack(alignment: .top, spacing: 16) {
                                VStack(spacing: 0) { Circle().fill(event.account.color).frame(width: 10, height: 10).padding(.top, 5); Rectangle().fill(.white.opacity(0.08)).frame(width: 1).frame(minHeight: 68) }
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(event.account.title).font(.headline)
                                    Text("\(event.account.provider.name) · \(event.window.title)").font(.caption).foregroundStyle(.secondary)
                                    Text(event.date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).hour().minute())).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 6) {
                                    TimelineView(.periodic(from: .now, by: 60)) { context in Text(ResetText.relative(event.date, now: context.date)).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(event.account.color) }
                                    Text(MetricReading(definition: RingDefinition(windowID: event.window.id), window: event.window, direction: event.account.displaySettings.direction, date: .now).percent.map { "\(Int($0.rounded()))% \(event.account.displaySettings.direction == .remaining ? "left" : "used")" } ?? "Usage unknown").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }.panel()
                }
            }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Resets").navigationBarTitleDisplayMode(.inline)
    }
}
