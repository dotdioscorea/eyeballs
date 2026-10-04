import XCTest
@testable import Requota

final class AmpLiveTests: XCTestCase {
    func testNativeSessionRenewalAndLiveCreditBalance() async throws {
        guard let path = ProcessInfo.processInfo.environment["AMP_LIVE_SESSION_FILE"] else { throw XCTSkip("Requires an independently authorized private native session.") }
        guard let tokens = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any] else { XCTFail("Invalid private session format."); return }
        // The saved access token may have expired during other tests. Renew its
        // independently issued refresh token before validating the native API.
        let now = Date.now
        let placeholder = AccountCredential(provider: .amp, issuer: AmpAuth.issuer, clientID: AmpAuth.clientID, subject: (tokens["user"] as! [String: Any])["id"] as! String, accountID: (tokens["user"] as! [String: Any])["id"] as? String, hostID: "live-test", accessToken: tokens["access_token"] as! String, refreshToken: tokens["refresh_token"] as? String, scopes: [], expiresAt: now)
        let renewed = try await AmpAuth.refresh(placeholder)
        // Preserve refresh rotation for a subsequent authorized live test.
        var updated = tokens; updated["access_token"] = renewed.accessToken; updated["refresh_token"] = renewed.refreshToken
        try JSONSerialization.data(withJSONObject: updated).write(to: URL(fileURLWithPath: path), options: .atomic)
        XCTAssertTrue(renewed.expiresAt > now)
        XCTAssertEqual(renewed.registrationIdentity, placeholder.registrationIdentity)
        let snapshot = try await UsageClient.fetch(account: AgentAccount(provider: .amp), credential: renewed)
        XCTAssertTrue(snapshot.identity == renewed.registrationIdentity)
        XCTAssertNotNil(snapshot.details?.spending.first?.balance)
        XCTAssertTrue(snapshot.windows.isEmpty)
    }
}
