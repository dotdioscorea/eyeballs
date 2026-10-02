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
    var title: String { (window?.title ?? "Unavailable") + (definition.kind == .time ? " time" : "") }
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
    var displaySettings: AccountDisplay {
        display ?? AccountDisplay(rings: Array((snapshot?.windows ?? []).prefix(2)).map { RingDefinition(windowID: $0.id) })
    }
    func readings(at date: Date = .now, settings: AccountDisplay? = nil) -> [MetricReading] {
        let settings = settings ?? displaySettings
        return settings.rings.prefix(4).map { definition in
            MetricReading(definition: definition, window: snapshot?.windows.first { $0.id == definition.windowID },
                          direction: definition.direction ?? settings.direction, date: date)
        }
    }
    func displayedReset(for readings: [MetricReading]) -> Date? {
        readings.compactMap { $0.window?.resetsAt }.min() ?? snapshot?.windows.compactMap(\.resetsAt).min()
    }
    func window(for period: UsagePeriod) -> UsageWindow? {
        let windows = snapshot?.windows ?? []
        switch period {
        case .session: return windows.first { $0.duration.map { $0 > 0 && $0 <= 21600 } == true }
        case .weekly: return windows.first { $0.duration.map { abs($0 - 604800) < 60 } == true || $0.title.localizedCaseInsensitiveContains("weekly") }
        }
    }
}
enum UsagePeriod { case session, weekly }

enum AccountSort: String, CaseIterable, Identifiable {
    case favorites, name, provider, mostRemaining, leastRemaining, sessionRemaining, weeklyRemaining, nextReset, lastUpdated
    var id: Self { self }
    var title: String {
        switch self {
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
        accounts.sorted { lhs, rhs in
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
