import CryptoKit
import Security
import XCTest
@testable import Eyeballs

final class AuthenticationTests: XCTestCase {
    let callback = URL(string: "http://127.0.0.1:1455/auth/callback")!
    func testNewAccountUsesItsOwnDynamicRegistrationAndPKCE() throws {
        let first = try OAuthAttempt(redirectURI: callback, hostID: "urn:uuid:phone")
        let second = try OAuthAttempt(redirectURI: callback, hostID: "urn:uuid:phone")
        XCTAssertNotEqual(first.state, second.state)
        XCTAssertNotEqual(first.nonce, second.nonce)
        XCTAssertNotEqual(first.verifier, second.verifier)
        let items = URLComponents(url: first.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(value("client_id"), "dynamic_agent_client")
        XCTAssertEqual(value("agent_name_hint"), "Eyeballs")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("code_challenge"), Data(SHA256.hash(data: Data(first.verifier.utf8))).base64URL)
        XCTAssertEqual(value("redirect_uri"), callback.absoluteString)
        XCTAssertNil(value("id_token_hint"))
    }
    func testForgedAndAmbiguousCallbacksAreRejected() throws {
        let attempt = try OAuthAttempt(redirectURI: callback, hostID: "urn:uuid:phone")
        let valid = callback.absoluteString + "?state=\(attempt.state)&code=fixture-code&client_id=oaiapp_fixture"
        XCTAssertEqual(try attempt.validateCallback(URL(string: valid)!).clientID, "oaiapp_fixture")
        for forged in [valid.replacingOccurrences(of: attempt.state, with: "wrong-state"), valid + "&state=\(attempt.state)", valid + "&code=other", valid.replacingOccurrences(of: "127.0.0.1", with: "localhost"), valid.replacingOccurrences(of: "1455", with: "1456"), valid.replacingOccurrences(of: "/auth/callback", with: "/callback"), valid.replacingOccurrences(of: "oaiapp_fixture", with: "dynamic_agent_client")] {
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
}
