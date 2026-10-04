import XCTest
@testable import Requota

// Explicitly opted-in protocol checks. These use existing included allowance;
// they do not redeem resets, buy credits, create API keys or widen OAuth grants.
final class AllowanceActivationLiveTests: XCTestCase {
    func testNativeCodexSubscriptionRequestCompletes() async throws {
        try await check(.codex, fileVariable: "CODEX_ACTIVATION_LIVE_SESSION_FILE")
    }
    func testNativeClaudeSubscriptionRequestCompletes() async throws {
        try await check(.claude, fileVariable: "CLAUDE_ACTIVATION_LIVE_SESSION_FILE")
    }
    private func check(_ provider: Provider, fileVariable: String) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ACTIVATION_LIVE_REQUESTS"] == "1", let path = environment[fileVariable] else {
            throw XCTSkip("Requires explicit opt-in and an independently authorized private session.")
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let credential = try decoder.decode(AccountCredential.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard credential.provider == provider, AllowanceActivation.permitted(credential), credential.expiresAt > .now else {
            XCTFail("Authorized activation credential required."); return
        }
        let account = AgentAccount(provider: provider)
        let before = try await UsageClient.fetch(account: account, credential: credential)
        let included = before.windows.filter { $0.id != "code-review" }
        guard !included.isEmpty, included.allSatisfy({ $0.safePercent.map { $0 < 90 } == true }),
              provider != .codex || before.includedUsageAllowed == true else {
            throw XCTSkip("Known included allowance required before the live request.")
        }
        try await AllowanceActivation.send(credential)
        let after = try await UsageClient.fetch(account: account, credential: credential)
        XCTAssertEqual(after.identity, credential.registrationIdentity)
        XCTAssertNotNil(AllowanceActivation.weekly(after, provider: provider))
        // An active week validates native transport, not an unused-clock start.
        print("ACTIVATION LIVE: \(provider.name) completed; account identity and weekly reading matched.")
    }
}
