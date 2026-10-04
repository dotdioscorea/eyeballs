import Foundation

// Devin CLI 3000.11.3's PKCE browser flow and Connect API. The REST CLI token
// endpoint returns a different credential; the seat-management exchange below
// is the one that authorizes CLI/Desktop quotas. Each connection is independent.
enum DevinAuth {
    static let issuer = "https://server.codeium.com"
    // Local protocol identifier, not a registered OAuth client ID.
    static let clientID = "requota-devin-cli-pkce-v1"
    static let authorizationEndpoint = "https://app.devin.ai/auth/cli/continue"
    static let service = "/exa.seat_management_pb.SeatManagementService/"

    static func request(_ method: String, token: String? = nil, body: [String: Any]? = nil) throws -> URLRequest {
        guard ["ExchangeDevinCLIPKCECode", "GetUserStatus"].contains(method) else { throw UsageError.invalidResponse }
        var request = URLRequest(url: URL(string: issuer + service + method)!)
        request.httpMethod = "POST"; request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("Requota/1.0", forHTTPHeaderField: "User-Agent")
        if method == "GetUserStatus" {
            guard let token, validToken(token), body == nil else { throw UsageError.wrongAccount }
            // This is the vendor's native header format, not HTTP Basic's
            // username/password encoding. Never send it outside this service.
            request.setValue("Basic " + token + "-" + token, forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["metadata": [
                "apiKey": token, "ideName": "chisel", "ideVersion": "3000.11.3",
                "extensionName": "chisel", "extensionVersion": "3000.11.3", "locale": "en", "platform": "ios"
            ]])
        } else {
            guard token == nil, let body, Set(body.keys) == ["code", "codeVerifier"],
                  let code = body["code"] as? String, !code.isEmpty,
                  let verifier = body["codeVerifier"] as? String, verifier.count >= 43, verifier.count <= 128 else { throw AuthError.invalidCallback }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.count <= 16_384 && token.range(of: "^[A-Za-z0-9._~$-]+$", options: .regularExpression) != nil
    }

    static func identity(_ raw: Any) throws -> (subject: String, accountID: String, email: String?) {
        guard let object = raw as? [String: Any], let user = object["userStatus"] as? [String: Any],
              let subject = user["userId"] as? String, validID(subject),
              let plan = user["planStatus"] as? [String: Any], let info = plan["planInfo"] as? [String: Any],
              let devin = info["devinInfo"] as? [String: Any], let org = devin["orgId"] as? String, validID(org),
              info["isDevin"] as? Bool == true else { throw AuthError.invalidIdentity }
        return (subject, org, UsageParser.safeLabel(user["email"]))
    }
    private static func validID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,160}$", options: .regularExpression) != nil
    }

    static func exchange(callback: URL, attempt: OAuthAttempt) async throws -> AccountCredential {
        guard attempt.provider == .devin, attempt.clientID == clientID else { throw AuthError.invalidCallback }
        let result = try attempt.validateCallback(callback)
        let raw = try await ProviderHTTP.json(request("ExchangeDevinCLIPKCECode", body: ["code": result.code, "codeVerifier": attempt.verifier]), unauthorizedError: .usageAccessDenied)
        guard let object = raw as? [String: Any], let token = object["sessionToken"] as? String, validToken(token),
              object["devinWebappHost"] as? String == "app.devin.ai", object["devinApiUrl"] as? String == "https://api.devin.ai" else { throw AuthError.invalidIdentity }
        let profile = try await ProviderHTTP.json(request("GetUserStatus", token: token), unauthorizedError: .signedOut)
        return try credential(token: token, profile: profile, previous: attempt.previous, hostID: attempt.hostID)
    }
    static func credential(token: String, profile: Any, previous: AccountCredential?, hostID: String) throws -> AccountCredential {
        guard validToken(token) else { throw AuthError.invalidIdentity }
        let verified = try identity(profile)
        if let previous {
            guard previous.provider == .devin, previous.issuer == issuer, previous.clientID == clientID,
                  previous.subject == verified.subject, previous.accountID == verified.accountID else { throw UsageError.wrongAccount }
        }
        // The native exchange reports no expiry or refresh token. Revocation
        // is detected by the authenticated API, rather than an invented timer.
        return AccountCredential(provider: .devin, issuer: issuer, clientID: clientID, subject: verified.subject, accountID: verified.accountID,
                                 hostID: hostID, accessToken: token, scopes: [], expiresAt: .distantFuture, email: verified.email)
    }
    static func refresh(_ previous: AccountCredential) async throws -> AccountCredential {
        guard previous.provider == .devin, previous.issuer == issuer, previous.clientID == clientID else { throw UsageError.wrongAccount }
        let profile = try await ProviderHTTP.json(request("GetUserStatus", token: previous.accessToken), unauthorizedError: .signedOut)
        return try credential(token: previous.accessToken, profile: profile, previous: previous, hostID: previous.hostID)
    }
}
