import XCTest
@testable import Eyeballs

final class MemoryVault: CredentialStorage {
    var values: [UUID: AccountCredential] = [:]
    func save(_ credential: AccountCredential, id: UUID) throws { values[id] = credential }
    func load(id: UUID) throws -> AccountCredential? { values[id] }
    func delete(id: UUID) throws { values[id] = nil }
}

@MainActor
final class AccountStoreTests: XCTestCase {
    var directory: URL!
    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }
    func store(vault: MemoryVault) -> AccountStore { AccountStore(location: directory.appendingPathComponent("accounts.json"), vault: vault, integratesWithSystem: false) }

    func testUnreadableMetadataIsPreservedAndCanRecoverAfterUnlock() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("accounts.json")
        let damaged = Data("unreadable-metadata".utf8)
        try damaged.write(to: path)
        let vault = MemoryVault(); let store = store(vault: vault)
        let credential = Fixture.credential("protected-data")
        let account = Fixture.account(credential)
        XCTAssertNotNil(store.error)
        XCTAssertThrowsError(try store.connect(account, credential: credential))
        XCTAssertEqual(try Data(contentsOf: path), damaged)
        XCTAssertTrue(vault.values.isEmpty)
        // Simulates protected data becoming readable; no empty cache is published.
        try JSONEncoder().encode([account]).write(to: path)
        store.reloadAccountsIfNeeded()
        XCTAssertEqual(store.accounts, [account]); XCTAssertNil(store.error)
        try store.connect(account, credential: credential)
        XCTAssertEqual(vault.values[account.id], credential)
    }
    func testTwoCodexAccountsWithSameEmailStaySeparateAfterRestartAndRemoval() throws {
        let vault = MemoryVault(); let store = store(vault: vault)
        let firstCredential = Fixture.credential("personal"); let secondCredential = Fixture.credential("work")
        let first = Fixture.account(firstCredential, label: "Personal"); let second = Fixture.account(secondCredential, label: "Work")
        try store.connect(first, credential: firstCredential)
        try store.connect(second, credential: secondCredential)
        XCTAssertEqual(store.accounts.count, 2)
        XCTAssertEqual(vault.values[first.id]?.accessToken, "fixture-personal")
        XCTAssertEqual(vault.values[second.id]?.accessToken, "fixture-work")
        let restored = self.store(vault: vault)
        XCTAssertEqual(restored.accounts.map(\.id), [first.id, second.id])
        try restored.remove(first.id)
        XCTAssertNil(vault.values[first.id])
        XCTAssertEqual(restored.accounts.map(\.id), [second.id])
        XCTAssertEqual(vault.values[second.id], secondCredential)
        let data = try Data(contentsOf: directory.appendingPathComponent("accounts.json"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("accessToken"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("refreshToken"))
    }
    func testReconnectPreservesConnectionIDNameNotesAndOtherAccount() throws {
        let vault = MemoryVault(); let store = store(vault: vault)
        var credential = Fixture.credential("a")
        var original = Fixture.account(credential, label: "Personal")
        original.notes = "Private note"; original.workstream = "Mac mini"
        let otherCredential = Fixture.credential("b"); let other = Fixture.account(otherCredential, label: "Work")
        try store.connect(original, credential: credential); try store.connect(other, credential: otherCredential)
        credential.accessToken = "fixture-new-token"
        var reconnected = Fixture.account(credential); reconnected.snapshot?.windows[0].usedPercent = 88
        try store.connect(reconnected, credential: credential)
        XCTAssertEqual(store.accounts.count, 2)
        XCTAssertEqual(store.accounts[0].id, original.id)
        XCTAssertEqual(store.accounts[0].label, "Personal")
        XCTAssertEqual(store.accounts[0].notes, "Private note")
        XCTAssertEqual(store.accounts[0].snapshot?.windows[0].safePercent, 88)
        XCTAssertEqual(vault.values[original.id]?.accessToken, "fixture-new-token")
        XCTAssertNil(vault.values[reconnected.id])
        XCTAssertEqual(vault.values[other.id], otherCredential)
    }
    func testReconnectCannotReplaceSelectedAccountWithAnotherIdentity() throws {
        let vault = MemoryVault(); let store = store(vault: vault)
        let originalCredential = Fixture.credential("a"); let original = Fixture.account(originalCredential)
        try store.connect(original, credential: originalCredential)
        let impostor = Fixture.credential("b")
        var replacement = Fixture.account(impostor); replacement.id = original.id
        XCTAssertThrowsError(try store.connect(replacement, credential: impostor))
        XCTAssertEqual(vault.values[original.id], originalCredential)
        XCTAssertEqual(store.accounts, [original])
    }
    func testOneExpiredAccountDoesNotInvalidateTheOther() async throws {
        let vault = MemoryVault()
        let store = AccountStore(location: directory.appendingPathComponent("accounts.json"), vault: vault, integratesWithSystem: false, fetcher: { account, credential in
            if credential.subject == "subject-a" { throw UsageError.signedOut }
            var snapshot = account.snapshot!; snapshot.windows[0].usedPercent = 79; return snapshot
        })
        let a = Fixture.credential("a"), b = Fixture.credential("b")
        let first = Fixture.account(a), second = Fixture.account(b)
        try store.connect(first, credential: a); try store.connect(second, credential: b)
        await store.refreshAll()
        XCTAssertTrue(store.accounts[0].needsLogin)
        XCTAssertEqual(store.accounts[0].snapshot?.windows[0].safePercent, 25)
        XCTAssertFalse(store.accounts[1].needsLogin)
        XCTAssertEqual(store.accounts[1].snapshot?.windows[0].safePercent, 79)
        XCTAssertEqual(vault.values[second.id], b)
    }
    func testRemovingAnAccountDuringRefreshCannotRestoreIt() async throws {
        let vault = MemoryVault()
        var continuation: CheckedContinuation<UsageSnapshot, Never>?
        let entered = expectation(description: "Request started")
        let store = AccountStore(location: directory.appendingPathComponent("accounts.json"), vault: vault, integratesWithSystem: false, fetcher: { _, _ in
            await withCheckedContinuation { value in continuation = value; entered.fulfill() }
        })
        let credential = Fixture.credential("a"); let account = Fixture.account(credential)
        try store.connect(account, credential: credential)
        let refresh = Task { await store.refresh(account.id) }
        await fulfillment(of: [entered], timeout: 3)
        try store.remove(account.id)
        continuation?.resume(returning: UsageSnapshot(windows: [], identity: credential.registrationIdentity))
        await refresh.value
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertNil(vault.values[account.id])
        XCTAssertTrue(self.store(vault: vault).accounts.isEmpty)
    }
    func testFixtureStoresDoNotReplaceDeviceWidgetData() throws {
        let original = WidgetCache.read()
        let vault = MemoryVault(); let store = store(vault: vault)
        let credential = Fixture.credential("isolated-widget-test")
        let account = Fixture.account(credential)
        try store.connect(account, credential: credential)
        XCTAssertEqual(WidgetCache.read(), original)
        try store.remove(account.id)
        XCTAssertEqual(WidgetCache.read(), original)
    }
    func testDeniedAccessRefreshesOnceAndSavesRotatingTokenBeforeUsageRetry() async throws {
        let vault = MemoryVault(); let original = Fixture.credential("a"); let account = Fixture.account(original)
        var renewals = 0; var reads = 0
        let store = AccountStore(location: directory.appendingPathComponent("accounts.json"), vault: vault, integratesWithSystem: false, fetcher: { _, credential in
            reads += 1
            if reads == 1 { throw UsageError.usageAccessDenied }
            XCTAssertEqual(vault.values[account.id]?.accessToken, "renewed")
            XCTAssertEqual(credential.refreshToken, "rotated")
            var snapshot = account.snapshot!; snapshot.windows[0].usedPercent = 42; return snapshot
        }, renewer: { credential in
            renewals += 1
            var new = credential; new.accessToken = "renewed"; new.refreshToken = "rotated"; return new
        })
        try store.connect(account, credential: original)
        await store.refresh(account.id)
        XCTAssertEqual(renewals, 1); XCTAssertEqual(reads, 2)
        XCTAssertFalse(store.accounts[0].needsLogin); XCTAssertNil(store.accounts[0].issue)
        XCTAssertEqual(store.accounts[0].snapshot?.windows[0].safePercent, 42)
    }
    func testFreshPermissionDenialPreservesConnectionAndDoesNotLoopSignIn() async throws {
        let vault = MemoryVault(); let credential = Fixture.credential("a"); let account = Fixture.account(credential)
        var renewals = 0; var reads = 0
        let store = AccountStore(location: directory.appendingPathComponent("accounts.json"), vault: vault, integratesWithSystem: false, fetcher: { _, _ in
            reads += 1; throw UsageError.usageAccessDenied
        }, renewer: { old in renewals += 1; var new = old; new.refreshToken = "rotated"; return new })
        try store.connect(account, credential: credential); await store.refresh(account.id)
        XCTAssertEqual(renewals, 1); XCTAssertEqual(reads, 2)
        XCTAssertFalse(store.accounts[0].needsLogin)
        XCTAssertEqual(store.accounts[0].issue, UsageError.usageAccessDenied.localizedDescription)
        XCTAssertEqual(store.accounts[0].snapshot, account.snapshot)
        XCTAssertEqual(vault.values[account.id]?.refreshToken, "rotated")
    }
    func testTerminalRefreshFailureRequiresReconnectForOnlyAffectedAccount() async throws {
        let vault = MemoryVault(); let a = Fixture.credential("a"), b = Fixture.credential("b")
        let first = Fixture.account(a), second = Fixture.account(b)
        let store = AccountStore(location: directory.appendingPathComponent("accounts.json"), vault: vault, integratesWithSystem: false, fetcher: { account, credential in
            if credential.subject == a.subject { throw UsageError.usageAccessDenied }
            return account.snapshot!
        }, renewer: { _ in throw UsageError.signedOut })
        try store.connect(first, credential: a); try store.connect(second, credential: b); await store.refreshAll()
        XCTAssertTrue(store.accounts[0].needsLogin); XCTAssertFalse(store.accounts[1].needsLogin)
        XCTAssertEqual(vault.values[second.id], b)
    }
    func testTwoAccountsPerProviderKeepTheirOwnCredentials() throws {
        let vault = MemoryVault(); let store = store(vault: vault)
        var expected: [UUID: AccountCredential] = [:]
        for provider in Provider.allCases {
            for name in ["personal", "work"] {
                var credential = Fixture.credential(name)
                credential.provider = provider; credential.issuer = ProviderAuth.issuer(provider)
                credential.clientID = ProviderAuth.clientID(provider)
                let account = Fixture.account(credential, label: provider.name + " " + name)
                try store.connect(account, credential: credential); expected[account.id] = credential
            }
        }
        XCTAssertEqual(store.accounts.count, Provider.allCases.count * 2)
        XCTAssertEqual(vault.values, expected)
        let restored = self.store(vault: vault)
        XCTAssertEqual(restored.accounts, store.accounts)
        let removed = try XCTUnwrap(restored.accounts.first { $0.provider == .claude })
        try restored.remove(removed.id); expected[removed.id] = nil
        XCTAssertEqual(vault.values, expected)
        XCTAssertEqual(restored.accounts.filter { $0.provider == .claude }.count, 1)
        XCTAssertEqual(restored.accounts.filter { $0.provider == .codex }.count, 2)
        XCTAssertEqual(restored.accounts.filter { $0.provider == .grok }.count, 2)
    }
    func testDisplayEditPreservesFreshUsageAndAccountHistoryIsRemovedIndependently() async throws {
        let vault = MemoryVault()
        let store = AccountStore(location: directory.appendingPathComponent("accounts.json"), vault: vault, integratesWithSystem: false, fetcher: { account, _ in
            var snapshot = account.snapshot!; snapshot.windows[0].usedPercent = 66; snapshot.updatedAt = .now; return snapshot
        })
        let a = Fixture.credential("history-a"), b = Fixture.credential("history-b")
        let first = Fixture.account(a), second = Fixture.account(b)
        try store.connect(first, credential: a); try store.connect(second, credential: b)
        var staleEditor = first
        await store.refreshAll()
        staleEditor.display = AccountDisplay(direction: .used, rings: [])
        store.update(staleEditor)
        XCTAssertEqual(store.accounts.first { $0.id == first.id }?.snapshot?.windows[0].safePercent, 66)
        XCTAssertEqual(store.accounts.first { $0.id == first.id }?.display, staleEditor.display)
        XCTAssertEqual(store.histories[first.id]?.last?.windows[0].safePercent, 66)
        let otherHistory = store.histories[second.id]
        try store.remove(first.id)
        XCTAssertNil(store.histories[first.id]); XCTAssertEqual(store.histories[second.id], otherHistory)
        let restored = self.store(vault: vault)
        XCTAssertEqual(restored.histories[second.id], otherHistory)
    }
    func testRefreshingManyAccountsBoundsConcurrencyAndRecordsActualReads() async throws {
        let vault = MemoryVault(); var active = 0; var maximum = 0; var completed = 0
        let store = AccountStore(location: directory.appendingPathComponent("accounts.json"), vault: vault, integratesWithSystem: false, fetcher: { account, _ in
            active += 1; maximum = max(maximum, active)
            defer { active -= 1; completed += 1 }
            try await Task.sleep(for: .milliseconds(30))
            var snapshot = account.snapshot!; snapshot.updatedAt = .now; snapshot.windows[0].usedPercent = 51; return snapshot
        })
        for index in 0..<8 { let credential = Fixture.credential("concurrent-\(index)"); try store.connect(Fixture.account(credential), credential: credential) }
        await store.refreshAll()
        XCTAssertEqual(completed, 8); XCTAssertEqual(maximum, 3)
        XCTAssertTrue(store.accounts.allSatisfy { $0.snapshot?.windows[0].safePercent == 51 })
        XCTAssertTrue(store.histories.values.allSatisfy { $0.last?.windows[0].safePercent == 51 })
    }

}
