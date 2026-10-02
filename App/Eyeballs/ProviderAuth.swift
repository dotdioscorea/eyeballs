import Foundation

// Native public-client protocols used by the installed CLIs. No password, cookie,
// inference request or CLI credential import is involved in these connections.
enum ProviderAuth {
    static let claudeClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let grokClientID = "b1a00492-073a-47ea-816f-4c329264a828"
    static func clientID(_ provider: Provider) -> String {
        switch provider { case .codex: return OpenAIAuth.codexClientID; case .claude: return claudeClientID; case .grok: return grokClientID; case .gemini: return GeminiAuth.clientID }
    }
    static func issuer(_ provider: Provider) -> String {
        switch provider { case .codex: return OpenAIAuth.issuer; case .claude: return "https://platform.claude.com"; case .grok: return "https://auth.x.ai"; case .gemini: return GeminiAuth.issuer }
    }
    static func authorizationEndpoint(_ provider: Provider) -> String {
        switch provider { case .codex: return OpenAIAuth.issuer + "/oauth/authorize"; case .claude: return "https://claude.com/cai/oauth/authorize"; case .grok: return issuer(provider) + "/oauth2/authorize"; case .gemini: return "https://accounts.google.com/o/oauth2/v2/auth" }
    }
    static func scopes(_ provider: Provider) -> String {
        switch provider {
        case .codex: return "openid profile email offline_access"
        case .claude: return "user:profile"
        // The Grok public client authorizes billing through its CLI proxy scopes.
        // It does not allow a separate billing:read scope.
        case .grok: return "openid profile email offline_access grok-cli:access api:access"
        case .gemini: return GeminiAuth.scopes
        }
    }
    static func exchange(callback: URL, attempt: OAuthAttempt) async throws -> AccountCredential {
        if attempt.provider == .gemini { return try await GeminiAuth.exchange(callback: callback, attempt: attempt) }
        if attempt.provider == .codex { return try await OpenAIAuth.exchange(callback: callback, attempt: attempt) }
        let verified = try attempt.validateCallback(callback)
        guard verified.clientID == clientID(attempt.provider) else { throw AuthError.invalidIdentity }
        var fields = ["grant_type": "authorization_code", "client_id": verified.clientID, "code": verified.code,
                      "code_verifier": attempt.verifier, "redirect_uri": attempt.redirectURI.absoluteString]
        if attempt.provider == .claude { fields["state"] = attempt.state }
        let raw = try await tokenRequest(provider: attempt.provider, fields: fields)
        return try await credential(raw, provider: attempt.provider, previous: attempt.previous, hostID: attempt.hostID, nonce: attempt.nonce)
    }
    static func refresh(_ previous: AccountCredential) async throws -> AccountCredential {
        if previous.provider == .gemini { return try await GeminiAuth.refresh(previous) }
        if previous.provider == .codex { return try await OpenAIAuth.refresh(previous) }
        guard previous.issuer == issuer(previous.provider), previous.clientID == clientID(previous.provider),
              let refresh = previous.refreshToken, !refresh.isEmpty else { throw UsageError.signedOut }
        var fields = ["grant_type": "refresh_token", "client_id": previous.clientID, "refresh_token": refresh]
        if previous.provider == .claude { fields["scope"] = scopes(.claude) }
        if previous.provider == .grok, let principal = previous.accountID?.split(separator: ":", maxSplits: 1), principal.count == 2 {
            fields["principal_type"] = String(principal[0]); fields["principal_id"] = String(principal[1])
        }
        let raw = try await tokenRequest(provider: previous.provider, fields: fields)
        return try await credential(raw, provider: previous.provider, previous: previous, hostID: previous.hostID, nonce: nil)
    }
    private static func tokenRequest(provider: Provider, fields: [String: String]) async throws -> [String: Any] {
        let endpoint = provider == .claude ? issuer(provider) + "/v1/oauth/token" : issuer(provider) + "/oauth2/token"
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("Eyeballs/1.0", forHTTPHeaderField: "User-Agent")
        if provider == .claude {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        } else {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = OpenAIAuth.form(fields)
        }
        let (data, response) = try await ProviderHTTP.data(request)
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AuthError.unavailable }
        guard (200..<300).contains(response.statusCode) else {
            let error = raw["error"] as? String ?? (raw["error"] as? [String: Any])?["type"] as? String
            if fields["grant_type"] == "refresh_token", ["invalid_grant", "invalid_refresh_token", "refresh_token_expired", "refresh_token_revoked"].contains(error ?? "") { throw UsageError.signedOut }
            if response.statusCode == 429 { throw UsageError.throttled(ProviderHTTP.retryDate(response.value(forHTTPHeaderField: "Retry-After"))) }
            throw AuthError.unavailable
        }
        return raw
    }
    private static func credential(_ raw: [String: Any], provider: Provider, previous: AccountCredential?, hostID: String, nonce: String?) async throws -> AccountCredential {
        guard let access = raw["access_token"] as? String, !access.isEmpty,
              (raw["token_type"] as? String ?? "bearer").lowercased() == "bearer" else { throw AuthError.invalidIdentity }
        let subject: String
        let accountID: String?
        let email: String?
        if provider == .claude {
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
            request.timeoutInterval = 20
            request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("Eyeballs/1.0", forHTTPHeaderField: "User-Agent")
            let identity = try claudeIdentity(try await ProviderHTTP.json(request, unauthorizedError: .usageAccessDenied))
            subject = identity.subject; accountID = identity.accountID; email = identity.email
        } else {
            let jwks = try await ProviderHTTP.json(URLRequest(url: URL(string: issuer(.grok) + "/.well-known/jwks.json")!), unauthorizedError: .unavailable)
            // xAI uses the same issuer, audience and ES256 keys for the access token.
            // Verify its principal, rather than trusting a decoded JWT payload.
            let claims = try IdentityVerifier.verify(access, jwks: jwks, issuer: issuer(.grok), audience: grokClientID, nonce: nil, algorithm: "ES256")
            let identity = try grokIdentity(claims)
            subject = identity.subject; accountID = identity.accountID
            if let idToken = raw["id_token"] as? String {
                let oidc = try IdentityVerifier.verify(idToken, jwks: jwks, issuer: issuer(.grok), audience: grokClientID, nonce: nonce, algorithm: "ES256")
                guard oidc["sub"] as? String == subject else { throw AuthError.invalidIdentity }
                email = oidc["email"] as? String ?? previous?.email
            } else {
                // Team consent deliberately omits an OIDC ID token. Its signed
                // access token, PKCE and state still establish the selected team.
                guard nonce == nil || identity.principalType == "Team" else { throw AuthError.invalidIdentity }
                email = previous?.email
            }
        }
        if let previous, previous.subject != subject || previous.accountID != accountID { throw UsageError.wrongAccount }
        let expiry = UsageParser.percent(raw["expires_in"]).flatMap { $0 > 0 ? Date.now.addingTimeInterval($0) : nil }
            ?? IdentityVerifier.payload(access).flatMap { UsageParser.date($0["exp"]) } ?? .now.addingTimeInterval(3600)
        guard expiry > .now else { throw UsageError.signedOut }
        return AccountCredential(provider: provider, issuer: issuer(provider), clientID: clientID(provider), subject: subject, accountID: accountID,
                                 hostID: hostID, accessToken: access, refreshToken: raw["refresh_token"] as? String ?? previous?.refreshToken,
                                 idToken: raw["id_token"] as? String ?? previous?.idToken,
                                 scopes: (raw["scope"] as? String ?? scopes(provider)).split(separator: " ").map(String.init),
                                 expiresAt: min(expiry, .now.addingTimeInterval(30 * 86400)), email: email)
    }
    static func claudeIdentity(_ raw: Any) throws -> (subject: String, accountID: String, email: String?) {
        guard let raw = raw as? [String: Any], let account = raw["account"] as? [String: Any],
              let subject = account["uuid"] as? String, !subject.isEmpty,
              let organization = raw["organization"] as? [String: Any], let id = organization["uuid"] as? String, !id.isEmpty else { throw AuthError.invalidIdentity }
        return (subject, id, account["email"] as? String)
    }
    static func grokIdentity(_ verifiedClaims: [String: Any]) throws -> (subject: String, accountID: String, principalType: String) {
        guard let subject = verifiedClaims["sub"] as? String, !subject.isEmpty,
              let type = (verifiedClaims["principal_type"] ?? verifiedClaims["principalType"]) as? String, ["User", "Team"].contains(type),
              let id = (verifiedClaims["principal_id"] ?? verifiedClaims["principalId"]) as? String, !id.isEmpty, !id.contains(":") else { throw AuthError.invalidIdentity }
        return (subject, type + ":" + id, type)
    }
}

