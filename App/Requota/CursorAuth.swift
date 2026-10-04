import Foundation
import CryptoKit

// Cursor's published native login handshake. Polling uses POST so the single-use
// verifier stays out of URLs. Identity comes from authenticated GetMe, not JWT text.
enum CursorAuth {
    static let issuer = "https://authentication.cursor.sh"
    static let clientID = "cursor-native-login"
    struct Attempt {
        var id: UUID = UUID()
        var verifier: String
        var challenge: String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URL }
        var expiresAt: Date = .now.addingTimeInterval(600)
        init() throws { verifier = try OAuthAttempt.random() }
        var url: URL {
            var components = URLComponents(string: "https://cursor.com/loginDeepControl")!
            components.queryItems = [URLQueryItem(name: "challenge", value: challenge), URLQueryItem(name: "uuid", value: id.uuidString), URLQueryItem(name: "mode", value: "login"), URLQueryItem(name: "redirectTarget", value: "cli")]
            return components.url!
        }
        var request: URLRequest {
            var request = URLRequest(url: URL(string: "https://api2.cursor.sh/auth/poll")!)
            request.httpMethod = "POST"; request.timeoutInterval = 25
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["uuid": id.uuidString, "verifier": verifier])
            return request
        }
        func validate(_ raw: [String: Any]) throws {
            guard (raw["uuid"] as? String).flatMap(UUID.init(uuidString:)) == id,
                  raw["challenge"] as? String == challenge,
                  let authID = raw["authId"] as? String, !authID.isEmpty,
                  let access = raw["accessToken"] as? String, !access.isEmpty else { throw AuthError.invalidIdentity }
        }
    }
    static func poll(_ attempt: Attempt) async throws -> [String: Any]? {
        guard attempt.expiresAt > .now else { throw AuthError.timedOut }
        let (data, response) = try await ProviderHTTP.data(attempt.request)
        if response.statusCode == 404 { return nil }
        if response.statusCode == 429 { throw UsageError.throttled(ProviderHTTP.retryDate(response.value(forHTTPHeaderField: "Retry-After"))) }
        guard (200..<300).contains(response.statusCode), let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AuthError.unavailable }
        try attempt.validate(value)
        return value
    }
    static func request(_ method: String, accessToken: String) throws -> URLRequest {
        guard ["GetMe", "GetCurrentPeriodUsage", "GetPlanInfo"].contains(method), !accessToken.isEmpty else { throw AuthError.invalidIdentity }
        var request = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/" + method)!)
        request.httpMethod = "POST"; request.timeoutInterval = 25
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        request.httpBody = Data("{}".utf8)
        return request
    }
    static func identity(_ value: [String: Any]) throws -> String {
        guard let subject = value["publicUserId"] as? String, !subject.isEmpty,
              let authID = value["authId"] as? String, !authID.isEmpty else { throw AuthError.invalidIdentity }
        return subject
    }
    static func credential(_ raw: [String: Any], attempt: Attempt, previous: AccountCredential?) async throws -> AccountCredential {
        try attempt.validate(raw)
        let access = raw["accessToken"] as! String
        guard let value = try await ProviderHTTP.json(request("GetMe", accessToken: access), unauthorizedError: .usageAccessDenied) as? [String: Any],
              value["authId"] as? String == raw["authId"] as? String else { throw AuthError.invalidIdentity }
        let subject = try identity(value)
        if let previous, previous.subject != subject { throw UsageError.wrongAccount }
        // The native CLI only renews API-key connections. Its browser sessions
        // require sign-in again after expiry; do not invent a WorkOS refresh API.
        guard let expiry = IdentityVerifier.payload(access).flatMap({ UsageParser.date($0["exp"]) }), expiry > .now else { throw AuthError.invalidIdentity }
        return AccountCredential(provider: .cursor, issuer: issuer, clientID: clientID, subject: subject, accountID: nil,
                                 hostID: OpenAIAuth.hostID, accessToken: access, refreshToken: nil, idToken: nil, scopes: [],
                                 expiresAt: min(expiry, .now.addingTimeInterval(60 * 86400)), email: value["email"] as? String)
    }
}
