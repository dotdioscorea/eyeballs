import Foundation

enum AmountDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    case remaining, used
    var id: Self { self }
    var title: String { self == .remaining ? "Remaining" : "Used / elapsed" }
}
enum MetricKind: String, Codable, CaseIterable, Sendable { case usage, time }
struct RingDefinition: Codable, Equatable, Identifiable, Sendable {
    var windowID: String
    var kind: MetricKind = .usage
    var direction: AmountDirection?
    var windowTitle: String?
    var id: String { windowID + ":" + kind.rawValue }
}
struct AccountDisplay: Codable, Equatable, Sendable {
    var direction: AmountDirection = .remaining
    var rings: [RingDefinition] = []
}
struct MetricReading: Identifiable, Equatable {
    var definition: RingDefinition
    var window: UsageWindow?
    var direction: AmountDirection
    var date: Date
    var id: String { definition.id }
    var title: String { (window?.title ?? definition.windowTitle ?? "Unavailable") + (definition.kind == .time ? " time" : "") + (window == nil && definition.windowTitle != nil ? " · unavailable" : "") }
    var caption: String {
        if definition.kind == .time { return direction == .remaining ? "time left" : "elapsed" }
        return direction == .remaining ? "left" : "used"
    }
    var centerCaption: String {
        if definition.kind == .time { return direction == .remaining ? "TIME LEFT" : "ELAPSED" }
        return direction == .remaining ? "LEFT" : "USED"
    }
    var percent: Double? {
        guard let window else { return nil }
        switch definition.kind {
        case .usage:
            guard let used = window.safePercent else { return nil }
            return direction == .remaining ? 100 - used : used
        case .time:
            guard let end = window.resetsAt, let duration = window.duration,
                  duration.isFinite, duration > 0 else { return nil }
            let remaining = max(0, min(100, end.timeIntervalSince(date) / duration * 100))
            return direction == .remaining ? remaining : 100 - remaining
        }
    }
    var value: String { percent.map { "\(Int($0.rounded()))%" } ?? "—" }
}
extension AgentAccount {
    var exhaustedWindows: [UsageWindow] { (snapshot?.windows ?? []).filter { ($0.safePercent ?? -1) >= 100 } }
    var displaySettings: AccountDisplay {
        display ?? defaultDisplay
    }
    var defaultDisplay: AccountDisplay {
        let windows = snapshot?.windows ?? []
        var rings = Array(windows.prefix(2)).map { RingDefinition(windowID: $0.id, windowTitle: $0.title) }
        if let weekly = window(for: .weekly), weekly.duration != nil, weekly.resetsAt != nil {
            rings.append(RingDefinition(windowID: weekly.id, kind: .time, windowTitle: weekly.title))
        }
        return AccountDisplay(rings: rings)
    }
    func readings(at date: Date = .now, settings: AccountDisplay? = nil) -> [MetricReading] {
        let settings = settings ?? displaySettings
        return settings.rings.prefix(4).map { definition in
            MetricReading(definition: definition, window: snapshot?.windows.first { $0.id == definition.windowID },
                          direction: definition.direction ?? settings.direction, date: date)
        }
    }
    func displayedReset(for readings: [MetricReading]) -> Date? {
        displayedResetWindow(for: readings)?.resetsAt
    }
    mutating func retainMetricNames() {
        guard var display else { return }
        for index in display.rings.indices {
            if let window = snapshot?.windows.first(where: { $0.id == display.rings[index].windowID }) { display.rings[index].windowTitle = window.title }
        }
        self.display = display
    }
    func displayedResetWindow(for readings: [MetricReading]) -> UsageWindow? {
        let selected = readings.compactMap(\.window).filter { $0.resetsAt != nil }
        let available = selected.isEmpty ? (snapshot?.windows ?? []).filter { $0.resetsAt != nil } : selected
        return available.min { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }
    }
    func window(for period: UsagePeriod) -> UsageWindow? {
        let windows = snapshot?.windows ?? []
        switch period {
        case .session: return windows.first { $0.duration.map { $0 > 0 && $0 <= 21600 } == true }
        case .weekly: return windows.first { $0.duration.map { abs($0 - 604800) < 60 } == true || $0.title.localizedCaseInsensitiveContains("weekly") }
        }
    }
}
extension UsageWindow {
    var shortTitle: String {
        let generic = ["weekly", "weekly credits", "daily", "daily requests", "current window", "primary window", "session"].contains(title.lowercased()) || title.range(of: "^[0-9]+-hour window$", options: .regularExpression) != nil
        guard generic else { return title }
        if let duration {
            if duration > 0 && duration < 3600 { return "\(Int(duration / 60))m" }
            if duration > 0 && duration <= 21600 { return "\(Int(duration / 3600))h" }
            if abs(duration - 604800) < 60 { return "Weekly" }
            if abs(duration - 86400) < 60 { return "Daily" }
        }
        return title
    }
}

