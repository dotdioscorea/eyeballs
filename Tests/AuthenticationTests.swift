import CryptoKit
import Security
import XCTest
@testable import Eyeballs

final class AuthenticationTests: XCTestCase {
    let callback = URL(string: "http://127.0.0.1:1455/auth/callback")!
    func testCursorBindsNativeHandshakeAndKeepsVerifierOutOfURLs() throws {
        let attempt = try CursorAuth.Attempt()
        XCTAssertFalse(attempt.url.absoluteString.contains(attempt.verifier))
        XCTAssertEqual(attempt.request.httpMethod, "POST")
        let body = try JSONSerialization.jsonObject(with: attempt.request.httpBody!) as! [String: String]
        XCTAssertEqual(body["verifier"], attempt.verifier)
        var raw: [String: Any] = ["uuid": attempt.id.uuidString, "challenge": attempt.challenge, "authId": "private-principal", "accessToken": "private-token"]
        XCTAssertNoThrow(try attempt.validate(raw))
        raw["uuid"] = UUID().uuidString; XCTAssertThrowsError(try attempt.validate(raw))
        raw["uuid"] = attempt.id.uuidString; raw["challenge"] = "different"; XCTAssertThrowsError(try attempt.validate(raw))
        XCTAssertEqual(try CursorAuth.identity(["authId": "private", "publicUserId": "verified-principal"]), "verified-principal")
        XCTAssertThrowsError(try CursorAuth.identity(["authId": "private"]))
        XCTAssertThrowsError(try CursorAuth.request("CreateUserApiKey", accessToken: "private"))
    }
    func testCopilotDeviceFlowRejectsForeignVerificationURLsAndInvalidPrincipals() throws {
        var raw: [String: Any] = ["device_code": "private-device-code", "user_code": "ABCD-EFGH", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 5]
        let verification = try CopilotAuth.Verification.decode(raw)
        XCTAssertEqual(verification.interval, 5)
        for url in ["http://github.com/login/device", "https://github.com.evil.test/login/device", "https://github.com/login/device?secret=value", "https://user@github.com/login/device"] {
            raw["verification_uri"] = url; XCTAssertThrowsError(try CopilotAuth.Verification.decode(raw))
        }
        XCTAssertEqual(try CopilotAuth.identity(["id": 123, "login": "fixture"]), "123")
        XCTAssertThrowsError(try CopilotAuth.identity(["id": true, "login": "fixture"]))
        XCTAssertThrowsError(try CopilotAuth.identity(["id": 123.5, "login": "fixture"]))
        XCTAssertThrowsError(try CopilotAuth.pollResult(["error": "access_denied"]))
        XCTAssertThrowsError(try CopilotAuth.pollResult(["error": "expired_token"]))
        if case .pending = try CopilotAuth.pollResult(["error": "authorization_pending"]) { } else { XCTFail("Expected pending") }
        if case .slowDown = try CopilotAuth.pollResult(["error": "slow_down"]) { } else { XCTFail("Expected slower polling") }
        let request = CopilotAuth.formRequest("https://github.com/login/oauth/access_token", fields: ["device_code": "private-device-code"])
        XCTAssertFalse(request.url!.absoluteString.contains("private-device-code"))
        XCTAssertTrue(String(decoding: request.httpBody!, as: UTF8.self).contains("private-device-code"))
    }
    func testCopilotNeverAcceptsUnreportedOrRepositoryScopes() async {
        for scope in [nil, "repo", "read:user,repo"] as [String?] {
            var raw = ["access_token": "fixture-access", "token_type": "bearer"]
            raw["scope"] = scope
            do { _ = try await CopilotAuth.credential(raw, previous: nil); XCTFail("Unsafe scope was accepted") }
            catch { }
        }
    }
    func testGeminiUsesGoogleNativeOAuthWithPKCEAndVerifiedIdentity() throws {
        XCTAssertThrowsError(try GeminiAuth.quotaProject([:]))
        XCTAssertThrowsError(try GeminiAuth.quotaProject(["cloudaicompanionProject": NSNull()]))
        XCTAssertEqual(try GeminiAuth.quotaProject(["cloudaicompanionProject": "managed-project"]), "managed-project")
        let redirect = URL(string: "http://127.0.0.1:43210/oauth2callback")!
        let attempt = try OAuthAttempt(redirectURI: redirect, hostID: "fixture", provider: .gemini)
        let url = attempt.authorizationURL
        XCTAssertEqual(url.host, "accounts.google.com")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "client_id" }?.value, GeminiAuth.clientID)
        XCTAssertEqual(query.first { $0.name == "access_type" }?.value, "offline")
        XCTAssertEqual(query.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertFalse(url.absoluteString.contains(attempt.verifier))
        XCTAssertThrowsError(try GeminiAuth.identity(["email": "unverified@example.com"]))
        XCTAssertNil(try GeminiAuth.identity(["id": "a", "email": "unverified@example.com"]).email)
        XCTAssertEqual(try GeminiAuth.identity(["id": "a", "email": "verified@example.com", "verified_email": true]).email, "verified@example.com")
        var credential = Fixture.credential("google"); credential.provider = .gemini; credential.issuer = GeminiAuth.issuer
        let request = try UsageClient.request(provider: .gemini, credential: credential)
        XCTAssertEqual(request.url?.host, "cloudcode-pa.googleapis.com")
        XCTAssertThrowsError(try UsageClient.request(provider: .codex, credential: credential))
    }
    func testCodexLoginRequestsQuotaCompatibleNativeCredentialsAndPKCE() throws {
        let first = try OAuthAttempt(redirectURI: callback, hostID: "urn:uuid:phone")
        let second = try OAuthAttempt(redirectURI: callback, hostID: "urn:uuid:phone")
        XCTAssertNotEqual(first.state, second.state)
        XCTAssertNotEqual(first.nonce, second.nonce)
        XCTAssertNotEqual(first.verifier, second.verifier)
        let items = URLComponents(url: first.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(first.authorizationURL.path, "/oauth/authorize")
        XCTAssertEqual(value("client_id"), OpenAIAuth.codexClientID)
        XCTAssertEqual(value("scope"), "openid profile email offline_access")
        XCTAssertNil(value("resource"))
        XCTAssertNil(value("agent_name_hint"))
        XCTAssertEqual(value("originator"), "eyeballs")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("code_challenge"), Data(SHA256.hash(data: Data(first.verifier.utf8))).base64URL)
        XCTAssertEqual(value("redirect_uri"), callback.absoluteString)
        XCTAssertNil(value("id_token_hint"))
    }
    func testForgedAndAmbiguousCallbacksAreRejected() throws {
        let attempt = try OAuthAttempt(redirectURI: callback, hostID: "urn:uuid:phone")
        let valid = callback.absoluteString + "?state=\(attempt.state)&code=fixture-code&client_id=\(OpenAIAuth.codexClientID)"
        XCTAssertEqual(try attempt.validateCallback(URL(string: valid)!).clientID, OpenAIAuth.codexClientID)
        XCTAssertEqual(try attempt.validateCallback(URL(string: callback.absoluteString + "?state=\(attempt.state)&code=fixture-code")!).clientID, OpenAIAuth.codexClientID)
        for forged in [valid.replacingOccurrences(of: attempt.state, with: "wrong-state"), valid + "&state=\(attempt.state)", valid + "&code=other", valid.replacingOccurrences(of: "127.0.0.1", with: "localhost"), valid.replacingOccurrences(of: "1455", with: "1456"), valid.replacingOccurrences(of: "/auth/callback", with: "/callback"), valid.replacingOccurrences(of: OpenAIAuth.codexClientID, with: "oaiapp_other")] {
            XCTAssertThrowsError(try attempt.validateCallback(URL(string: forged)!))
        }
    }
    func testReturningAccountCannotReplaceItsIssuedClientID() throws {
        let previous = Fixture.credential("a")
        let attempt = try OAuthAttempt(redirectURI: callback, hostID: "urn:uuid:phone", previous: previous)
        let valid = callback.absoluteString + "?state=\(attempt.state)&code=fixture-code"
        XCTAssertEqual(try attempt.validateCallback(URL(string: valid)!).clientID, previous.clientID)
        XCTAssertThrowsError(try attempt.validateCallback(URL(string: valid + "&client_id=oaiapp_different")!))
        let items = URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertNil(items.first { $0.name == "agent_name_hint" })
    }
    func testIdentityClaimsRejectWrongIssuerAudienceNonceAndExpiry() throws {
        let now = Date(timeIntervalSince1970: 1790931600)
        let good: [String: Any] = ["iss": OpenAIAuth.issuer, "aud": "oaiapp_fixture", "sub": "fixture-subject", "iat": now.timeIntervalSince1970, "exp": now.addingTimeInterval(3600).timeIntervalSince1970, "nonce": "fixture-nonce"]
        try IdentityVerifier.validateClaims(good, issuer: OpenAIAuth.issuer, audience: "oaiapp_fixture", nonce: "fixture-nonce", now: now)
        for (field, value) in [("iss", "https://example.com" as Any), ("aud", "oaiapp_other"), ("nonce", "different"), ("exp", now.addingTimeInterval(-30).timeIntervalSince1970), ("iat", now.addingTimeInterval(60).timeIntervalSince1970), ("sub", ""), ("exp", true)] {
            var bad = good; bad[field] = value
            XCTAssertThrowsError(try IdentityVerifier.validateClaims(bad, issuer: OpenAIAuth.issuer, audience: "oaiapp_fixture", nonce: "fixture-nonce", now: now))
        }
    }
    func testRealRSASignatureAcceptedButTamperedPayloadRejected() throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let data = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        var index = 0
        func tlv() throws -> Data {
            guard index + 2 <= data.count else { throw AuthError.invalidIdentity }
            index += 1; var count = Int(data[index]); index += 1
            if count & 0x80 != 0 {
                let bytes = count & 0x7f; count = 0
                for _ in 0..<bytes { count = (count << 8) | Int(data[index]); index += 1 }
            }
            guard index + count <= data.count else { throw AuthError.invalidIdentity }
            return data[index..<(index + count)]
        }
        _ = try tlv() // Outer sequence; move to its content rather than past it.
        var n = try tlv(); index += n.count
        if n.first == 0 { n.removeFirst() }
        let e = try tlv()
        let jwks: [String: Any] = ["keys": [["kid": "fixture", "kty": "RSA", "alg": "RS256", "use": "sig", "n": n.base64URL, "e": e.base64URL]]]
        let now = Date.now
        let claims: [String: Any] = ["iss": OpenAIAuth.issuer, "aud": "oaiapp_fixture", "sub": "verified", "nonce": "nonce", "iat": now.timeIntervalSince1970, "exp": now.addingTimeInterval(3600).timeIntervalSince1970]
        let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "fixture"]).base64URL
        let payload = try JSONSerialization.data(withJSONObject: claims).base64URL
        let message = header + "." + payload
        let signature = try XCTUnwrap(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(message.utf8) as CFData, nil) as Data?)
        let token = message + "." + signature.base64URL
        XCTAssertEqual(try IdentityVerifier.verify(token, jwks: jwks, issuer: OpenAIAuth.issuer, audience: "oaiapp_fixture", nonce: "nonce")["sub"] as? String, "verified")
        var forged = claims; forged["sub"] = "impostor"
        let changed = header + "." + (try JSONSerialization.data(withJSONObject: forged).base64URL) + "." + signature.base64URL
        XCTAssertThrowsError(try IdentityVerifier.verify(changed, jwks: jwks, issuer: OpenAIAuth.issuer, audience: "oaiapp_fixture", nonce: "nonce"))
        XCTAssertThrowsError(try IdentityVerifier.verify("eyJhbGciOiJub25lIn0.e30.", jwks: jwks, issuer: OpenAIAuth.issuer, audience: "oaiapp_fixture", nonce: "nonce"))
    }
    func testFormEncodingPreservesLiteralPlusAndNewlines() {
        let data = OpenAIAuth.form(["code": "a+b&c\n"])
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(encoded.contains("%2B"))
        XCTAssertTrue(encoded.contains("%26"))
        XCTAssertTrue(encoded.contains("%0A"))
    }
    func testCodexTokenResponseWithoutExpiresInOrScopeUsesExpiryHint() throws {
        let expiry = Date.now.addingTimeInterval(3600)
        let payload = try JSONSerialization.data(withJSONObject: ["exp": expiry.timeIntervalSince1970, "scp": ["openid", "offline_access"]]).base64URL
        let access = "e30." + payload + ".fixture-signature"
        let credential = try OpenAIAuth.credential(["access_token": access, "refresh_token": "fixture-refresh"], previous: nil, clientID: OpenAIAuth.codexClientID, subject: "verified-by-caller", accountID: "workspace", hostID: "fixture", email: nil)
        XCTAssertEqual(credential.expiresAt.timeIntervalSince1970, expiry.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(credential.scopes, ["openid", "offline_access"])
        XCTAssertEqual(credential.clientID, OpenAIAuth.codexClientID)
    }
    func testClaudeAndGrokUseSeparateNativeClientsAndLimitedScopes() throws {
        // Pin the provider contracts independently of the URL builder. Grok's
        // public-client allowlist is defined by xai-grok-login/src/config.rs;
        // billing:read is not allowed and prevents authentication-code issuance.
        let expectedScopes: [Provider: String] = [
            .claude: "user:profile",
            .grok: "openid profile email offline_access grok-cli:access api:access"
        ]
        for provider in [Provider.claude, .grok] {
            let attempt = try OAuthAttempt(redirectURI: URL(string: "http://127.0.0.1:54321/callback")!, hostID: "fixture", provider: provider)
            let url = attempt.authorizationURL
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            XCTAssertEqual(value("client_id"), ProviderAuth.clientID(provider))
            XCTAssertEqual(value("code_challenge_method"), "S256")
            XCTAssertEqual(value("state"), attempt.state)
            XCTAssertEqual(value("scope"), expectedScopes[provider])
            XCTAssertFalse(value("scope")!.contains("inference"))
            XCTAssertFalse(value("scope")!.contains("write"))
            XCTAssertEqual(url.host, provider == .claude ? "claude.com" : "auth.x.ai")
        }
    }
    func testClaudeIdentityRequiresAccountAndOrganizationIDs() throws {
        let profile: [String: Any] = ["account": ["uuid": "a", "email": "same@example.test"], "organization": ["uuid": "org-a"]]
        let identity = try ProviderAuth.claudeIdentity(profile)
        XCTAssertEqual(identity.subject, "a"); XCTAssertEqual(identity.accountID, "org-a")
        XCTAssertThrowsError(try ProviderAuth.claudeIdentity(["account": ["email": "same@example.test"]]))
        XCTAssertThrowsError(try ProviderAuth.claudeIdentity(["account": ["uuid": ""], "organization": ["uuid": "org-a"]]))
    }
    func testGrokPreflightDoesNotConsumeCallbackAndRejectsUntrustedOrigins() throws {
        let attempt = try OAuthAttempt(redirectURI: URL(string: "http://127.0.0.1:54321/callback")!, hostID: "fixture", provider: .grok)
        let headers = ["origin": "https://accounts.x.ai", "access-control-request-method": "GET", "access-control-request-private-network": "true"]
        let preflight = try LoopbackRequest.reply(method: "OPTIONS", target: "/callback", headers: headers, attempt: attempt)
        XCTAssertTrue(preflight.preflight); XCTAssertNil(preflight.callback)
        XCTAssertTrue(preflight.response.contains("Access-Control-Allow-Private-Network: true"))
        let callback = try LoopbackRequest.reply(method: "GET", target: "/callback?state=\(attempt.state)&code=fixture", headers: ["origin": "https://accounts.x.ai"], attempt: attempt)
        XCTAssertFalse(callback.preflight); XCTAssertNotNil(callback.callback)
        XCTAssertThrowsError(try LoopbackRequest.reply(method: "GET", target: "/callback?state=wrong&code=fixture", headers: [:], attempt: attempt))
        XCTAssertThrowsError(try LoopbackRequest.reply(method: "GET", target: "/callback?state=\(attempt.state)&code=fixture", headers: ["origin": "https://attacker.example"], attempt: attempt))
        XCTAssertThrowsError(try LoopbackRequest.reply(method: "OPTIONS", target: "/callback", headers: ["origin": "https://accounts.x.ai", "access-control-request-method": "POST"], attempt: attempt))
    }
    func testRealGrokES256SignatureIsVerifiedAndAlgorithmCannotBeSubstituted() throws {
        let key = P256.Signing.PrivateKey()
        let bytes = key.publicKey.x963Representation
        let jwks: [String: Any] = ["keys": [["kid": "grok-fixture", "kty": "EC", "crv": "P-256", "alg": "ES256", "x": bytes[1..<33].base64URL, "y": bytes[33..<65].base64URL]]]
        let claims: [String: Any] = ["iss": ProviderAuth.issuer(.grok), "aud": ProviderAuth.grokClientID, "sub": "verified", "nonce": "fixture", "iat": Date.now.timeIntervalSince1970, "exp": Date.now.addingTimeInterval(3600).timeIntervalSince1970]
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": "grok-fixture"]).base64URL
        let payload = try JSONSerialization.data(withJSONObject: claims).base64URL
        let message = header + "." + payload
        let signature = try key.signature(for: Data(message.utf8)).rawRepresentation.base64URL
        let token = message + "." + signature
        XCTAssertEqual(try IdentityVerifier.verify(token, jwks: jwks, issuer: ProviderAuth.issuer(.grok), audience: ProviderAuth.grokClientID, nonce: "fixture", algorithm: "ES256")["sub"] as? String, "verified")
        var forged = claims; forged["sub"] = "impostor"
        XCTAssertThrowsError(try IdentityVerifier.verify(header + "." + JSONSerialization.data(withJSONObject: forged).base64URL + "." + signature, jwks: jwks, issuer: ProviderAuth.issuer(.grok), audience: ProviderAuth.grokClientID, nonce: "fixture", algorithm: "ES256"))
        XCTAssertThrowsError(try IdentityVerifier.verify(token, jwks: jwks, issuer: ProviderAuth.issuer(.grok), audience: ProviderAuth.grokClientID, nonce: "fixture"))
    }
    func testGrokUserAndTeamPrincipalsRemainDifferentConnections() throws {
        let user = try ProviderAuth.grokIdentity(["sub": "user", "principal_type": "User", "principal_id": "personal"])
        let team = try ProviderAuth.grokIdentity(["sub": "user", "principal_type": "Team", "principal_id": "work"])
        XCTAssertEqual(user.subject, team.subject)
        XCTAssertNotEqual(user.accountID, team.accountID)
        XCTAssertThrowsError(try ProviderAuth.grokIdentity(["sub": "user", "principal_type": "Other", "principal_id": "work"]))
        XCTAssertThrowsError(try ProviderAuth.grokIdentity(["sub": "user", "principal_type": "Team"]))
    }
}
