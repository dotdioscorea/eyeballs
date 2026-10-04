import Foundation

extension UsageParser {
    static func kimi(_ raw: Any, profile: Any, subject: String) throws -> UsageSnapshot {
        guard let object = raw as? [String: Any], let profile = profile as? [String: Any] else { throw UsageError.invalidResponse }
        let identity = try KimiAuth.identity(profile)
        guard identity.subject == subject else { throw UsageError.wrongAccount }
        var windows: [UsageWindow] = []
        if let usages = object["usages"] as? [String: Any] {
            for (key, title, duration) in [("limit_5h", "5-hour window", 18000.0), ("limit_7d", "Weekly", 604800.0),
                                           ("limit_month_total", "Monthly total", 0.0), ("limit_month_code", "Monthly Code", 0.0)] {
                guard let entry = usages[key] as? [String: Any], let ratio = positiveAmount(entry["used_ratio"]), (ratio * 100).isFinite else { continue }
                windows.append(UsageWindow(id: key, title: title, usedPercent: ratio * 100, resetsAt: date(entry["reset_time"]), duration: duration > 0 ? duration : nil))
            }
        }
        // Older Kimi Code deployments supply amounts rather than ratios.
        if windows.isEmpty, let usage = object["usage"] as? [String: Any], let percent = kimiLegacyPercent(usage) {
            windows.append(UsageWindow(id: "limit_7d", title: "Weekly", usedPercent: percent, resetsAt: date(usage["resetTime"]), duration: 604800))
            for entry in (object["limits"] as? [[String: Any]] ?? []).prefix(30) {
                guard let window = entry["window"] as? [String: Any], let detail = entry["detail"] as? [String: Any],
                      let length = positiveAmount(window["duration"]), length > 0, let percent = kimiLegacyPercent(detail) else { continue }
                let multiplier: Double
                switch window["timeUnit"] as? String {
                case "TIME_UNIT_MINUTE": multiplier = 60
                case "TIME_UNIT_HOUR": multiplier = 3600
                case "TIME_UNIT_DAY": multiplier = 86400
                case "TIME_UNIT_SECOND": multiplier = 1
                default: continue
                }
                let duration = length * multiplier
                guard duration.isFinite, duration <= 366 * 86400 else { continue }
                let id = duration == 18000 ? "limit_5h" : "kimi-window-" + metricKey([String(duration)])
                guard !windows.contains(where: { $0.id == id }) else { continue }
                let title = duration == 18000 ? "5-hour window" : "\(Int(duration / 3600))-hour window"
                windows.append(UsageWindow(id: id, title: title, usedPercent: percent, resetsAt: date(detail["resetTime"]), duration: duration))
            }
        }
        var details = ProviderDetails()
        if let wallet = object["boosterWallet"] as? [String: Any] {
            let limit = wallet["monthlyChargeLimit"] as? [String: Any], used = wallet["monthlyUsed"] as? [String: Any]
            let currency = safeLabel(limit?["currency"]) ?? safeLabel(used?["currency"])
            if let currency, currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil,
               [limit, used].compactMap({ $0?["currency"] as? String }).allSatisfy({ $0 == currency }) {
                if let balance = wallet["balance"] as? [String: Any], balance["type"] as? String == "BOOSTER",
                   let left = decimal(balance["amountLeft"]) {
                    // Official SDK: fixed-point units / 1,000,000 = cents.
                    details.spending.append(SpendingDetails(id: "kimi-booster", title: "Extra credits", balance: left / 100_000_000, currency: currency))
                }
                let usedAmount = positiveAmount(used?["priceInCents"]).map { $0 / 100 }
                let cap = wallet["monthlyChargeLimitEnabled"] as? Bool == true ? positiveAmount(limit?["priceInCents"]).map { $0 / 100 } : nil
                if usedAmount != nil || cap != nil {
                    details.spending.append(SpendingDetails(id: "kimi-extra-spend", title: "Monthly extra usage", used: usedAmount, limit: cap, currency: currency))
                }
            }
        }
        // An empty payload was verified on Free accounts. Paid accounts must
        // supply a recognized reading; schema failures retain the last snapshot.
        guard !windows.isEmpty || !details.isEmpty || (object.isEmpty && identity.plan?.lowercased() == "free") else { throw UsageError.invalidResponse }
        var result = UsageSnapshot(windows: windows, plan: identity.plan)
        result.details = details.isEmpty ? nil : details
        let level = decimal(profile["user_level"]).map { String($0) } ?? ""
        let goodsVersion = decimal(profile["goods_version"]).map { String($0) } ?? ""
        result.allowanceContext = [identity.plan ?? "", level, goodsVersion].joined(separator: "|")
        return result
    }
    private static func kimiLegacyPercent(_ raw: [String: Any]) -> Double? {
        guard let limit = positiveAmount(raw["limit"]), limit > 0 else { return nil }
        let used = positiveAmount(raw["used"]) ?? positiveAmount(raw["remaining"]).flatMap { $0 <= limit ? limit - $0 : nil }
        return used.flatMap { ($0 / limit * 100).isFinite ? $0 / limit * 100 : nil }
    }
}
