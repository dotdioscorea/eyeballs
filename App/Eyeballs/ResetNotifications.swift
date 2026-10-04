import Foundation

struct ResetNotificationRules: Codable, Equatable {
    var enabled = true
    var lowAllowance = true
    var lowThreshold = 10
    var sessionReset = false
    var allowanceChanges = false
    var weeklyReset = true
    var earlyReset = true
    var bankedChanges = true
    var bankedExpiry = true
    var allowanceReminder = true
    var allowanceHours = 24
    var minimumRemaining = 10
    var bankedExpiryHours = 24
    var parsingFailures = true
    init() {}
    enum CodingKeys: String, CodingKey { case enabled, lowAllowance, lowThreshold, sessionReset, allowanceChanges, weeklyReset, earlyReset, bankedChanges, bankedExpiry, allowanceReminder, allowanceHours, minimumRemaining, bankedExpiryHours, parsingFailures }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        lowAllowance = try c.decodeIfPresent(Bool.self, forKey: .lowAllowance) ?? lowAllowance
        lowThreshold = try c.decodeIfPresent(Int.self, forKey: .lowThreshold) ?? lowThreshold
        sessionReset = try c.decodeIfPresent(Bool.self, forKey: .sessionReset) ?? sessionReset
        allowanceChanges = try c.decodeIfPresent(Bool.self, forKey: .allowanceChanges) ?? allowanceChanges
        weeklyReset = try c.decodeIfPresent(Bool.self, forKey: .weeklyReset) ?? weeklyReset
        earlyReset = try c.decodeIfPresent(Bool.self, forKey: .earlyReset) ?? earlyReset
        bankedChanges = try c.decodeIfPresent(Bool.self, forKey: .bankedChanges) ?? bankedChanges
        bankedExpiry = try c.decodeIfPresent(Bool.self, forKey: .bankedExpiry) ?? bankedExpiry
        allowanceReminder = try c.decodeIfPresent(Bool.self, forKey: .allowanceReminder) ?? allowanceReminder
        allowanceHours = try c.decodeIfPresent(Int.self, forKey: .allowanceHours) ?? allowanceHours
        minimumRemaining = try c.decodeIfPresent(Int.self, forKey: .minimumRemaining) ?? minimumRemaining
        bankedExpiryHours = try c.decodeIfPresent(Int.self, forKey: .bankedExpiryHours) ?? bankedExpiryHours
        parsingFailures = try c.decodeIfPresent(Bool.self, forKey: .parsingFailures) ?? parsingFailures
    }
    func announces(_ kind: AccountEvent.Kind) -> Bool {
        guard enabled else { return false }
        switch kind {
        case .weeklyReset: return weeklyReset
        case .earlyReset: return earlyReset
        case .bankedDetected, .bankedUsed, .bankedRemoved: return bankedChanges
        case .bankedExpired: return bankedExpiry
        case .parsingFailure: return parsingFailures
        case .allowanceChanged: return allowanceChanges
        }
    }
}
struct PlannedReminder: Equatable {
    var id: String
    var accountID: UUID
    var date: Date
    var title: String
    var body: String
}
enum ResetReminderPlan {
    static func make(accounts: [AgentAccount], rules: ResetNotificationRules, overrides: [String: ResetNotificationRules] = [:], now: Date = .now) -> [PlannedReminder] {
        var result: [PlannedReminder] = []
        for account in accounts where !account.needsLogin {
            let rules = overrides[account.provider.rawValue] ?? rules
            guard rules.enabled else { continue }
            if rules.lowAllowance, let snapshot = account.snapshot, now.timeIntervalSince(snapshot.updatedAt) <= 6 * 3600 {
                for window in snapshot.windows {
                    guard let used = window.safePercent, 100 - used <= Double(max(0, min(100, rules.lowThreshold))), window.resetsAt.map({ $0 > now }) ?? true else { continue }
                    let cycle = window.resetsAt.map { String(Int($0.timeIntervalSince1970 / 60) * 60) } ?? "current"
                    result.append(PlannedReminder(id: "reminder-\(account.id)-\(window.id)-\(cycle)-low", accountID: account.id, date: now.addingTimeInterval(1), title: "\(account.title): \(window.shortTitle) low", body: "\(Int((100 - used).rounded()))% remaining at the last update."))
                }
            }
            if rules.sessionReset {
                for window in account.snapshot?.windows ?? [] where !EventDetection.weekly(window) {
                    guard let reset = window.resetsAt, reset > now else { continue }
                    result.append(PlannedReminder(id: "reminder-\(account.id)-\(window.id)-\(Int(reset.timeIntervalSince1970 / 60) * 60)-reset", accountID: account.id, date: reset, title: "\(account.title): \(window.shortTitle) reset due", body: "Open Requota to update usage."))
                }
            }
            for window in account.snapshot?.windows ?? [] where EventDetection.weekly(window) {
                guard let reset = window.resetsAt, reset > now else { continue }
                let key = "reminder-\(account.id)-\(window.id)-\(Int(reset.timeIntervalSince1970 / 60) * 60)"
                if rules.weeklyReset {
                    result.append(PlannedReminder(id: key + "-reset", accountID: account.id, date: reset, title: "\(account.title): weekly reset due", body: "\(window.title) · Open Requota to update usage."))
                }
                if rules.allowanceReminder, let used = window.safePercent, 100 - used >= Double(max(0, min(100, rules.minimumRemaining))) {
                    let hours = max(1, min(168, rules.allowanceHours))
                    let date = reset.addingTimeInterval(-Double(hours) * 3600)
                    result.append(PlannedReminder(id: key + "-allowance", accountID: account.id, date: max(date, now.addingTimeInterval(1)), title: "\(account.title): weekly reset approaching", body: "\(Int((100 - used).rounded()))% remained at the last update. Reset \(reset.formatted(date: .abbreviated, time: .shortened))."))
                }
            }
            if rules.bankedExpiry {
                for item in account.snapshot?.bankedResets ?? [] {
                    guard let expiry = item.expiresAt, expiry > now else { continue }
                    let key = "reminder-\(account.id)-banked-\(item.id)-\(Int(expiry.timeIntervalSince1970 / 60) * 60)"
                    result.append(PlannedReminder(id: key + "-expiry", accountID: account.id, date: expiry, title: "\(account.title): banked reset expires", body: "\(item.count) reset\(item.count == 1 ? "" : "s") due to expire."))
                    let hours = max(1, min(168, rules.bankedExpiryHours))
                    let date = expiry.addingTimeInterval(-Double(hours) * 3600)
                    result.append(PlannedReminder(id: key + "-warning", accountID: account.id, date: max(date, now.addingTimeInterval(1)), title: "\(account.title): banked reset expiring", body: "\(item.count) reset\(item.count == 1 ? "" : "s") available at the last update. Expires \(expiry.formatted(date: .abbreviated, time: .shortened))."))
                }
            }
        }
        return result.sorted { $0.date < $1.date }
    }
}
