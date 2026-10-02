import AuthenticationServices
import CryptoKit
import Foundation
import Network
import Security
import UIKit

enum AuthError: LocalizedError {
    case cancelled, timedOut, invalidCallback, invalidIdentity, unavailable
    var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign-in was cancelled. Your saved accounts are unchanged."
        case .timedOut: return "Sign-in timed out. Tap Continue to start a fresh sign-in."
        case .invalidCallback: return "The sign-in response could not be verified. Please start again."
        case .invalidIdentity: return "The provider’s identity could not be verified. No connection was saved."
        case .unavailable: return "Sign-in is unavailable right now. Please try again."
        }
    }
}

struct OAuthAttempt {
    let provider: Provider
    let state: String
    let nonce: String
    let verifier: String
    let clientID: String
    let hostID: String
    let redirectURI: URL
    let previous: AccountCredential?
    init(redirectURI: URL, hostID: String, previous: AccountCredential? = nil, provider: Provider = .codex) throws {
        state = try Self.random(); nonce = try Self.random(); verifier = try Self.random()
        guard previous == nil || previous?.provider == provider else { throw UsageError.wrongAccount }
        self.provider = provider
        self.clientID = previous?.clientID ?? ProviderAuth.clientID(provider)
        self.hostID = hostID; self.redirectURI = redirectURI; self.previous = previous
    }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AuthError.unavailable }
        return Data(bytes).base64URL
    }
    var authorizationURL: URL {
        if provider != .codex {
            var parts = URLComponents(string: ProviderAuth.authorizationEndpoint(provider))!
            parts.queryItems = [
                URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
                URLQueryItem(name: "scope", value: ProviderAuth.scopes(provider)), URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "code_challenge", value: Data(SHA256.hash(data: Data(verifier.utf8))).base64URL)
            ]
            if provider == .gemini { parts.queryItems! += [URLQueryItem(name: "access_type", value: "offline"), URLQueryItem(name: "prompt", value: "consent select_account")] }
            if provider == .grok { parts.queryItems! += [URLQueryItem(name: "nonce", value: nonce), URLQueryItem(name: "referrer", value: "eyeballs")] }
            return parts.url!
        }
        let legacyRegistration = clientID.hasPrefix("oaiapp_")
        var parts = URLComponents(string: OpenAIAuth.issuer + (legacyRegistration ? "/api/accounts/authorize" : "/oauth/authorize"))!
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: legacyRegistration ? "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct" : "openid profile email offline_access"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce), URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Data(SHA256.hash(data: Data(verifier.utf8))).base64URL)
        ]
        if legacyRegistration {
            items += [URLQueryItem(name: "ext_agent_host_id", value: hostID), URLQueryItem(name: "resource", value: "https://api.openai.com/v1")]
        } else {
            items += [URLQueryItem(name: "id_token_add_organizations", value: "true"), URLQueryItem(name: "codex_cli_simplified_flow", value: "true"), URLQueryItem(name: "originator", value: "eyeballs")]
        }
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
        guard returned == nil || returned == clientID else { throw AuthError.invalidCallback }
        return (code, clientID)
    }
}

