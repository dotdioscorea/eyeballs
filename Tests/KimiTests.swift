import XCTest
@testable import Eyeballs

final class KimiTests: XCTestCase {
    func testDeviceAuthorizationStaysInSelectedRegionAndRejectsAmbiguousURLs() throws {
        for region in KimiAuth.Region.allCases {
            let base = "https://" + region.siteHost + "/code/authorize_device"
            let good: [String: Any] = ["device_code": "private-device", "user_code": "ABCD-1234", "verification_uri": base, "verification_uri_complete": base + "?user_code=ABCD-1234", "expires_in": 1800, "interval": 5]
            let attempt = try KimiAuth.Verification.decode(good, region: region, hostID: "device")
            XCTAssertEqual(attempt.url.absoluteString, base + "?user_code=ABCD-1234")
            for badURL in [base + "?user_code=ABCD-1234&user_code=ABCD-1234", base + "#fragment", "https://www.kimi.com.evil.test/code/authorize_device?user_code=ABCD-1234", "http://" + region.siteHost + "/code/authorize_device?user_code=ABCD-1234"] {
                var bad = good; bad["verification_uri_complete"] = badURL
                XCTAssertThrowsError(try KimiAuth.Verification.decode(bad, region: region, hostID: "device"))
            }
            var bad = good; bad["expires_in"] = true
            XCTAssertThrowsError(try KimiAuth.Verification.decode(bad, region: region, hostID: "device"))
        }
        XCTAssertThrowsError(try KimiAuth.Region.matching("https://auth.kimi.com.evil.test"))
    }
    func testProfileIdentityRefreshRotationAndDifferentAccountRejection() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let raw: [String: Any] = ["access_token": "access", "refresh_token": "refresh", "scope": "kimi-code", "token_type": "Bearer", "expires_in": 900]
        let profile: [String: Any] = ["user_id": "account-a", "email": "private@example.test", "user_level_name": "Free"]
        let first = try KimiAuth.validatedCredential(raw, profile: profile, region: .global, hostID: "device", previous: nil, now: now)
        var rotated = raw; rotated["access_token"] = "new-access"; rotated["refresh_token"] = "new-refresh"
        let second = try KimiAuth.validatedCredential(rotated, profile: profile, region: .global, hostID: first.hostID, previous: first, now: now)
        XCTAssertEqual(second.refreshToken, "new-refresh"); XCTAssertEqual(second.registrationIdentity, first.registrationIdentity)
        XCTAssertEqual(second.expiresAt, now.addingTimeInterval(900))
        XCTAssertThrowsError(try KimiAuth.validatedCredential(raw, profile: ["user_id": "account-b"], region: .global, hostID: "device", previous: first, now: now))
        XCTAssertThrowsError(try KimiAuth.validatedCredential(raw, profile: profile, region: .mainlandChina, hostID: "device", previous: first, now: now))
        for (key, value) in [("expires_in", true as Any), ("scope", "other"), ("token_type", "Basic"), ("refresh_token", "")] {
            var bad = raw; bad[key] = value
            XCTAssertThrowsError(try KimiAuth.validatedCredential(bad, profile: profile, region: .global, hostID: "device", previous: nil, now: now))
        }
    }
    func testReadOnlyRequestsBindCredentialsToRegion() throws {
        let raw: [String: Any] = ["access_token": "private-access", "refresh_token": "refresh", "scope": "kimi-code", "expires_in": 900]
        for region in KimiAuth.Region.allCases {
            var credential = try KimiAuth.validatedCredential(raw, profile: ["user_id": "account-a"], region: region, hostID: "device", previous: nil)
            let request = try UsageClient.request(provider: .kimi, credential: credential)
            XCTAssertEqual(request.url!.absoluteString, region.api + "/usages")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer private-access")
            XCTAssertFalse(request.url!.absoluteString.contains("private-access"))
            let account = AgentAccount(provider: .kimi, snapshot: UsageSnapshot(identity: credential.registrationIdentity))
            XCTAssertEqual(account.usageURL.host, region.siteHost)
            credential.issuer = "https://evil.test"
            XCTAssertThrowsError(try UsageClient.request(provider: .kimi, credential: credential))
        }
        XCTAssertThrowsError(try KimiAuth.request("/keys", region: .global, accessToken: "token"))
        XCTAssertEqual(DiagnosticEndpoint.identify(URL(string: "https://auth.kimi.ai/api/oauth/token")), .token)
        XCTAssertEqual(DiagnosticEndpoint.identify(URL(string: "https://api.kimi.ai/coding/v1/me")), .identity)
    }
    func testModernQuotaRatioWindowsAndUnknownMonthlyDuration() throws {
        let raw: [String: Any] = ["usages": ["limit_5h": ["used_ratio": 0, "reset_time": "2026-10-04T12:00:00Z"], "limit_7d": ["used_ratio": "0.75"], "limit_month_code": ["used_ratio": 1.25]]]
        let snapshot = try UsageParser.kimi(raw, profile: ["user_id": "account-a", "user_level_name": "Vivace"], subject: "account-a")
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [0, 75, 125])
        XCTAssertEqual(snapshot.windows.map(\.duration), [18000, 604800, nil])
        XCTAssertEqual(snapshot.windows.last?.safePercent, 100)
        XCTAssertNil(snapshot.billingEndsAt)
        XCTAssertThrowsError(try UsageParser.kimi(raw, profile: ["user_id": "account-b"], subject: "account-a"))
    }
    func testOnlyVerifiedFreePlanAcceptsEmptyQuotaAndTierChangesChangeContext() throws {
        let free = try UsageParser.kimi([:], profile: ["user_id": "a", "user_level_name": "Free"], subject: "a")
        XCTAssertTrue(free.windows.isEmpty); XCTAssertNil(free.creditBalance)
        XCTAssertEqual(AgentAccount(provider: .kimi, snapshot: free).emptyMetricMessage, "No quota reported")
        for plan in ["Vivace", "Unknown"] { XCTAssertThrowsError(try UsageParser.kimi([:], profile: ["user_id": "a", "user_level_name": plan], subject: "a")) }
        for ratio in [true, "bad", -0.2, Double.infinity] as [Any] {
            XCTAssertThrowsError(try UsageParser.kimi(["usages": ["limit_7d": ["used_ratio": ratio]]], profile: ["user_id": "a", "user_level_name": "Free"], subject: "a"))
        }
        let paid = try UsageParser.kimi(["usages": ["limit_7d": ["used_ratio": 0]]], profile: ["user_id": "a", "user_level_name": "Vivace", "goods_version": 2], subject: "a")
        XCTAssertNotEqual(paid.allowanceContext, free.allowanceContext)
    }
    func testBoosterBalanceAndSpendUseReportedCurrencyWithoutInventingReset() throws {
        let raw: [String: Any] = ["boosterWallet": ["balance": ["type": "BOOSTER", "amountLeft": "123000000"], "monthlyUsed": ["priceInCents": 150, "currency": "CNY"], "monthlyChargeLimit": ["priceInCents": 2000, "currency": "CNY"], "monthlyChargeLimitEnabled": true]]
        let snapshot = try UsageParser.kimi(raw, profile: ["user_id": "a"], subject: "a")
        XCTAssertEqual(snapshot.details?.spending.first?.balance, 1.23)
        XCTAssertEqual(snapshot.details?.spending.last?.used, 1.5)
        XCTAssertEqual(snapshot.details?.spending.last?.limit, 20)
        XCTAssertEqual(snapshot.details?.spending.last?.currency, "CNY")
        XCTAssertTrue(snapshot.windows.isEmpty); XCTAssertNil(snapshot.details?.spending.last?.resetsAt)
        let diagnostic = UsageParsingDiagnostic.make(provider: .kimi, raw: raw, snapshot: snapshot)
        let json = String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self)
        XCTAssertEqual(diagnostic.fields[.kimiWallet], .object)
        XCTAssertFalse(json.contains("CNY")); XCTAssertFalse(json.contains("123000000"))
    }
    func testLegacyAmountsDoNotClaimToBeTokensOrCredits() throws {
        let raw: [String: Any] = ["usage": ["limit": "100", "remaining": "40"], "limits": [["window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"], "detail": ["limit": 10, "used": 5]]]]
        let snapshot = try UsageParser.kimi(raw, profile: ["user_id": "a"], subject: "a")
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [60, 50])
        XCTAssertEqual(snapshot.windows.map(\.duration), [604800, 18000])
        XCTAssertTrue(snapshot.windows.allSatisfy { $0.amountUnit == nil })
    }
}
