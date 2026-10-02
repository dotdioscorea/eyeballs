import Foundation
import SwiftUI

enum Provider: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex, claude, grok
    var id: String { rawValue }
    var name: String {
        switch self { case .codex: return "Codex"; case .claude: return "Claude"; case .grok: return "Grok" }
    }
    var subtitle: String {
        switch self { case .codex: return "ChatGPT plans & Codex"; case .claude: return "Claude & Claude Code"; case .grok: return "SuperGrok & Grok Build" }
    }
    var symbol: String {
        switch self { case .codex: return "command"; case .claude: return "asterisk"; case .grok: return "slash.circle" }
    }
    var color: Color {
        switch self { case .codex: return Color(hex: 0xB9F577); case .claude: return Color(hex: 0xF2AD8B); case .grok: return Color(hex: 0xAAA5FF) }
    }
    var usageURL: URL {
        switch self {
        case .codex: return URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .claude: return URL(string: "https://claude.ai/settings/usage")!
        case .grok: return URL(string: "https://grok.com/?_s=usage")!
        }
    }
}

struct UsageWindow: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var usedPercent: Double?
    var resetsAt: Date?
    var duration: TimeInterval?
    var safePercent: Double? {
        guard let usedPercent, usedPercent.isFinite, usedPercent >= 0 else { return nil }
        return min(100, usedPercent)
    }
    func resetDue(at date: Date = .now) -> Bool { resetsAt.map { $0 <= date } ?? false }
    func pace(at date: Date = .now) -> String? {
        guard let percent = safePercent, let end = resetsAt, let duration, duration > 0, end > date else { return nil }
        let elapsed = max(0, min(1, 1 - end.timeIntervalSince(date) / duration))
        if percent > elapsed * 100 + 15 { return "Ahead of pace" }
        return "Room to work"
    }
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    var windows: [UsageWindow] = []
    var plan: String?
    var email: String?
    var identity: String?
    var creditBalance: String?
    var billingEndsAt: Date?
    var updatedAt: Date = .now
    var source: String = "Provider"
    var nextReset: Date? { windows.compactMap(\.resetsAt).filter { $0 > .now }.min() }
    func isStale(at date: Date = .now) -> Bool {
        date.timeIntervalSince(updatedAt) > 30 * 60 || windows.contains { $0.resetDue(at: date) }
    }
}

struct AgentAccount: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var provider: Provider
    var label: String = ""
    var workstream: String = ""
    var notes: String = ""
    var renewalReminder: Date?
    var favorite: Bool = true
    var snapshot: UsageSnapshot?
    var issue: String?
    var needsLogin: Bool = false
    var addedAt: Date = .now
    var title: String { label.isEmpty ? provider.name : label }
    var nextReset: Date? { snapshot?.nextReset }
}

enum WidgetCache {
    static let group = "group.com.dotdioscorea.eyeballs"
    static let key = "account-summaries-v1"
    static func read() -> [AgentAccount] {
        guard let data = UserDefaults(suiteName: group)?.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([AgentAccount].self, from: data)) ?? []
    }
    static func write(_ accounts: [AgentAccount]) {
        // Widgets need only labels, usage and timestamps; exclude email, identity and private notes.
        let summaries = accounts.map { original in
            var copy = original
            copy.notes = ""
            copy.snapshot?.email = nil
            copy.snapshot?.identity = nil
            copy.issue = copy.needsLogin ? "Reconnect in Eyeballs" : nil
            return copy
        }
        if let data = try? JSONEncoder().encode(summaries) {
            UserDefaults(suiteName: group)?.set(data, forKey: key)
        }
    }
}

extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1) }
}

enum DemoAccounts {
    static var accounts: [AgentAccount] {
        let now = Date.now
        return [
            AgentAccount(provider: .codex, label: "Personal", workstream: "Eyeballs · MacBook", snapshot: UsageSnapshot(windows: [UsageWindow(id: "session", title: "5-hour window", usedPercent: 38, resetsAt: now.addingTimeInterval(10800), duration: 18000), UsageWindow(id: "week", title: "Weekly", usedPercent: 62, resetsAt: now.addingTimeInterval(172800), duration: 604800)], plan: "Pro", source: "Sample data")),
            AgentAccount(provider: .claude, label: "Work", workstream: "Portico · Mac mini", snapshot: UsageSnapshot(windows: [UsageWindow(id: "session", title: "5-hour window", usedPercent: 84, resetsAt: now.addingTimeInterval(2700), duration: 18000), UsageWindow(id: "week", title: "Weekly", usedPercent: 47, resetsAt: now.addingTimeInterval(345600), duration: 604800)], plan: "Max", source: "Sample data")),
            AgentAccount(provider: .grok, label: "Research", workstream: "Ideas & exploration", snapshot: UsageSnapshot(windows: [UsageWindow(id: "week", title: "Weekly credits", usedPercent: 21, resetsAt: now.addingTimeInterval(259200), duration: 604800)], plan: "SuperGrok", source: "Sample data"))
        ]
    }
}
