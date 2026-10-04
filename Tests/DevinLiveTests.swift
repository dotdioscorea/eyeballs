import XCTest
@testable import Requota

final class DevinLiveTests: XCTestCase {
    func testIndependentNativeCredentialIdentityAndLiveQuotas() async throws {
        guard let path = ProcessInfo.processInfo.environment["DEVIN_LIVE_SESSION_FILE"] else { throw XCTSkip("Requires an independently authorized private native session.") }
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any]
        guard let token = (raw?["response"] as? [String: Any])?["sessionToken"] as? String else { XCTFail("Invalid private session format."); return }
        let profile = try await ProviderHTTP.json(DevinAuth.request("GetUserStatus", token: token))
        let original = try DevinAuth.credential(token: token, profile: profile, previous: nil, hostID: "live-test")
        let checked = try await DevinAuth.refresh(original)
        XCTAssertTrue(checked.registrationIdentity == original.registrationIdentity)
        XCTAssertEqual(checked.expiresAt, .distantFuture)
        let snapshot = try await UsageClient.fetch(account: AgentAccount(provider: .devin), credential: checked)
        XCTAssertTrue(snapshot.identity == checked.registrationIdentity)
        XCTAssertNotNil(snapshot.plan)
        XCTAssertTrue(snapshot.windows.contains { $0.id == "weekly" && $0.usedPercent != nil && $0.resetsAt != nil })
        XCTAssertTrue(snapshot.windows.contains { $0.id == "daily" && $0.usedPercent != nil })
    }
}
