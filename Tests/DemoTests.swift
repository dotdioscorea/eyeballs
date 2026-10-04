import XCTest
@testable import Requota

@MainActor
final class DemoTests: XCTestCase {
    var directory: URL!
    override func setUp() { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func testDemoEditsAndDeletionCannotTouchLiveAccountsOrCredentials() throws {
        let vault = MemoryVault()
        let path = directory.appendingPathComponent("live/accounts.json")
        let live = AccountStore(location: path, vault: vault, integratesWithSystem: false)
        let credential = Fixture.credential("real"); let real = Fixture.account(credential)
        try live.connect(real, credential: credential)
        let before = try Data(contentsOf: path)
        var modes: [Bool] = []
        let session = AccountSession(live: live, demoLocation: directory.appendingPathComponent("demo/accounts.json"), restoresMode: false, integratesWithSystem: false, publishMode: { modes.append($0) })
        session.startDemo()
        let demo = try XCTUnwrap(session.demo)
        XCTAssertEqual(demo.accounts.count, Provider.allCases.count + 2); XCTAssertEqual(demo.histories.count, Provider.allCases.count + 2); XCTAssertFalse(demo.events.isEmpty)
        var sample = demo.accounts[0]; sample.label = "Edited demo"; demo.update(sample)
        try demo.remove(sample.id)
        demo.addDemoAccount(provider: .claude, name: "Extra")
        XCTAssertNil(try demo.savedCredential(for: real.id))
        XCTAssertThrowsError(try demo.connect(real, credential: credential))
        XCTAssertEqual(try Data(contentsOf: path), before)
        XCTAssertEqual(vault.values, [real.id: credential])
        session.endDemo()
        XCTAssertTrue(session.current === live); XCTAssertEqual(live.accounts, [real]); XCTAssertEqual(modes, [true, false])
        session.startDemo()
        XCTAssertEqual(session.demo?.accounts.count, Provider.allCases.count + 2)
        XCTAssertFalse(session.demo!.accounts.contains { $0.id == sample.id })
        XCTAssertEqual(try Data(contentsOf: path), before)
    }

    func testCreditOnlyDemoAccountCanBeAddedWithoutInventingQuotaOrBilling() throws {
        let demo = AccountStore(location: directory.appendingPathComponent("demo/accounts.json"), integratesWithSystem: false, isDemo: true)
        demo.resetDemo()
        demo.addDemoAccount(provider: .cline, name: "Credits")
        let account = try XCTUnwrap(demo.accounts.last)
        XCTAssertEqual(account.provider, .cline)
        XCTAssertTrue(DemoData.contains(account.id))
        XCTAssertEqual(account.label, "Credits")
        XCTAssertEqual(account.snapshot?.creditBalance, "8.43")
        XCTAssertEqual(account.snapshot?.windows, [])
        XCTAssertNil(account.snapshot?.billingEndsAt)
    }

    func testDemoRefreshAndSimulatedResetNeverFetchOrRenewCredentials() async throws {
        let vault = MemoryVault(); var fetches = 0; var renewals = 0
        let demo = AccountStore(location: directory.appendingPathComponent("demo/accounts.json"), vault: vault, integratesWithSystem: false, isDemo: true, fetcher: { _, _ in fetches += 1; throw UsageError.unavailable }, renewer: { _ in renewals += 1; throw UsageError.unavailable })
        demo.resetDemo()
        await demo.refreshAll()
        demo.simulateDemoReset()
        XCTAssertEqual(fetches, 0); XCTAssertEqual(renewals, 0); XCTAssertTrue(vault.values.isEmpty)
        XCTAssertFalse(demo.accounts.contains { $0.needsLogin })
        XCTAssertEqual(demo.accounts[0].snapshot?.windows.last?.safePercent, 0)
        XCTAssertTrue(demo.events.contains { $0.kind == .earlyReset && $0.detectedAt > Date.now.addingTimeInterval(-60) })
        XCTAssertTrue(demo.events.contains { $0.kind == .bankedUsed && $0.detectedAt > Date.now.addingTimeInterval(-60) })
        let real = AccountStore(location: directory.appendingPathComponent("real/accounts.json"), integratesWithSystem: false)
        real.resetDemo(); XCTAssertTrue(real.accounts.isEmpty)
    }

    func testIllustrativeHistoryHasIdlePeriodsAndConsistentQuotaCycles() throws {
        let now = Date(timeIntervalSince1970: 1791114000)
        let accounts = DemoData.accounts(now: now)
        var custom = accounts[0]; custom.id = UUID(uuidString: "DE000000-0000-0000-0000-000000000000")!
        for account in Array(accounts.prefix(6)) + [custom] {
            let history = DemoData.history(for: account, now: now)
            XCTAssertEqual(history.first?.date, now.addingTimeInterval(-40 * 86400))
            XCTAssertEqual(history.last?.windows, account.snapshot?.windows)
            if account.provider == .copilot {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                for reading in history {
                    let reset = try XCTUnwrap(reading.windows.first?.resetsAt)
                    XCTAssertEqual(calendar.component(.day, from: reset), 1)
                    XCTAssertEqual(calendar.component(.hour, from: reset), 0)
                }
            }
            var idle = 0; var active = 0; var resets = 0
            for (before, after) in zip(history, history.dropFirst()) {
                for (a, b) in zip(before.windows, after.windows) {
                    let used = try XCTUnwrap(b.usedPercent)
                    XCTAssertTrue((0...100).contains(used))
                    if a.resetsAt == b.resetsAt {
                        XCTAssertGreaterThanOrEqual(used + 0.000001, a.usedPercent ?? 0)
                        if used == a.usedPercent { idle += 1 } else { active += 1 }
                    } else {
                        resets += 1
                        XCTAssertLessThanOrEqual(try XCTUnwrap(a.resetsAt), after.date)
                    }
                }
            }
            XCTAssertGreaterThan(idle, 0); XCTAssertGreaterThan(active, 0); XCTAssertGreaterThan(resets, 0)
        }
        XCTAssertEqual(accounts.first(where: { $0.provider == .grok })?.snapshot?.windows.count, 1)
        XCTAssertTrue(accounts.first(where: { $0.provider == .cline })!.snapshot!.windows.isEmpty)
        XCTAssertFalse(accounts.contains { $0.label.contains("Demo") || $0.snapshot?.plan == "Sample plan" })
    }

    func testWidgetDeepLinksSelectTheRightModeAndAccount() throws {
        let live = AccountStore(location: directory.appendingPathComponent("real/accounts.json"), vault: MemoryVault(), integratesWithSystem: false)
        let account = Fixture.account(Fixture.credential("real")); try live.connect(account, credential: Fixture.credential("real"))
        let session = AccountSession(live: live, demoLocation: directory.appendingPathComponent("demo/accounts.json"), restoresMode: false, integratesWithSystem: false, publishMode: { _ in })
        session.open(URL(string: "requota://account/\(DemoData.id(1))")!)
        XCTAssertTrue(session.isDemo); XCTAssertEqual(session.current.notificationAccountID, DemoData.id(1))
        session.open(URL(string: "eyeballs://account/\(account.id)")!)
        XCTAssertFalse(session.isDemo); XCTAssertEqual(live.notificationAccountID, account.id)
        session.open(URL(string: "https://example.com/\(DemoData.id(0))")!)
        XCTAssertFalse(session.isDemo)
    }
}
