import Foundation

// Public device flow and read-only account APIs used by Moonshot's Kimi Code SDK.
// https://github.com/MoonshotAI/kimi-code/tree/main/packages/oauth/src
enum KimiAuth {
    static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    enum Region: String, CaseIterable, Identifiable {
        case global, mainlandChina
        var id: String { rawValue }
        var title: String { self == .global ? "International" : "Mainland China" }
        var issuer: String { "https://auth.kimi." + (self == .global ? "ai" : "com") }
        var api: String { "https://api.kimi." + (self == .global ? "ai" : "com") + "/coding/v1" }
        var siteHost: String { "www.kimi." + (self == .global ? "ai" : "com") }
        static func matching(_ issuer: String) throws -> Self {
            guard let value = allCases.first(where: { $0.issuer == issuer }) else { throw UsageError.wrongAccount }
            return value
        }
    }
    struct Verification {
        let deviceCode: String
        let url: URL
        let expiresAt: Date
        let interval: TimeInterval
        let region: Region
        let hostID: String
        static func decode(_ raw: [String: Any], region: Region, hostID: String, now: Date = .now) throws -> Self {
            guard let device = raw["device_code"] as? String, !device.isEmpty,
                  let code = raw["user_code"] as? String, code.range(of: "^[A-Z0-9]{4}-[A-Z0-9]{4}$", options: .regularExpression) != nil,
                  let base = raw["verification_uri"] as? String, let baseURL = URL(string: base), validURL(baseURL, region: region), baseURL.query == nil,
                  let expiry = UsageParser.percent(raw["expires_in"]), expiry > 0, expiry <= 3600,
                  let interval = UsageParser.percent(raw["interval"]), interval > 0, interval <= 60 else { throw AuthError.invalidIdentity }
            var url = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
            url.queryItems = [URLQueryItem(name: "user_code", value: code)]
            if let complete = raw["verification_uri_complete"] as? String {
                guard let supplied = URL(string: complete), validURL(supplied, region: region),
                      let fields = URLComponents(url: supplied, resolvingAgainstBaseURL: false)?.queryItems,
                      fields.count == 1, fields.first?.name == "user_code", fields.first?.value == code else { throw AuthError.invalidIdentity }
            }
            return Self(deviceCode: device, url: url.url!, expiresAt: now.addingTimeInterval(expiry), interval: interval, region: region, hostID: hostID)
        }
        private static func validURL(_ url: URL, region: Region) -> Bool {
            url.scheme == "https" && url.host == region.siteHost && url.path == "/code/authorize_device" && url.user == nil && url.password == nil && url.port == nil && url.fragment == nil
        }
    }
    static func formRequest(_ path: String, region: Region, hostID: String, fields: [String: String]) -> URLRequest {
        var request = CopilotAuth.formRequest(region.issuer + path, fields: fields)
        request.setValue("requota_ios", forHTTPHeaderField: "X-Msh-Platform")
        request.setValue("1.0", forHTTPHeaderField: "X-Msh-Version")
        request.setValue(hostID, forHTTPHeaderField: "X-Msh-Device-Id")
        return request
    }
    static func begin(region: Region, hostID: String) async throws -> Verification {
        let request = formRequest("/api/oauth/device_authorization", region: region, hostID: hostID, fields: ["client_id": clientID])
        guard let raw = try await ProviderHTTP.json(request, unauthorizedError: .unavailable) as? [String: Any] else { throw UsageError.invalidResponse }
        return try Verification.decode(raw, region: region, hostID: hostID)
    }
    static func poll(_ attempt: Verification) async throws -> ClineAuth.PollResult {
        let request = formRequest("/api/oauth/token", region: attempt.region, hostID: attempt.hostID,
                                  fields: ["client_id": clientID, "device_code": attempt.deviceCode, "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
        let (data, response) = try await ProviderHTTP.data(request)
        if response.statusCode == 429 { throw UsageError.throttled(ProviderHTTP.retryDate(response.value(forHTTPHeaderField: "Retry-After"))) }
        guard [200, 400].contains(response.statusCode), let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AuthError.unavailable }
        return try ClineAuth.pollResult(raw)
    }
    static func request(_ path: String, region: Region, accessToken: String) throws -> URLRequest {
        guard ["/me", "/usages"].contains(path), !accessToken.isEmpty else { throw UsageError.invalidResponse }
        var request = URLRequest(url: URL(string: region.api + path)!); request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Requota/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        return request
    }
    static func identity(_ raw: Any) throws -> (subject: String, email: String?, plan: String?) {
        guard let profile = raw as? [String: Any], let subject = UsageParser.safeLabel(profile["user_id"]) else { throw AuthError.invalidIdentity }
        return (subject, UsageParser.safeLabel(profile["email"]), UsageParser.safeLabel(profile["user_level_name"]))
    }
    static func validatedCredential(_ raw: [String: Any], profile: Any, region: Region, hostID: String, previous: AccountCredential?, now: Date = .now) throws -> AccountCredential {
        guard let access = raw["access_token"] as? String, !access.isEmpty,
              let refresh = raw["refresh_token"] as? String, !refresh.isEmpty,
              (raw["token_type"] as? String ?? "Bearer").lowercased() == "bearer",
              let expiry = UsageParser.percent(raw["expires_in"]), expiry > 0, expiry <= 86400,
              let scope = raw["scope"] as? String, scope.split(separator: " ").contains("kimi-code") else { throw AuthError.invalidIdentity }
        let identity = try identity(profile)
        if let previous, previous.provider != .kimi || previous.issuer != region.issuer || previous.clientID != clientID || previous.subject != identity.subject || previous.accountID != identity.subject { throw UsageError.wrongAccount }
        return AccountCredential(provider: .kimi, issuer: region.issuer, clientID: clientID, subject: identity.subject, accountID: identity.subject,
                                 hostID: hostID, accessToken: access, refreshToken: refresh, scopes: scope.split(separator: " ").map(String.init), expiresAt: now.addingTimeInterval(expiry), email: identity.email)
    }
    static func credential(_ raw: [String: Any], region: Region, hostID: String, previous: AccountCredential?) async throws -> AccountCredential {
        guard let access = raw["access_token"] as? String, !access.isEmpty else { throw AuthError.invalidIdentity }
        let profile = try await ProviderHTTP.json(request("/me", region: region, accessToken: access), unauthorizedError: .usageAccessDenied)
        return try validatedCredential(raw, profile: profile, region: region, hostID: hostID, previous: previous)
    }
    static func refresh(_ previous: AccountCredential) async throws -> AccountCredential {
        guard previous.provider == .kimi, previous.clientID == clientID, let refresh = previous.refreshToken, !refresh.isEmpty else { throw UsageError.signedOut }
        let region = try Region.matching(previous.issuer)
        let request = formRequest("/api/oauth/token", region: region, hostID: previous.hostID, fields: ["client_id": clientID, "grant_type": "refresh_token", "refresh_token": refresh])
        let (data, response) = try await ProviderHTTP.data(request)
        if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any], ["invalid_grant", "invalid_refresh_token", "refresh_token_expired", "refresh_token_revoked"].contains(raw["error"] as? String ?? "") { throw UsageError.signedOut }
        guard let raw = try ProviderHTTP.decodeJSON(data, response: response, unauthorizedError: .signedOut) as? [String: Any] else { throw UsageError.invalidResponse }
        return try await credential(raw, region: region, hostID: previous.hostID, previous: previous)
    }
}
