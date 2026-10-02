import Foundation

// Public installed-app registration shipped in Google's Gemini CLI. Installed
// apps cannot keep client secrets confidential; this is not a user's API key.
// https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/oauth2.ts
enum GeminiAuth {
    static let clientID = "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com"
    static let installedClientSecret = "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"
    static let issuer = "https://accounts.google.com"
    static let scopes = "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile"
    static func quotaProject(_ response: [String: Any]) throws -> String {
        guard let project = response["cloudaicompanionProject"] as? String, !project.isEmpty else {
            throw GeminiSetupRequired()
        }
        return project
    }
    static func exchange(callback: URL, attempt: OAuthAttempt) async throws -> AccountCredential {
        let verified = try attempt.validateCallback(callback)
        guard attempt.provider == .gemini, verified.clientID == clientID else { throw AuthError.invalidIdentity }
        let raw = try await token(["grant_type": "authorization_code", "code": verified.code,
                                   "redirect_uri": attempt.redirectURI.absoluteString, "code_verifier": attempt.verifier])
        return try await credential(raw, previous: attempt.previous, hostID: attempt.hostID)
    }
    static func refresh(_ previous: AccountCredential) async throws -> AccountCredential {
        guard previous.provider == .gemini, previous.issuer == issuer, previous.clientID == clientID,
              let refresh = previous.refreshToken, !refresh.isEmpty else { throw UsageError.signedOut }
        let raw = try await token(["grant_type": "refresh_token", "refresh_token": refresh])
        return try await credential(raw, previous: previous, hostID: previous.hostID)
    }
    private static func token(_ fields: [String: String]) async throws -> [String: Any] {
        var fields = fields; fields["client_id"] = clientID; fields["client_secret"] = installedClientSecret
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = OpenAIAuth.form(fields)
        let (data, response) = try await ProviderHTTP.data(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageError.invalidResponse }
        if object["error"] as? String == "invalid_grant", fields["grant_type"] == "refresh_token" { throw UsageError.signedOut }
        guard (200..<300).contains(response.statusCode) else { throw AuthError.unavailable }
        return object
    }
    static func identity(_ raw: Any) throws -> (subject: String, email: String?) {
        guard let object = raw as? [String: Any], let id = object["id"] as? String, !id.isEmpty else { throw AuthError.invalidIdentity }
        return (id, object["verified_email"] as? Bool == true ? object["email"] as? String : nil)
    }
    private static func credential(_ raw: [String: Any], previous: AccountCredential?, hostID: String) async throws -> AccountCredential {
        guard let access = raw["access_token"] as? String, !access.isEmpty,
              (raw["token_type"] as? String ?? "bearer").lowercased() == "bearer" else { throw AuthError.invalidIdentity }
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization"); request.timeoutInterval = 20
        let verified = try identity(try await ProviderHTTP.json(request, unauthorizedError: .usageAccessDenied))
        if let previous, previous.subject != verified.subject { throw UsageError.wrongAccount }
        let expiry = UsageParser.percent(raw["expires_in"]).flatMap { $0 > 0 ? Date.now.addingTimeInterval($0) : nil } ?? .now.addingTimeInterval(3600)
        return AccountCredential(provider: .gemini, issuer: issuer, clientID: clientID, subject: verified.subject, accountID: nil,
                                 hostID: hostID, accessToken: access, refreshToken: raw["refresh_token"] as? String ?? previous?.refreshToken,
                                 idToken: nil, scopes: (raw["scope"] as? String ?? scopes).split(separator: " ").map(String.init),
                                 expiresAt: min(expiry, .now.addingTimeInterval(86400)), email: verified.email)
    }
}

struct GeminiSetupRequired: LocalizedError {
    var errorDescription: String? { "Google has not provided a Gemini CLI or Code Assist project for this account. Enable Code Assist for the account, then try again." }
}