enum OpenAIAuth {
    static let issuer = "https://auth.openai.com"
    // Public native Codex client from OpenAI's local app-server login implementation.
    // This personal, local integration reads quotas; it never requests inference.
    static let codexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static var hostID: String {
        if let existing = UserDefaults.standard.string(forKey: "oauth-host-id") { return existing }
        let value = "urn:uuid:" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: "oauth-host-id")
        return value
    }
    static func exchange(callback: URL, attempt: OAuthAttempt) async throws -> AccountCredential {
        let result = try attempt.validateCallback(callback)
        var fields = [
            "grant_type": "authorization_code", "client_id": result.clientID, "code": result.code,
            "code_verifier": attempt.verifier, "redirect_uri": attempt.redirectURI.absoluteString
        ]
        if result.clientID.hasPrefix("oaiapp_") { fields["resource"] = "https://api.openai.com/v1" }
        let raw = try await tokenRequest(fields)
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
        guard previous.provider == .codex, previous.issuer == issuer,
              previous.clientID == codexClientID || previous.clientID.hasPrefix("oaiapp_"),
              let refresh = previous.refreshToken, !refresh.isEmpty else { throw UsageError.signedOut }
        var fields = ["grant_type": "refresh_token", "client_id": previous.clientID, "refresh_token": refresh]
        if previous.clientID.hasPrefix("oaiapp_") { fields["resource"] = "https://api.openai.com/v1" }
        let raw = try await tokenRequest(fields)
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
        var request = URLRequest(url: URL(string: issuer + (credential.clientID.hasPrefix("oaiapp_") ? "/api/accounts/oauth/revoke" : "/oauth/revoke"))!)
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
        let client = fields["client_id"] ?? ""
        guard client == codexClientID || client.hasPrefix("oaiapp_") else { throw AuthError.invalidIdentity }
        var request = URLRequest(url: URL(string: issuer + (client.hasPrefix("oaiapp_") ? "/api/accounts/oauth/token" : "/oauth/token"))!)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(fields)
        let (data, response) = try await ProviderHTTP.data(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AuthError.unavailable }
        guard (200..<300).contains(response.statusCode) else {
            let unusable = ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"]
            if let code = object["error"] as? String, unusable.contains(code) {
                if fields["grant_type"] == "refresh_token" { throw UsageError.signedOut }
                throw AuthError.invalidCallback
            }
            throw AuthError.unavailable
        }
        return object
    }
    static func credential(_ raw: [String: Any], previous: AccountCredential?, clientID: String, subject: String, accountID: String?, hostID: String, email: String?) throws -> AccountCredential {
        guard let access = raw["access_token"] as? String, !access.isEmpty,
              (raw["token_type"] as? String ?? "bearer").lowercased() == "bearer" else { throw AuthError.invalidIdentity }
        // Codex's token response need not include expires_in or scope. These JWT fields
        // are scheduling hints only; identity is verified separately and the usage API
        // must authorize the credential before the account can be saved.
        let metadata = IdentityVerifier.payload(access) ?? [:]
        let expiry = UsageParser.percent(raw["expires_in"]).flatMap { $0 > 0 ? Date.now.addingTimeInterval($0) : nil }
            ?? UsageParser.date(metadata["exp"]) ?? .now.addingTimeInterval(3600)
        guard expiry > .now else { throw UsageError.signedOut }
        let scopes = (raw["scope"] as? String).map { $0.split(separator: " ").map(String.init) } ?? metadata["scp"] as? [String] ?? previous?.scopes ?? []
        return AccountCredential(provider: .codex, issuer: issuer, clientID: clientID, subject: subject, accountID: accountID, hostID: hostID, accessToken: access,
                                 refreshToken: raw["refresh_token"] as? String ?? previous?.refreshToken, idToken: raw["id_token"] as? String ?? previous?.idToken,
                                 scopes: scopes, expiresAt: min(expiry, .now.addingTimeInterval(30 * 86400)), email: email)
    }
    private static func identity(idToken: String, clientID: String, nonce: String?) async throws -> [String: Any] {
        let request = URLRequest(url: URL(string: issuer + "/.well-known/jwks.json")!)
        let jwks = try await ProviderHTTP.json(request, unauthorizedError: .unavailable)
        return try IdentityVerifier.verify(idToken, jwks: jwks, issuer: issuer, audience: clientID, nonce: nonce)
    }
}

