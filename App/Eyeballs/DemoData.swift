import Foundation
import SwiftUI
import WidgetKit
import UserNotifications

// Sample accounts never receive credentials and have their own files and widget cache.
enum DemoData {
    static var location: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("EyeballsDemo/accounts.json") }
    static func id(_ index: Int) -> UUID { UUID(uuidString: String(format: "DE000000-0000-0000-0000-%012d", index + 1))! }
    static func contains(_ id: UUID) -> Bool { id.uuidString.hasPrefix("DE000000-") }
    static func accounts(now: Date = .now) -> [AgentAccount] {
        let providers: [Provider] = [.codex, .claude, .grok, .codex, .claude, .copilot, .cursor, .gemini, .cline]
        let names = ["Personal", "Work", "Research", "Mac mini", "Studio", "Copilot", "Cursor", "Gemini", "Cline"]
        return providers.enumerated().map { index, provider in
            let used = Double(23 + index * 8)
            let weekly = UsageWindow(id: "week", title: "Weekly", usedPercent: used, resetsAt: now.addingTimeInterval(Double(2 + index % 4) * 86400), duration: 604800)
            var windows = [weekly]
            if provider == .codex || provider == .claude {
                windows.insert(UsageWindow(id: "session", title: "5-hour window", usedPercent: Double(15 + index * 11), resetsAt: now.addingTimeInterval(10800), duration: 18000), at: 0)
            } else if provider == .cursor || provider == .copilot {
                windows = [UsageWindow(id: "month", title: "Monthly", usedPercent: used, resetsAt: now.addingTimeInterval(12 * 86400), duration: 30 * 86400, usedAmount: used / 100 * (provider == .cursor ? 20 : 50), limitAmount: provider == .cursor ? 20 : 50, amountUnit: provider == .cursor ? "USD" : "requests")]
            } else if provider == .gemini {
                windows = [UsageWindow(id: "daily", title: "Daily requests", usedPercent: used, resetsAt: now.addingTimeInterval(10 * 3600), duration: 86400, usedAmount: used * 10, limitAmount: 1000, amountUnit: "requests")]
            }
            if provider == .cline { windows = [] }
            let banked: [BankedReset]? = index == 0 ? [BankedReset(id: "demo-weekly", title: "Weekly", expiresAt: now.addingTimeInterval(2 * 86400), firstDetectedAt: now.addingTimeInterval(-3 * 86400))] : nil
            return AgentAccount(id: id(index), provider: provider, label: "Demo · " + names[index], workstream: index < 5 ? "Sample account" : "", snapshot: UsageSnapshot(windows: windows, plan: "Sample plan", billingEndsAt: now.addingTimeInterval(12 * 86400), updatedAt: now, source: "Demo", creditBalance: provider == .cline ? "0.5000" : nil, bankedResets: banked), addedAt: now.addingTimeInterval(-30 * 86400))
        }
    }
    static func history(for account: AgentAccount, now: Date = .now) -> [UsageHistorySample] {
        (0...720).map { hour in
            let date = now.addingTimeInterval(Double(hour - 720) * 3600)
            var windows = account.snapshot?.windows ?? []
            for index in windows.indices {
                let duration = windows[index].duration ?? 604800
                let cycle = max(1, Int(duration / 3600))
                windows[index].usedPercent = Double((hour + index * 11 + (Int(account.id.uuidString.suffix(2), radix: 16) ?? 0)) % cycle) / Double(cycle) * 90
                if let limit = windows[index].limitAmount { windows[index].usedAmount = limit * windows[index].usedPercent! / 100 }
                windows[index].resetsAt = date.addingTimeInterval(duration)
            }
            if hour == 720 { windows = account.snapshot?.windows ?? [] }
            return UsageHistorySample(date: date, windows: windows)
        }
    }
    static func events(accounts: [AgentAccount], now: Date = .now) -> [AccountEvent] {
        guard let first = accounts.first, let second = accounts.dropFirst().first else { return [] }
        let kinds: [AccountEvent.Kind] = [.weeklyReset, .bankedExpired, .earlyReset, .bankedUsed, .bankedDetected]
        return kinds.enumerated().map { index, kind in
            let date = now.addingTimeInterval(-Double(5 - index) * 86400)
            return AccountEvent(id: "demo-\(index)", accountID: index == 2 ? second.id : first.id, kind: kind, date: date, detectedAt: date, window: "Weekly", count: kind == .bankedDetected || kind == .bankedUsed || kind == .bankedExpired ? 1 : nil, inferred: kind == .earlyReset || kind == .bankedUsed)
        }
    }
}

