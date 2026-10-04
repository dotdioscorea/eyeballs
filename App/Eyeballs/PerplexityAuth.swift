import Foundation

// Perplexity's passwordless email flow. Each connection owns its session; no
// browser cookies are read and no shared cookie store is used.
enum PerplexityAuth {
    static let issuer = "https://www.perplexity.ai"
    static let clientID = "requota-email-code-v1"
    static let cookieName = "__Secure-next-auth.session-token"
    struct Attempt {
        let email: String
        let csrfCookie: String
        let startedAt: Date
    }
    enum LoginError: LocalizedError {
        case email, code
        var errorDescription: String? { self == .email ? "Enter a valid email address." : "The code is incorrect or expired. Request a new code and try again." }
    }
    static func email(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 254, value.range(of: "^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\\.[A-Za-z]{2,}$", options: .regularExpression) != nil else { throw LoginError.email }
        return value
    }
    static func safeCookie(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 24_000 && value.utf8.allSatisfy { $0 > 32 && $0 < 127 && ![34, 44, 59, 92].contains($0) }
    }
    static func validSessionToken(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return safeCookie(value) && value.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil && parts.count == 5 && !parts[0].isEmpty && !parts[2].isEmpty && !parts[3].isEmpty && !parts[4].isEmpty
    }
    static func request(_ path: String, cookie: String? = nil) throws -> URLRequest {
        guard ["/api/auth/csrf", "/api/auth/signin/email", "/api/auth/callback/email", "/api/auth/session", "/api/user", "/rest/rate-limit/status"].contains(path) else { throw UsageError.invalidResponse }
        var request = URLRequest(url: URL(string: issuer + path)!); request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Requota/1.0", forHTTPHeaderField: "User-Agent")
        if let cookie { guard safeCookie(cookie) else { throw AuthError.invalidIdentity }; request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        return request
    }
    static func sessionRequest(_ path: String, credential: AccountCredential) throws -> URLRequest {
        guard credential.provider == .perplexity, credential.issuer == issuer, credential.clientID == clientID,
              ["/api/auth/session", "/api/user", "/rest/rate-limit/status"].contains(path), validSessionToken(credential.accessToken) else { throw UsageError.wrongAccount }
        return try request(path, cookie: cookieName + "=" + credential.accessToken)
    }
    static func cookies(_ response: HTTPURLResponse) -> [HTTPCookie] {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { $0[String(describing: $1.key)] = String(describing: $1.value) }
        return HTTPCookie.cookies(withResponseHeaderFields: headers, for: URL(string: issuer)!).filter {
            ["www.perplexity.ai", ".perplexity.ai", "perplexity.ai"].contains($0.domain) && $0.path == "/" && safeCookie($0.value)
        }
    }
    static func token(_ response: HTTPURLResponse, fallback: String? = nil) throws -> String {
        let values = cookies(response).filter { $0.isSecure }
        let found = values.first { $0.name == cookieName }?.value
        guard let value = found ?? fallback, validSessionToken(value) else { throw AuthError.invalidIdentity }
        return value
    }
    static func begin(email value: String) async throws -> Attempt {
        let email = try Self.email(value)
        let (data, response) = try await ProviderHTTP.data(request("/api/auth/csrf"))
        guard let raw = try ProviderHTTP.decodeJSON(data, response: response) as? [String: Any], let csrf = raw["csrfToken"] as? String, safeCookie(csrf),
              let cookie = cookies(response).first(where: { ["next-auth.csrf-token", "__Host-next-auth.csrf-token"].contains($0.name) }) else { throw AuthError.invalidIdentity }
        var send = try request("/api/auth/signin/email", cookie: cookie.name + "=" + cookie.value)
        send.httpMethod = "POST"; send.setValue("application/json", forHTTPHeaderField: "Content-Type")
        send.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "csrfToken": csrf, "callbackUrl": issuer + "/", "json": "true"])
        guard let result = try await ProviderHTTP.json(send, unauthorizedError: .usageAccessDenied) as? [String: Any],
              let value = result["url"] as? String, let url = URL(string: value), url.scheme == "https", url.host == "www.perplexity.ai", url.path == "/auth/verify-request",
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil else { throw UsageError.invalidResponse }
        return Attempt(email: email, csrfCookie: cookie.name + "=" + cookie.value, startedAt: .now)
    }
    static func verificationRequest(_ attempt: Attempt, code: String, now: Date = .now) throws -> URLRequest {
        guard code.count == 6, code.range(of: "^[0-9]{6}$", options: .regularExpression) != nil, now.timeIntervalSince(attempt.startedAt) >= 0, now.timeIntervalSince(attempt.startedAt) <= 5 * 60 else { throw LoginError.code }
        var request = try request("/api/auth/callback/email", cookie: attempt.csrfCookie)
        var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "callbackUrl", value: issuer + "/"), URLQueryItem(name: "email", value: attempt.email), URLQueryItem(name: "token", value: code)]
        request.url = url.url
        return request
    }
    static func complete(_ attempt: Attempt, code: String, previous: AccountCredential?) async throws -> AccountCredential {
        let (_, response) = try await ProviderHTTP.data(verificationRequest(attempt, code: code))
        if response.statusCode == 429 { throw UsageError.throttled(ProviderHTTP.retryDate(response.value(forHTTPHeaderField: "Retry-After"))) }
        guard [302, 303].contains(response.statusCode), let location = response.value(forHTTPHeaderField: "Location"),
              let redirect = URL(string: location, relativeTo: URL(string: issuer)!)?.absoluteURL,
              redirect.scheme == "https", redirect.host == "www.perplexity.ai", redirect.path == "/", redirect.user == nil, redirect.password == nil, redirect.port == nil else { throw LoginError.code }
        let provisional = AccountCredential(provider: .perplexity, issuer: issuer, clientID: clientID, subject: previous?.subject ?? "", accountID: previous?.accountID,
                                            hostID: previous?.hostID ?? UUID().uuidString, accessToken: try token(response), scopes: [], expiresAt: .now, email: attempt.email)
        return try await renew(provisional, previous: previous, expectedEmail: attempt.email)
    }
    static func validated(_ raw: Any, token: String, previous: AccountCredential?, expectedEmail: String?, hostID: String, now: Date = .now) throws -> AccountCredential {
        guard let raw = raw as? [String: Any], let user = raw["user"] as? [String: Any] else { throw UsageError.signedOut }
        guard let id = UsageParser.safeLabel(user["id"]), let email = user["email"] as? String,
              let expiry = UsageParser.date(raw["expires"]), expiry > now, expiry <= now.addingTimeInterval(60 * 86400), validSessionToken(token), (try? Self.email(email)) != nil else { throw AuthError.invalidIdentity }
        if let expectedEmail, email.lowercased() != expectedEmail.lowercased() { throw UsageError.wrongAccount }
        if let previous, previous.provider != .perplexity || previous.issuer != issuer || previous.clientID != clientID || previous.subject != id || previous.accountID != id { throw UsageError.wrongAccount }
        return AccountCredential(provider: .perplexity, issuer: issuer, clientID: clientID, subject: id, accountID: id, hostID: hostID, accessToken: token, scopes: [], expiresAt: expiry, email: email)
    }
    private static func renew(_ credential: AccountCredential, previous: AccountCredential?, expectedEmail: String?) async throws -> AccountCredential {
        let (data, response) = try await ProviderHTTP.data(sessionRequest("/api/auth/session", credential: credential))
        let raw = try ProviderHTTP.decodeJSON(data, response: response)
        return try validated(raw, token: token(response, fallback: credential.accessToken), previous: previous, expectedEmail: expectedEmail, hostID: credential.hostID)
    }
    static func refresh(_ credential: AccountCredential) async throws -> AccountCredential {
        try await renew(credential, previous: credential, expectedEmail: nil)
    }
}
