import XCTest
@testable import Requota

@MainActor
final class SignInTests: XCTestCase {
    func testEmailCodeLoginRetriesUsageWithoutReusingTheConsumedCode() async throws {
        var connection = Fixture.credential("perplexity"); connection.provider = .perplexity
        let account = AgentAccount(provider: .perplexity)
        let snapshot = UsageSnapshot(windows: [], remainingAllowances: [.init(id: "pro_search", title: "Pro searches", remaining: 3, available: true)])
        var sends = 0, verifications = 0, reads = 0
        let model = SignInModel(fetcher: { _, _ in
            reads += 1
            if reads == 1 { throw UsageError.invalidResponse }
            return snapshot
        }, emailBegin: { email in
            sends += 1; return .init(email: email, csrfCookie: "csrf=value", startedAt: .now)
        }, emailVerify: { _, code, previous in
            verifications += 1; XCTAssertEqual(code, "123456"); XCTAssertNil(previous); return connection
        })
        model.inputEmail = "person@example.test"; model.requestEmailCode(account: account, previous: nil)
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !model.working }, object: nil)], timeout: 3)
        XCTAssertTrue(model.awaitingEmailCode); XCTAssertNil(model.credential)
        model.inputCode = "123456"; model.verifyEmailCode(account: account, previous: nil)
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !model.working }, object: nil)], timeout: 3)
        XCTAssertNotNil(model.credential); XCTAssertNil(model.snapshot); XCTAssertTrue(model.reportSuggested)
        XCTAssertTrue(model.inputCode.isEmpty); XCTAssertFalse(model.awaitingEmailCode)
        model.retryEmailUsage(account: account)
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !model.working }, object: nil)], timeout: 3)
        XCTAssertEqual(model.snapshot, snapshot); XCTAssertNil(model.message); XCTAssertFalse(model.reportSuggested)
        XCTAssertEqual(sends, 1); XCTAssertEqual(verifications, 1); XCTAssertEqual(reads, 2)
    }
    func testCancelEmailLoginDiscardsCodeAndLateIdentity() async throws {
        let account = AgentAccount(provider: .perplexity)
        var connection = Fixture.credential("perplexity"); connection.provider = .perplexity
        let model = SignInModel(emailBegin: { email in .init(email: email, csrfCookie: "csrf=value", startedAt: .now) }, emailVerify: { _, _, _ in
            try? await Task.sleep(for: .milliseconds(50)); return connection
        })
        model.inputEmail = "person@example.test"; model.requestEmailCode(account: account, previous: nil)
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !model.working }, object: nil)], timeout: 3)
        model.inputCode = "123456"; model.verifyEmailCode(account: account, previous: nil); model.cancel()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !model.working }, object: nil)], timeout: 3)
        XCTAssertNil(model.credential); XCTAssertNil(model.snapshot); XCTAssertTrue(model.inputCode.isEmpty); XCTAssertFalse(model.awaitingEmailCode)
    }
    func testFreshLoginIsNotReadyToSaveUntilUsageSucceeds() async throws {
        for provider in Provider.allCases {
            var credential = Fixture.credential("fresh"); credential.provider = provider
            let account = AgentAccount(provider: provider)
            let model = SignInModel(signer: { _ in credential }, fetcher: { _, _ in throw UsageError.usageAccessDenied })
            model.start(account: account, previous: nil)
            await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !model.working }, object: nil)], timeout: 3)
            XCTAssertNotNil(model.credential); XCTAssertNil(model.snapshot)
            XCTAssertEqual(model.message, UsageError.usageAccessDenied.localizedDescription)
            XCTAssertFalse(model.message!.contains("expired"))
        }
    }
    func testAnotherAttemptClearsPreviouslyVerifiedIdentityAndReading() async throws {
        let credential = Fixture.credential("a"); let account = Fixture.account(credential)
        var calls = 0
        let model = SignInModel(signer: { _ in
            calls += 1
            if calls == 2 { throw AuthError.cancelled }
            return credential
        }, fetcher: { _, _ in account.snapshot! })
        model.start(account: account, previous: nil)
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !model.working }, object: nil)], timeout: 3)
        XCTAssertNotNil(model.snapshot)
        model.start(account: account, previous: nil)
        XCTAssertNil(model.credential); XCTAssertNil(model.snapshot)
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !model.working }, object: nil)], timeout: 3)
        XCTAssertNil(model.credential); XCTAssertNil(model.snapshot)
        XCTAssertEqual(model.message, AuthError.cancelled.localizedDescription)
    }
}
