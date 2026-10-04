import Foundation

enum MetricIdentityMigration {
    // Build 10 identified additional Codex limits by array position. Match only
    // unambiguous recorded names/durations when moving to provider feature IDs.
    static func replacement(_ old: UsageWindow, in windows: [UsageWindow]) -> String? {
        guard old.id.range(of: "^additional-[0-9]+$", options: .regularExpression) != nil else { return nil }
        let matches = windows.filter { $0.id.hasPrefix("additional-") && $0.id.hasSuffix("-primary") && $0.title == old.title && $0.duration == old.duration }
        return matches.count == 1 ? matches[0].id : nil
    }
    static func windows(_ old: [UsageWindow], matching current: [UsageWindow]) -> [UsageWindow] {
        old.map { window in var copy = window; copy.id = replacement(window, in: current) ?? window.id; return copy }
    }
    static func account(_ original: AgentAccount, matching current: [UsageWindow]) -> AgentAccount {
        guard original.provider == .codex else { return original }
        var account = original
        let old = account.snapshot?.windows ?? []
        account.retainMetricNames()
        if var display = account.display {
            for index in display.rings.indices {
                let ring = display.rings[index]
                let candidate = old.first { $0.id == ring.windowID } ?? ring.windowTitle.map { UsageWindow(id: ring.windowID, title: $0) }
                if let candidate {
                    let candidates = candidate.duration == nil ? current.filter { $0.title == candidate.title } : current
                    if let id = replacement(candidate.duration == nil && candidates.count == 1 ? UsageWindow(id: candidate.id, title: candidate.title, duration: candidates[0].duration) : candidate, in: current) { display.rings[index].windowID = id }
                }
            }
            account.display = display
        }
        account.snapshot?.windows = windows(old, matching: current)
        return account
    }
}
