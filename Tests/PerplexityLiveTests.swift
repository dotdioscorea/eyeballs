import XCTest
@testable import Eyeballs

// Opt-in check using a private session created by this app's email protocol.
// Never use exported browser cookies. The normal test suite performs no login.
final class PerplexityLiveTests: XCTestCase {
    func testNativeSessionRenewalIdentityAndAllowances() async throws {
        guard let path = ProcessInfo.processInfo.environment["PERPLEXITY_LIVE_SESSION_FILE"] else { throw XCTSkip("Requires an explicitly authorized private test session.") }
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any]
        guard let cookies = raw?["cookies"] as? [String: String], let token = cookies[PerplexityAuth.cookieName], let profile = raw?["profile"] else { XCTFail("Invalid private test session format."); return }
        let original = try PerplexityAuth.validated(profile, token: token, previous: nil, expectedEmail: nil, hostID: "live-test")
        let renewed = try await PerplexityAuth.refresh(original)
        XCTAssertTrue(renewed.registrationIdentity == original.registrationIdentity)
        XCTAssertTrue(renewed.accessToken != original.accessToken)
        XCTAssertTrue(renewed.expiresAt > .now)
        let account = AgentAccount(provider: .perplexity)
        let snapshot = try await UsageClient.fetch(account: account, credential: renewed)
        XCTAssertTrue(snapshot.identity == renewed.registrationIdentity)
        XCTAssertTrue(snapshot.remainingAllowances?.contains { $0.id == "pro_search" && $0.remaining != nil } == true)
        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertNil(snapshot.nextReset)
    }
}
