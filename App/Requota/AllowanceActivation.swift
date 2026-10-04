import Foundation

enum ActivationError: LocalizedError {
    case unsupported, permissionRequired, allowanceUnknown, alreadyActive, recentlyAttempted, incomplete
    var errorDescription: String? {
        switch self {
        case .unsupported: return "Activation is not available for this provider."
        case .permissionRequired: return "Allow activation for this account first."
        case .allowanceUnknown: return "An unused included allowance could not be confirmed. No request was sent."
        case .alreadyActive: return "The weekly window is already active."
        case .recentlyAttempted: return "An activation request was already attempted recently."
        case .incomplete: return "The activation request could not be confirmed. Refresh usage before trying again."
        }
    }
}

// The policy is shared; request adapters are enabled only after live validation.
// A 0% reading can be rounded, so completion and a confirmed clock change differ.
enum AllowanceActivation {
    static func supported(_ provider: Provider) -> Bool { provider == .codex || provider == .claude }
    static func permitted(_ credential: AccountCredential) -> Bool {
        guard !credential.accessToken.isEmpty else { return false }
        switch credential.provider {
        case .codex: return credential.issuer == OpenAIAuth.issuer && credential.clientID == OpenAIAuth.codexClientID && credential.accountID?.isEmpty == false
        case .claude: return credential.issuer == ProviderAuth.issuer(.claude) && credential.clientID == ProviderAuth.claudeClientID && credential.scopes.contains("user:inference")
        default: return false
        }
    }
    static func weekly(_ snapshot: UsageSnapshot, provider: Provider) -> UsageWindow? {
        switch provider {
        case .codex: return snapshot.windows.first { ["primary_window", "secondary_window"].contains($0.id) && $0.duration == 604800 }
        case .claude: return snapshot.windows.first { $0.id == "seven_day" }
        default: return nil
        }
    }
    static func candidate(_ snapshot: UsageSnapshot, provider: Provider, now: Date = .now) -> Bool {
        guard supported(provider), now.timeIntervalSince(snapshot.updatedAt) >= -60,
              now.timeIntervalSince(snapshot.updatedAt) <= 120,
              let week = weekly(snapshot, provider: provider), week.safePercent == 0, week.clockReported == true else { return false }
        let plan = snapshot.plan?.lowercased() ?? ""
        // Avoid pay-as-you-go and token-billed workspaces. Plan changes are checked
        // against the new reading, never an account's previously saved tier.
        guard provider == .codex ? (["free", "go", "plus", "pro"].contains(plan) && snapshot.includedUsageAllowed == true) : (plan == "pro" || plan.hasPrefix("max")) else { return false }
        let included = snapshot.windows.filter { $0.id != "code-review" }
        guard !included.isEmpty, included.allSatisfy({ $0.safePercent.map { $0 < 90 } == true }) else { return false }
        // An established deadline needs no request. Missing and freshly moving
        // deadlines are candidates, not a claim that the week has not started.
        if let reset = week.resetsAt { return abs(reset.timeIntervalSince(now) - 604800) <= (provider == .claude ? 3600 : 300) }
        return true
    }
    static func mayAutomaticallyAttempt(_ snapshot: UsageSnapshot, provider: Provider, record: ActivationRecord?, now: Date = .now) -> Bool {
        guard candidate(snapshot, provider: provider, now: now) else { return false }
        guard let record else { return true }
        if now.timeIntervalSince(record.attemptedAt) >= 604800 { return true }
        // Re-arm only after real usage and a subsequent observed reset. A moving
        // unstarted deadline, rounding, relaunch or an uncertain POST cannot re-arm.
        return record.usedSinceAttempt == true && record.lastObservedUsed.map { $0 > 0 } == true
    }
    static func confirmedStart(before: UsageSnapshot, after: UsageSnapshot, provider: Provider, attemptedAt: Date) -> Bool {
        guard let old = weekly(before, provider: provider), old.resetsAt == nil,
              let reset = weekly(after, provider: provider)?.resetsAt else { return false }
        return abs(reset.timeIntervalSince(attemptedAt) - 604800) <= (provider == .claude ? 3600 : 600)
    }
    static func send(_ credential: AccountCredential,
                     transport: (URLRequest) async throws -> (Data, HTTPURLResponse) = ProviderHTTP.data) async throws {
        guard permitted(credential) else { throw ActivationError.permissionRequired }
        let codex = credential.provider == .codex
        let catalogueURL = codex ? "https://chatgpt.com/backend-api/codex/models?client_version=0.159.3" : "https://api.anthropic.com/v1/models"
        var catalogue = request(catalogueURL, credential: credential)
        catalogue.setValue("application/json", forHTTPHeaderField: "Accept")
        let (modelsData, modelsResponse) = try await transport(catalogue)
        guard let object = try ProviderHTTP.decodeJSON(modelsData, response: modelsResponse, unauthorizedError: .usageAccessDenied) as? [String: Any] else { throw UsageError.invalidResponse }
        let model: String
        if codex {
            let models = object["models"] as? [[String: Any]] ?? []
            guard let available = models.first(where: {
                let slug = $0["slug"] as? String ?? ""
                let efforts = $0["supported_reasoning_levels"] as? [[String: Any]] ?? []
                return slug.hasSuffix("-luna") && $0["visibility"] as? String == "list" && efforts.contains { $0["effort"] as? String == "low" }
            }), let slug = available["slug"] as? String else { throw ActivationError.unsupported }
            model = slug
        } else {
            let models = object["data"] as? [[String: Any]] ?? []
            guard let available = models.first(where: { ($0["id"] as? String)?.hasPrefix("claude-haiku-") == true }), let id = available["id"] as? String else { throw ActivationError.unsupported }
            model = id
        }
        var message = request(codex ? "https://chatgpt.com/backend-api/codex/responses" : "https://api.anthropic.com/v1/messages", credential: credential)
        message.httpMethod = "POST"; message.timeoutInterval = 45
        message.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any]
        if codex {
            message.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            body = ["model": model, "instructions": "Reply only OK. No explanation.", "input": [["role": "user", "content": [["type": "input_text", "text": "Reply OK."]]]], "tools": [], "tool_choice": "none", "parallel_tool_calls": false, "reasoning": ["effort": "low"], "store": false, "stream": true]
        } else {
            body = ["model": model, "max_tokens": 8, "messages": [["role": "user", "content": "Reply only OK."]]]
        }
        message.httpBody = try JSONSerialization.data(withJSONObject: body)
        try Task.checkCancellation()
        // Deliberately no retry of POST: transport failure may follow consumption.
        let (data, response) = try await transport(message)
        if response.statusCode == 401 || response.statusCode == 403 { throw UsageError.usageAccessDenied }
        if response.statusCode == 429 { throw UsageError.throttled(ProviderHTTP.retryDate(response.value(forHTTPHeaderField: "Retry-After"))) }
        guard (200..<300).contains(response.statusCode), data.count < 1_000_000 else { throw ActivationError.incomplete }
        if codex {
            guard completedStream(data) else { throw ActivationError.incomplete }
        } else {
            guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  ["end_turn", "max_tokens"].contains(result["stop_reason"] as? String ?? "") else { throw ActivationError.incomplete }
        }
    }
    static func completedStream(_ data: Data) -> Bool {
        var completed = false
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) where line.hasPrefix("data: ") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any] else { continue }
            if ["response.failed", "response.incomplete", "error"].contains(object["type"] as? String ?? "") { return false }
            if object["type"] as? String == "response.completed" { completed = (object["response"] as? [String: Any])?["status"] as? String == "completed" }
        }
        return completed
    }
    private static func request(_ url: String, credential: AccountCredential) -> URLRequest {
        var result = URLRequest(url: URL(string: url)!)
        result.timeoutInterval = 20
        result.setValue("Bearer " + credential.accessToken, forHTTPHeaderField: "Authorization")
        result.setValue("Requota/1.0", forHTTPHeaderField: "User-Agent")
        if credential.provider == .codex {
            result.setValue("requota", forHTTPHeaderField: "originator")
            result.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        } else {
            result.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            result.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        return result
    }
}
