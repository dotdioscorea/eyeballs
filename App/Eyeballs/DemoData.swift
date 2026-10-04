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
        let providers: [Provider] = [.codex, .claude, .codex, .cursor, .grok, .copilot, .cline, .perplexity, .gemini, .kimi, .devin, .amp, .claude]
        let names = ["Personal", "Work", "Projects", "Studio", "Research", "GitHub", "Cline", "Search", "Gemini", "Kimi Code", "Devin", "Amp", "Writing"]
        let plans = ["Pro", "Max 5x", "Plus", "Pro", "SuperGrok", "Pro", "", "Pro", "Standard", "Moderato", "Free", "", "Pro"]
        let weeklyUsed: [Double] = [34, 71, 83, 59, 43, 61, 0, 0, 27, 65, 62, 0, 46]
        let shortUsed: [Double] = [46, 58, 24, 0, 0, 0, 0, 0, 0, 19, 35, 0, 37]
        let daysLeft: [Double] = [2.1, 3.3, 0.8, 12, 4.2, 19, 0, 0, 0.4, 2.7, 3, 0, 5.1]
        let shortMinutes: [Double] = [167, 43, 251, 0, 0, 0, 0, 0, 0, 118, 0, 0, 92]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let nextMonth = calendar.dateInterval(of: .month, for: now)!.end
        return providers.enumerated().map { index, provider in
            var windows: [UsageWindow] = []
            func quota(_ id: String, _ title: String, _ used: Double, _ duration: TimeInterval, _ remaining: TimeInterval) -> UsageWindow {
                UsageWindow(id: id, title: title, usedPercent: used, resetsAt: now.addingTimeInterval(remaining), duration: duration)
            }
            switch provider {
            case .codex, .claude:
                windows = [quota("session", "5-hour window", shortUsed[index], 18000, shortMinutes[index] * 60), quota("week", "Weekly", weeklyUsed[index], 604800, daysLeft[index] * 86400)]
            case .grok:
                windows = [quota("credits", "Weekly credits", weeklyUsed[index], 604800, daysLeft[index] * 86400)]
            case .cursor, .copilot:
                let limit: Double = provider == .cursor ? 20 : 300
                windows = [UsageWindow(id: "month", title: provider == .cursor ? "Included usage" : "Premium requests", usedPercent: weeklyUsed[index], resetsAt: provider == .copilot ? nextMonth : now.addingTimeInterval(daysLeft[index] * 86400), duration: provider == .copilot ? nextMonth.timeIntervalSince(calendar.dateInterval(of: .month, for: now)!.start) : 30 * 86400, usedAmount: limit * weeklyUsed[index] / 100, limitAmount: limit, amountUnit: provider == .cursor ? "USD" : "requests")]
            case .gemini:
                windows = [quota("daily", "Daily requests", weeklyUsed[index], 86400, 10 * 3600)]
            case .kimi:
                windows = [quota("limit_5h", "5-hour window", shortUsed[index], 18000, shortMinutes[index] * 60), quota("limit_7d", "Weekly", weeklyUsed[index], 604800, daysLeft[index] * 86400)]
            case .devin:
                windows = [quota("daily", "Daily", shortUsed[index], 86400, 8 * 3600), quota("weekly", "Weekly", weeklyUsed[index], 604800, daysLeft[index] * 86400)]
            case .cline, .perplexity, .amp: break
            }
            var details: ProviderDetails?
            if provider == .claude {
                details = ProviderDetails(spending: [SpendingDetails(id: "claude-spend", title: "Extra usage", used: 3.5, limit: 20, balance: 12, currency: "USD", enabled: true)], breakdowns: [UsageBreakdown(id: "claude-weekly-apps", title: "Share of weekly usage", rows: [.init(id: "code", title: "Claude Code", percent: 78), .init(id: "chats", title: "Chats", percent: 22)])])
            }
            let banked: [BankedReset]? = index == 0 ? [BankedReset(id: "demo-weekly", title: "Weekly", expiresAt: now.addingTimeInterval(2 * 86400), firstDetectedAt: now.addingTimeInterval(-3 * 86400))] : nil
            let allowances: [RemainingAllowance]? = provider == .perplexity ? [.init(id: "pro_search", title: "Pro searches", remaining: 240, available: true), .init(id: "research", title: "Research", remaining: 14, available: true)] : nil
            return AgentAccount(id: id(index), provider: provider, label: names[index], snapshot: UsageSnapshot(windows: windows, plan: plans[index].isEmpty ? nil : plans[index], creditBalance: provider == .cline ? "8.43" : provider == .amp ? "$5.00" : nil, billingEndsAt: [.cline, .perplexity, .devin, .amp].contains(provider) ? nil : now.addingTimeInterval(Double([12, 8, 23, 12, 17, 6, 0, 0, 21, 9, 0, 0, 16][index]) * 86400), updatedAt: now, source: "Demo", bankedResets: banked, details: details, remainingAllowances: allowances), colorHex: index == 2 ? 0x7794F8 : nil, addedAt: now.addingTimeInterval(-40 * 86400))
        }
    }

    // Integrate distinct activity patterns, rather than drawing percentage ramps.
    // Each quota cycle has one reset date and a monotonically increasing counter.
    static func history(for account: AgentAccount, now: Date = .now) -> [UsageHistorySample] {
        let step: TimeInterval = 1200
        let count = 40 * 72
        let start = now.addingTimeInterval(-Double(count) * step)
        let seed = max(1, Int(account.id.uuidString.suffix(3)) ?? 7)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func activity(_ date: Date, metric: Int) -> Double {
            let parts = calendar.dateComponents([.hour, .minute, .weekday], from: date)
            let hour = Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
            let day = Int(floor(date.timeIntervalSince1970 / 86400))
            // Each account has its own schedule, days off, and concentrated sessions.
            // The seed also survives remapping into isolated screenshot accounts.
            let variation = Double((day * (11 + seed * 2) + seed * 23 + metric * 7).magnitude % 19) / 18
            let weekend = parts.weekday == 1 || parts.weekday == 7
            let scale = (0.08 + pow(variation, 2) * 2.4) * (weekend ? (seed % 3 == 1 ? 0.9 : 0.12) : 1)
            let schedules: [(Double, Double, Double)] = [(9, 19, 0.6), (13, 17, 0.2), (7, 22, 1.5), (10, 16, 0.8), (16, 21, 0.9)]
            let schedule = schedules[(seed - 1) % schedules.count]
            let shift = Double((day + seed * 3).magnitude % 5) * 0.65 - 1.3
            let first = exp(-pow((hour - schedule.0 - shift) / 1.1, 2))
            let second = exp(-pow((hour - schedule.1 + shift) / 1.5, 2)) * schedule.2 * (0.3 + variation)
            let burstHour = Double((day * seed + metric * 5).magnitude % 14) + 7
            let burst = exp(-pow((hour - burstHour) / 0.5, 2)) * variation * 0.7
            let idle = hour < 5 || hour > 23.5 || (day + seed * 3) % (7 + seed % 4) == 0
            return idle ? 0 : scale * (first + second + burst)
        }
        let original = account.snapshot?.windows ?? []
        var series: [[UsageWindow]] = Array(repeating: [], count: count + 1)
        for (metric, template) in original.enumerated() {
            let duration = template.duration ?? 604800
            let currentEnd = template.resetsAt ?? now.addingTimeInterval(duration)
            let extendedStart = start.addingTimeInterval(-duration - step)
            let integrationCount = Int(ceil(now.timeIntervalSince(extendedStart) / step)) + 1
            var totals: [Double] = [0]
            for tick in 0..<integrationCount { totals.append(totals.last! + activity(extendedStart.addingTimeInterval((Double(tick) + 0.5) * step), metric: metric)) }
            func integral(_ date: Date) -> Double {
                let position = max(0, date.timeIntervalSince(extendedStart) / step)
                let index = min(totals.count - 2, Int(position))
                return totals[index] + (totals[index + 1] - totals[index]) * min(1, position - Double(index))
            }
            for tick in 0...count {
                let date = start.addingTimeInterval(Double(tick) * step)
                let shift = floor(date.timeIntervalSince(currentEnd) / duration) + 1
                let month = account.provider == .copilot ? calendar.dateInterval(of: .month, for: date) : nil
                let end = month?.end ?? currentEnd.addingTimeInterval(shift * duration)
                let begin = month?.start ?? end.addingTimeInterval(-duration)
                let currentCycle = month.map { $0.end == currentEnd } ?? (shift == 0)
                let until = currentCycle ? now : end
                let consumed = max(0, integral(date) - integral(begin))
                let total = max(0.0001, integral(until) - integral(begin))
                let cycle = Int(floor(begin.timeIntervalSince1970 / duration))
                let peak = currentCycle ? template.safePercent ?? 0 : 56 + Double((cycle * 13 + seed * 17 + metric * 11).magnitude % 40)
                var window = template
                window.usedPercent = min(100, peak * consumed / total)
                window.resetsAt = end
                window.duration = end.timeIntervalSince(begin)
                if let limit = window.limitAmount { window.usedAmount = limit * window.usedPercent! / 100 }
                if tick == count { window = template }
                series[tick].append(window)
            }
        }
        return (0...count).map { tick in
            UsageHistorySample(date: start.addingTimeInterval(Double(tick) * step), windows: series[tick], remainingAllowances: account.snapshot?.remainingAllowances, creditBalance: account.snapshot?.creditBalance)
        }
    }
    static func events(accounts: [AgentAccount], now: Date = .now) -> [AccountEvent] {
        var events: [AccountEvent] = []
        for account in accounts {
            for window in account.snapshot?.windows ?? [] where EventDetection.weekly(window) {
                guard let end = window.resetsAt, let duration = window.duration else { continue }
                for cycle in 1...5 {
                    let date = end.addingTimeInterval(-Double(cycle) * duration)
                    if date <= now { events.append(AccountEvent(id: "demo-\(account.id)-\(window.id)-\(cycle)", accountID: account.id, kind: .weeklyReset, date: date, detectedAt: date, window: window.title, windowID: window.id)) }
                }
            }
            for reset in account.snapshot?.bankedResets ?? [] {
                if let date = reset.firstDetectedAt { events.append(AccountEvent(id: "demo-\(reset.id)-detected", accountID: account.id, kind: .bankedDetected, date: date, detectedAt: date, window: reset.title, count: reset.count)) }
            }
        }
        return events.sorted { $0.date > $1.date }
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
        if samples.accounts.isEmpty || samples.accounts.contains(where: { $0.snapshot?.plan == "Sample plan" }) || (samples.accounts.first?.snapshot?.updatedAt ?? .distantPast) < Date.now.addingTimeInterval(-86400) { samples.resetDemo() }
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
            let content = UNMutableNotificationContent(); content.title = "Requota demo"; content.body = "Sample weekly reset reminder."; content.sound = .default
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
