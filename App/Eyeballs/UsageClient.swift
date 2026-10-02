import Foundation
import CoreFoundation

enum UsageError: LocalizedError {
    case signedOut, unavailable, throttled(Date), invalidResponse, wrongAccount, unsupportedLogin
    var errorDescription: String? {
        switch self {
        case .signedOut: return "Your connection has expired. Sign in again to update usage."
        case .unavailable: return "The provider isn’t sharing usage right now. Your last reading is still available."
        case .throttled(let date): return "The provider asked us to wait. Try again after \(date.formatted(date: .omitted, time: .shortened))."
        case .invalidResponse: return "The provider returned an unrecognized usage response. Your last reading has been kept."
        case .wrongAccount: return "This sign-in belongs to a different account. Add it as a new connection instead."
        case .unsupportedLogin: return "This provider has not enabled a supported sign-in for Eyeballs."
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
        return (data, response)
    }
    static func json(_ request: URLRequest) async throws -> Any {
        let (data, response) = try await data(request)
        if response.statusCode == 401 { throw UsageError.signedOut }
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
        case .grok:
            expectedIssuer = "https://auth.x.ai"
            endpoint = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
        }
        guard credential.issuer == expectedIssuer else { throw UsageError.wrongAccount }
        var request = URLRequest(url: URL(string: endpoint)!)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Eyeballs/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        if provider == .codex, let id = credential.accountID { request.setValue(id, forHTTPHeaderField: "ChatGPT-Account-Id") }
        if provider == .claude { request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta") }
        if provider == .grok { request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth") }
        return request
    }
    static func fetch(account: AgentAccount, credential: AccountCredential) async throws -> UsageSnapshot {
        let raw = try await ProviderHTTP.json(request(provider: account.provider, credential: credential))
        var snapshot: UsageSnapshot
        switch account.provider {
        case .codex: snapshot = try UsageParser.codex(raw)
        case .claude: snapshot = try UsageParser.claude(raw)
        case .grok: snapshot = try UsageParser.grok(raw)
        }
        if account.provider == .codex, let reported = snapshot.identity, let selected = credential.accountID, reported != selected { throw UsageError.wrongAccount }
        snapshot.identity = credential.registrationIdentity
        snapshot.email = credential.email
        snapshot.source = "\(account.provider.name) API"
        return snapshot
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
        for (index, entry) in (object["additional_rate_limits"] as? [[String: Any]] ?? []).enumerated() {
            guard let limit = entry["rate_limit"] as? [String: Any], let window = limit["primary_window"] as? [String: Any] else { continue }
            let label = entry["limit_name"] as? String ?? entry["metered_feature"] as? String ?? "Additional limit"
            windows.append(UsageWindow(id: "additional-\(index)", title: label, usedPercent: percent(window["used_percent"]), resetsAt: date(window["reset_at"]), duration: percent(window["limit_window_seconds"])))
        }
        if let limit = object["code_review_rate_limit"] as? [String: Any], let window = limit["primary_window"] as? [String: Any] {
            windows.append(UsageWindow(id: "code-review", title: "Code review", usedPercent: percent(window["used_percent"]), resetsAt: date(window["reset_at"]), duration: percent(window["limit_window_seconds"])))
        }
        let credits = object["credits"] as? [String: Any]
        let balance = credits?["balance"]
        let creditBalance = (balance as? String) ?? percent(balance).map { String($0) }
        return UsageSnapshot(windows: windows, plan: (object["plan_type"] as? String)?.capitalized, identity: object["account_id"] as? String, creditBalance: creditBalance)
    }
    static func claude(_ raw: Any) throws -> UsageSnapshot {
        guard let object = raw as? [String: Any], object["five_hour"] != nil || object["seven_day"] != nil || object["limits"] != nil else { throw UsageError.invalidResponse }
        var windows: [UsageWindow] = []
        for (key, title, duration) in [("five_hour", "5-hour window", 18000.0), ("seven_day", "Weekly", 604800.0), ("seven_day_opus", "Opus weekly", 604800.0), ("seven_day_sonnet", "Sonnet weekly", 604800.0), ("seven_day_cowork", "Cowork weekly", 604800.0), ("seven_day_oauth_apps", "Connected apps weekly", 604800.0)] {
            guard let value = object[key] as? [String: Any] else { continue }
            windows.append(UsageWindow(id: key, title: title, usedPercent: percent(value["utilization"]), resetsAt: date(value["resets_at"]), duration: duration))
        }
        return UsageSnapshot(windows: windows)
    }
    static func grok(_ raw: Any) throws -> UsageSnapshot {
        guard let object = raw as? [String: Any], let config = object["config"] as? [String: Any] else { throw UsageError.invalidResponse }
        let period = config["currentPeriod"] as? [String: Any]
        let quotaEnd = date(period?["end"])
        let end = quotaEnd ?? date(config["billingPeriodEnd"])
        let start = quotaEnd != nil ? date(period?["start"]) : date(config["billingPeriodStart"])
        let duration = start.flatMap { start in end.flatMap { $0 > start ? $0.timeIntervalSince(start) : nil } }
        var used = percent(config["creditUsagePercent"])
        if used == nil, let cap = percent((config["onDemandCap"] as? [String: Any])?["val"]), cap > 0,
           let spent = percent((config["onDemandUsed"] as? [String: Any])?["val"]) { used = spent / cap * 100 }
        guard used != nil || end != nil else { throw UsageError.invalidResponse }
        let title = duration.map { $0 >= 6 * 86400 && $0 <= 8 * 86400 ? "Weekly credits" : "Current credits" } ?? "Current credits"
        var windows = [UsageWindow(id: "credits", title: title, usedPercent: used, resetsAt: end, duration: duration)]
        for value in config["productUsage"] as? [[String: Any]] ?? [] {
            guard let product = value["product"] as? String, !product.isEmpty, let amount = percent(value["usagePercent"]) else { continue }
            windows.append(UsageWindow(id: "product-" + product, title: product, usedPercent: amount, resetsAt: end, duration: duration))
        }
        return UsageSnapshot(windows: windows, plan: ((config["subscriptionTier"] ?? object["subscriptionTier"]) as? String)?.replacingOccurrences(of: "_", with: " ").capitalized, billingEndsAt: date(config["billingPeriodEnd"]))
    }
}
