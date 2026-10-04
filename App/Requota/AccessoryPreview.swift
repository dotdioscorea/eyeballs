#if DEBUG
import SwiftUI
import WidgetKit

// Uses the extension's exact content at accessory dimensions. This harness is
// compiled out of Release and never accesses credentials or provider endpoints.
struct AccessoryPreviewView: View {
    private let now = Date.now
    private func entry(_ used: Double, title: String = "Personal", metric: LockScreenMetric = .week) -> LockScreenEntry {
        .init(date: now, account: AgentAccount(provider: .codex, label: title, snapshot: .init(windows: [.init(id: "week", title: "Weekly", usedPercent: used, resetsAt: now.addingTimeInterval(259200), duration: 604800)], creditBalance: used == 100 ? "15.00" : nil, updatedAt: now)), metric: metric)
    }
    private var credits: LockScreenEntry { .init(date: now, account: .init(provider: .amp, label: "Credits", snapshot: .init(creditBalance: "1234.56789", updatedAt: now)), metric: .credits) }
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Accessory previews").font(.headline)
            HStack(spacing: 24) {
                slot(entry(0), family: .accessoryCircular, width: 62, height: 62)
                slot(entry(100, title: "Work"), family: .accessoryCircular, width: 62, height: 62)
                slot(credits, family: .accessoryCircular, width: 62, height: 62)
            }
            HStack(spacing: 20) {
                slot(entry(37), family: .accessoryRectangular, width: 156, height: 72)
                slot(entry(100, title: "Work"), family: .accessoryRectangular, width: 156, height: 72)
            }
            slot(entry(0, metric: .weekTime), family: .accessoryCircular, width: 62, height: 62)
            slot(entry(37), family: .accessoryInline, width: 336, height: 20)
            slot(credits, family: .accessoryInline, width: 336, height: 20)
            Spacer()
        }.foregroundStyle(.white).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
    }
    private func slot(_ entry: LockScreenEntry, family: WidgetFamily, width: CGFloat, height: CGFloat) -> some View {
        LockScreenAccessoryContent(entry: entry, family: family).frame(width: width, height: height, alignment: .leading).border(.white.opacity(0.2)).accessibilityElement(children: .contain)
    }
}
#endif
