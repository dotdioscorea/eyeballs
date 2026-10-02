import XCTest
@testable import Eyeballs

final class UsageTests: XCTestCase {
    func testCodexWeeklyPrimaryIsNotPresentedAsAShortWindow() throws {
        let raw: [String: Any] = ["plan_type": "pro", "rate_limit": ["primary_window": ["used_percent": 41, "reset_at": 1791104422, "limit_window_seconds": 604800]]]
        let value = try UsageParser.codex(raw)
        XCTAssertEqual(value.windows.count, 1)
        XCTAssertEqual(value.windows[0].title, "Weekly")
        XCTAssertEqual(value.windows[0].safePercent, 41)
        XCTAssertEqual(value.windows[0].resetsAt, Date(timeIntervalSince1970: 1791104422))
    }
    func testClaudeMissingLimitsRemainMissing() throws {
        let raw: [String: Any] = ["five_hour": ["utilization": NSNull(), "resets_at": NSNull()], "seven_day": NSNull()]
        let value = try UsageParser.claude(raw)
        XCTAssertEqual(value.windows.count, 1)
        XCTAssertNil(value.windows[0].safePercent)
        XCTAssertNil(value.windows[0].resetsAt)
        XCTAssertThrowsError(try UsageParser.claude([:]))
        XCTAssertThrowsError(try UsageParser.codex([:]))
    }
    func testInvalidPercentagesAndBooleanDatesAreRejected() {
        XCTAssertNil(UsageParser.percent(true))
        XCTAssertNil(UsageParser.percent(-1))
        XCTAssertNil(UsageParser.percent(Double.nan))
        XCTAssertNil(UsageParser.date(true))
        XCTAssertNil(UsageParser.date("unknown"))
        XCTAssertEqual(UsageParser.percent(0), 0)
        XCTAssertEqual(UsageWindow(id: "limit", title: "Limit", usedPercent: 150).safePercent, 100)
    }
    func testGrokQuotaResetAndBillingStaySeparate() throws {
        let value = try UsageParser.grok(["config": ["creditUsagePercent": 23, "currentPeriod": ["start": "2026-10-01T00:00:00Z", "end": "2026-10-08T00:00:00Z"], "billingPeriodStart": "2026-09-15T00:00:00Z", "billingPeriodEnd": "2026-10-15T00:00:00Z"]])
        XCTAssertEqual(value.windows[0].safePercent, 23)
        XCTAssertEqual(value.windows[0].duration, 604800)
        XCTAssertNotEqual(value.windows[0].resetsAt, value.billingEndsAt)
        XCTAssertEqual(value.windows[0].title, "Weekly credits")
        let missingStart = try UsageParser.grok(["config": ["creditUsagePercent": 23, "currentPeriod": ["end": "2026-10-08T00:00:00Z"], "billingPeriodStart": "2026-09-15T00:00:00Z"]])
        XCTAssertNil(missingStart.windows[0].duration)
    }
    func testGrokOnDemandBudgetIsSeparateFromIncludedUsage() throws {
        let value = try UsageParser.grok(["config": ["monthlyLimit": ["val": 400], "used": ["val": 40], "onDemandCap": ["val": 200], "onDemandUsed": ["val": 50]]])
        XCTAssertEqual(value.windows[0].safePercent, 10)
        XCTAssertEqual(value.windows[1].safePercent, 25)
        let unknown = try UsageParser.grok(["config": ["currentPeriod": ["end": "2026-10-08T00:00:00Z"]]])
        XCTAssertNil(unknown.windows[0].safePercent)
        XCTAssertThrowsError(try UsageParser.grok(["config": [:]]))
    }
    func testLiveGrokProtoZeroShapeReportsFullRemainingQuota() throws {
        let raw: [String: Any] = ["config": ["currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY", "start": "2026-10-02T14:53:18.095343+00:00", "end": "2026-10-09T14:53:18.095343+00:00"], "isUnifiedBillingUser": true, "onDemandCap": ["val": 0], "onDemandUsed": ["val": 0], "prepaidBalance": ["val": 0]]]
        let value = try UsageParser.grok(raw)
        XCTAssertEqual(value.windows[0].safePercent, 0)
        XCTAssertEqual(value.windows[0].duration, 604800)
        let account = AgentAccount(provider: .grok, snapshot: value)
        XCTAssertEqual(account.readings().first?.percent, 100)
        let diagnostic = UsageParsingDiagnostic.make(provider: .grok, raw: raw, snapshot: value)
        XCTAssertEqual(diagnostic.fields[.creditUsagePercent], .missing)
        XCTAssertEqual(diagnostic.fields[.isUnifiedBillingUser], .boolean)
        XCTAssertEqual(diagnostic.calculation, .protoZero)
        XCTAssertEqual(diagnostic.readings, [.zeroUsed])
    }
    func testGrokNullPercentageDoesNotImplyZeroAndLegacyCentsCanOmitZero() throws {
        let value = try UsageParser.grok(["config": ["creditUsagePercent": NSNull(), "isUnifiedBillingUser": true, "currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2026-10-09T14:53:18Z"]]])
        XCTAssertNil(value.windows[0].safePercent)
        let legacy = try UsageParser.grok(["config": ["monthlyLimit": ["val": "200"], "used": [:]]])
        XCTAssertEqual(legacy.windows[0].safePercent, 0)
        XCTAssertNil(UsageParser.cent(nil))
    }
    func testCodexBankedResetsKeepOnlyAvailableUnexpiredCredits() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows: [[String: Any]] = [
            ["id": "private-credit-1", "title": "Weekly reset", "status": "available", "expires_at": now.addingTimeInterval(3600).timeIntervalSince1970],
            ["id": "private-credit-2", "status": "available"],
            ["status": "redeemed", "expires_at": now.addingTimeInterval(3600).timeIntervalSince1970],
            ["status": "available", "expires_at": now.addingTimeInterval(-1).timeIntervalSince1970]
        ]
        let credits = try XCTUnwrap(UsageParser.codexResets(["credits": rows], now: now))
        XCTAssertEqual(credits.count, 2); XCTAssertEqual(credits.first?.expiresAt, now.addingTimeInterval(3600))
        XCTAssertNil(credits.last?.expiresAt)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(credits), as: UTF8.self).contains("private-credit"))
        XCTAssertNil(UsageParser.codexResets([:]))
        let summary = try UsageParser.codex(["rate_limit": [:], "rate_limit_reset_credits": ["available_count": 3]])
        XCTAssertEqual(summary.bankedResets?.first?.count, 3)
    }
    func testGeminiQuotasKeepModelBucketsIndependentAndHandleExhaustion() throws {
        let raw: [String: Any] = ["buckets": [
            ["modelId": "gemini-pro", "remainingFraction": 0.75, "remainingAmount": "75", "resetTime": "2026-10-03T07:00:00Z"],
            ["modelId": "gemini-flash", "remainingAmount": "0", "resetTime": "2026-10-03T07:00:00Z"],
            ["modelId": "gemini-unknown", "resetTime": "2026-10-03T07:00:00Z"],
            ["modelId": "gemini-invalid", "remainingFraction": 1.2]
        ]]
        let value = try UsageParser.gemini(raw)
        XCTAssertEqual(value.windows.map(\.safePercent), [25, 100, nil, nil])
        XCTAssertTrue(value.windows.allSatisfy { $0.duration == nil })
        XCTAssertEqual(AgentAccount(provider: .gemini, snapshot: value).readings().map(\.percent), [75, 0])
        XCTAssertThrowsError(try UsageParser.gemini([:]))
        let malformed = try UsageParser.gemini(["buckets": [["modelId": "boolean", "remainingFraction": true]]])
        XCTAssertNil(malformed.windows.first?.safePercent)
    }
    func testCopilotLiveTokenBillingShapeSkipsUnlimitedQuotasAndPreservesRemaining() throws {
        let raw: [String: Any] = ["copilot_plan": "individual", "token_based_billing": true, "quota_reset_date_utc": "2026-11-01T00:00:00.000Z", "quota_snapshots": [
            "chat": ["unlimited": true, "entitlement": 0, "percent_remaining": 100],
            "completions": ["unlimited": true, "entitlement": 0, "percent_remaining": 100],
            "premium_interactions": ["unlimited": false, "entitlement": 1500, "percent_remaining": 16.8, "quota_remaining": 252.3, "quota_reset_at": 0]
        ]]
        let value = try UsageParser.copilot(raw)
        XCTAssertEqual(value.windows.count, 1); XCTAssertEqual(value.windows[0].title, "AI credits")
        XCTAssertEqual(value.windows[0].usedPercent!, 83.2, accuracy: 0.0001)
        XCTAssertEqual(value.windows[0].resetsAt, UsageParser.date("2026-11-01T00:00:00Z"))
        let legacy = try UsageParser.copilot(["quota_reset_date": "2026-11-01", "monthly_quotas": ["chat": 50, "completions": 2000], "limited_user_quotas": ["chat": 35, "completions": 1000]])
        XCTAssertEqual(legacy.windows.map(\.safePercent), [30, 50])
        XCTAssertEqual(legacy.windows.first?.resetsAt, UsageParser.date("2026-11-01T00:00:00Z"))
        let invalid = try UsageParser.copilot(["quota_snapshots": ["chat": ["percent_remaining": NSNull(), "entitlement": 10, "quota_remaining": 10]]])
        XCTAssertNil(invalid.windows.first?.safePercent)
        XCTAssertThrowsError(try UsageParser.copilot([:]))
    }
    func testResetMarksStaleWithoutInventingZero() {
        let now = Date(timeIntervalSince1970: 1790931600)
        let window = UsageWindow(id: "window", title: "Window", usedPercent: 97, resetsAt: now.addingTimeInterval(-1), duration: 18000)
        let snapshot = UsageSnapshot(windows: [window], updatedAt: now.addingTimeInterval(-10))
        XCTAssertTrue(snapshot.isStale(at: now))
        XCTAssertEqual(snapshot.windows[0].safePercent, 97)
    }
    func testCredentialsAreRoutedOnlyToTheirProvider() throws {
        let credential = Fixture.credential("a")
        let request = try UsageClient.request(provider: .codex, credential: credential)
        XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-a")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account-a")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertThrowsError(try UsageClient.request(provider: .claude, credential: credential))
        var wrongIssuer = credential; wrongIssuer.issuer = "https://example.com"
        XCTAssertThrowsError(try UsageClient.request(provider: .codex, credential: wrongIssuer))
    }
    func testRetryAfterSupportsSecondsAndHTTPDates() {
        let now = Date(timeIntervalSince1970: 1790931600)
        XCTAssertEqual(ProviderHTTP.retryDate("120", now: now), now.addingTimeInterval(120))
        XCTAssertEqual(ProviderHTTP.retryDate("Fri, 02 Oct 2026 11:00:00 GMT", now: now), Date(timeIntervalSince1970: 1790938800))
        XCTAssertEqual(ProviderHTTP.retryDate("invalid", now: now), now.addingTimeInterval(300))
    }
    func testFreshUsageRejectionIsNotReportedAsExpiredLogin() throws {
        let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        for status in [401, 403] {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            XCTAssertThrowsError(try ProviderHTTP.decodeJSON(Data("{}".utf8), response: response, unauthorizedError: .usageAccessDenied)) { error in
                guard case UsageError.usageAccessDenied = error else { return XCTFail("A fresh grant rejection was treated as expired") }
            }
        }
    }
}

enum Fixture {
    static func credential(_ name: String) -> AccountCredential {
        AccountCredential(provider: .codex, issuer: "https://auth.openai.com", clientID: OpenAIAuth.codexClientID, subject: "subject-" + name, accountID: "account-" + name,
                          hostID: "urn:uuid:fixture", accessToken: "fixture-" + name, refreshToken: "fixture-refresh-" + name, idToken: nil,
                          scopes: ["openid", "profile", "email", "offline_access"], expiresAt: .distantFuture, email: "same-email@example.com")
    }
    static func account(_ credential: AccountCredential, label: String = "") -> AgentAccount {
        AgentAccount(provider: credential.provider, label: label, snapshot: UsageSnapshot(windows: [UsageWindow(id: "weekly", title: "Weekly", usedPercent: 25)], identity: credential.registrationIdentity))
    }
}
