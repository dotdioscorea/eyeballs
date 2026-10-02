import AuthenticationServices
import CryptoKit
import Foundation
import Network
import Security
import UIKit

enum AuthError: LocalizedError {
    case cancelled, invalidCallback, invalidIdentity, unavailable, missingUsagePermission
    var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign-in was cancelled. Your saved accounts are unchanged."
        case .invalidCallback: return "The sign-in response could not be verified. Please start again."
        case .invalidIdentity: return "The provider’s identity could not be verified. No connection was saved."
        case .unavailable: return "Sign-in is unavailable right now. Please try again."
        case .missingUsagePermission: return "ChatGPT did not grant access for this connection. No connection was saved."
        }
    }
}

struct OAuthAttempt {
    let state: String
    let nonce: String
    let verifier: String
    let clientID: String
    let hostID: String
    let redirectURI: URL
    let previous: AccountCredential?
    init(redirectURI: URL, hostID: String, previous: AccountCredential? = nil) throws {
        state = try Self.random(); nonce = try Self.random(); verifier = try Self.random()
        self.clientID = previous?.clientID ?? "dynamic_agent_client"
        self.hostID = hostID; self.redirectURI = redirectURI; self.previous = previous
    }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AuthError.unavailable }
        return Data(bytes).base64URL
    }
    var authorizationURL: URL {
        var parts = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        var items = [
            URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "ext_agent_host_id", value: hostID),
            URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"),
            URLQueryItem(name: "resource", value: "https://api.openai.com/v1"), URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce), URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Data(SHA256.hash(data: Data(verifier.utf8))).base64URL)
        ]
        if previous == nil { items.append(URLQueryItem(name: "agent_name_hint", value: "Eyeballs")) }
        if let hint = previous?.idToken { items.append(URLQueryItem(name: "id_token_hint", value: hint)) }
        parts.queryItems = items
        return parts.url!
    }
    func validateCallback(_ url: URL) throws -> (code: String, clientID: String) {
        guard url.scheme == redirectURI.scheme, url.host == redirectURI.host, url.port == redirectURI.port,
              url.path == redirectURI.path, url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state else { throw AuthError.invalidCallback }
        if items.contains(where: { $0.name == "error" }) { throw AuthError.cancelled }
        guard items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty,
              items.filter({ $0.name == "client_id" }).count <= 1 else { throw AuthError.invalidCallback }
        let returned = items.first(where: { $0.name == "client_id" })?.value
        if previous != nil {
            guard returned == nil || returned == clientID else { throw AuthError.invalidCallback }
            return (code, clientID)
        }
        guard let returned, returned.hasPrefix("oaiapp_"), returned.count < 200 else { throw AuthError.invalidCallback }
        return (code, returned)
    }
}