@MainActor
final class AccountSession: ObservableObject {
    let live: AccountStore
    @Published private(set) var demo: AccountStore?
    var current: AccountStore { demo ?? live }
    var isDemo: Bool { demo != nil }
    private let demoLocation: URL
    private let integratesWithSystem: Bool
    private let publishMode: (Bool) -> Void
    init(live: AccountStore, demoLocation: URL = DemoData.location, restoresMode: Bool = true, integratesWithSystem: Bool = true,
         publishMode: @escaping (Bool) -> Void = { WidgetCache.demoActive = $0; WidgetCenter.shared.reloadAllTimelines() }) {
        self.live = live; self.demoLocation = demoLocation; self.integratesWithSystem = integratesWithSystem; self.publishMode = publishMode
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--exit-demo-test") { publishMode(false) }
        #endif
        if restoresMode, WidgetCache.demoActive { startDemo() }
    }
    func startDemo() {
        guard demo == nil else { return }
        let samples = AccountStore(location: demoLocation, integratesWithSystem: integratesWithSystem, isDemo: true)
        if samples.accounts.isEmpty || (samples.accounts.first?.snapshot?.updatedAt ?? .distantPast) < Date.now.addingTimeInterval(-86400) { samples.resetDemo() }
        demo = samples; publishMode(true)
    }
    func endDemo() {
        demo = nil; publishMode(false); live.restoreWidgetSummaries()
        if integratesWithSystem {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: ["eyeballs-demo-reminder"])
            center.removeDeliveredNotifications(withIdentifiers: ["eyeballs-demo-reminder"])
        }
    }
    func open(_ url: URL) {
        guard url.scheme == "eyeballs", let id = UUID(uuidString: url.lastPathComponent) else { return }
        if DemoData.contains(id) { startDemo() }
        else if live.accounts.contains(where: { $0.id == id }) { if isDemo { endDemo() } }
        guard current.accounts.contains(where: { $0.id == id }) else { return }
        current.notificationAccountID = id
    }
    func testNotification() async {
        guard isDemo else { return }
        do {
            let center = UNUserNotificationCenter.current()
            guard try await center.requestAuthorization(options: [.alert, .sound]) else { demo?.error = "Notifications are disabled in iOS Settings."; return }
            let content = UNMutableNotificationContent(); content.title = "Eyeballs demo"; content.body = "Sample weekly reset reminder."; content.sound = .default
            content.userInfo = ["accountID": DemoData.id(0).uuidString]
            try await center.add(UNNotificationRequest(identifier: "eyeballs-demo-reminder", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)))
        } catch { demo?.error = "The demo notification could not be scheduled." }
    }
}

struct AccountSessionView: View {
    @ObservedObject var session: AccountSession
    var body: some View {
        VStack(spacing: 0) {
            if session.isDemo {
                HStack {
                    Text("Demo · Sample data").font(.caption.weight(.medium))
                    Spacer()
                    Button("Exit demo") { session.endDemo() }.font(.caption.weight(.semibold)).accessibilityIdentifier("exit-demo")
                }.padding(.horizontal, 16).padding(.vertical, 8).background(Theme.card)
            }
            RootView().environmentObject(session.current).environmentObject(session)
                .defaultAppStorage(session.isDemo ? UserDefaults(suiteName: "eyeballs-demo-preferences")! : .standard)
                .id(session.isDemo)
        }.background(Theme.background).onOpenURL { session.open($0) }
    }
}
