import XCTest
import CryptoKit
@testable import Eyeballs

final class DevinTests: XCTestCase {
    static func profile(plan: String = "Free", daily: Any? = 100, weekly: Any? = 75) -> [String: Any] {
        var status: [String: Any] = ["planInfo": ["planName": plan, "isDevin": true, "devinInfo": ["orgId": "org-a"]], "dailyQuotaResetAtUnix": "1791100800", "weeklyQuotaResetAtUnix": "1791619200"]
        status["dailyQuotaRemainingPercent"] = daily; status["weeklyQuotaRemainingPercent"] = weekly
        return ["userStatus": ["userId": "user-a", "email": "private@example.test", "planStatus": status]]
    }
    func testPKCEAuthorizationAndCallbackBindStateAndLoopback() throws {
        let attempt = try OAuthAttempt(redirectURI: URL(string: "http://127.0.0.1:43219/callback")!, hostID: "device", provider: .devin)
        let parts = try XCTUnwrap(URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: parts.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(parts.host, "app.devin.ai"); XCTAssertEqual(parts.path, "/auth/cli/continue")
        XCTAssertEqual(query["redirect_uri"], attempt.redirectURI.absoluteString)
        XCTAssertEqual(query["code_challenge"], Data(SHA256.hash(data: Data(attempt.verifier.utf8))).base64URL)
        XCTAssertEqual(query["code_challenge_method"], "S256"); XCTAssertEqual(query["cli_pkce_marker"], "1")
        XCTAssertEqual(query["prompt"], "select_account"); XCTAssertNil(query["client_id"])
        let callback = "http://127.0.0.1:43219/callback?code=one-time-code&state=" + attempt.state
        XCTAssertEqual(try attempt.validateCallback(URL(string: callback)!).code, "one-time-code")
        for bad in [callback + "&code=other", callback + "&state=other", callback + "#fragment", callback.replacingOccurrences(of: "43219", with: "43220"), callback.replacingOccurrences(of: "127.0.0.1", with: "localhost")] {
            XCTAssertThrowsError(try attempt.validateCallback(URL(string: bad)!))
        }
    }
    func testReadOnlyNativeRequestPinsCredentialAndUsesVendorHeader() throws {
        var credential = try DevinAuth.credential(token: "native$session-token", profile: Self.profile(), previous: nil, hostID: "device")
        let request = try UsageClient.request(provider: .devin, credential: credential)
        XCTAssertEqual(request.url!.absoluteString, DevinAuth.issuer + DevinAuth.service + "GetUserStatus")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic native$session-token-native$session-token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let metadata = try XCTUnwrap(body["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["apiKey"] as? String, credential.accessToken)
        XCTAssertFalse(request.url!.absoluteString.contains(credential.accessToken))
        XCTAssertThrowsError(try DevinAuth.request("PurchaseCredits", token: credential.accessToken))
        XCTAssertThrowsError(try DevinAuth.request("GetUserStatus", token: "token\r\nInjected: true"))
        credential.issuer = "https://evil.test"
        XCTAssertThrowsError(try UsageClient.request(provider: .devin, credential: credential))
        credential.issuer = DevinAuth.issuer; credential.clientID = "different"
        XCTAssertThrowsError(try UsageClient.request(provider: .devin, credential: credential))
    }
    func testVerifiedIdentitySupportsMultipleAccountsAndDoesNotInventExpiration() throws {
        let first = try DevinAuth.credential(token: "token-a", profile: Self.profile(), previous: nil, hostID: "device")
        let next = try DevinAuth.credential(token: "token-b", profile: Self.profile(plan: "Max"), previous: first, hostID: "device")
        XCTAssertEqual(first.registrationIdentity, next.registrationIdentity)
        XCTAssertEqual(next.expiresAt, .distantFuture); XCTAssertNil(next.refreshToken)
        var other = Self.profile(); var user = other["userStatus"] as! [String: Any]; user["userId"] = "user-b"; other["userStatus"] = user
        let separate = try DevinAuth.credential(token: "token-c", profile: other, previous: nil, hostID: "device")
        XCTAssertNotEqual(first.registrationIdentity, separate.registrationIdentity)
        XCTAssertThrowsError(try DevinAuth.credential(token: "token-c", profile: other, previous: first, hostID: "device"))
        XCTAssertThrowsError(try UsageParser.devin(other, subject: first.subject, accountID: first.accountID))
        XCTAssertThrowsError(try DevinAuth.identity(["userStatus": ["userId": "user-a"]]))
    }
    func testQuotaRemainingAndUnixResetsIncludeExhaustedZero() throws {
        let snapshot = try UsageParser.devin(Self.profile(daily: 0, weekly: "63.5"), subject: "user-a", accountID: "org-a")
        XCTAssertEqual(snapshot.plan, "Free")
        XCTAssertEqual(snapshot.windows.map(\.id), ["daily", "weekly"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [100, 36.5])
        XCTAssertEqual(snapshot.windows.map(\.duration), [86400, 604800])
        XCTAssertEqual(snapshot.windows.first?.resetsAt, Date(timeIntervalSince1970: 1791100800))
        XCTAssertNil(snapshot.billingEndsAt); XCTAssertNil(snapshot.creditBalance)
        for bad in [true, "bad", -1, 101, Double.infinity] as [Any] {
            XCTAssertThrowsError(try UsageParser.devin(Self.profile(daily: bad), subject: "user-a", accountID: "org-a"))
        }
    }
    func testMissingQuotasStayMissingAndPlanChangesChangeAllowanceContext() throws {
        let empty = try UsageParser.devin(Self.profile(daily: nil, weekly: nil), subject: "user-a", accountID: "org-a")
        XCTAssertTrue(empty.windows.isEmpty)
        let paid = try UsageParser.devin(Self.profile(plan: "Max"), subject: "user-a", accountID: "org-a")
        XCTAssertNotEqual(paid.allowanceContext, empty.allowanceContext)
        var raw = Self.profile(); var user = raw["userStatus"] as! [String: Any]; var status = user["planStatus"] as! [String: Any]; var info = status["planInfo"] as! [String: Any]
        info["hideDailyQuota"] = true; status["planInfo"] = info; user["planStatus"] = status; raw["userStatus"] = user
        XCTAssertEqual(try UsageParser.devin(raw, subject: "user-a", accountID: "org-a").windows.map(\.id), ["weekly"])
    }
    func testQuotaProtoZeroRequiresBothBillingStrategyAndReportedReset() throws {
        var raw = Self.profile(daily: nil, weekly: nil)
        var user = raw["userStatus"] as! [String: Any]; var status = user["planStatus"] as! [String: Any]; var info = status["planInfo"] as! [String: Any]
        info["billingStrategy"] = "BILLING_STRATEGY_QUOTA"; status["planInfo"] = info; user["planStatus"] = status; raw["userStatus"] = user
        XCTAssertEqual(try UsageParser.devin(raw, subject: "user-a", accountID: "org-a").windows.map(\.usedPercent), [100, 100])
        status.removeValue(forKey: "dailyQuotaResetAtUnix"); status.removeValue(forKey: "weeklyQuotaResetAtUnix"); user["planStatus"] = status; raw["userStatus"] = user
        XCTAssertTrue(try UsageParser.devin(raw, subject: "user-a", accountID: "org-a").windows.isEmpty)
    }
    func testModelStatusAndDiagnosticTypesNeverExposeProfileValues() throws {
        var raw = Self.profile(); var user = raw["userStatus"] as! [String: Any]
        user["cascadeModelConfigData"] = ["clientModelConfigs": [["modelUid": "a", "label": "Model A", "disabled": false], ["modelUid": "b", "label": "Model B", "disabled": true], ["modelUid": "c", "label": "Model C"]]]; raw["userStatus"] = user
        let snapshot = try UsageParser.devin(raw, subject: "user-a", accountID: "org-a")
        XCTAssertEqual(snapshot.details?.models.sorted { $0.title < $1.title }.map(\.status), ["Available", "Unavailable", "Available"])
        let diagnostic = UsageParsingDiagnostic.make(provider: .devin, raw: raw, snapshot: snapshot)
        XCTAssertEqual(diagnostic.fields[.dailyQuotaRemainingPercent], .number)
        XCTAssertEqual(diagnostic.fields[.weeklyQuotaResetAtUnix], .string)
        let json = String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self)
        for value in ["private@example.test", "user-a", "org-a", "Model A", "1791619200"] { XCTAssertFalse(json.contains(value)) }
        XCTAssertEqual(DiagnosticEndpoint.identify(URL(string: DevinAuth.issuer + DevinAuth.service + "GetUserStatus")), .usage)
        XCTAssertEqual(DiagnosticEndpoint.identify(URL(string: DevinAuth.issuer + DevinAuth.service + "ExchangeDevinCLIPKCECode")), .token)
    }
}
