import XCTest
@testable import Requota

final class ClineTests: XCTestCase {
    func testDeviceVerificationRejectsForeignAndAmbiguousURLs() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let good: [String: Any] = ["device_code": "private-device", "user_code": "ABCD-1234", "verification_uri": "https://authkit.cline.bot/device", "verification_uri_complete": "https://authkit.cline.bot/device?user_code=ABCD-1234", "expires_in": 300, "interval": 5]
        let value = try ClineAuth.Verification.decode(good, now: now)
        XCTAssertEqual(value.url.absoluteString, "https://authkit.cline.bot/device?user_code=ABCD-1234")
        XCTAssertEqual(value.expiresAt, now.addingTimeInterval(300))
        XCTAssertFalse(value.url.absoluteString.contains("private-device"))
        for url in ["https://authkit.cline.bot.evil.test/device", "http://authkit.cline.bot/device", "https://user@authkit.cline.bot/device", "https://authkit.cline.bot:444/device", "https://authkit.cline.bot/device#fragment", "https://authkit.cline.bot/device?user_code=DIFF-1234", "https://authkit.cline.bot/device?user_code=ABCD-1234&user_code=ABCD-1234"] {
            var bad = good; bad["verification_uri_complete"] = url
            XCTAssertThrowsError(try ClineAuth.Verification.decode(bad))
        }
        for (key, badValue) in [("expires_in", true as Any), ("expires_in", 1801), ("interval", 0), ("user_code", "../../../private")] {
            var bad = good; bad[key] = badValue
            XCTAssertThrowsError(try ClineAuth.Verification.decode(bad))
        }
    }

    func testPollingDistinguishesPendingAndTerminalFailures() throws {
        if case .pending = try ClineAuth.pollResult(["error": "authorization_pending"]) {} else { XCTFail() }
        if case .slowDown = try ClineAuth.pollResult(["error": "slow_down"]) {} else { XCTFail() }
        for error in ["access_denied", "expired_token", "unknown_error"] {
            XCTAssertThrowsError(try ClineAuth.pollResult(["error": error]))
        }
        XCTAssertThrowsError(try ClineAuth.pollResult(["access_token": "private-access"]))
        XCTAssertThrowsError(try ClineAuth.pollResult(["access_token": "private-access", "refresh_token": "private-refresh", "token_type": "Basic"]))
        if case .tokens = try ClineAuth.pollResult(["access_token": "private-access", "refresh_token": "private-refresh", "token_type": "Bearer"]) {} else { XCTFail() }
    }

    func testRequestsKeepTokensOutOfURLsAndLimitEndpoints() throws {
        let request = try ClineAuth.apiRequest("/api/v1/users/private-user/balance", accessToken: "private-access")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer workos:private-access")
        XCTAssertFalse(request.url!.absoluteString.contains("private-access"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(try ClineAuth.apiRequest("/api/v1/users/me", accessToken: "workos:private-access").value(forHTTPHeaderField: "Authorization"), "Bearer workos:private-access")
        for path in ["/api/v1/users/../balance", "https://evil.test", "/api/v1/users/private-user/balance?token=x", "/api/v1/agents", "/api/v1/users/me?x=1"] {
            XCTAssertThrowsError(try ClineAuth.apiRequest(path, accessToken: "private-access"))
        }
        XCTAssertThrowsError(try ClineAuth.apiRequest("/api/v1/users/me", accessToken: "private-access", body: ["value": "private"]))
        XCTAssertThrowsError(try ClineAuth.apiRequest("/api/v1/auth/register", accessToken: "private-access"))
    }

    func testRegisteredTokensBindToAuthenticatedProfileAndReturningAccount() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let data: [String: Any] = ["accessToken": "new-access", "refreshToken": "new-refresh", "tokenType": "Bearer", "expiresAt": "2027-01-15T09:00:00.123456789Z", "userInfo": ["clineUserId": "account-a"]]
        let raw: [String: Any] = ["success": true, "data": data]
        let profile: [String: Any] = ["success": true, "data": ["id": "account-a", "email": "private@example.test"]]
        let first = try ClineAuth.validatedCredential(raw, profile: profile, previous: nil, now: now)
        XCTAssertEqual(first.subject, "account-a")
        XCTAssertEqual(first.expiresAt.timeIntervalSince(now), 3600.123456789, accuracy: 0.001)
        let rotated = try ClineAuth.validatedCredential(raw, profile: profile, previous: first, now: now)
        XCTAssertEqual(rotated.hostID, first.hostID)
        var other = first; other.subject = "account-b"
        XCTAssertThrowsError(try ClineAuth.validatedCredential(raw, profile: profile, previous: other, now: now))
        other = first; other.provider = .codex
        XCTAssertThrowsError(try ClineAuth.validatedCredential(raw, profile: profile, previous: other, now: now))
        let wrongProfile: [String: Any] = ["success": true, "data": ["id": "account-b"]]
        XCTAssertThrowsError(try ClineAuth.validatedCredential(raw, profile: wrongProfile, previous: nil, now: now))
        XCTAssertThrowsError(try ClineAuth.validatedCredential(raw, profile: profile, previous: nil, now: now.addingTimeInterval(3601)))
        XCTAssertThrowsError(try ClineAuth.identity(["success": true, "data": ["id": "../private"]]))
    }

    func testCreditBalanceKeepsZeroDistinctFromMissingWithoutInventingQuota() throws {
        for (balance, expected) in [(0, "0.0000"), (500_000, "0.5000"), (1_234_567, "1.2346"), (-250_000, "-0.2500")] {
            let raw: [String: Any] = ["success": true, "data": ["userId": "private-user", "balance": balance, "privateField": "private-value"]]
            let snapshot = try UsageParser.cline(raw, subject: "private-user")
            XCTAssertEqual(snapshot.creditBalance, expected)
            XCTAssertTrue(snapshot.windows.isEmpty)
            XCTAssertNil(snapshot.billingEndsAt)
            let diagnostic = UsageParsingDiagnostic.make(provider: .cline, raw: raw, snapshot: snapshot)
            let json = String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self)
            XCTAssertEqual(diagnostic.fields[.creditBalance], .number)
            XCTAssertFalse(json.contains("private-user")); XCTAssertFalse(json.contains("private-value"))
        }
        for value in [NSNull(), true, Double.infinity, "12.75"] as [Any] {
            XCTAssertThrowsError(try UsageParser.cline(["success": true, "data": ["userId": "private-user", "balance": value]], subject: "private-user"))
        }
        XCTAssertThrowsError(try UsageParser.cline(["success": true, "data": ["userId": "other-user", "balance": 0]], subject: "private-user"))
    }
}
