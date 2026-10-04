import Foundation

// Cline's SDK WorkOS device flow, followed by its native token registration.
// https://github.com/cline/cline/blob/main/sdk/packages/core/src/auth/cline.ts
enum ClineAuth {
    static let issuer = "https://api.cline.bot"
    static let clientID = "client_01K3A541FN8TA3EPPHTD2325AR"
    struct Verification {
        let deviceCode: String
        let userCode: String
        let url: URL
        let expiresAt: Date
        let interval: TimeInterval
        static func decode(_ raw: [String: Any], now: Date = .now) throws -> Self {
            guard let device = raw["device_code"] as? String, !device.isEmpty,
                  let code = raw["user_code"] as? String, code.range(of: "^[A-Z0-9]{4}-[A-Z0-9]{4}$", options: .regularExpression) != nil,
                  let base = raw["verification_uri"] as? String, let baseURL = URL(string: base),
                  validURL(baseURL), baseURL.query == nil,
                  let expiry = UsageParser.percent(raw["expires_in"]), expiry > 0, expiry <= 1800,
                  let interval = UsageParser.percent(raw["interval"]), interval > 0, interval <= 60 else { throw AuthError.invalidIdentity }
            var url = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
            url.queryItems = [URLQueryItem(name: "user_code", value: code)]
            if let complete = raw["verification_uri_complete"] as? String {
                guard let supplied = URL(string: complete), validURL(supplied),
                      let fields = URLComponents(url: supplied, resolvingAgainstBaseURL: false)?.queryItems,
                      fields.count == 1, fields.first?.name == "user_code", fields.first?.value == code else { throw AuthError.invalidIdentity }
            }
            return Self(deviceCode: device, userCode: code, url: url.url!, expiresAt: now.addingTimeInterval(expiry), interval: interval)
        }
        private static func validURL(_ url: URL) -> Bool {
            url.scheme == "https" && url.host == "authkit.cline.bot" && url.path == "/device" && url.user == nil && url.password == nil && url.port == nil && url.fragment == nil
        }
    }
    enum PollResult { case pending, slowDown, tokens([String: Any]) }
    static func pollResult(_ raw: [String: Any]) throws -> PollResult {
        switch raw["error"] as? String {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "access_denied": throw AuthError.cancelled
        case "expired_token", "token_expired": throw AuthError.timedOut
        case .some: throw AuthError.unavailable
        case nil:
            guard let access = raw["access_token"] as? String, !access.isEmpty,
                  let refresh = raw["refresh_token"] as? String, !refresh.isEmpty,
                  (raw["token_type"] as? String ?? "Bearer").lowercased() == "bearer" else { throw AuthError.invalidIdentity }
            return .tokens(raw)
        }
    }
    static func begin() async throws -> Verification {
        let request = CopilotAuth.formRequest("https://api.workos.com/user_management/authorize/device", fields: ["client_id": clientID])
        guard let raw = try await ProviderHTTP.json(request, unauthorizedError: .unavailable) as? [String: Any] else { throw UsageError.invalidResponse }
        return try Verification.decode(raw)
    }
    static func poll(_ attempt: Verification) async throws -> PollResult {
        let request = CopilotAuth.formRequest("https://api.workos.com/user_management/authenticate", fields: ["client_id": clientID, "device_code": attempt.deviceCode, "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
        let (data, response) = try await ProviderHTTP.data(request)
        if response.statusCode == 429 { throw UsageError.throttled(ProviderHTTP.retryDate(response.value(forHTTPHeaderField: "Retry-After"))) }
        guard [200, 400].contains(response.statusCode), let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AuthError.unavailable }
        return try pollResult(raw)
    }
    static func apiRequest(_ path: String, accessToken: String? = nil, body: [String: String]? = nil) throws -> URLRequest {
        let balance = path.range(of: "^/api/v1/users/[A-Za-z0-9_-]{1,160}/balance$", options: .regularExpression) != nil
        guard ["/api/v1/users/me", "/api/v1/auth/register", "/api/v1/auth/refresh"].contains(path) || balance else { throw UsageError.invalidResponse }
        var request = URLRequest(url: URL(string: issuer + path)!); request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Requota/1.0", forHTTPHeaderField: "User-Agent")
        if let accessToken { request.setValue("Bearer " + (accessToken.hasPrefix("workos:") ? accessToken : "workos:" + accessToken), forHTTPHeaderField: "Authorization") }
        if let body {
            guard path.hasPrefix("/api/v1/auth/") else { throw UsageError.invalidResponse }
            request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else { guard accessToken != nil, !path.hasPrefix("/api/v1/auth/") else { throw UsageError.invalidResponse } }
        return request
    }
    static func unwrap(_ raw: Any) throws -> [String: Any] {
        guard let raw = raw as? [String: Any], raw["success"] as? Bool == true, let data = raw["data"] as? [String: Any] else { throw UsageError.invalidResponse }
        return data
    }
    static func identity(_ raw: Any) throws -> (id: String, email: String?) {
        let data = try unwrap(raw)
        guard let id = data["id"] as? String, id.range(of: "^[A-Za-z0-9_-]{1,160}$", options: .regularExpression) != nil else { throw AuthError.invalidIdentity }
        return (id, data["email"] as? String)
    }
    static func register(_ tokens: [String: Any], previous: AccountCredential?) async throws -> AccountCredential {
        guard let access = tokens["access_token"] as? String, !access.isEmpty, let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty else { throw AuthError.invalidIdentity }
        let raw = try await ProviderHTTP.json(apiRequest("/api/v1/auth/register", body: ["accessToken": access, "refreshToken": refresh]), unauthorizedError: .usageAccessDenied)
        return try await credential(raw, previous: previous)
    }
    static func credential(_ raw: Any, previous: AccountCredential?) async throws -> AccountCredential {
        let data = try unwrap(raw)
        guard let access = data["accessToken"] as? String, !access.isEmpty,
              let refresh = data["refreshToken"] as? String, !refresh.isEmpty,
              let expiry = UsageParser.date(data["expiresAt"]), expiry > .now,
              (data["tokenType"] as? String ?? "Bearer").lowercased() == "bearer" else { throw AuthError.invalidIdentity }
        let profile = try await ProviderHTTP.json(apiRequest("/api/v1/users/me", accessToken: access), unauthorizedError: .usageAccessDenied)
        return try validatedCredential(raw, profile: profile, previous: previous)
    }
    static func validatedCredential(_ raw: Any, profile rawProfile: Any, previous: AccountCredential?, now: Date = .now) throws -> AccountCredential {
        let data = try unwrap(raw)
        guard let access = data["accessToken"] as? String, !access.isEmpty,
              let refresh = data["refreshToken"] as? String, !refresh.isEmpty,
              let expiry = UsageParser.date(data["expiresAt"]), expiry > now,
              (data["tokenType"] as? String ?? "Bearer").lowercased() == "bearer" else { throw AuthError.invalidIdentity }
        let profile = try identity(rawProfile)
        if let supplied = (data["userInfo"] as? [String: Any])?["clineUserId"] as? String, supplied != profile.id { throw UsageError.wrongAccount }
        if let previous, previous.provider != .cline || previous.issuer != issuer || previous.clientID != clientID || previous.subject != profile.id { throw UsageError.wrongAccount }
        return AccountCredential(provider: .cline, issuer: issuer, clientID: clientID, subject: profile.id, accountID: profile.id, hostID: previous?.hostID ?? UUID().uuidString,
                                 accessToken: access, refreshToken: refresh, scopes: [], expiresAt: min(expiry, now.addingTimeInterval(60 * 86400)), email: profile.email)
    }
    static func refresh(_ previous: AccountCredential) async throws -> AccountCredential {
        guard previous.provider == .cline, previous.issuer == issuer, previous.clientID == clientID,
              let refresh = previous.refreshToken, !refresh.isEmpty else { throw UsageError.signedOut }
        let request = try apiRequest("/api/v1/auth/refresh", body: ["refreshToken": refresh, "grantType": "refresh_token"])
        let (data, response) = try await ProviderHTTP.data(request)
        let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if !(200..<300).contains(response.statusCode), let raw {
            let code = raw["error"] as? String ?? (raw["error"] as? [String: Any])?["code"] as? String
            if ["invalid_grant", "invalid_refresh_token", "refresh_token_expired", "refresh_token_revoked"].contains(code ?? "") { throw UsageError.signedOut }
        }
        return try await credential(ProviderHTTP.decodeJSON(data, response: response, unauthorizedError: .usageAccessDenied), previous: previous)
    }
}
