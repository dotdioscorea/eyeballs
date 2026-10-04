import Foundation
import SwiftUI

enum Provider: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex, claude, grok, gemini, copilot, cursor, cline, kimi, perplexity, devin, amp
    var id: String { rawValue }
    var name: String {
        switch self { case .codex: return "Codex"; case .claude: return "Claude"; case .grok: return "Grok"; case .gemini: return "Gemini"; case .copilot: return "Copilot"; case .cursor: return "Cursor"; case .cline: return "Cline"; case .kimi: return "Kimi Code"; case .perplexity: return "Perplexity"; case .devin: return "Devin"; case .amp: return "Amp" }
    }
    var subtitle: String {
        switch self { case .codex: return "ChatGPT plans & Codex"; case .claude: return "Claude & Claude Code"; case .grok: return "SuperGrok & Grok Build"; case .gemini: return "Gemini CLI & Code Assist"; case .copilot: return "GitHub Copilot"; case .cursor: return "Cursor plans & agents"; case .cline: return "Cline account credits"; case .kimi: return "Kimi Code quotas & credits"; case .perplexity: return "Search & research allowances"; case .devin: return "Devin CLI & Desktop quotas"; case .amp: return "Personal credit balance" }
    }
    var symbol: String {
        switch self { case .codex: return "command"; case .claude: return "asterisk"; case .grok: return "slash.circle"; case .gemini: return "sparkle"; case .copilot: return "sparkles"; case .cursor: return "cursorarrow"; case .cline: return "terminal"; case .kimi: return "moon"; case .perplexity: return "sparkle.magnifyingglass"; case .devin: return "terminal"; case .amp: return "bolt" }
    }
    var color: Color {
        switch self { case .codex: return Color(hex: 0x10A37F); case .claude: return Color(hex: 0xD97757); case .grok: return Color(hex: 0xE5E5E5); case .gemini: return Color(hex: 0x4285F4); case .copilot: return Color(hex: 0x8250DF); case .cursor: return Color(hex: 0xE5E5E5); case .cline: return Color(hex: 0xFFFFFF); case .kimi: return Color(hex: 0x6172F3); case .perplexity: return Color(hex: 0x20B8CD); case .devin: return Color(hex: 0x73A9E9); case .amp: return Color(hex: 0xA3B18A) }
    }
    var usageURL: URL {
        switch self {
        case .codex: return URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .claude: return URL(string: "https://claude.ai/settings/usage")!
        case .grok: return URL(string: "https://grok.com/?_s=usage")!
        case .gemini: return URL(string: "https://codeassist.google/")!
        case .copilot: return URL(string: "https://github.com/settings/copilot")!
        case .cursor: return URL(string: "https://cursor.com/dashboard")!
        case .cline: return URL(string: "https://app.cline.bot/")!
        case .kimi: return URL(string: "https://www.kimi.ai/code/console")!
        case .perplexity: return URL(string: "https://www.perplexity.ai/account")!
        case .devin: return URL(string: "https://app.devin.ai/settings/usage")!
        case .amp: return URL(string: "https://ampcode.com/settings")!
        }
    }
}

struct UsageWindow: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var usedPercent: Double?
    var resetsAt: Date?
    var duration: TimeInterval?
    var usedAmount: Double?
    var limitAmount: Double?
    var amountUnit: String?
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
    var bankedResets: [BankedReset]?
    var allowanceContext: String?
    var details: ProviderDetails?
    var remainingAllowances: [RemainingAllowance]?
    var resetInventory: ResetInventory?
    var nextReset: Date? { windows.compactMap(\.resetsAt).filter { $0 > .now }.min() }
    func isStale(at date: Date = .now) -> Bool {
        date.timeIntervalSince(updatedAt) > 30 * 60 || windows.contains { $0.resetDue(at: date) }
    }
}

struct BankedReset: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var count: Int = 1
    var expiresAt: Date?
    var firstDetectedAt: Date?
    var usableNow: Bool?
}

// Only display-safe grant data is persisted. Provider redemption handles are hashed.
struct ResetInventory: Codable, Equatable, Sendable {
    var checkedAt: Date
    var grants: [ResetGrant]
}
struct ResetGrant: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var remaining: Int
    var total: Int?
    var startsAt: Date?
    var expiresAt: Date?
    var paused: Bool
    var usableNow: Bool?
    var windowIDs: [String]
    var firstDetectedAt: Date?
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
    var needsReport: Bool?
    var display: AccountDisplay?
    var colorHex: UInt32?
    var addedAt: Date = .now
    var title: String { label.isEmpty ? provider.name : label }
    var nextReset: Date? { snapshot?.nextReset }
    var planTitle: String? {
        guard let plan = snapshot?.plan, !plan.isEmpty else { return nil }
        // Preserve provider spellings instead of lowercasing internal capitals.
        if plan.lowercased() == "supergrok" { return "SuperGrok" }
        if plan.lowercased().hasPrefix("max ") { return "Max " + plan.dropFirst(4).lowercased() }
        return plan == plan.lowercased() || plan == plan.uppercased() ? plan.capitalized : plan
    }
    var color: Color { colorHex.map { Color(hex: $0) } ?? provider.color }
    var emptyMetricMessage: String { snapshot?.windows.isEmpty == true ? "No quota reported" : "No metrics selected" }
    var usageURL: URL {
        if provider == .kimi, snapshot?.identity?.hasPrefix("https://auth.kimi.com|") == true { return URL(string: "https://www.kimi.com/code/console")! }
        return provider.usageURL
    }
}

extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1) }
}
