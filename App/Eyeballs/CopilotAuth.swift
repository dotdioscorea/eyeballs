import Foundation
import CoreFoundation

// Public native client registration in Microsoft's GitHub authentication extension.
// https://github.com/microsoft/vscode/tree/main/extensions/github-authentication
enum CopilotAuth {
    static let clientID = "01ab8ac9400c4e429b23"
    static let issuer = "https://github.com"
    struct Verification {
        var deviceCode: String
        var userCode: String
        var url: URL
        var expiresAt: Date
        var interval: TimeInterval
        static func decode(_ value: [String: Any], now: Date = .now) throws -> Self {
            guard let device = value["device_code"] as? String, !device.isEmpty,
                  let code = value["user_code"] as? String, code.range(of: "^[A-Z0-9]{4}-[A-Z0-9]{4}$", options: .regularExpression) != nil,
                  let address = value["verification_uri"] as? String, let url = URL(string: address),
                  url.scheme == "https", url.host == "github.com", url.path == "/login/device",
                  url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
                  let expiry = UsageParser.percent(value["expires_in"]), expiry > 0, expiry <= 1800,
                  let interval = UsageParser.percent(value["interval"]), interval > 0, interval <= 60 else { throw AuthError.invalidIdentity }
            return Self(deviceCode: device, userCode: code, url: url, expiresAt: now.addingTimeInterval(expiry), interval: interval)
        }
    }
    enum PollResult { case pending, slowDown, token([String: Any]) }
    static func pollResult(_ value: [String: Any]) throws -> PollResult {
        switch value["error"] as? String {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "access_denied": throw AuthError.cancelled
        case "expired_token", "token_expired": throw AuthError.timedOut
        case .some: throw AuthError.unavailable
        case nil:
            guard let token = value["access_token"] as? String, !token.isEmpty else { throw AuthError.invalidIdentity }
            return .token(value)
        }
    }
    static func formRequest(_ url: String, fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!); request.httpMethod = "POST"; request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Eyeballs/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = OpenAIAuth.form(fields)
        return request
    }
    static func json(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await ProviderHTTP.data(request)
        guard (200..<300).contains(response.statusCode),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AuthError.unavailable }
        return value
    }
    static func begin() async throws -> Verification {
        try Verification.decode(try await json(formRequest(issuer + "/login/device/code", fields: ["client_id": clientID, "scope": "read:user"])))
    }
    static func poll(_ verification: Verification) async throws -> PollResult {
        try pollResult(try await json(formRequest(issuer + "/login/oauth/access_token", fields: ["client_id": clientID, "device_code": verification.deviceCode, "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])))
    }
    static func identity(_ raw: Any) throws -> String {
        guard let value = raw as? [String: Any], let id = value["id"] as? NSNumber,
              CFGetTypeID(id) != CFBooleanGetTypeID(), id.doubleValue > 0, id.doubleValue.isFinite,
              id.doubleValue.rounded(.towardZero) == id.doubleValue,
              let login = value["login"] as? String, !login.isEmpty else { throw AuthError.invalidIdentity }
        return id.stringValue
    }
    static func credential(_ raw: [String: Any], previous: AccountCredential?) async throws -> AccountCredential {
        guard let access = raw["access_token"] as? String, !access.isEmpty,
              (raw["token_type"] as? String ?? "bearer").lowercased() == "bearer" else { throw AuthError.invalidIdentity }
        guard let scope = raw["scope"] as? String else { throw AuthError.invalidIdentity }
        let scopes = scope.split { $0 == "," || $0 == " " }.map(String.init)
        // Never retain repository access for a usage-only connection.
        guard Set(scopes).isSubset(of: ["read:user", "user:email"]) else { throw UsageError.usageAccessDenied }
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
        request.setValue("Eyeballs/1.0", forHTTPHeaderField: "User-Agent"); request.timeoutInterval = 20
        let rawIdentity = try await ProviderHTTP.json(request, unauthorizedError: .usageAccessDenied)
        let subject = try identity(rawIdentity)
        if let previous, previous.subject != subject { throw UsageError.wrongAccount }
        let expiry: Date
        if let reported = raw["expires_in"] {
            guard let seconds = UsageParser.percent(reported), seconds > 0 else { throw AuthError.invalidIdentity }
            expiry = Date.now.addingTimeInterval(seconds)
        } else { expiry = .distantFuture }
        guard expiry > .now else { throw UsageError.signedOut }
        return AccountCredential(provider: .copilot, issuer: issuer, clientID: clientID, subject: subject, accountID: nil,
                                 hostID: OpenAIAuth.hostID, accessToken: access, refreshToken: raw["refresh_token"] as? String ?? previous?.refreshToken,
                                 idToken: nil, scopes: scopes, expiresAt: expiry, email: nil)
    }
    static func refresh(_ previous: AccountCredential) async throws -> AccountCredential {
        guard previous.provider == .copilot, previous.issuer == issuer, previous.clientID == clientID,
              let refresh = previous.refreshToken, !refresh.isEmpty else { throw UsageError.signedOut }
        let value = try await json(formRequest(issuer + "/login/oauth/access_token", fields: ["client_id": clientID, "grant_type": "refresh_token", "refresh_token": refresh]))
        guard value["error"] == nil else { throw UsageError.signedOut }
        return try await credential(value, previous: previous)
    }
}
