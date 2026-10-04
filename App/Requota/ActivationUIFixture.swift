#if DEBUG && targetEnvironment(simulator)
import Foundation

// Controlled provider responses for native activation UI checks. This cannot be
// compiled into a release build, uses separate metadata and never calls a provider.
final class ActivationUIFixture: CredentialStorage {
    private var deadlines: [String: Date] = [:]
    private var deleted = Set<UUID>()
    init(location: URL) {
        if let data = try? Data(contentsOf: location), let accounts = try? JSONDecoder().decode([AgentAccount].self, from: data) {
            for account in accounts {
                if let reset = account.activation?.resetAt { deadlines[account.id.uuidString] = reset }
            }
        }
    }
    func load(id: UUID) throws -> AccountCredential? {
        guard !deleted.contains(id), let account = SimulatorFixtures.accounts().first(where: { $0.id == id }) else { return nil }
        return AccountCredential(provider: account.provider, issuer: ProviderAuth.issuer(account.provider), clientID: ProviderAuth.clientID(account.provider),
            subject: id.uuidString, accountID: "fixture-account-" + id.uuidString, hostID: "activation-ui-fixture",
            accessToken: "fixture-token-" + id.uuidString, scopes: ["user:profile", "user:inference"], expiresAt: .distantFuture)
    }
    func save(_ credential: AccountCredential, id: UUID) throws { }
    func delete(id: UUID) throws { deleted.insert(id) }
    func fetch(_ account: AgentAccount, _ credential: AccountCredential) async throws -> UsageSnapshot {
        guard var snapshot = SimulatorFixtures.accounts().first(where: { $0.id == account.id })?.snapshot else { throw UsageError.wrongAccount }
        snapshot.identity = credential.registrationIdentity; snapshot.updatedAt = .now
        if let reset = deadlines[credential.subject], let index = snapshot.windows.firstIndex(where: { $0.duration == 604800 }) {
            snapshot.windows[index].resetsAt = reset
        }
        return snapshot
    }
    func activate(_ credential: AccountCredential) async throws {
        guard AllowanceActivation.permitted(credential) else { throw ActivationError.permissionRequired }
        deadlines[credential.subject] = .now.addingTimeInterval(604800)
    }
}
#endif
