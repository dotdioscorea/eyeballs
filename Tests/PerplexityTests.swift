import XCTest
@testable import Eyeballs

final class PerplexityTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let token = "header..iv.ciphertext.tag"
    func credential(_ id: String = "account-a") throws -> AccountCredential {
        try PerplexityAuth.validated(["user": ["id": id, "email": "person@example.test"], "expires": now.addingTimeInterval(3600).ISO8601Format()], token: token,
                                    previous: nil, expectedEmail: "person@example.test", hostID: "host", now: now)
    }
    func status(_ count: Any = 3) -> [String: Any] {
        ["modes": ["pro_search": ["available": true, "remaining_detail": ["kind": "exact", "remaining": count]],
                   "research": ["available": false, "remaining_detail": ["kind": "exact", "remaining": 0]]]]
    }
    var profile: [String: Any] { ["id": "account-a", "payment_tier": "none", "subscription_status": "none", "subscription_tier": "none"] }
    func testEmailAndCodeValidationKeepRequestsOnTheProvider() throws {
        XCTAssertEqual(try PerplexityAuth.email(" person+work@example.test "), "person+work@example.test")
        for value in ["", "person", "person@example.test\r\nInjected: yes", "a@x", "a b@example.test"] { XCTAssertThrowsError(try PerplexityAuth.email(value)) }
        let attempt = PerplexityAuth.Attempt(email: "person+work@example.test", csrfCookie: "next-auth.csrf-token=csrf%7Chash", startedAt: now)
        let request = try PerplexityAuth.verificationRequest(attempt, code: "123456", now: now)
        XCTAssertEqual(request.url?.host, "www.perplexity.ai")
        XCTAssertEqual(request.url?.scheme, "https")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "email" }?.value, attempt.email)
        XCTAssertEqual(DiagnosticEndpoint.identify(request.url), .token)
        for code in ["12345", "1234567", "12345a", "123456\n"] { XCTAssertThrowsError(try PerplexityAuth.verificationRequest(attempt, code: code, now: now)) }
        XCTAssertThrowsError(try PerplexityAuth.verificationRequest(attempt, code: "123456", now: now.addingTimeInterval(301)))
    }
    func testSessionRequestsAreIsolatedAndRejectCredentialInjection() throws {
        var c = try credential()
        let request = try PerplexityAuth.sessionRequest("/rest/rate-limit/status", credential: c)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), PerplexityAuth.cookieName + "=" + token)
        XCTAssertFalse(request.url!.absoluteString.contains(token))
        for path in ["https://attacker.test/", "/api/auth/signout", "/rest/billing/credits/purchase"] { XCTAssertThrowsError(try PerplexityAuth.sessionRequest(path, credential: c)) }
        for value in ["token; another=value", "token\r\nHeader: value", "", String(repeating: "x", count: 24_001)] {
            c.accessToken = value; XCTAssertThrowsError(try PerplexityAuth.sessionRequest("/api/user", credential: c))
        }
        c = try credential(); c.issuer = "https://attacker.test"; XCTAssertThrowsError(try PerplexityAuth.sessionRequest("/api/user", credential: c))
    }
    func testSessionRenewalPreservesIdentityAndUsesReportedExpiry() throws {
        let old = try credential()
        let raw: [String: Any] = ["user": ["id": "account-a", "email": "PERSON@example.test"], "expires": now.addingTimeInterval(7200).ISO8601Format()]
        let new = try PerplexityAuth.validated(raw, token: "new..iv.ciphertext.tag", previous: old, expectedEmail: "person@example.test", hostID: old.hostID, now: now)
        XCTAssertEqual(new.registrationIdentity, old.registrationIdentity)
        XCTAssertEqual(new.expiresAt, now.addingTimeInterval(7200))
        XCTAssertNotEqual(new.accessToken, old.accessToken)
        XCTAssertThrowsError(try PerplexityAuth.validated(raw, token: token, previous: try credential("account-b"), expectedEmail: nil, hostID: "host", now: now))
        XCTAssertThrowsError(try PerplexityAuth.validated(raw, token: token, previous: old, expectedEmail: "other@example.test", hostID: "host", now: now))
        for expiry in [now.addingTimeInterval(-1), now.addingTimeInterval(61 * 86400)] {
            var bad = raw; bad["expires"] = expiry.ISO8601Format()
            XCTAssertThrowsError(try PerplexityAuth.validated(bad, token: token, previous: old, expectedEmail: nil, hostID: "host", now: now))
        }
        XCTAssertThrowsError(try PerplexityAuth.validated([:], token: token, previous: old, expectedEmail: nil, hostID: "host", now: now))
    }
    func testOnlySecureProviderSessionCookiesCanRotateTheToken() throws {
        func response(_ cookie: String) -> HTTPURLResponse { HTTPURLResponse(url: URL(string: PerplexityAuth.issuer + "/api/auth/session")!, statusCode: 200, httpVersion: nil, headerFields: ["Set-Cookie": cookie])! }
        XCTAssertEqual(try PerplexityAuth.token(response(PerplexityAuth.cookieName + "=" + token + "; Path=/; Secure; HttpOnly")), token)
        XCTAssertThrowsError(try PerplexityAuth.token(response(PerplexityAuth.cookieName + "=" + token + "; Path=/")))
        XCTAssertThrowsError(try PerplexityAuth.token(response(PerplexityAuth.cookieName + "=" + token + "; Domain=attacker.test; Path=/; Secure")))
        XCTAssertThrowsError(try PerplexityAuth.token(response(PerplexityAuth.cookieName + "=not-a-session; Path=/; Secure")))
    }
    func testRemainingCountsAreNotConvertedIntoPercentagesOrResetDates() throws {
        let snapshot = try UsageParser.perplexity(status(), profile: profile, subject: "account-a")
        XCTAssertTrue(snapshot.windows.isEmpty); XCTAssertNil(snapshot.nextReset)
        XCTAssertEqual(snapshot.plan, "Free")
        XCTAssertEqual(snapshot.remainingAllowances?.first?.remaining, 3)
        XCTAssertEqual(snapshot.remainingAllowances?.last?.remaining, 0)
        XCTAssertEqual(AgentAccount(provider: .perplexity, snapshot: snapshot).allowanceSummary, "Pro searches · 3 left")
        XCTAssertThrowsError(try UsageParser.perplexity(status(), profile: profile, subject: "account-b"))
        for invalid in [true as Any, -1, 2.5, Double.infinity, "three"] { XCTAssertThrowsError(try UsageParser.perplexity(status(invalid), profile: profile, subject: "account-a")) }
        XCTAssertThrowsError(try UsageParser.perplexity(["modes": [:]], profile: profile, subject: "account-a"))
    }
    func testUnreportedCountDoesNotBecomeZeroOrUnlimited() throws {
        let raw: [String: Any] = ["modes": ["pro_search": ["available": true, "remaining_detail": ["kind": "not_provided"]]]]
        let snapshot = try UsageParser.perplexity(raw, profile: profile, subject: "account-a")
        XCTAssertNil(snapshot.remainingAllowances?.first?.remaining)
        XCTAssertEqual(snapshot.remainingAllowances?.first?.value, "Available")
    }
    func testDebugBundleDescribesCountSchemaWithoutCopyingValues() throws {
        let diagnostic = UsageParsingDiagnostic.make(provider: .perplexity, raw: status(97), snapshot: nil)
        XCTAssertEqual(diagnostic.fields[.remainingCount], .number)
        XCTAssertEqual(diagnostic.fields[.remainingKind], .string)
        let encoded = String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self)
        XCTAssertFalse(encoded.contains("97")); XCTAssertFalse(encoded.contains("person@example.test"))
        let changed = UsageParsingDiagnostic.make(provider: .perplexity, raw: status("ninety-seven"), snapshot: nil)
        XCTAssertEqual(changed.fields[.remainingCount], .string)
    }
    func testRemainingCountHistoryRetainsChangesAndBreaksAtMissingReadings() throws {
        var snapshot = try UsageParser.perplexity(status(), profile: profile, subject: "account-a"); snapshot.updatedAt = now
        let store = UsageHistoryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var samples = store.append(snapshot, to: [], now: now)
        snapshot.updatedAt = now.addingTimeInterval(30); samples = store.append(snapshot, to: samples, now: snapshot.updatedAt)
        snapshot.updatedAt = now.addingTimeInterval(60); snapshot.remainingAllowances?[0].remaining = 2
        samples = store.append(snapshot, to: samples, now: snapshot.updatedAt)
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(RemainingAllowanceSeries.segments(samples, metric: "pro_search").first?.map(\.usedPercent), [3, 3, 2])
        var missing = samples[2]; missing.date = now.addingTimeInterval(90); missing.remainingAllowances?[0].remaining = nil
        var next = samples[2]; next.date = now.addingTimeInterval(120)
        XCTAssertEqual(RemainingAllowanceSeries.segments(samples + [missing, next], metric: "pro_search").count, 2)
        let savedID = UUID(); defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.write(samples, id: savedID)
        XCTAssertEqual(store.read(savedID, now: snapshot.updatedAt), samples)
        let old = try JSONDecoder().decode(UsageHistorySample.self, from: JSONEncoder().encode(UsageHistorySample(date: now, windows: [])))
        XCTAssertNil(old.remainingAllowances)
    }
    func testWidgetSummaryKeepsAllowancesAndExcludesAccountIdentity() throws {
        var snapshot = try UsageParser.perplexity(status(), profile: profile, subject: "account-a"); snapshot.identity = "private-account"; snapshot.email = "private@example.test"
        let account = AgentAccount(provider: .perplexity, label: "Personal", snapshot: snapshot)
        let summary = WidgetCache.sanitized([account])[0]
        XCTAssertEqual(summary.snapshot?.remainingAllowances, account.snapshot?.remainingAllowances)
        XCTAssertNil(summary.snapshot?.email); XCTAssertNil(summary.snapshot?.identity)
    }
}
