import Foundation
import CryptoKit
import CoreFoundation

extension UsageParser {
    static func decimal(_ raw: Any?) -> Double? {
        if let text = raw as? String, text.count <= 128,
           text.range(of: "^[+-]?[0-9]+(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$", options: .regularExpression) != nil,
           let value = Double(text), value.isFinite { return value }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    static func positiveAmount(_ raw: Any?) -> Double? { decimal(raw).flatMap { $0 >= 0 ? $0 : nil } }
    static func safeLabel(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 120, !clean.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return clean
    }
    static func metricKey(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "|").utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    static func messageEstimate(_ raw: Any?) -> MessageEstimate? {
        guard let values = raw as? [Any], values.count == 2,
              let lower = positiveAmount(values[0]), let upper = positiveAmount(values[1]),
              lower.rounded() == lower, upper.rounded() == upper, upper >= lower, upper <= 1_000_000_000 else { return nil }
        return MessageEstimate(lower: Int(lower), upper: Int(upper))
    }
    static func codexDetails(_ object: [String: Any]) -> ProviderDetails? {
        var result = ProviderDetails()
        if let credits = object["credits"] as? [String: Any] {
            result.credits = CreditDetails(available: credits["has_credits"] as? Bool, unlimited: credits["unlimited"] as? Bool,
                                          overageLimitReached: credits["overage_limit_reached"] as? Bool,
                                          spendLimitReached: (object["spend_control"] as? [String: Any])?["reached"] as? Bool,
                                          localMessages: messageEstimate(credits["approx_local_messages"]), cloudMessages: messageEstimate(credits["approx_cloud_messages"]))
        }
        if let spend = object["spend_control"] as? [String: Any], let limit = spend["individual_limit"] as? [String: Any] {
            result.spending = [SpendingDetails(id: "codex-spend", title: "Spending limit", used: positiveAmount(limit["used"]), limit: positiveAmount(limit["limit"]),
                                              unit: "credits", stoppedReason: spend["reached"] as? Bool == true ? "Spending limit reached" : nil, resetsAt: date(limit["reset_at"]))]
        }
        if let models = object["model_usage"] as? [String: [String: Any]] {
            result.models = models.keys.sorted().prefix(30).compactMap { key in
                guard let title = safeLabel(key), let info = models[key], info["available"] is Bool || info["credits_would_enable"] is Bool else { return nil }
                return ModelAccess(id: metricKey([key]), title: title, available: info["available"] as? Bool, creditsWouldEnable: info["credits_would_enable"] as? Bool, availableAt: date(info["available_at"]))
            }
        }
        return result.isEmpty ? nil : result
    }
    static func codexAdditionalWindows(_ object: [String: Any]) -> [UsageWindow] {
        var result: [UsageWindow] = [], seen = Set<String>()
        for item in (object["additional_rate_limits"] as? [[String: Any]] ?? []).prefix(30) {
            guard let limit = item["rate_limit"] as? [String: Any], let label = safeLabel(item["limit_name"]) ?? safeLabel(item["metered_feature"]) else { continue }
            let feature = safeLabel(item["metered_feature"]) ?? label
            for (key, suffix) in [("primary_window", "primary"), ("secondary_window", "secondary")] {
                guard let window = limit[key] as? [String: Any] else { continue }
                let id = "additional-" + metricKey([feature]) + "-" + suffix
                guard seen.insert(id).inserted else { continue }
                let duration = percent(window["limit_window_seconds"]).flatMap { $0 > 0 ? $0 : nil }
                let title = label + (suffix == "secondary" ? (duration == 604800 ? " weekly" : " secondary") : "")
                result.append(UsageWindow(id: id, title: title, usedPercent: percent(window["used_percent"]), resetsAt: date(window["reset_at"]), duration: duration))
            }
        }
        return result
    }
    struct Money {
        var value: Double
        var currency: String
        static func read(_ raw: Any?) -> Self? {
            guard let money = raw as? [String: Any], let amount = decimal(money["amount_minor"]),
                  let exponent = percent(money["exponent"]), exponent.rounded() == exponent, exponent <= 6,
                  let currency = money["currency"] as? String, currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else { return nil }
            return Self(value: amount / pow(10, exponent), currency: currency)
        }
    }
    static func claudeDetails(_ object: [String: Any], windows: inout [UsageWindow]) -> ProviderDetails? {
        var result = ProviderDetails()
        if let spend = object["spend"] as? [String: Any] {
            let used = Money.read(spend["used"]), limit = Money.read(spend["limit"]), balance = Money.read(spend["balance"])
            let currency = used?.currency ?? limit?.currency ?? balance?.currency
            if currency != nil, [used, limit, balance].compactMap({ $0 }).allSatisfy({ $0.currency == currency }) {
                let item = SpendingDetails(id: "claude-spend", title: "Usage credits", used: used?.value, limit: limit?.value, balance: balance?.value,
                                           currency: currency, enabled: spend["enabled"] as? Bool, stoppedReason: extraUsageReason(spend["disabled_reason"]), resetsAt: date(spend["resets_at"]))
                result.spending.append(item)
                appendSpendWindow(item, reportedPercent: percent(spend["percent"]), windows: &windows)
            }
        }
        if result.spending.isEmpty, let extra = object["extra_usage"] as? [String: Any] {
            let currency = (extra["currency"] as? String).flatMap { $0.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil ? $0 : nil }
            let exponent = percent(extra["decimal_places"]).flatMap { $0 <= 6 && $0.rounded() == $0 ? $0 : nil }
            // Legacy Claude amounts are minor currency units. Keep unknown
            // currencies as credits, without assigning a dollar conversion.
            let validScale = extra["decimal_places"] == nil || exponent != nil
            let divisor = currency != nil ? pow(10, exponent ?? 2) : 1
            let item = SpendingDetails(id: "claude-spend", title: "Extra usage", used: validScale ? positiveAmount(extra["used_credits"]).map { $0 / divisor } : nil,
                                       limit: validScale ? positiveAmount(extra["monthly_limit"]).map { $0 / divisor } : nil, currency: currency, unit: currency == nil ? "credits" : nil,
                                       enabled: extra["is_enabled"] as? Bool, stoppedReason: extraUsageReason(extra["disabled_reason"]), resetsAt: date(extra["resets_at"]))
            result.spending.append(item); appendSpendWindow(item, reportedPercent: percent(extra["utilization"]), windows: &windows)
        }
        if let breakdown = object["seven_day_breakdown"] as? [String: Any], let rawRows = breakdown["rows"] as? [[String: Any]] {
            var seen = Set<String>()
            let rows = rawRows.prefix(30).compactMap { row -> UsageBreakdown.Row? in
                guard let key = safeLabel(row["key"]), seen.insert(key).inserted, let title = safeLabel(row["display_name"]),
                      let value = percent(row["percent"]), value <= 100 else { return nil }
                return .init(id: metricKey([key]), title: title, percent: value)
            }
            if !rows.isEmpty { result.breakdowns.append(UsageBreakdown(id: "claude-weekly-apps", title: "Share of weekly usage", asOf: date(breakdown["as_of"]), startedAt: date(breakdown["window_started_at"]), rows: rows)) }
        }
        return result.isEmpty ? nil : result
    }
    private static func appendSpendWindow(_ item: SpendingDetails, reportedPercent: Double?, windows: inout [UsageWindow]) {
        guard item.used != nil || item.limit != nil else { return }
        let calculated = item.used.flatMap { used in item.limit.flatMap { $0 > 0 && used >= 0 ? used / $0 * 100 : nil } }.flatMap { $0.isFinite ? $0 : nil }
        windows.append(UsageWindow(id: item.id, title: item.title, usedPercent: reportedPercent ?? calculated, resetsAt: item.resetsAt,
                                   usedAmount: item.used, limitAmount: item.limit, amountUnit: item.currency ?? item.unit))
    }
    private static func extraUsageReason(_ raw: Any?) -> String? {
        switch raw as? String {
        case "out_of_credits": return "Credit balance exhausted"
        case "spend_limit_reached", "budget_exhausted": return "Spending limit reached"
        case "user_disabled", "disabled": return "Turned off in Claude"
        case "no_payment_method": return "No payment method"
        case "not_eligible", "ineligible": return "Not available on this plan"
        default: return nil
        }
    }
    static func claudeScopedWindows(_ object: [String: Any], windows: inout [UsageWindow]) {
        for item in (object["limits"] as? [[String: Any]] ?? []).prefix(30) {
            guard let kind = item["kind"] as? String, let group = item["group"] as? String,
                  let amount = percent(item["percent"]), ["weekly", "session"].contains(group) else { continue }
            let scope = item["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any], surface = scope?["surface"] as? [String: Any]
            let modelName = safeLabel(model?["display_name"]), surfaceName = safeLabel(surface?["display_name"])
            let labels = [modelName, surfaceName].compactMap { $0 }
            let id: String, title: String
            if kind == "session", labels.isEmpty { id = "five_hour"; title = "5-hour window" }
            else if kind == "weekly_all", labels.isEmpty { id = "seven_day"; title = "Weekly" }
            else if !labels.isEmpty {
                let known = modelName?.lowercased()
                if group == "weekly", surfaceName == nil, ["opus", "sonnet"].contains(known ?? "") { id = "seven_day_" + known! }
                else { id = "claude-scoped-" + metricKey([kind, group, safeLabel(model?["id"]) ?? modelName ?? "", safeLabel(surface?["id"]) ?? surfaceName ?? ""]) }
                title = labels.joined(separator: " · ") + (group == "weekly" ? " weekly" : " 5-hour")
            } else { continue }
            if let index = windows.firstIndex(where: { $0.id == id }) {
                if windows[index].usedPercent == nil { windows[index].usedPercent = amount }
                if windows[index].resetsAt == nil { windows[index].resetsAt = date(item["resets_at"]) }
                continue
            }
            windows.append(UsageWindow(id: id, title: title, usedPercent: amount, resetsAt: date(item["resets_at"]), duration: group == "weekly" ? 604800 : 18000))
        }
    }
}
