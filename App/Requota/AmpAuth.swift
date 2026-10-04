import Foundation

// Amp CLI's WorkOS device grant and read-only JSON RPCs. No access-token
// creation, provider-key linking, thread execution or credit purchase is used.
enum AmpAuth {
    static let issuer = "https://ampcode.com"
    static let authAPI = "https://authapi.ampcode.com"
    static let clientID = "client_01JNSEYM3V0J5AXK4YXNXRXTGP"
    struct Verification {
        let deviceCode: String
        let url: URL
        let expiresAt: Date
        let interval: TimeInterval
        static func decode(_ raw: [String: Any], now: Date = .now) throws -> Self {
            guard let device = raw["device_code"] as? String, !device.isEmpty,
                  let code = raw["user_code"] as? String, code.range(of: "^[A-Z0-9]{4}-[A-Z0-9]{4}$", options: .regularExpression) != nil,
                  let base = raw["verification_uri"] as? String, validURL(URL(string: base)), URL(string: base)?.query == nil,
                  let complete = raw["verification_uri_complete"] as? String, let url = URL(string: complete), validURL(url),
                  let fields = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  fields.count == 1, fields[0].name == "user_code", fields[0].value == code,
                  let expiry = UsageParser.percent(raw["expires_in"]), expiry > 0, expiry <= 1800,
                  let interval = UsageParser.percent(raw["interval"]), interval > 0, interval <= 60 else { throw AuthError.invalidIdentity }
            return Self(deviceCode: device, url: url, expiresAt: now.addingTimeInterval(expiry), interval: interval)
        }
        private static func validURL(_ url: URL?) -> Bool {
            guard let url else { return false }
            return url.scheme == "https" && url.host == "auth.ampcode.com" && url.path == "/device" && url.user == nil && url.password == nil && url.port == nil && url.fragment == nil
        }
    }
    static func begin() async throws -> Verification {
        let config = try await ProviderHTTP.json(URLRequest(url: URL(string: issuer + "/api/auth/oauth-config")!)) as? [String: Any]
        guard config?["clientID"] as? String == clientID, config?["apiURL"] as? String == authAPI else { throw UsageError.invalidResponse }
        let raw = try await ProviderHTTP.json(CopilotAuth.formRequest(authAPI + "/user_management/authorize/device", fields: ["client_id": clientID]))
        guard let object = raw as? [String: Any] else { throw UsageError.invalidResponse }
        return try Verification.decode(object)
    }
    static func poll(_ attempt: Verification) async throws -> ClineAuth.PollResult {
        let request = CopilotAuth.formRequest(authAPI + "/user_management/authenticate", fields: ["client_id": clientID, "device_code": attempt.deviceCode, "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
        let (data, response) = try await ProviderHTTP.data(request)
        if response.statusCode == 429 { throw UsageError.throttled(ProviderHTTP.retryDate(response.value(forHTTPHeaderField: "Retry-After"))) }
        guard [200, 400].contains(response.statusCode), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AuthError.unavailable }
        return try ClineAuth.pollResult(object)
    }
    static func request(_ method: String, token: String) throws -> URLRequest {
        guard ["getUserInfo", "userDisplayBalanceInfo"].contains(method), !token.isEmpty, token.count < 32768,
              token.range(of: "^[A-Za-z0-9._~-]+$", options: .regularExpression) != nil else { throw UsageError.wrongAccount }
        var request = URLRequest(url: URL(string: issuer + "/api/internal?" + method)!)
        request.httpMethod = "POST"; request.timeoutInterval = 25
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Requota/1.0", forHTTPHeaderField: "User-Agent")
        let params: [String: Any] = method == "userDisplayBalanceInfo" ? ["markdown": false, "details": false] : [:]
        request.httpBody = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        return request
    }
    static func unwrap(_ raw: Any) throws -> [String: Any] {
        guard let object = raw as? [String: Any], object["ok"] as? Bool == true, let result = object["result"] as? [String: Any] else { throw UsageError.invalidResponse }
        return result
    }
    static func identity(_ raw: Any) throws -> (subject: String, email: String?) {
        let profile = try unwrap(raw)
        guard let id = profile["id"] as? String, id.range(of: "^[A-Za-z0-9_-]{1,160}$", options: .regularExpression) != nil else { throw AuthError.invalidIdentity }
        return (id, UsageParser.safeLabel(profile["email"]))
    }
    static func credential(_ tokens: [String: Any], previous: AccountCredential?) async throws -> AccountCredential {
        guard let token = tokens["access_token"] as? String else { throw AuthError.invalidIdentity }
        let profile = try await ProviderHTTP.json(request("getUserInfo", token: token))
        return try validatedCredential(tokens, profile: profile, previous: previous)
    }
    static func validatedCredential(_ tokens: [String: Any], profile: Any, previous: AccountCredential?, now: Date = .now) throws -> AccountCredential {
        guard let access = tokens["access_token"] as? String, !access.isEmpty,
              let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty,
              (tokens["token_type"] as? String ?? "Bearer").lowercased() == "bearer",
              let expiry = UsageParser.date(IdentityVerifier.payload(access)?["exp"]), expiry > now else { throw AuthError.invalidIdentity }
        // JWT expiry is only a scheduling hint. Identity comes from the
        // authenticated Amp API and must agree with WorkOS's token response.
        let verified = try identity(profile)
        guard (tokens["user"] as? [String: Any])?["id"] as? String == verified.subject else { throw UsageError.wrongAccount }
        if let previous {
            guard previous.provider == .amp, previous.issuer == issuer, previous.clientID == clientID, previous.subject == verified.subject, previous.accountID == verified.subject else { throw UsageError.wrongAccount }
        }
        return AccountCredential(provider: .amp, issuer: issuer, clientID: clientID, subject: verified.subject, accountID: verified.subject, hostID: previous?.hostID ?? UUID().uuidString, accessToken: access, refreshToken: refresh, scopes: [], expiresAt: min(expiry, now.addingTimeInterval(86400)), email: verified.email)
    }
    static func refresh(_ previous: AccountCredential) async throws -> AccountCredential {
        guard previous.provider == .amp, previous.issuer == issuer, previous.clientID == clientID, let refresh = previous.refreshToken, !refresh.isEmpty else { throw UsageError.signedOut }
        let request = CopilotAuth.formRequest(authAPI + "/user_management/authenticate", fields: ["client_id": clientID, "grant_type": "refresh_token", "refresh_token": refresh])
        let (data, response) = try await ProviderHTTP.data(request)
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], ["invalid_grant", "invalid_refresh_token", "refresh_token_expired", "refresh_token_revoked"].contains(object["error"] as? String ?? "") { throw UsageError.signedOut }
        guard let raw = try ProviderHTTP.decodeJSON(data, response: response) as? [String: Any] else { throw UsageError.invalidResponse }
        return try await credential(raw, previous: previous)
    }
}
