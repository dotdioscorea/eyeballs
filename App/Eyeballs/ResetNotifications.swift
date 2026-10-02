import Foundation

struct ResetNotificationRules: Codable, Equatable {
    var weeklyReset = true
    var earlyReset = true
    var bankedChanges = true
    var bankedExpiry = true
    var allowanceReminder = true
    var allowanceHours = 24
    var minimumRemaining = 10
    var bankedExpiryHours = 24
    var parsingFailures = true
    func announces(_ kind: AccountEvent.Kind) -> Bool {
        switch kind {
        case .weeklyReset: return weeklyReset
        case .earlyReset: return earlyReset
        case .bankedDetected, .bankedUsed, .bankedRemoved: return bankedChanges
        case .bankedExpired: return bankedExpiry
        case .parsingFailure: return parsingFailures
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
    static func make(accounts: [AgentAccount], rules: ResetNotificationRules, now: Date = .now) -> [PlannedReminder] {
        var result: [PlannedReminder] = []
        for account in accounts where !account.needsLogin {
            for window in account.snapshot?.windows ?? [] where EventDetection.weekly(window) {
                guard let reset = window.resetsAt, reset > now else { continue }
                let key = "reminder-\(account.id)-\(window.id)-\(reset.timeIntervalSince1970)"
                if rules.weeklyReset {
                    result.append(PlannedReminder(id: key + "-reset", accountID: account.id, date: reset, title: "\(account.title): weekly reset due", body: "\(window.title) · Open Eyeballs to update usage."))
                }
                if rules.allowanceReminder, let used = window.safePercent, 100 - used >= Double(max(0, min(100, rules.minimumRemaining))) {
                    let hours = max(1, min(168, rules.allowanceHours))
                    let date = reset.addingTimeInterval(-Double(hours) * 3600)
                    if date > now {
                        result.append(PlannedReminder(id: key + "-allowance", accountID: account.id, date: date, title: "\(account.title): reset in \(hours)h", body: "\(Int((100 - used).rounded()))% remained at the last update."))
                    }
                }
            }
            if rules.bankedExpiry {
                for item in account.snapshot?.bankedResets ?? [] {
                    guard let expiry = item.expiresAt, expiry > now else { continue }
                    let key = "reminder-\(account.id)-banked-\(item.id)-\(expiry.timeIntervalSince1970)"
                    result.append(PlannedReminder(id: key + "-expiry", accountID: account.id, date: expiry, title: "\(account.title): banked reset expires", body: "\(item.count) reset\(item.count == 1 ? "" : "s") due to expire."))
                    let hours = max(1, min(168, rules.bankedExpiryHours))
                    let date = expiry.addingTimeInterval(-Double(hours) * 3600)
                    if date > now { result.append(PlannedReminder(id: key + "-warning", accountID: account.id, date: date, title: "\(account.title): banked reset expires in \(hours)h", body: "\(item.count) reset\(item.count == 1 ? "" : "s") available at the last update.")) }
                }
            }
        }
        return Array(result.sorted { $0.date < $1.date }.prefix(50))
    }
}
