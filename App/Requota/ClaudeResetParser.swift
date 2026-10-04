import Foundation
import CryptoKit
import CoreFoundation

extension UsageParser {
    static func claudeResetInventory(_ raw: Any?, now: Date) -> ResetInventory? {
        guard let object = raw as? [String: Any],
              let eligible = object["eligible"] as? NSNumber, CFGetTypeID(eligible) == CFBooleanGetTypeID(), eligible.boolValue,
              let rows = object["grants"] as? [[String: Any]], rows.count <= 200 else { return nil }
        func integer(_ raw: Any?) -> Int? {
            guard let number = percent(raw), number <= 100, number.rounded() == number else { return nil }
            return Int(number)
        }
        func boolean(_ raw: Any?) -> Bool? {
            guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        var grants: [ResetGrant] = []
        var ids = Set<String>()
        for row in rows {
            guard let remaining = integer(row["resets_left"]), let paused = boolean(row["paused"]) else { return nil }
            let total = integer(row["resets_total"])
            if row["resets_total"] != nil && !(row["resets_total"] is NSNull) && total == nil { return nil }
            guard total.map({ $0 >= remaining }) ?? true else { return nil }
            let start = date(row["starts_at"]), expiry = date(row["ends_at"])
            for key in ["starts_at", "ends_at"] {
                if let value = row[key], !(value is NSNull), date(value) == nil { return nil }
            }
            guard start == nil || expiry == nil || start! < expiry! else { return nil }
            let windowIDs = (row["clears"] as? [String] ?? []).filter { ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_overage_included"].contains($0) }.sorted()
            let identity = (row["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "\(start?.timeIntervalSince1970 ?? 0)|\(expiry?.timeIntervalSince1970 ?? 0)|\(windowIDs.joined(separator: ","))"
            let id = "claude-reset-" + SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            // Ambiguous or malformed inventory stays unknown rather than becoming zero.
            guard ids.insert(id).inserted else { return nil }
            grants.append(ResetGrant(id: id, remaining: remaining, total: total, startsAt: start, expiresAt: expiry,
                                     paused: paused, usableNow: boolean(row["usable_now"]), windowIDs: windowIDs))
        }
        return ResetInventory(checkedAt: now, grants: grants)
    }

    static func availableClaudeResets(_ inventory: ResetInventory, now: Date) -> [BankedReset] {
        inventory.grants.compactMap { grant in
            guard grant.remaining > 0, !grant.paused,
                  grant.startsAt.map({ $0 <= now }) ?? true,
                  grant.expiresAt.map({ $0 > now }) ?? true else { return nil }
            // usable_now can be false while a banked grant is waiting for a limit.
            return BankedReset(id: grant.id, title: "Usage reset", count: grant.remaining, expiresAt: grant.expiresAt, usableNow: grant.usableNow)
        }.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }
}
