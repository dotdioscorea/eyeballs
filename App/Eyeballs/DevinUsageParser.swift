import Foundation

extension UsageParser {
    static func devin(_ raw: Any, subject: String, accountID: String?) throws -> UsageSnapshot {
        let identity: (subject: String, accountID: String, email: String?)
        do { identity = try DevinAuth.identity(raw) } catch { throw UsageError.invalidResponse }
        guard identity.subject == subject, identity.accountID == accountID else { throw UsageError.wrongAccount }
        guard let object = raw as? [String: Any], let user = object["userStatus"] as? [String: Any],
              let status = user["planStatus"] as? [String: Any], let info = status["planInfo"] as? [String: Any],
              let plan = safeLabel(info["planName"]) else { throw UsageError.invalidResponse }
        var snapshot = UsageSnapshot(plan: plan)
        snapshot.allowanceContext = metricKey(["devin", plan, info["billingStrategy"] as? String ?? "", String(info["hideDailyQuota"] as? Bool ?? false), String(info["hideWeeklyQuota"] as? Bool ?? false)])
        for (id, title, field, reset, duration, hidden) in [
            ("daily", "Daily", "dailyQuotaRemainingPercent", "dailyQuotaResetAtUnix", 86400.0, "hideDailyQuota"),
            ("weekly", "Weekly", "weeklyQuotaRemainingPercent", "weeklyQuotaResetAtUnix", 604800.0, "hideWeeklyQuota")
        ] {
            guard info[hidden] as? Bool != true else { continue }
            // Quota billing's ProtoJSON omits a zero scalar when exhausted.
            // A reported reset and recognised billing strategy establish the
            // window; missing data on another plan stays missing.
            var rawValue = status[field]
            if rawValue == nil, info["billingStrategy"] as? String == "BILLING_STRATEGY_QUOTA", unixDate(status[reset]) != nil { rawValue = 0 }
            if let rawValue {
                guard let remaining = decimal(rawValue), remaining >= 0, remaining <= 100 else { throw UsageError.invalidResponse }
                snapshot.windows.append(UsageWindow(id: id, title: title, usedPercent: 100 - remaining, resetsAt: unixDate(status[reset]), duration: duration))
            }
        }
        var details = ProviderDetails()
        let configs = (user["cascadeModelConfigData"] as? [String: Any])?["clientModelConfigs"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        let ordered = configs.sorted { (($0["disabled"] as? Bool) == true ? 1 : 0) < (($1["disabled"] as? Bool) == true ? 1 : 0) }
        for config in ordered.prefix(300) {
            guard let key = safeLabel(config["modelUid"]), let title = safeLabel(config["label"]), seen.insert(key).inserted else { continue }
            // Connect ProtoJSON omits false boolean scalars. A recognised model
            // record without disabled therefore means enabled, not unknown.
            guard config["disabled"] == nil || config["disabled"] is Bool else { throw UsageError.invalidResponse }
            details.models.append(ModelAccess(id: metricKey(["devin", key]), title: title, available: config["disabled"] as? Bool != true))
        }
        details.models.sort {
            if $0.available != $1.available { return $0.available == true }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        snapshot.details = details.isEmpty ? nil : details
        return snapshot
    }
    private static func unixDate(_ raw: Any?) -> Date? {
        guard let seconds = decimal(raw), seconds > 0, seconds <= 32_503_680_000 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
