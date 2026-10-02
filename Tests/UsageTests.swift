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
    func testGrokOnDemandFallbackAndUnknownPercent() throws {
        let value = try UsageParser.grok(["config": ["onDemandCap": ["val": 200], "onDemandUsed": ["val": 50]]])
        XCTAssertEqual(value.windows[0].safePercent, 25)
        let unknown = try UsageParser.grok(["config": ["currentPeriod": ["end": "2026-10-08T00:00:00Z"]]])
        XCTAssertNil(unknown.windows[0].safePercent)
        XCTAssertThrowsError(try UsageParser.grok(["config": [:]]))
    }
    func testResetMarksStaleWithoutInventingZero() {
        let now = Date(timeIntervalSince1970: 1790931600)
        let window = UsageWindow(id: "window", title: "Window", usedPercent: 97, resetsAt: now.addingTimeInterval(-1), duration: 18000)
        let snapshot = UsageSnapshot(windows: [window], updatedAt: now.addingTimeInterval(-10))
        XCTAssertTrue(snapshot.isStale(at: now))
        XCTAssertEqual(snapshot.windows[0].safePercent, 97)
        XCTAssertNil(window.pace(at: now))
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
}

enum Fixture {
    static func credential(_ name: String) -> AccountCredential {
        AccountCredential(provider: .codex, issuer: "https://auth.openai.com", clientID: "oaiapp_fixture-" + name, subject: "subject-" + name, accountID: "account-" + name,
                          hostID: "urn:uuid:fixture", accessToken: "fixture-" + name, refreshToken: "fixture-refresh-" + name, idToken: nil,
                          scopes: ["chatgpt.tokens.use.direct"], expiresAt: .distantFuture, email: "same-email@example.com")
    }
    static func account(_ credential: AccountCredential, label: String = "") -> AgentAccount {
        AgentAccount(provider: credential.provider, label: label, snapshot: UsageSnapshot(windows: [UsageWindow(id: "weekly", title: "Weekly", usedPercent: 25)], identity: credential.registrationIdentity))
    }
}
