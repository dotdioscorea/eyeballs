import XCTest
@testable import Requota

final class MemoryVault: CredentialStorage {
    var values: [UUID: AccountCredential] = [:]
    func save(_ credential: AccountCredential, id: UUID) throws { values[id] = credential }
    func load(id: UUID) throws -> AccountCredential? { values[id] }
    func delete(id: UUID) throws { values[id] = nil }
}

@MainActor
final class AccountStoreTests: XCTestCase {
    func testPerplexityRefreshRenewsAndPersistsItsSessionBeforeAUsageFailure() async throws {
        let vault = MemoryVault()
        let old = try PerplexityAuth.validated(["user": ["id": "account-a", "email": "person@example.test"], "expires": Date.now.addingTimeInterval(30 * 86400).ISO8601Format()], token: "header..iv.ciphertext.tag", previous: nil, expectedEmail: nil, hostID: "host")
        let account = AgentAccount(provider: .perplexity, snapshot: UsageSnapshot(windows: [], identity: old.registrationIdentity, remainingAllowances: [.init(id: "pro_search", title: "Pro searches", remaining: 3, available: true)]))
        var renewals = 0, reads = 0
        let store = AccountStore(location: directory.appendingPathComponent("accounts.json"), vault: vault, integratesWithSystem: false, fetcher: { _, credential in
            reads += 1; XCTAssertEqual(credential.accessToken, "rotated\(renewals)..iv.ciphertext.tag"); throw UsageError.invalidResponse
        }, renewer: { original in
            renewals += 1; var next = original; next.accessToken = "rotated\(renewals)..iv.ciphertext.tag"; return next
        })
        try store.connect(account, credential: old)
        await store.refresh(account.id); await store.refresh(account.id)
        XCTAssertEqual(renewals, 2); XCTAssertEqual(reads, 2)
        XCTAssertEqual(vault.values[account.id]?.accessToken, "rotated2..iv.ciphertext.tag")
        XCTAssertEqual(store.accounts[0].snapshot, account.snapshot); XCTAssertFalse(store.accounts[0].needsLogin)
        XCTAssertTrue(store.accounts[0].needsReport == true)
    }
    func testRefreshingAdditionalCodexLimitsMigratesSavedDisplayAndHistory() async throws {
        let path = directory.appendingPathComponent("accounts.json")
        let vault = MemoryVault()
        let credential = Fixture.credential("codex")
        let old = UsageWindow(id: "additional-0", title: "Fast", usedPercent: 10, duration: 18000)
        let updated = try UsageParser.codex(["rate_limit": [:], "additional_rate_limits": [["limit_name": "Fast", "metered_feature": "fast", "rate_limit": ["primary_window": ["used_percent": 20, "limit_window_seconds": 18000]]]]])
        let store = AccountStore(location: path, vault: vault, integratesWithSystem: false, fetcher: { _, _ in updated })
        var account = Fixture.account(credential)
        account.snapshot = UsageSnapshot(windows: [old], identity: credential.registrationIdentity, updatedAt: .now.addingTimeInterval(-3600))
        account.display = AccountDisplay(rings: [RingDefinition(windowID: old.id, kind: .time, direction: .used)])
        try store.connect(account, credential: credential)
        await store.refresh(account.id)
        let expectedID = try XCTUnwrap(updated.windows.first?.id)
        XCTAssertEqual(store.accounts[0].display?.rings[0].windowID, expectedID)
        XCTAssertEqual(store.accounts[0].display?.rings[0].direction, .used)
        XCTAssertTrue(store.histories[account.id]!.allSatisfy { $0.windows.first?.id == expectedID })
        let restored = AccountStore(location: path, vault: vault, integratesWithSystem: false)
        XCTAssertEqual(restored.accounts[0].display?.rings[0].windowID, expectedID)
        XCTAssertTrue(restored.histories[account.id]!.allSatisfy { $0.windows.first?.id == expectedID })
    }
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
        XCTAssertEqual(store.existingConnection(for: credential)?.id, original.id)
        XCTAssertEqual(try store.connect(reconnected, credential: credential), original.id)
        XCTAssertEqual(store.accounts.count, 2)
        XCTAssertEqual(store.accounts[0].id, original.id)
        XCTAssertEqual(store.accounts[0].label, "Personal")
        XCTAssertEqual(store.accounts[0].notes, "Private note")
        XCTAssertEqual(store.accounts[0].snapshot?.windows[0].safePercent, 88)
        XCTAssertEqual(vault.values[original.id]?.accessToken, "fixture-new-token")
        XCTAssertNil(vault.values[reconnected.id])
        XCTAssertEqual(vault.values[other.id], otherCredential)
    }
    func testDuplicateLookupUsesVerifiedProviderIdentityNotEmail() throws {
        let vault = MemoryVault(); let store = store(vault: vault)
        var first = Fixture.credential("claude"); first.provider = .claude
        var second = first; second.accountID = "other-organization"
        var otherProvider = first; otherProvider.provider = .codex
        var a = Fixture.account(first, label: "Personal"); a.provider = .claude
        var b = Fixture.account(second, label: "Work"); b.provider = .claude
        XCTAssertEqual(try store.connect(a, credential: first), a.id)
        XCTAssertNil(store.existingConnection(for: second))
        XCTAssertNil(store.existingConnection(for: otherProvider))
        XCTAssertEqual(try store.connect(b, credential: second), b.id)
        XCTAssertEqual(store.existingConnection(for: first)?.title, "Personal")
        XCTAssertEqual(store.existingConnection(for: second)?.title, "Work")
        XCTAssertEqual(store.accounts.count, 2)
        var renewed = first; renewed.accessToken = "fixture-renewed"; renewed.hostID = "other-phone"
        XCTAssertEqual(store.existingConnection(for: renewed)?.id, a.id)
    }
    func testReconnectCannotReplaceSelectedAccountWithAnotherIdentity() throws {
        let vault = MemoryVault(); let store = store(vault: vault)
        let originalCredential = Fixture.credential("a"); let original = Fixture.account(originalCredential)
        try store.connect(original, credential: originalCredential)
        let connectedAccounts = store.accounts
        let impostor = Fixture.credential("b")
        var replacement = Fixture.account(impostor); replacement.id = original.id
        XCTAssertThrowsError(try store.connect(replacement, credential: impostor))
        XCTAssertEqual(vault.values[original.id], originalCredential)
        XCTAssertEqual(store.accounts, connectedAccounts)
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
        _ = await refresh.value
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

    func testBackgroundExpirationDoesNotCreateErrorsHistoryOrStartMoreRequests() async throws {
        let vault = MemoryVault(); var started = 0
        let entered = expectation(description: "Three provider requests started"); entered.expectedFulfillmentCount = 3
        let store = AccountStore(location: directory.appendingPathComponent("accounts.json"), vault: vault, integratesWithSystem: false, fetcher: { _, _ in
            started += 1; entered.fulfill()
            try await Task.sleep(for: .seconds(30))
            throw UsageError.invalidResponse
        })
        for index in 0..<8 { let credential = Fixture.credential("expire-\(index)"); try store.connect(Fixture.account(credential), credential: credential) }
        let accounts = store.accounts, history = store.histories
        let operation = Task { await store.refreshAll() }
        await fulfillment(of: [entered], timeout: 3); operation.cancel()
        let summary = await operation.value
        XCTAssertEqual(started, 3); XCTAssertTrue(summary.cancelled); XCTAssertFalse(summary.succeeded)
        XCTAssertEqual(summary.failed, 0); XCTAssertEqual(summary.updated, 0)
        XCTAssertEqual(store.accounts, accounts); XCTAssertEqual(store.histories, history)
        XCTAssertTrue(store.refreshing.isEmpty); XCTAssertNil(store.reportAccountID)
    }

    func testAutomaticRefreshSkipsRecentReadingsButManualRefreshAndDueResetDoNot() async throws {
        let vault = MemoryVault(); var reads = 0
        let store = AccountStore(location: directory.appendingPathComponent("accounts.json"), vault: vault, integratesWithSystem: false, fetcher: { account, _ in
            reads += 1; return account.snapshot!
        })
        let credential = Fixture.credential("fresh"), dueCredential = Fixture.credential("due")
        var fresh = Fixture.account(credential); fresh.snapshot?.updatedAt = .now
        var due = Fixture.account(dueCredential); due.snapshot?.updatedAt = .now; due.snapshot?.windows[0].resetsAt = .now.addingTimeInterval(-10)
        try store.connect(fresh, credential: credential); try store.connect(due, credential: dueCredential)
        let summary = await store.refreshAll(minimumAge: 300)
        XCTAssertEqual(reads, 1); XCTAssertEqual(summary.updated, 1); XCTAssertEqual(summary.skipped, 1)
        await store.refresh(fresh.id)
        XCTAssertEqual(reads, 2)
    }

    func testCancelledNetworkRequestKeepsLastReadingAndRotatedCredential() async throws {
        let vault = MemoryVault(); var credential = Fixture.credential("rotate-cancel")
        credential.expiresAt = .now.addingTimeInterval(-1)
        let account = Fixture.account(credential)
        let store = AccountStore(location: directory.appendingPathComponent("accounts.json"), vault: vault, integratesWithSystem: false, fetcher: { _, _ in throw URLError(.cancelled) }, renewer: { old in
            var rotated = old; rotated.refreshToken = "rotated-before-cancellation"; return rotated
        })
        try store.connect(account, credential: credential)
        let history = store.histories
        let connectedAccounts = store.accounts
        let outcome = await store.refresh(account.id)
        XCTAssertEqual(outcome, .cancelled); XCTAssertEqual(store.accounts, connectedAccounts); XCTAssertEqual(store.histories, history)
        XCTAssertEqual(vault.values[account.id]?.refreshToken, "rotated-before-cancellation")
    }

    func testFailedRefreshCycleDoesNotReportSuccessToIOS() async throws {
        let vault = MemoryVault()
        let store = AccountStore(location: directory.appendingPathComponent("accounts.json"), vault: vault, integratesWithSystem: false, fetcher: { _, _ in throw URLError(.notConnectedToInternet) })
        let credential = Fixture.credential("offline"); try store.connect(Fixture.account(credential), credential: credential)
        let summary = await store.refreshAll()
        XCTAssertEqual(summary.failed, 1); XCTAssertFalse(summary.succeeded); XCTAssertFalse(store.accounts[0].needsLogin)
    }

    func testCustomOrderSurvivesRestartAndFilteredReorderingKeepsHiddenAccounts() throws {
        let vault = MemoryVault(); let store = store(vault: vault)
        let credentials = (0..<4).map { Fixture.credential("order-\($0)") }
        let accounts = credentials.map { Fixture.account($0) }
        for (account, credential) in zip(accounts, credentials) { try store.connect(account, credential: credential) }
        store.reorder([accounts[2].id, UUID(), accounts[0].id, accounts[2].id])
        XCTAssertEqual(store.accounts.map(\.id), [accounts[2].id, accounts[1].id, accounts[0].id, accounts[3].id])
        store.move(accounts[3].id, to: accounts[1].id)
        XCTAssertEqual(self.store(vault: vault).accounts.map(\.id), [accounts[2].id, accounts[3].id, accounts[1].id, accounts[0].id])
        XCTAssertEqual(AccountSort.manual.sorted(store.accounts), store.accounts)
        XCTAssertEqual(vault.values.count, 4)
    }
    func testParsingFailureKeepsLastReadingAndOffersOnlyOneReportUntilRecovery() async throws {
        let vault = MemoryVault(); var fails = true
        let store = AccountStore(location: directory.appendingPathComponent("accounts.json"), vault: vault, integratesWithSystem: false, fetcher: { account, _ in
            if fails { throw UsageError.invalidResponse }; var snapshot = account.snapshot!; snapshot.updatedAt = .now; return snapshot
        })
        let credential = Fixture.credential("parse"); let account = Fixture.account(credential)
        try store.connect(account, credential: credential)
        await store.refresh(account.id)
        XCTAssertEqual(store.reportAccountID, account.id); XCTAssertEqual(store.accounts.first?.snapshot, account.snapshot)
        XCTAssertEqual(store.events.filter { $0.kind == .parsingFailure }.count, 1)
        store.reportAccountID = nil; await store.refresh(account.id)
        XCTAssertNil(store.reportAccountID); XCTAssertEqual(store.events.filter { $0.kind == .parsingFailure }.count, 1)
        fails = false; await store.refresh(account.id); XCTAssertNil(store.accounts.first?.needsReport)
        XCTAssertEqual(self.store(vault: vault).events, store.events)
        try store.remove(account.id); XCTAssertTrue(self.store(vault: vault).events.isEmpty)
    }

}
