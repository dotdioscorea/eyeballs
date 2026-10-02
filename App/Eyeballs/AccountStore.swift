import SwiftUI
import WidgetKit
import UserNotifications

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var accounts: [AgentAccount] = []
    @Published var refreshing: Set<UUID> = []
    @Published var isDemo = false
    @Published var error: String?
    @Published var notificationsEnabled = UserDefaults.standard.bool(forKey: "reset-notifications")
    private var cooldowns: [UUID: Date] = [:]
    private var revisions: [UUID: Int] = [:]
    private let location: URL
    private let vault: any CredentialStorage
    private let fetcher: (AgentAccount, AccountCredential) async throws -> UsageSnapshot
    private let renewer: (AccountCredential) async throws -> AccountCredential
    init(location: URL? = nil, vault: any CredentialStorage = CredentialVault(),
         fetcher: @escaping (AgentAccount, AccountCredential) async throws -> UsageSnapshot = { try await UsageClient.fetch(account: $0, credential: $1) },
         renewer: @escaping (AccountCredential) async throws -> AccountCredential = { try await OpenAIAuth.refresh($0) }) {
        self.location = location ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Eyeballs/accounts.json")
        self.vault = vault; self.fetcher = fetcher; self.renewer = renewer
        if let data = try? Data(contentsOf: self.location) {
            do { accounts = try JSONDecoder().decode([AgentAccount].self, from: data) }
            catch { self.error = "Your saved accounts could not be read. Your secure sessions have been kept." }
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo") { startDemo() }
        #endif
    }
    func startDemo() {
        for account in accounts { revisions[account.id, default: 0] += 1 }
        isDemo = true; accounts = DemoAccounts.accounts
    }
    func endDemo() {
        isDemo = false
        accounts = (try? Data(contentsOf: location)).flatMap { try? JSONDecoder().decode([AgentAccount].self, from: $0) } ?? []
    }
    func savedCredential(for id: UUID) throws -> AccountCredential? { try vault.load(id: id) }
    func connect(_ account: AgentAccount, credential: AccountCredential) throws {
        guard !isDemo else { return }
        guard account.provider == credential.provider, account.snapshot?.identity == credential.registrationIdentity else { throw UsageError.wrongAccount }
        let identity = credential.registrationIdentity
        let exact = accounts.firstIndex(where: { $0.id == account.id })
        if let exact, let saved = accounts[exact].snapshot?.identity, saved != identity { throw UsageError.wrongAccount }
        let existing = exact ?? accounts.firstIndex(where: { $0.provider == account.provider && $0.snapshot?.identity == identity })
        if let existing {
            var merged = accounts[existing]
            try vault.save(credential, id: merged.id)
            merged.snapshot = account.snapshot; merged.needsLogin = false; merged.issue = nil
            revisions[merged.id, default: 0] += 1; cooldowns[merged.id] = nil
            accounts[existing] = merged
        } else {
            try vault.save(credential, id: account.id)
            var connected = account; connected.needsLogin = false; connected.issue = nil
            revisions[account.id, default: 0] += 1
            accounts.append(connected)
        }
        persist()
    }
    func update(_ account: AgentAccount) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        // An editor may have opened before a refresh; preserve the latest usage and connection.
        accounts[index].label = account.label; accounts[index].workstream = account.workstream
        accounts[index].notes = account.notes; accounts[index].renewalReminder = account.renewalReminder
        accounts[index].favorite = account.favorite; persist()
    }
    func remove(_ id: UUID) throws {
        if !isDemo { try vault.delete(id: id) }
        revisions[id, default: 0] += 1
        accounts.removeAll { $0.id == id }
        cooldowns[id] = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: notificationIDs(id))
        persist()
    }
    func refreshAll() async {
        guard !isDemo else { return }
        for id in accounts.map(\.id) { await refresh(id) }
    }
    func refresh(_ id: UUID) async {
        guard !isDemo, !refreshing.contains(id), let account = accounts.first(where: { $0.id == id }), !account.needsLogin else { return }
        if let cooldown = cooldowns[id], cooldown > .now { return }
        let revision = revisions[id, default: 0]
        refreshing.insert(id); defer { refreshing.remove(id) }
        do {
            guard var credential = try vault.load(id: id) else { throw UsageError.signedOut }
            if credential.expiresAt < .now.addingTimeInterval(60) {
                credential = try await renewer(credential)
                guard !isDemo, revisions[id, default: 0] == revision, accounts.contains(where: { $0.id == id }) else { return }
                // Save rotating tokens before the usage request, even if that later request fails.
                try vault.save(credential, id: id)
            }
            let snapshot = try await fetcher(account, credential)
            guard !isDemo, revisions[id, default: 0] == revision, let index = accounts.firstIndex(where: { $0.id == id }) else { return }
            accounts[index].snapshot = snapshot; accounts[index].issue = nil; accounts[index].needsLogin = false
        } catch {
            guard !isDemo, revisions[id, default: 0] == revision, let index = accounts.firstIndex(where: { $0.id == id }) else { return }
            accounts[index].issue = error.localizedDescription
            if case UsageError.signedOut = error { accounts[index].needsLogin = true }
            if case UsageError.throttled(let until) = error { cooldowns[id] = until }
        }
        persist()
    }
    func enableNotifications(_ enabled: Bool) async {
        if enabled {
            do {
                let accepted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                notificationsEnabled = accepted
                if !accepted { error = "Reset reminders are disabled in iOS Settings. You can enable them under Notifications → Eyeballs." }
            } catch { self.error = "Notifications could not be enabled. Please try again."; notificationsEnabled = false }
        } else {
            notificationsEnabled = false
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        }
        UserDefaults.standard.set(notificationsEnabled, forKey: "reset-notifications")
        await scheduleNotifications()
    }
    private func notificationIDs(_ id: UUID) -> [String] { (0..<12).map { "reset-\(id)-\($0)" } }
    private func scheduleNotifications() async {
        guard !isDemo, notificationsEnabled else { return }
        let center = UNUserNotificationCenter.current()
        // Bound the total to iOS's pending-notification limit, choosing the nearest resets.
        center.removeAllPendingNotificationRequests()
        let events = accounts.flatMap { account in
            (account.snapshot?.windows ?? []).enumerated().compactMap { index, window -> (AgentAccount, UsageWindow, Int)? in
                guard let date = window.resetsAt, date > .now else { return nil }
                return (account, window, index)
            }
        }.sorted { $0.1.resetsAt! < $1.1.resetsAt! }.prefix(50)
        for (account, window, index) in events {
            let content = UNMutableNotificationContent()
            content.title = "\(account.title) is due to reset"
            content.body = "\(account.provider.name) · \(window.title). Open Eyeballs for a fresh reading."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, window.resetsAt!.timeIntervalSinceNow), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "reset-\(account.id)-\(index)", content: content, trigger: trigger))
        }
    }
    private func persist() {
        guard !isDemo else { return }
        do {
            try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(accounts).write(to: location, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            WidgetCache.write(accounts)
            WidgetCenter.shared.reloadAllTimelines()
            Task { await scheduleNotifications() }
        } catch { self.error = "Your changes could not be saved. Please try again." }
    }
}
