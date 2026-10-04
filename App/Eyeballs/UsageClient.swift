import Foundation
import CoreFoundation
import CryptoKit

enum UsageError: LocalizedError {
    case signedOut, usageAccessDenied, unavailable, throttled(Date), invalidResponse, wrongAccount, unsupportedLogin
    var errorDescription: String? {
        switch self {
        case .signedOut: return "Your connection has expired. Sign in again to update usage."
        case .usageAccessDenied: return "Sign-in completed, but the provider did not authorize usage access for this connection."
        case .unavailable: return "The provider isn’t sharing usage right now. Your last reading is still available."
        case .throttled(let date): return "The provider asked us to wait. Try again after \(date.formatted(date: .omitted, time: .shortened))."
        case .invalidResponse: return "The provider returned an unrecognized usage response. Your last reading has been kept."
        case .wrongAccount: return "This sign-in belongs to a different account. Add it as a new connection instead."
        case .unsupportedLogin: return "This provider has not enabled a supported sign-in for Requota."
        }
    }
}

final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum ProviderHTTP {
    static func data(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.url?.scheme == "https" else { throw UsageError.invalidResponse }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, data.count < 1_000_000 else { throw UsageError.invalidResponse }
        Diagnostics.record(.http, status: response.statusCode, endpoint: .identify(request.url))
        return (data, response)
    }
    static func json(_ request: URLRequest, unauthorizedError: UsageError = .signedOut) async throws -> Any {
        let (data, response) = try await data(request)
        return try decodeJSON(data, response: response, unauthorizedError: unauthorizedError)
    }
    static func decodeJSON(_ data: Data, response: HTTPURLResponse, unauthorizedError: UsageError = .signedOut) throws -> Any {
        if response.statusCode == 401 || response.statusCode == 403 { throw unauthorizedError }
        if response.statusCode == 429 {
            throw UsageError.throttled(retryDate(response.value(forHTTPHeaderField: "Retry-After")))
        }
        guard (200..<300).contains(response.statusCode) else { throw UsageError.unavailable }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw UsageError.invalidResponse }
        return object
    }
    static func retryDate(_ value: String?, now: Date = .now) -> Date {
        if let value, let seconds = Double(value), seconds.isFinite, seconds >= 0 { return now.addingTimeInterval(max(60, min(seconds, 86400))) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return value.flatMap(formatter.date).map { max(now.addingTimeInterval(60), $0) } ?? now.addingTimeInterval(300)
    }
}