enum UpdatedText {
    static func relative(_ updated: Date, now: Date = .now) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(updated)) / 60)
        return minutes == 0 ? "Updated just now" : "Updated \(minutes)m ago"
    }
}
enum UsagePeriod { case session, weekly }

enum DashboardLayout: String, CaseIterable, Identifiable {
    case cards, tiles, bars
    var id: Self { self }
    var title: String { switch self { case .cards: return "Cards"; case .tiles: return "Tiles"; case .bars: return "Compact" } }
    var symbol: String { switch self { case .cards: return "rectangle"; case .tiles: return "square.grid.2x2"; case .bars: return "line.3.horizontal" } }
}

extension Array where Element == MetricReading {
    var primary: MetricReading? {
        first { $0.definition.kind == .usage && ($0.window?.duration.map { abs($0 - 604800) < 60 } == true || $0.window?.title.localizedCaseInsensitiveContains("weekly") == true) }
        ?? first { $0.definition.kind == .usage } ?? first
    }
}

enum AccountSort: String, CaseIterable, Identifiable {
    case manual, favorites, name, provider, mostRemaining, leastRemaining, sessionRemaining, weeklyRemaining, nextReset, lastUpdated
    var id: Self { self }
    var title: String {
        switch self {
        case .manual: return "Custom order"
        case .favorites: return "Favorites first"
        case .name: return "Name"
        case .provider: return "Provider"
        case .mostRemaining: return "Most remaining"
        case .leastRemaining: return "Least remaining"
        case .sessionRemaining: return "5-hour remaining"
        case .weeklyRemaining: return "Weekly remaining"
        case .nextReset: return "Next reset"
        case .lastUpdated: return "Last updated"
        }
    }
    func sorted(_ accounts: [AgentAccount]) -> [AgentAccount] {
        if self == .manual { return accounts }
        return accounts.sorted { lhs, rhs in
            switch self {
            case .favorites:
                if lhs.favorite != rhs.favorite { return lhs.favorite }
            case .provider:
                if lhs.provider.name != rhs.provider.name { return lhs.provider.name < rhs.provider.name }
            default: break
            }
            let a = metric(lhs), b = metric(rhs)
            if a != b {
                guard let a else { return false }
                guard let b else { return true }
                return self == .leastRemaining || self == .nextReset ? a < b : a > b
            }
            let name = lhs.title.localizedStandardCompare(rhs.title)
            if name != .orderedSame { return name == .orderedAscending }
            if lhs.provider != rhs.provider { return lhs.provider.rawValue < rhs.provider.rawValue }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
    private func metric(_ account: AgentAccount) -> Double? {
        switch self {
        case .mostRemaining, .leastRemaining: return account.snapshot?.windows.first?.safePercent.map { 100 - $0 }
        case .sessionRemaining: return account.window(for: .session)?.safePercent.map { 100 - $0 }
        case .weeklyRemaining: return account.window(for: .weekly)?.safePercent.map { 100 - $0 }
        case .nextReset: return account.snapshot?.windows.compactMap(\.resetsAt).min()?.timeIntervalSince1970
        case .lastUpdated: return account.snapshot?.updatedAt.timeIntervalSince1970
        default: return nil
        }
    }
}