enum IdentityVerifier {
    static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, token.utf8.count < 32_768, let data = Data(base64URL: String(parts[1])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    static func verify(_ token: String, jwks: Any, issuer: String, audience: String, nonce: String?, now: Date = .now, algorithm: String = "RS256") throws -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, token.utf8.count < 32_768,
              let headerData = Data(base64URL: parts[0]), let claimsData = Data(base64URL: parts[1]), let signature = Data(base64URL: parts[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any], header["alg"] as? String == algorithm, header["crit"] == nil,
              let kid = header["kid"] as? String,
              let keys = (jwks as? [String: Any])?["keys"] as? [[String: Any]],
              let key = keys.first(where: { $0["kid"] as? String == kid && ($0["use"] as? String ?? "sig") == "sig" && ($0["alg"] as? String ?? algorithm) == algorithm }) else { throw AuthError.invalidIdentity }
        let message = Data((parts[0] + "." + parts[1]).utf8)
        if algorithm == "RS256" {
            guard key["kty"] as? String == "RSA", let n = key["n"] as? String, let modulus = Data(base64URL: n), modulus.count >= 256,
                  let e = key["e"] as? String, let exponent = Data(base64URL: e) else { throw AuthError.invalidIdentity }
            let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
            guard let publicKey = SecKeyCreateWithData(sequence(integer(modulus) + integer(exponent)) as CFData, attributes as CFDictionary, nil),
                  SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil) else { throw AuthError.invalidIdentity }
        } else if algorithm == "ES256" {
            guard key["kty"] as? String == "EC", key["crv"] as? String == "P-256",
                  let x = key["x"] as? String, let y = key["y"] as? String,
                  let xBytes = Data(base64URL: x), let yBytes = Data(base64URL: y), xBytes.count == 32, yBytes.count == 32,
                  let publicKey = try? P256.Signing.PublicKey(x963Representation: Data([4]) + xBytes + yBytes),
                  let ecSignature = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
                  publicKey.isValidSignature(ecSignature, for: message) else { throw AuthError.invalidIdentity }
        } else { throw AuthError.invalidIdentity }
        guard let claims = try? JSONSerialization.jsonObject(with: claimsData) as? [String: Any] else { throw AuthError.invalidIdentity }
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

    func signIn(provider: Provider = .codex, previous: AccountCredential?, usePrivateSession: Bool = false) async throws -> AccountCredential {
        let callback = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                pending = continuation
                do { try start(provider: provider, previous: previous, usePrivateSession: usePrivateSession) } catch { finish(.failure(error)) }
            }
        } onCancel: { Task { @MainActor in self.cancel() } }
        guard let attempt else { throw AuthError.invalidCallback }
        defer { self.attempt = nil }
        return try await ProviderAuth.exchange(callback: callback, attempt: attempt)
    }
    func cancel() { finish(.failure(AuthError.cancelled)) }
    private func start(provider: Provider, previous: AccountCredential?, usePrivateSession: Bool) throws {
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
                        let host = provider == .claude ? "localhost" : "127.0.0.1"
                        let path = provider == .codex ? "/auth/callback" : provider == .gemini ? "/oauth2callback" : "/callback"
                        let redirect = URL(string: "http://\(host):\(port.rawValue)\(path)")!
                        let attempt = try OAuthAttempt(redirectURI: redirect, hostID: OpenAIAuth.hostID, previous: previous, provider: provider)
                        self.attempt = attempt
                        let session = ASWebAuthenticationSession(url: attempt.authorizationURL, callbackURLScheme: nil) { [weak self] _, _ in
                            Task { @MainActor in self?.finish(.failure(AuthError.cancelled)) }
                        }
                        // Reuse system sign-in cookies by default. A separate login is
                        // available when the user explicitly chooses another account.
                        session.prefersEphemeralWebBrowserSession = usePrivateSession
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
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(AuthError.timedOut))
        }
    }
    nonisolated private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            let combined = bytes + (data ?? Data())
            guard combined.count <= 16_384, error == nil else { connection.cancel(); return }
            if let text = String(data: combined, encoding: .utf8), text.contains("\r\n\r\n") {
                let parts = (text.components(separatedBy: "\r\n").first ?? "").split(separator: " ")
                Task { @MainActor in
                    guard let self, let attempt = self.attempt, self.pending != nil, parts.count == 3 else { connection.cancel(); return }
                    let headers = text.components(separatedBy: "\r\n").dropFirst().reduce(into: [String: String]()) { result, line in
                        let pair = line.split(separator: ":", maxSplits: 1)
                        if pair.count == 2 { result[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces) }
                    }
                    guard let reply = try? LoopbackRequest.reply(method: String(parts[0]), target: String(parts[1]), headers: headers, attempt: attempt) else { connection.cancel(); return }
                    if reply.preflight {
                        connection.send(content: Data(reply.response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                        return
                    }
                    guard let url = reply.callback else { connection.cancel(); return }
                    // Ignore unrelated and forged requests; they cannot consume the pending login.
                    let result: Result<URL, Error>
                    do { _ = try attempt.validateCallback(url); result = .success(url) }
                    catch AuthError.cancelled { result = .failure(AuthError.cancelled) }
                    catch { connection.cancel(); return }
                    connection.send(content: Data(reply.response.utf8), completion: .contentProcessed { _ in connection.cancel() })
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
