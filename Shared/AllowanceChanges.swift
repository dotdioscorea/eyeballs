import Foundation

enum AllowanceChanges {
    static func contextChanged(_ before: String?, _ after: String?) -> Bool {
        guard let before, let after, !before.isEmpty, !after.isEmpty else { return false }
        return before != after
    }
    static func windowChanged(_ before: UsageWindow, _ after: UsageWindow) -> Bool {
        if let old = before.limitAmount, let new = after.limitAmount, old.isFinite, new.isFinite, old != new { return true }
        if contextChanged(before.amountUnit, after.amountUnit) { return true }
        if let old = before.duration, let new = after.duration, old.isFinite, new.isFinite, abs(old - new) > 1 {
            let calendarMonths = (27 * 86400.0...32 * 86400.0).contains(old) && (27 * 86400.0...32 * 86400.0).contains(new)
            if !calendarMonths { return true }
        }
        return false
    }
    static func snapshotChanged(_ before: UsageSnapshot, _ after: UsageSnapshot) -> Bool {
        if contextChanged(before.allowanceContext ?? before.plan, after.allowanceContext ?? after.plan) { return true }
        return after.windows.contains { window in before.windows.first(where: { $0.id == window.id }).map { windowChanged($0, window) } ?? false }
    }
}
