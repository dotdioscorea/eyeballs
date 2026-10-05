#if DEBUG && targetEnvironment(simulator)
import Foundation

// Simulator-only sign-in responses; no requests or real credentials.
@MainActor enum SignInUIFixture {
    static var enabled: Bool { SimulatorFixtures.enabled && ProcessInfo.processInfo.arguments.contains("--signin-fixture") }
    static let existingID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static func credential(_ selectedID: UUID? = nil) -> AccountCredential {
        let id = selectedID ?? existingID
        return .init(provider: .claude, issuer: "https://signin.example.test", clientID: "fixture", subject: id.uuidString,
              accountID: "fixture-" + id.uuidString, hostID: "simulator", accessToken: "fixture-only",
              scopes: [], expiresAt: .distantFuture, email: "tony@example.test")
    }
    static func model() -> SignInModel {
        var attempts = 0
        return SignInModel(signer: { _ in
            attempts += 1
            return credential(attempts == 1 ? existingID : UUID())
        }, fetcher: { _, credential in
            var snapshot = SimulatorFixtures.accounts().first { $0.id == existingID }!.snapshot!
            snapshot.identity = credential.registrationIdentity; snapshot.email = credential.email
            return snapshot
        })
    }
}
#endif
