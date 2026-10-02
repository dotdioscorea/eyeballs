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
    var display: AccountDisplay?
    var addedAt: Date = .now
    var title: String { label.isEmpty ? provider.name : label }
    var nextReset: Date? { snapshot?.nextReset }
}

extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1) }
}
