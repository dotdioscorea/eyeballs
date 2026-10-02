import XCTest
@testable import Eyeballs

@MainActor
final class SignInTests: XCTestCase {
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