enum OpenAIAuth {
    static let issuer = "https://auth.openai.com"
    static var hostID: String {
        if let existing = UserDefaults.standard.string(forKey: "oauth-host-id") { return existing }
        let value = "urn:uuid:" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: "oauth-host-id")
        return value
    }
    static func exchange(callback: URL, attempt: OAuthAttempt) async throws -> AccountCredential {
        let result = try attempt.validateCallback(callback)
        let raw = try await tokenRequest([
            "grant_type": "authorization_code", "client_id": result.clientID, "code": result.code,
            "code_verifier": attempt.verifier, "redirect_uri": attempt.redirectURI.absoluteString,
            "resource": "https://api.openai.com/v1"
        ])
        guard let idToken = raw["id_token"] as? String else { throw AuthError.invalidIdentity }
        let claims = try await identity(idToken: idToken, clientID: result.clientID, nonce: attempt.nonce)
        let subject = claims["sub"] as! String
        let accountID = (claims["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String
        if let previous = attempt.previous {
            guard subject == previous.subject, accountID == previous.accountID else { throw UsageError.wrongAccount }
        }
        return try credential(raw, previous: attempt.previous, clientID: result.clientID, subject: subject, accountID: accountID, hostID: attempt.hostID, email: claims["email"] as? String)
    }
    static func refresh(_ previous: AccountCredential) async throws -> AccountCredential {
        guard previous.provider == .codex, previous.issuer == issuer, previous.clientID.hasPrefix("oaiapp_"),
              let refresh = previous.refreshToken, !refresh.isEmpty else { throw UsageError.signedOut }
        let raw = try await tokenRequest(["grant_type": "refresh_token", "client_id": previous.clientID, "refresh_token": refresh, "resource": "https://api.openai.com/v1"])
        if let token = raw["id_token"] as? String {
            let claims = try await identity(idToken: token, clientID: previous.clientID, nonce: nil)
            guard claims["sub"] as? String == previous.subject else { throw UsageError.wrongAccount }
            let accountID = (claims["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String
            guard accountID == previous.accountID else { throw UsageError.wrongAccount }
        }
        return try credential(raw, previous: previous, clientID: previous.clientID, subject: previous.subject, accountID: previous.accountID, hostID: previous.hostID, email: previous.email)
    }
    static func revoke(_ credential: AccountCredential) async throws {
        guard credential.provider == .codex, credential.issuer == issuer, let token = credential.refreshToken else { return }
        var request = URLRequest(url: URL(string: issuer + "/api/accounts/oauth/revoke")!)
        request.httpMethod = "POST"; request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(["token": token, "token_type_hint": "refresh_token", "client_id": credential.clientID])
        let (_, response) = try await ProviderHTTP.data(request)
        guard response.statusCode == 200 else { throw AuthError.unavailable }
    }
    static func form(_ fields: [String: String]) -> Data {
        var parts = URLComponents()
        parts.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((parts.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    }
    private static func tokenRequest(_ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: issuer + "/api/accounts/oauth/token")!)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(fields)
        let (data, response) = try await ProviderHTTP.data(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AuthError.unavailable }
        guard (200..<300).contains(response.statusCode) else {
            let unusable = ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"]
            if let code = object["error"] as? String, unusable.contains(code) { throw UsageError.signedOut }
            throw AuthError.unavailable
        }
        return object
    }
    private static func credential(_ raw: [String: Any], previous: AccountCredential?, clientID: String, subject: String, accountID: String?, hostID: String, email: String?) throws -> AccountCredential {
        guard let access = raw["access_token"] as? String, !access.isEmpty,
              let expires = UsageParser.percent(raw["expires_in"]), expires > 0,
              (raw["token_type"] as? String)?.lowercased() == "bearer" else { throw AuthError.invalidIdentity }
        let scopes = (raw["scope"] as? String).map { $0.split(separator: " ").map(String.init) } ?? previous?.scopes ?? []
        guard scopes.contains("chatgpt.tokens.use.direct") else { throw AuthError.missingUsagePermission }
        return AccountCredential(provider: .codex, issuer: issuer, clientID: clientID, subject: subject, accountID: accountID, hostID: hostID, accessToken: access,
                                 refreshToken: raw["refresh_token"] as? String ?? previous?.refreshToken, idToken: raw["id_token"] as? String ?? previous?.idToken,
                                 scopes: scopes, expiresAt: .now.addingTimeInterval(expires), email: email)
    }
    private static func identity(idToken: String, clientID: String, nonce: String?) async throws -> [String: Any] {
        let request = URLRequest(url: URL(string: issuer + "/.well-known/jwks.json")!)
        let jwks = try await ProviderHTTP.json(request)
        return try IdentityVerifier.verify(idToken, jwks: jwks, issuer: issuer, audience: clientID, nonce: nonce)
    }
}

enum IdentityVerifier {
    // The provider currently publishes RSA/RS256 signing keys. Reject every other algorithm.
    static func verify(_ token: String, jwks: Any, issuer: String, audience: String, nonce: String?, now: Date = .now) throws -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, token.utf8.count < 32_768,
              let headerData = Data(base64URL: parts[0]), let claimsData = Data(base64URL: parts[1]), let signature = Data(base64URL: parts[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any], header["alg"] as? String == "RS256", header["crit"] == nil,
              let kid = header["kid"] as? String,
              let keys = (jwks as? [String: Any])?["keys"] as? [[String: Any]],
              let key = keys.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" && $0["use"] as? String == "sig" && ($0["alg"] as? String ?? "RS256") == "RS256" }),
              let n = key["n"] as? String, let modulus = Data(base64URL: n), modulus.count >= 256,
              let e = key["e"] as? String, let exponent = Data(base64URL: e) else { throw AuthError.invalidIdentity }
        let der = sequence(integer(modulus) + integer(exponent))
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        guard let publicKey = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil),
              let claims = try? JSONSerialization.jsonObject(with: claimsData) as? [String: Any] else { throw AuthError.invalidIdentity }
        try validateClaims(claims, issuer: issuer, audience: audience, nonce: nonce, now: now)
        return claims
    }
    static func validateClaims(_ claims: [String: Any], issuer: String, audience: String, nonce: String?, now: Date) throws {
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard claims["iss"] as? String == issuer, audiences.contains(audience),
              let exp = UsageParser.date(claims["exp"]), exp > now.addingTimeInterval(-5),
              let iat = UsageParser.date(claims["iat"]), iat <= now.addingTimeInterval(5),
              let subject = claims["sub"] as? String, !subject.isEmpty else { throw AuthError.invalidIdentity }
        if let nbf = claims["nbf"], UsageParser.date(nbf).map({ $0 <= now.addingTimeInterval(5) }) != true { throw AuthError.invalidIdentity }
        if let nonce, claims["nonce"] as? String != nonce { throw AuthError.invalidIdentity }
        if audiences.count > 1, claims["azp"] as? String != audience { throw AuthError.invalidIdentity }
    }
    static func integer(_ input: Data) -> Data {
        var bytes = input
        while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
        if (bytes.first ?? 0) & 0x80 != 0 { bytes.insert(0, at: 0) }
        return Data([0x02]) + length(bytes.count) + bytes
    }
    static func sequence(_ bytes: Data) -> Data { Data([0x30]) + length(bytes.count) + bytes }
    static func length(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var value = count; var bytes: [UInt8] = []
        while value > 0 { bytes.insert(UInt8(value & 255), at: 0); value >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}

extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(base64URL: String) {
        guard base64URL.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        self.init(base64Encoded: value)
    }
}

@MainActor
final class OAuthBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var listener: NWListener?
    private var pending: CheckedContinuation<URL, Error>?
    private var attempt: OAuthAttempt?
    private var timeout: Task<Void, Never>?
    private let queue = DispatchQueue(label: "Eyeballs.loopback-auth")

    func signIn(previous: AccountCredential?) async throws -> AccountCredential {
        let callback = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                pending = continuation
                do { try start(previous: previous) } catch { finish(.failure(error)) }
            }
        } onCancel: { Task { @MainActor in self.cancel() } }
        guard let attempt else { throw AuthError.invalidCallback }
        defer { self.attempt = nil }
        return try await OpenAIAuth.exchange(callback: callback, attempt: attempt)
    }
    func cancel() { finish(.failure(AuthError.cancelled)) }
    private func start(previous: AccountCredential?) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, self.pending != nil else { return }
                switch state {
                case .ready:
                    guard let port = listener?.port else { self.finish(.failure(AuthError.unavailable)); return }
                    do {
                        let redirect = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!
                        let attempt = try OAuthAttempt(redirectURI: redirect, hostID: OpenAIAuth.hostID, previous: previous)
                        self.attempt = attempt
                        let session = ASWebAuthenticationSession(url: attempt.authorizationURL, callbackURLScheme: nil) { [weak self] _, _ in
                            Task { @MainActor in self?.finish(.failure(AuthError.cancelled)) }
                        }
                        // A new account always has a separate system-browser authentication session.
                        session.prefersEphemeralWebBrowserSession = true
                        session.presentationContextProvider = self
                        self.session = session
                        guard session.start() else { self.finish(.failure(AuthError.unavailable)); return }
                    } catch { self.finish(.failure(error)) }
                case .failed: self.finish(.failure(AuthError.unavailable))
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .global())
            self?.receive(connection, bytes: Data())
        }
        listener.start(queue: queue)
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(AuthError.unavailable))
        }
    }
    nonisolated private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            let combined = bytes + (data ?? Data())
            guard combined.count <= 16_384, error == nil else { connection.cancel(); return }
            if let text = String(data: combined, encoding: .utf8), text.contains("\r\n\r\n") {
                let parts = (text.components(separatedBy: "\r\n").first ?? "").split(separator: " ")
                Task { @MainActor in
                    guard let self, let attempt = self.attempt, self.pending != nil,
                          parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/auth/callback?"),
                          let url = URL(string: "http://127.0.0.1:\(attempt.redirectURI.port!)" + parts[1]) else { connection.cancel(); return }
                    // Ignore unrelated and forged requests; they cannot consume the pending login.
                    let result: Result<URL, Error>
                    do { _ = try attempt.validateCallback(url); result = .success(url) }
                    catch AuthError.cancelled { result = .failure(AuthError.cancelled) }
                    catch { connection.cancel(); return }
                    let body = "<!doctype html><meta name=viewport content='width=device-width'><title>Eyeballs</title><p>You can return to Eyeballs.</p>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    self.finish(result)
                }
            } else if complete { connection.cancel() }
            else { self?.receive(connection, bytes: combined) }
        }
    }
    private func finish(_ result: Result<URL, Error>) {
        guard let pending else { return }
        self.pending = nil
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        session?.cancel(); session = nil
        pending.resume(with: result)
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
