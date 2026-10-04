import Foundation

extension UsageParser {
    static func perplexity(_ raw: Any, profile: Any, subject: String) throws -> UsageSnapshot {
        guard let profile = profile as? [String: Any], let id = safeLabel(profile["id"]) else { throw UsageError.invalidResponse }
        guard id == subject else { throw UsageError.wrongAccount }
        guard let raw = raw as? [String: Any], let modes = raw["modes"] as? [String: Any] else { throw UsageError.invalidResponse }
        var allowances: [RemainingAllowance] = []
        for (key, title) in [("pro_search", "Pro searches"), ("research", "Research"), ("labs", "Labs"), ("agentic_research", "Agentic research")] {
            guard let item = modes[key] as? [String: Any], let detail = item["remaining_detail"] as? [String: Any], let kind = detail["kind"] as? String else { continue }
            let count: Int?
            if kind == "exact" {
                guard let number = positiveAmount(detail["remaining"]), number.rounded() == number, number <= 1_000_000_000 else { continue }
                count = Int(number)
            } else if kind == "not_provided" { count = nil }
            else { continue }
            let available = item["available"] as? Bool
            guard count != nil || available != nil else { continue }
            allowances.append(RemainingAllowance(id: key, title: title, remaining: count, available: available))
        }
        guard allowances.contains(where: { $0.id == "pro_search" }) else { throw UsageError.invalidResponse }
        let tier = safeLabel(profile["subscription_tier"]).flatMap { $0 == "none" ? nil : $0 }
        let payment = safeLabel(profile["payment_tier"]).flatMap { $0 == "none" ? nil : $0 }
        let free = profile["subscription_status"] as? String == "none" && profile["payment_tier"] as? String == "none"
        var snapshot = UsageSnapshot(plan: tier?.capitalized ?? payment?.capitalized ?? (free ? "Free" : nil))
        snapshot.remainingAllowances = allowances
        snapshot.allowanceContext = [safeLabel(profile["subscription_status"]) ?? "", tier ?? "", payment ?? ""].joined(separator: "|")
        return snapshot
    }
}