struct LoopbackReply {
    let preflight: Bool
    let callback: URL?
    let response: String
}

enum LoopbackRequest {
    static func reply(method: String, target: String, headers: [String: String], attempt: OAuthAttempt) throws -> LoopbackReply {
        guard target.hasPrefix("/"), !target.hasPrefix("//"),
              let url = URL(string: "http://\(attempt.redirectURI.host!):\(attempt.redirectURI.port!)" + target),
              url.path == attempt.redirectURI.path else { throw AuthError.invalidCallback }
        var cors = ""
        if let origin = headers["origin"] {
            guard attempt.provider == .grok, origin == "https://accounts.x.ai" else { throw AuthError.invalidCallback }
            cors = "Access-Control-Allow-Origin: https://accounts.x.ai\r\nVary: Origin\r\n"
        }
        if method == "OPTIONS" {
            guard attempt.provider == .grok, headers["origin"] == "https://accounts.x.ai",
                  headers["access-control-request-method"] == "GET", headers["access-control-request-headers"] == nil else { throw AuthError.invalidCallback }
            cors += "Access-Control-Allow-Methods: GET\r\nAccess-Control-Allow-Private-Network: true\r\n"
            return LoopbackReply(preflight: true, callback: nil, response: "HTTP/1.1 204 No Content\r\n\(cors)Content-Length: 0\r\nConnection: close\r\n\r\n")
        }
        guard method == "GET" else { throw AuthError.invalidCallback }
        do { _ = try attempt.validateCallback(url) } catch AuthError.cancelled { /* Validated denial returns to the app. */ }
        let body = "<!doctype html><meta name=viewport content='width=device-width'><title>Eyeballs</title><p>You can return to Eyeballs.</p>"
        return LoopbackReply(preflight: false, callback: url, response: "HTTP/1.1 200 OK\r\n\(cors)Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
    }
}
