import XCTest
@testable import Eyeballs

final class AmpTests: XCTestCase {
    private let profile: [String: Any] = ["ok": true, "result": ["id": "account-a", "email": "private@example.test"]]
    private func tokens(_ expiry: Date, access: String = "access", refresh: String = "refresh") -> [String: Any] {
        let body = try! JSONSerialization.data(withJSONObject: ["exp": expiry.timeIntervalSince1970]).base64URL
        return ["access_token": "header." + body + "." + access, "refresh_token": refresh, "user": ["id": "account-a"]]
    }
    func testDeviceGrantRejectsForeignAmbiguousAndExpiredMetadata() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let raw: [String: Any] = ["device_code": "private-device", "user_code": "ABCD-1234", "verification_uri": "https://auth.ampcode.com/device", "verification_uri_complete": "https://auth.ampcode.com/device?user_code=ABCD-1234", "expires_in": 300, "interval": 5]
        let attempt = try AmpAuth.Verification.decode(raw, now: now)
        XCTAssertEqual(attempt.expiresAt, now.addingTimeInterval(300))
        for url in ["https://auth.ampcode.com.evil.test/device?user_code=ABCD-1234", "https://auth.ampcode.com/device?user_code=ABCD-1234&user_code=ABCD-1234", "http://auth.ampcode.com/device?user_code=ABCD-1234", "https://auth.ampcode.com/device?user_code=ABCD-1234#fragment"] {
            var bad = raw; bad["verification_uri_complete"] = url
            XCTAssertThrowsError(try AmpAuth.Verification.decode(bad))
        }
        var bad = raw; bad["expires_in"] = true
        XCTAssertThrowsError(try AmpAuth.Verification.decode(bad))
    }
    func testSessionRotationUsesAuthenticatedIdentityAndRejectsOtherAccounts() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try AmpAuth.validatedCredential(tokens(now.addingTimeInterval(300)), profile: profile, previous: nil, now: now)
        let next = try AmpAuth.validatedCredential(tokens(now.addingTimeInterval(600), access: "rotated", refresh: "rotated-refresh"), profile: profile, previous: first, now: now)
        XCTAssertEqual(next.registrationIdentity, first.registrationIdentity)
        XCTAssertEqual(next.refreshToken, "rotated-refresh")
        XCTAssertEqual(next.expiresAt, now.addingTimeInterval(600))
        var different = first; different.subject = "account-b"
        XCTAssertThrowsError(try AmpAuth.validatedCredential(tokens(now.addingTimeInterval(300)), profile: profile, previous: different, now: now))
        XCTAssertThrowsError(try AmpAuth.validatedCredential(tokens(now.addingTimeInterval(-1)), profile: profile, previous: nil, now: now))
        XCTAssertThrowsError(try AmpAuth.validatedCredential(tokens(now.addingTimeInterval(300)), profile: ["ok": true, "result": ["id": "account-b"]], previous: nil, now: now))
    }
    func testReadOnlyRequestsNeverUseCookiesOrIncludeSecretsInURLs() throws {
        let request = try AmpAuth.request("userDisplayBalanceInfo", token: "private-token")
        XCTAssertEqual(request.url!.absoluteString, "https://ampcode.com/api/internal?userDisplayBalanceInfo")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer private-token")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["method"] as? String, "userDisplayBalanceInfo")
        XCTAssertEqual((body["params"] as? [String: Any])?["markdown"] as? Bool, false)
        for method in ["purchaseCredits", "startSubscription", "getAccessToken", "https://evil.test"] { XCTAssertThrowsError(try AmpAuth.request(method, token: "token")) }
        XCTAssertThrowsError(try AmpAuth.request("getUserInfo", token: "token\r\nInjected: true"))
        XCTAssertEqual(DiagnosticEndpoint.identify(request.url), .usage)
    }
    func testNativeBalanceKeepsZeroAndRejectsUnknownFormatsAndWrongIdentity() throws {
        for (amount, expected) in [("0", 0.0), ("12.34", 12.34), ("1,234.56", 1234.56)] {
            let raw: [String: Any] = ["ok": true, "result": ["displayText": "Signed in as private@example.test\nIndividual credits: $" + amount + " remaining - https://ampcode.com/settings\n"]]
            let snapshot = try UsageParser.amp(raw, profile: profile, subject: "account-a")
            XCTAssertEqual(snapshot.details?.spending.first?.balance, expected)
            XCTAssertEqual(snapshot.details?.spending.first?.currency, "USD")
            XCTAssertTrue(snapshot.windows.isEmpty); XCTAssertNil(snapshot.billingEndsAt); XCTAssertNil(snapshot.nextReset)
            let diagnostic = UsageParsingDiagnostic.make(provider: .amp, raw: raw, snapshot: snapshot)
            let json = String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self)
            XCTAssertFalse(json.contains("private@example.test")); XCTAssertFalse(json.contains("Individual credits"))
            XCTAssertThrowsError(try UsageParser.amp(raw, profile: profile, subject: "account-b"))
        }
        for text in ["Signed in as private@example.test\nIndividual credits: unavailable", "Signed in as other@example.test\nIndividual credits: $0 remaining", "Signed in as private@example.test\nIndividual credits: $0 remaining\nIndividual credits: $10 remaining", "Signed in as private@example.test\nIndividual credits: £10 remaining"] {
            XCTAssertThrowsError(try UsageParser.amp(["ok": true, "result": ["displayText": text]], profile: profile, subject: "account-a"))
        }
    }
}