struct UsageClient {
    static func request(provider: Provider, credential: AccountCredential) throws -> URLRequest {
        guard credential.provider == provider, !credential.accessToken.isEmpty else { throw UsageError.wrongAccount }
        let expectedIssuer: String
        let endpoint: String
        switch provider {
        case .codex:
            expectedIssuer = "https://auth.openai.com"
            endpoint = "https://chatgpt.com/backend-api/wham/usage"
        case .claude:
            expectedIssuer = "https://platform.claude.com"
            endpoint = "https://api.anthropic.com/api/oauth/usage"
        case .gemini:
            expectedIssuer = GeminiAuth.issuer
            endpoint = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
        case .amp:
            guard credential.issuer == AmpAuth.issuer, credential.clientID == AmpAuth.clientID else { throw UsageError.wrongAccount }
            return try AmpAuth.request("userDisplayBalanceInfo", token: credential.accessToken)
        case .devin:
            guard credential.issuer == DevinAuth.issuer, credential.clientID == DevinAuth.clientID else { throw UsageError.wrongAccount }
            return try DevinAuth.request("GetUserStatus", token: credential.accessToken)
        case .perplexity:
            return try PerplexityAuth.sessionRequest("/rest/rate-limit/status", credential: credential)
        case .kimi:
            guard credential.clientID == KimiAuth.clientID else { throw UsageError.wrongAccount }
            return try KimiAuth.request("/usages", region: KimiAuth.Region.matching(credential.issuer), accessToken: credential.accessToken)
        case .cline:
            expectedIssuer = ClineAuth.issuer
            endpoint = ClineAuth.issuer + "/api/v1/users/" + credential.subject + "/balance"
        case .cursor:
            expectedIssuer = CursorAuth.issuer
            endpoint = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
        case .copilot:
            expectedIssuer = CopilotAuth.issuer
            endpoint = "https://api.github.com/copilot_internal/user"
        case .grok:
            expectedIssuer = "https://auth.x.ai"
            endpoint = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
        }
        guard credential.issuer == expectedIssuer else { throw UsageError.wrongAccount }
        var request = URLRequest(url: URL(string: endpoint)!)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Requota/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        if provider == .codex, let id = credential.accountID { request.setValue(id, forHTTPHeaderField: "ChatGPT-Account-Id") }
        if provider == .claude { request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta") }
        if provider == .grok {
            request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
            let teamID = credential.accountID?.hasPrefix("Team:") == true ? credential.accountID?.dropFirst(5).description : nil
            request.setValue(teamID ?? credential.subject, forHTTPHeaderField: "x-userid")
        }
        if provider == .cline {
            guard credential.clientID == ClineAuth.clientID else { throw UsageError.wrongAccount }
            return try ClineAuth.apiRequest("/api/v1/users/" + credential.subject + "/balance", accessToken: credential.accessToken)
        }
        if provider == .cursor {
            guard credential.clientID == CursorAuth.clientID else { throw UsageError.wrongAccount }
            return try CursorAuth.request("GetCurrentPeriodUsage", accessToken: credential.accessToken)
        }
        return request
    }
    static func fetch(account: AgentAccount, credential: AccountCredential) async throws -> UsageSnapshot {
        try await Diagnostics.$context.withValue(.init(provider: account.provider, accountID: account.id)) {
            try await fetchSnapshot(account: account, credential: credential)
        }
    }
    private static func fetchSnapshot(account: AgentAccount, credential: AccountCredential) async throws -> UsageSnapshot {
        var tier: [String: Any]?
        let raw: Any
        if account.provider == .gemini {
            let assist = try await geminiRequest("loadCodeAssist", body: ["metadata": ["ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]], credential: credential)
            tier = assist["paidTier"] as? [String: Any] ?? assist["currentTier"] as? [String: Any]
            let project = try GeminiAuth.quotaProject(assist)
            raw = try await geminiRequest("retrieveUserQuota", body: ["project": project], credential: credential)
        } else { raw = try await ProviderHTTP.json(request(provider: account.provider, credential: credential), unauthorizedError: account.provider == .devin ? .signedOut : .usageAccessDenied) }
        var parsed: UsageSnapshot?
        defer { Diagnostics.record(.usageParsed, provider: account.provider, parsing: .make(provider: account.provider, raw: raw, snapshot: parsed)) }
        var snapshot: UsageSnapshot
        switch account.provider {
        case .codex: snapshot = try UsageParser.codex(raw)
        case .claude: snapshot = try UsageParser.claude(raw)
        case .grok: snapshot = try UsageParser.grok(raw)
        case .gemini: snapshot = try UsageParser.gemini(raw); snapshot.plan = tier?["name"] as? String ?? tier?["id"] as? String
        case .cline: snapshot = try UsageParser.cline(raw, subject: credential.subject)
        case .kimi:
            let profile = try await ProviderHTTP.json(KimiAuth.request("/me", region: KimiAuth.Region.matching(credential.issuer), accessToken: credential.accessToken), unauthorizedError: .usageAccessDenied)
            snapshot = try UsageParser.kimi(raw, profile: profile, subject: credential.subject)
        case .perplexity:
            let profile = try await ProviderHTTP.json(PerplexityAuth.sessionRequest("/api/user", credential: credential), unauthorizedError: .usageAccessDenied)
            snapshot = try UsageParser.perplexity(raw, profile: profile, subject: credential.subject)
        case .amp:
            let profile = try await ProviderHTTP.json(AmpAuth.request("getUserInfo", token: credential.accessToken), unauthorizedError: .usageAccessDenied)
            snapshot = try UsageParser.amp(raw, profile: profile, subject: credential.subject)
        case .devin: snapshot = try UsageParser.devin(raw, subject: credential.subject, accountID: credential.accountID)
        case .copilot: snapshot = try UsageParser.copilot(raw)
        case .cursor:
            snapshot = try UsageParser.cursor(raw)
            if let info = try? await ProviderHTTP.json(CursorAuth.request("GetPlanInfo", accessToken: credential.accessToken)) as? [String: Any] { snapshot.plan = (info["planInfo"] as? [String: Any])?["planName"] as? String }
            try Task.checkCancellation()
        }
        parsed = snapshot
        if account.provider == .claude, let profile = try? await ProviderHTTP.json(ProviderAuth.claudeProfileRequest(accessToken: credential.accessToken)),
           let identity = try? ProviderAuth.claudeIdentity(profile) {
            guard identity.subject == credential.subject, identity.accountID == credential.accountID else { throw UsageError.wrongAccount }
            let details = UsageParser.claudePlan(profile)
            snapshot.plan = details.plan; snapshot.allowanceContext = details.context
        }
        try Task.checkCancellation()
        if account.provider == .codex {
            var resetRequest = try request(provider: .codex, credential: credential)
            resetRequest.url = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
            if let details = try? await ProviderHTTP.json(resetRequest), let resets = UsageParser.codexResets(details) {
                snapshot.bankedResets = resets
            }
            try Task.checkCancellation()
        }
        if account.provider == .codex, let reported = snapshot.identity, let selected = credential.accountID, reported != selected { throw UsageError.wrongAccount }
        snapshot.identity = credential.registrationIdentity
        snapshot.email = credential.email
        snapshot.source = "\(account.provider.name) API"
        return snapshot
    }
    static func geminiRequest(_ method: String, body: [String: Any], credential: AccountCredential) async throws -> [String: Any] {
        guard ["loadCodeAssist", "retrieveUserQuota"].contains(method) else { throw UsageError.invalidResponse }
        var request = try request(provider: .gemini, credential: credential)
        request.url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:" + method)!
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        guard let object = try await ProviderHTTP.json(request, unauthorizedError: .usageAccessDenied) as? [String: Any] else { throw UsageError.invalidResponse }
        return object
    }

}

enum UsageParser {
    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue > 0 { return Date(timeIntervalSince1970: number.doubleValue > 1e12 ? number.doubleValue / 1000 : number.doubleValue) }
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
    static func percent(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite && value >= 0 ? value : nil
    }
    static func cursorMilliseconds(_ value: Any?) -> Date? {
        let number: Double?
        if let text = value as? String, text.range(of: "^[0-9]+$", options: .regularExpression) != nil { number = Double(text) }
        else { number = percent(value) }
        guard let number, number > 0, number.isFinite else { return nil }
        return Date(timeIntervalSince1970: number / 1000)
    }
    static func cursor(_ raw: Any) throws -> UsageSnapshot {
        guard let object = raw as? [String: Any], let plan = object["planUsage"] as? [String: Any] else { throw UsageError.invalidResponse }
        let end = cursorMilliseconds(object["billingCycleEnd"])
        let start = cursorMilliseconds(object["billingCycleStart"])
        let duration = start.flatMap { start in end.flatMap { $0 > start ? $0.timeIntervalSince(start) : nil } }
        var windows: [UsageWindow] = []
        for (key, title) in [("totalPercentUsed", "Included usage"), ("autoPercentUsed", "Auto"), ("apiPercentUsed", "Named models")] {
            var used = percent(plan[key])
            if plan[key] == nil, key == "totalPercentUsed", let limit = percent(plan["limit"]), limit > 0, let spend = percent(plan["totalSpend"]) { used = spend / limit * 100 }
            if key == "totalPercentUsed" || plan[key] != nil { windows.append(UsageWindow(id: key, title: title, usedPercent: used, resetsAt: end, duration: duration)) }
        }
        return UsageSnapshot(windows: windows, billingEndsAt: end)
    }
    static func codex(_ raw: Any) throws -> UsageSnapshot {
        guard let object = raw as? [String: Any], object["rate_limit"] != nil || object["credits"] != nil else { throw UsageError.invalidResponse }
        let limits = object["rate_limit"] as? [String: Any] ?? [:]
        var windows: [UsageWindow] = []
        for (key, fallback) in [("primary_window", "Current window"), ("secondary_window", "Weekly")] {
            guard let value = limits[key] as? [String: Any] else { continue }
            let duration = percent(value["limit_window_seconds"]).flatMap { $0 > 0 ? $0 : nil }
            let title = duration.map { $0 <= 21600 ? "\(Int($0 / 3600))-hour window" : $0 >= 604800 ? "Weekly" : fallback } ?? fallback
            windows.append(UsageWindow(id: key, title: title, usedPercent: percent(value["used_percent"]), resetsAt: date(value["reset_at"]), duration: duration))
        }
        windows.append(contentsOf: codexAdditionalWindows(object))
        if let limit = object["code_review_rate_limit"] as? [String: Any], let window = limit["primary_window"] as? [String: Any] {
            windows.append(UsageWindow(id: "code-review", title: "Code review", usedPercent: percent(window["used_percent"]), resetsAt: date(window["reset_at"]), duration: percent(window["limit_window_seconds"])))
        }
        let credits = object["credits"] as? [String: Any]
        let balance = credits?["balance"]
        let creditBalance = decimal(balance).map { value in (balance as? String) ?? String(value) }
        let count = percent((object["rate_limit_reset_credits"] as? [String: Any])?["available_count"]).map { Int(min($0, 10000)) }
        let resets = count.map { $0 > 0 ? [BankedReset(id: "summary", title: "Usage reset", count: $0)] : [] }
        return UsageSnapshot(windows: windows, plan: (object["plan_type"] as? String)?.capitalized, identity: object["account_id"] as? String, creditBalance: creditBalance, bankedResets: resets, details: codexDetails(object))
    }
    static func codexResets(_ raw: Any, now: Date = .now) -> [BankedReset]? {
        guard let object = raw as? [String: Any], let credits = object["credits"] as? [[String: Any]] else { return nil }
        return credits.enumerated().compactMap { index, credit in
            guard credit["status"] as? String == "available" else { return nil }
            let expiry = date(credit["expires_at"])
            guard expiry.map({ $0 > now }) ?? true else { return nil }
            let identity = credit["id"] as? String ?? "\(credit["title"] as? String ?? "reset")-\(expiry?.timeIntervalSince1970 ?? 0)-\(index)"
            let key = SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            return BankedReset(id: "banked-" + key, title: String((credit["title"] as? String ?? "Usage reset").prefix(100)), expiresAt: expiry)
        }.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }
    static func claude(_ raw: Any) throws -> UsageSnapshot {
        guard let object = raw as? [String: Any], object["five_hour"] != nil || object["seven_day"] != nil || object["limits"] != nil else { throw UsageError.invalidResponse }
        var windows: [UsageWindow] = []
        for (key, title, duration) in [("five_hour", "5-hour window", 18000.0), ("seven_day", "Weekly", 604800.0), ("seven_day_opus", "Opus weekly", 604800.0), ("seven_day_sonnet", "Sonnet weekly", 604800.0), ("seven_day_cowork", "Cowork weekly", 604800.0), ("seven_day_oauth_apps", "Connected apps weekly", 604800.0)] {
            guard let value = object[key] as? [String: Any] else { continue }
            windows.append(UsageWindow(id: key, title: title, usedPercent: percent(value["utilization"]), resetsAt: date(value["resets_at"]), duration: duration))
        }
        claudeScopedWindows(object, windows: &windows)
        let details = claudeDetails(object, windows: &windows)
        return UsageSnapshot(windows: windows, details: details)
    }
    static func claudePlan(_ raw: Any) -> (plan: String?, context: String?) {
        guard let object = raw as? [String: Any], let organization = object["organization"] as? [String: Any],
              let type = organization["organization_type"] as? String, !type.isEmpty else { return (nil, nil) }
        let tier = organization["rate_limit_tier"] as? String ?? ""
        var plan = ["claude_pro": "Pro", "claude_max": "Max", "claude_team": "Team", "claude_enterprise": "Enterprise", "claude_free": "Free"][type]
        if type == "claude_max", tier == "default_claude_max_5x" { plan = "Max 5×" }
        if type == "claude_max", tier == "default_claude_max_20x" { plan = "Max 20×" }
        // Only tier fields contribute; names and organization IDs never do.
        let seat = organization["seat_tier"] as? String ?? ""
        let context = SHA256.hash(data: Data([type, tier, seat].joined(separator: "|").utf8)).map { String(format: "%02x", $0) }.joined()
        return (plan, context)
    }
    static func grok(_ raw: Any) throws -> UsageSnapshot {
        guard let object = raw as? [String: Any], let config = object["config"] as? [String: Any] else { throw UsageError.invalidResponse }
        let period = config["currentPeriod"] as? [String: Any]
        let quotaEnd = date(period?["end"])
        let end = quotaEnd ?? date(config["billingPeriodEnd"])
        let start = quotaEnd != nil ? date(period?["start"]) : date(config["billingPeriodStart"])
        let duration = start.flatMap { start in end.flatMap { $0 > start ? $0.timeIntervalSince(start) : nil } }
        var used = percent(config["creditUsagePercent"])
        // The unified credits endpoint uses proto3 JSON: an omitted scalar is
        // zero, not unknown. Require the new schema discriminator so legacy or
        // incomplete responses do not turn an unknown allowance into 100% left.
        if used == nil, config["creditUsagePercent"] == nil,
           config["isUnifiedBillingUser"] as? Bool == true,
           ["USAGE_PERIOD_TYPE_WEEKLY", "USAGE_PERIOD_TYPE_MONTHLY"].contains(period?["type"] as? String ?? "") {
            used = 0
        }
        if used == nil, let cap = cent(config["monthlyLimit"]), cap > 0,
           let spent = cent(config["used"]) { used = spent / cap * 100 }
        guard used != nil || end != nil else { throw UsageError.invalidResponse }
        let title = duration.map { $0 >= 6 * 86400 && $0 <= 8 * 86400 ? "Weekly credits" : "Current credits" } ?? "Current credits"
        var windows = [UsageWindow(id: "credits", title: title, usedPercent: used, resetsAt: end, duration: duration)]
        if let cap = cent(config["onDemandCap"]), cap > 0, let spent = cent(config["onDemandUsed"]) {
            windows.append(UsageWindow(id: "on-demand", title: "On-demand", usedPercent: spent / cap * 100, resetsAt: date(config["billingPeriodEnd"]), usedAmount: spent / 100, limitAmount: cap / 100, amountUnit: "USD"))
        }
        for value in config["productUsage"] as? [[String: Any]] ?? [] {
            guard let product = value["product"] as? String, !product.isEmpty, let amount = percent(value["usagePercent"]) else { continue }
            windows.append(UsageWindow(id: "product-" + product, title: product, usedPercent: amount, resetsAt: end, duration: duration))
        }
        let balance = cent(config["prepaidBalance"]).map { String(format: "$%.2f", $0 / 100) }
        var details = ProviderDetails()
        if let used = cent(config["onDemandUsed"]) {
            details.spending.append(.init(id: "grok-on-demand", title: "On-demand usage", used: used / 100, limit: cent(config["onDemandCap"]).flatMap { $0 > 0 ? $0 / 100 : nil }, currency: "USD", resetsAt: date(config["billingPeriodEnd"])))
        }
        return UsageSnapshot(windows: windows, plan: ((config["subscriptionTier"] ?? object["subscriptionTier"]) as? String)?.replacingOccurrences(of: "_", with: " ").capitalized, creditBalance: balance, billingEndsAt: date(config["billingPeriodEnd"]), details: details.isEmpty ? nil : details)
    }
    static func gemini(_ raw: Any) throws -> UsageSnapshot {
        guard let object = raw as? [String: Any], let buckets = object["buckets"] as? [[String: Any]] else { throw UsageError.invalidResponse }
        var seen = Set<String>()
        let windows = buckets.enumerated().compactMap { index, bucket -> UsageWindow? in
            let model = bucket["modelId"] as? String ?? "Quota"
            let token = bucket["tokenType"] as? String ?? ""
            let id = model + ":" + token
            guard seen.insert(id).inserted else { return nil }
            var used: Double?
            if let fraction = percent(bucket["remainingFraction"]), fraction <= 1 { used = (1 - fraction) * 100 }
            // A reported remaining amount of zero establishes exhaustion even if
            // proto JSON omitted the zero-valued fraction. Absence remains unknown.
            else if bucket["remainingFraction"] == nil, bucket["remainingAmount"] as? String == "0" { used = 100 }
            return UsageWindow(id: id, title: model + (token.isEmpty ? "" : " · " + token), usedPercent: used, resetsAt: date(bucket["resetTime"]))
        }
        let amounts = windows.compactMap { window -> RemainingAllowance? in
            guard let bucket = buckets.first(where: { (safeLabel($0["modelId"]) ?? "Quota") + ":" + ($0["tokenType"] as? String ?? "") == window.id }),
                  let value = positiveAmount(bucket["remainingAmount"]), value <= 1_000_000_000_000, value.rounded() == value else { return nil }
            return RemainingAllowance(id: "gemini-" + metricKey([window.id]), title: window.title, remaining: Int(value))
        }
        return UsageSnapshot(windows: windows, remainingAllowances: amounts.isEmpty ? nil : amounts)
    }
    // Microsoft's chatEntitlementService consumes the same quota snapshots.
    // Unlimited categories and categories without allocation are not finite rings.
    static func copilot(_ raw: Any) throws -> UsageSnapshot {
        guard let object = raw as? [String: Any], object["quota_snapshots"] != nil || object["monthly_quotas"] != nil else { throw UsageError.invalidResponse }
        func number(_ value: Any?) -> Double? {
            percent(value) ?? (value as? String).flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }
        func resetDate(_ value: Any?) -> Date? {
            if let parsed = date(value) { return parsed }
            guard let value = value as? String, value.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil else { return nil }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
            return formatter.date(from: value)
        }
        let reset = resetDate(object["quota_reset_date_utc"]) ?? resetDate(object["quota_reset_date"]) ?? resetDate(object["limited_user_reset_date"])
        let snapshots = object["quota_snapshots"] as? [String: [String: Any]] ?? [:]
        let allocations = object["monthly_quotas"] as? [String: Any] ?? [:]
        let legacy = object["limited_user_quotas"] as? [String: Any] ?? [:]
        var windows: [UsageWindow] = []
        for (id, label) in [("premium_interactions", object["token_based_billing"] as? Bool == true ? "AI credits" : "Premium requests"), ("chat", "Chat"), ("completions", "Completions")] {
            if let quota = snapshots[id] {
                guard quota["unlimited"] as? Bool != true, number(quota["entitlement"]) != 0 else { continue }
                var used: Double?
                if let remaining = percent(quota["percent_remaining"]), remaining <= 100 { used = 100 - remaining }
                else if quota["percent_remaining"] == nil, let total = number(quota["entitlement"]), total > 0,
                        let left = number(quota["quota_remaining"]) { used = max(0, 100 - left / total * 100) }
                windows.append(UsageWindow(id: id, title: label, usedPercent: used, resetsAt: date(quota["quota_reset_at"]) ?? reset, usedAmount: number(quota["credits_used"]) ?? number(quota["used"]), limitAmount: number(quota["entitlement"]), amountUnit: label))
            } else if let total = number(allocations[id]), total > 0, let left = number(legacy[id]) {
                windows.append(UsageWindow(id: id, title: label, usedPercent: max(0, 100 - left / total * 100), resetsAt: reset))
            }
        }
        let details = copilotDetails(object, windows: &windows, reset: reset)
        for index in windows.indices {
            if let counter = details?.usage?.first(where: { $0.id == "copilot-" + windows[index].id }) {
                windows[index].usedAmount = counter.used; windows[index].amountUnit = counter.unit
            }
        }
        return UsageSnapshot(windows: windows, plan: object["copilot_plan"] as? String, billingEndsAt: reset, details: details)
    }
    static func cline(_ raw: Any, subject: String) throws -> UsageSnapshot {
        let data = try ClineAuth.unwrap(raw)
        guard data["userId"] as? String == subject else { throw UsageError.wrongAccount }
        guard let balance = data["balance"] as? NSNumber, CFGetTypeID(balance) != CFBooleanGetTypeID(), balance.doubleValue.isFinite else { throw UsageError.invalidResponse }
        // Match Cline's controller (/100) and credit display (/10,000).
        // The live dashboard shows REST balance 500,000 as 0.5000 credits.
        // A balance does not establish a fixed allowance or reset period.
        return UsageSnapshot(creditBalance: String(format: "%.4f", balance.doubleValue / 1_000_000))
    }
    static func cent(_ raw: Any?) -> Double? {
        guard let object = raw as? [String: Any] else { return nil }
        // A present, empty Cent object represents proto3 zero. An absent object
        // remains unknown. The protocol can encode int64 as a decimal string.
        guard let raw = object["val"] else { return object.isEmpty ? 0 : nil }
        return percent(raw) ?? (raw as? String).flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}
