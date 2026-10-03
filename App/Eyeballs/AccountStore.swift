import SwiftUI
import WidgetKit
import UserNotifications

@MainActor
final class AccountStore: ObservableObject {
    let isDemo: Bool
    @Published private(set) var accounts: [AgentAccount] = []
    @Published private(set) var histories: [UUID: [UsageHistorySample]] = [:]
    private let historyStore: UsageHistoryStore
    @Published private(set) var events: [AccountEvent] = []
    @Published var notificationAccountID: UUID?
    @Published var reportAccountID: UUID?
    @Published var notificationRules = UserDefaults.standard.data(forKey: "notification-rules").flatMap { try? JSONDecoder().decode(ResetNotificationRules.self, from: $0) } ?? ResetNotificationRules()
    private let eventFile: AccountEventFile
    private var loadedEvents = false
    private var notificationGeneration = 0
    @Published var refreshing: Set<UUID> = []
    @Published var error: String?
    @Published var notificationsEnabled = UserDefaults.standard.bool(forKey: "reset-notifications")
    private var cooldowns: [UUID: Date] = [:]
    private var revisions: [UUID: Int] = [:]
    private let location: URL
    private var loadedAccounts = false
    private let integratesWithSystem: Bool
    private let publishesWidgetSummaries: Bool
    private let vault: any CredentialStorage
    private let fetcher: (AgentAccount, AccountCredential) async throws -> UsageSnapshot
    private let renewer: (AccountCredential) async throws -> AccountCredential
    init(location: URL? = nil, vault: any CredentialStorage = CredentialVault(), integratesWithSystem: Bool = true, isDemo: Bool = false,
         fetcher: @escaping (AgentAccount, AccountCredential) async throws -> UsageSnapshot = { try await UsageClient.fetch(account: $0, credential: $1) },
         renewer: @escaping (AccountCredential) async throws -> AccountCredential = { try await ProviderAuth.refresh($0) }) {
        self.isDemo = isDemo
        var selectedLocation = location ?? (isDemo ? DemoData.location : nil)
        #if DEBUG
        if !isDemo, location == nil, SimulatorFixtures.enabled, !SimulatorFixtures.widgetEnabled { selectedLocation = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("EyeballsUITest/accounts.json") }
        #endif
        self.location = selectedLocation ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Eyeballs/accounts.json")
        self.eventFile = AccountEventFile(location: self.location.deletingLastPathComponent().appendingPathComponent("events.json"))
        self.historyStore = UsageHistoryStore(directory: self.location.deletingLastPathComponent().appendingPathComponent("history"))
        self.integratesWithSystem = integratesWithSystem && !isDemo
        self.publishesWidgetSummaries = integratesWithSystem
        self.vault = vault; self.fetcher = fetcher; self.renewer = renewer
        if isDemo { notificationsEnabled = false }
        do {
            let data = try Data(contentsOf: self.location)
            accounts = try JSONDecoder().decode([AgentAccount].self, from: data)
            loadedAccounts = true
        } catch {
            if !FileManager.default.fileExists(atPath: self.location.path) {
                loadedAccounts = true
            } else { self.error = "Your saved accounts could not be read. Your secure sessions have been kept." }
        }
        do { events = try eventFile.read(); loadedEvents = true } catch { self.error = "Saved events could not be read." }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--clear-widget-fixture"), !accounts.isEmpty,
           accounts.allSatisfy({ $0.snapshot?.source == "UI Test Fixture" }) { accounts = []; persist() }
        if !isDemo, SimulatorFixtures.enabled, accounts.isEmpty { accounts = SimulatorFixtures.accounts() }
        if !isDemo, SimulatorFixtures.widgetEnabled { persist() }
        #endif
        for account in accounts { histories[account.id] = historyStore.read(account.id); if let snapshot = account.snapshot { recordHistory(snapshot, id: account.id) } }
        #if DEBUG
        if !isDemo, SimulatorFixtures.enabled {
            let fresh = SimulatorFixtures.accounts()
            for index in accounts.indices { if let sample = fresh.first(where: { $0.id == accounts[index].id }) {
                accounts[index].snapshot = sample.snapshot
                if ProcessInfo.processInfo.arguments.contains("--ring-boundaries") { accounts[index].display = sample.display }
            } }
            for account in accounts {
                histories[account.id] = (0..<72).map { index in
                    var windows = account.snapshot!.windows
                    windows[0].usedPercent = Double((index * 7) % 100)
                    windows[1].usedPercent = min(100, Double(index) * 0.55 + (account.snapshot?.windows[1].safePercent ?? 0) * 0.6)
                    return UsageHistorySample(date: Date.now.addingTimeInterval(Double(index - 72) * 3600), windows: windows)
                }
            }
        }
        #endif
        if publishesWidgetSummaries, loadedAccounts { publishWidgets() }
    }
    private func recordHistory(_ snapshot: UsageSnapshot, id: UUID) {
        let samples = historyStore.append(snapshot, to: histories[id] ?? [])
        do { try historyStore.write(samples, id: id); histories[id] = samples }
        catch { self.error = "Usage history could not be saved." }
    }
    private func publishWidgets() {
        guard publishesWidgetSummaries else { return }
        if isDemo { WidgetCache.writeDemo(accounts) } else { WidgetCache.write(accounts) }
        WidgetCenter.shared.reloadAllTimelines()
    }
    func restoreWidgetSummaries() { if loadedAccounts { publishWidgets() } }
    func savedCredential(for id: UUID) throws -> AccountCredential? { isDemo ? nil : try vault.load(id: id) }
    func connect(_ account: AgentAccount, credential: AccountCredential) throws {
        guard !isDemo else { throw UsageError.unavailable }
        guard loadedAccounts else { throw UsageError.unavailable }
        guard account.provider == credential.provider, account.snapshot?.identity == credential.registrationIdentity else { throw UsageError.wrongAccount }
        let identity = credential.registrationIdentity
        let exact = accounts.firstIndex(where: { $0.id == account.id })
        if let exact, let saved = accounts[exact].snapshot?.identity, saved != identity { throw UsageError.wrongAccount }
        let existing = exact ?? accounts.firstIndex(where: { $0.provider == account.provider && $0.snapshot?.identity == identity })
        if let existing {
            if let snapshot = account.snapshot { migrateMetrics(at: existing, matching: snapshot) }
            var merged = accounts[existing]
            try vault.save(credential, id: merged.id)
            merged.retainMetricNames()
            if let snapshot = account.snapshot { merged.snapshot = observe(snapshot, previous: merged.snapshot, id: merged.id) }; merged.needsLogin = false; merged.issue = nil; merged.needsReport = nil
            revisions[merged.id, default: 0] += 1; cooldowns[merged.id] = nil
            accounts[existing] = merged
            if let snapshot = merged.snapshot { recordHistory(snapshot, id: merged.id) }
        } else {
            try vault.save(credential, id: account.id)
            var connected = account; connected.needsLogin = false; connected.issue = nil; connected.needsReport = nil
            if let snapshot = connected.snapshot { connected.snapshot = observe(snapshot, previous: nil, id: connected.id) }
            revisions[account.id, default: 0] += 1
            accounts.append(connected)
            if let snapshot = connected.snapshot { recordHistory(snapshot, id: connected.id) }
        }
        persist()
    }
    func update(_ account: AgentAccount) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        // An editor may have opened before a refresh; preserve the latest usage and connection.
        accounts[index].label = account.label; accounts[index].workstream = account.workstream
        accounts[index].notes = account.notes; accounts[index].renewalReminder = account.renewalReminder
        accounts[index].favorite = account.favorite; accounts[index].display = account.display; accounts[index].colorHex = account.colorHex
        accounts[index].retainMetricNames(); persist()
    }
    private func migrateMetrics(at index: Int, matching snapshot: UsageSnapshot) {
        let original = accounts[index]
        guard original.provider == .codex,
              (original.snapshot?.windows.contains { $0.id.range(of: "^additional-[0-9]+$", options: .regularExpression) != nil } == true || original.display?.rings.contains { $0.windowID.range(of: "^additional-[0-9]+$", options: .regularExpression) != nil } == true) else { return }
        let migrated = MetricIdentityMigration.account(original, matching: snapshot.windows)
        guard migrated != original else { return }
        accounts[index] = migrated
        let id = original.id
        if let samples = histories[id] {
            let updated = samples.map { sample in
                var copy = sample; copy.windows = MetricIdentityMigration.windows(sample.windows, matching: snapshot.windows); return copy
            }
            do { try historyStore.write(updated, id: id); histories[id] = updated }
            catch { self.error = "Usage history could not be saved." }
        }
        for eventIndex in events.indices where events[eventIndex].accountID == id {
            if let windowID = events[eventIndex].windowID, let old = original.snapshot?.windows.first(where: { $0.id == windowID }),
               let replacement = MetricIdentityMigration.replacement(old, in: snapshot.windows) { events[eventIndex].windowID = replacement }
        }
        saveEvents()
    }
    func reorder(_ ids: [UUID]) {
        let ranks = Dictionary(uniqueKeysWithValues: Array(Set(ids)).map { ($0, ids.firstIndex(of: $0)!) })
        let ordered = accounts.filter { ranks[$0.id] != nil }.sorted { ranks[$0.id]! < ranks[$1.id]! }
        var next = ordered.makeIterator()
        accounts = accounts.map { ranks[$0.id] == nil ? $0 : next.next()! }
        persist()
    }
    func move(_ id: UUID, to target: UUID) {
        guard let from = accounts.firstIndex(where: { $0.id == id }), let to = accounts.firstIndex(where: { $0.id == target }), from != to else { return }
        let account = accounts.remove(at: from); accounts.insert(account, at: to); persist()
    }
    func remove(_ id: UUID) throws {
        if !isDemo { try vault.delete(id: id) }
        try historyStore.remove(id); histories[id] = nil
        revisions[id, default: 0] += 1
        accounts.removeAll { $0.id == id }
        cooldowns[id] = nil
        events.removeAll { $0.accountID == id }; saveEvents()
        if integratesWithSystem {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: notificationIDs(id))
            Task {
                let pending = await center.pendingNotificationRequests()
                center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.content.userInfo["accountID"] as? String == id.uuidString }.map(\.identifier))
                let delivered = await center.deliveredNotifications()
                center.removeDeliveredNotifications(withIdentifiers: delivered.filter { $0.request.content.userInfo["accountID"] as? String == id.uuidString }.map { $0.request.identifier })
            }
        }
        persist()
    }
    func reloadAccountsIfNeeded() {
        guard !loadedAccounts else { return }
        do {
            accounts = try JSONDecoder().decode([AgentAccount].self, from: Data(contentsOf: location))
            loadedAccounts = true; error = nil
            for account in accounts { histories[account.id] = historyStore.read(account.id) }
            if integratesWithSystem { publishWidgets() }
        } catch { }
    }
    func refreshAll() async {
        if isDemo { for account in accounts { await refresh(account.id) }; return }
        reloadAccountsIfNeeded()
        #if DEBUG
        if SimulatorFixtures.enabled { return }
        #endif
        // Oldest readings go first so a short background grant does not always
        // refresh the same accounts. Bound concurrent provider requests to three.
        var pending = accounts.sorted { ($0.snapshot?.updatedAt ?? .distantPast) < ($1.snapshot?.updatedAt ?? .distantPast) }.map(\.id).makeIterator()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { if let id = pending.next() { group.addTask { await self.refresh(id) } } }
            while await group.next() != nil {
                if Task.isCancelled { group.cancelAll(); break }
                if let id = pending.next() { group.addTask { await self.refresh(id) } }
            }
        }
    }
    private func renewCredential(_ credential: AccountCredential, account: AgentAccount) async throws -> AccountCredential {
        try await Diagnostics.$context.withValue(.init(provider: account.provider, accountID: account.id)) {
            try await renewer(credential)
        }
    }
    func refresh(_ id: UUID) async {
        if isDemo {
            guard let index = accounts.firstIndex(where: { $0.id == id }), var snapshot = accounts[index].snapshot else { return }
            snapshot.updatedAt = .now; accounts[index].snapshot = snapshot; recordHistory(snapshot, id: id); persist(); return
        }
        #if DEBUG
        if SimulatorFixtures.enabled { return }
        #endif
        guard !refreshing.contains(id), let account = accounts.first(where: { $0.id == id }), !account.needsLogin else { return }
        #if DEBUG
        if account.snapshot?.source == "UI Test Fixture" { return }
        #endif
        if let cooldown = cooldowns[id], cooldown > .now { return }
        let revision = revisions[id, default: 0]
        refreshing.insert(id); defer { refreshing.remove(id) }
        do {
            guard var credential = try vault.load(id: id) else { throw UsageError.signedOut }
            var renewed = false
            if credential.expiresAt < .now.addingTimeInterval(60) {
                credential = try await renewCredential(credential, account: account)
                renewed = true
                guard revisions[id, default: 0] == revision, accounts.contains(where: { $0.id == id }) else { return }
                // Save rotating tokens before the usage request, even if that later request fails.
                try vault.save(credential, id: id)
            }
            let snapshot: UsageSnapshot
            do { snapshot = try await fetcher(account, credential) }
            catch UsageError.usageAccessDenied where !renewed {
                // One refresh can recover a revoked/expired access token. If the fresh
                // token is also denied, retain the connection and report permission
                // failure; only a terminal refresh error requests another sign-in.
                credential = try await renewCredential(credential, account: account)
                guard revisions[id, default: 0] == revision, accounts.contains(where: { $0.id == id }) else { return }
                try vault.save(credential, id: id)
                snapshot = try await fetcher(account, credential)
            }
            guard revisions[id, default: 0] == revision, let index = accounts.firstIndex(where: { $0.id == id }) else { return }
            migrateMetrics(at: index, matching: snapshot)
            recordHistory(snapshot, id: id)
            accounts[index].retainMetricNames()
            accounts[index].snapshot = observe(snapshot, previous: accounts[index].snapshot, id: id); accounts[index].issue = nil; accounts[index].needsLogin = false; accounts[index].needsReport = nil
            if integratesWithSystem { Diagnostics.record(.refreshSucceeded, provider: account.provider) }
        } catch {
            guard revisions[id, default: 0] == revision, let index = accounts.firstIndex(where: { $0.id == id }) else { return }
            accounts[index].issue = error.localizedDescription
            if integratesWithSystem { Diagnostics.record(.refreshFailed, provider: account.provider, failure: .category(error)) }
            if case UsageError.invalidResponse = error {
                if accounts[index].needsReport != true {
                    accounts[index].needsReport = true; reportAccountID = id
                    appendEvents([AccountEvent(id: "\(id):parse:\(Date.now.timeIntervalSince1970)", accountID: id, kind: .parsingFailure, date: .now, detectedAt: .now)])
                }
            }
            if case UsageError.signedOut = error { accounts[index].needsLogin = true }
            if case UsageError.throttled(let until) = error { cooldowns[id] = until }
        }
        persist()
    }
    func enableNotifications(_ enabled: Bool) async {
        if isDemo { notificationsEnabled = enabled; return }
        guard integratesWithSystem else { return }
        if enabled {
            do {
                let accepted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                notificationsEnabled = accepted
                if !accepted { error = "Reset reminders are disabled in iOS Settings. You can enable them under Notifications → Requota." }
            } catch { self.error = "Notifications could not be enabled. Please try again."; notificationsEnabled = false }
        } else {
            notificationsEnabled = false
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        }
        UserDefaults.standard.set(notificationsEnabled, forKey: "reset-notifications")
        await scheduleNotifications()
    }
    private func notificationIDs(_ id: UUID) -> [String] { (0..<12).map { "reset-\(id)-\($0)" } }
    func saveNotificationRules() {
        guard !isDemo else { return }
        if let data = try? JSONEncoder().encode(notificationRules) { UserDefaults.standard.set(data, forKey: "notification-rules") }
        Task { await scheduleNotifications() }
    }
    private func observe(_ snapshot: UsageSnapshot, previous: UsageSnapshot?, id: UUID) -> UsageSnapshot {
        let result = EventDetection.compare(accountID: id, previous: previous, current: snapshot)
        appendEvents(result.events)
        return result.snapshot
    }
    private func saveEvents() {
        guard loadedEvents else { return }
        do { try eventFile.write(events) } catch { self.error = "Events could not be saved." }
    }
    private func appendEvents(_ additions: [AccountEvent]) {
        guard loadedEvents else { return }
        let ids = Set(events.map(\.id))
        let fresh = additions.filter { !ids.contains($0.id) }
        events.append(contentsOf: fresh)
        events = Array(events.filter { $0.detectedAt > Date.now.addingTimeInterval(-90 * 86400) }.sorted { $0.detectedAt < $1.detectedAt }.suffix(2000))
        saveEvents()
        if integratesWithSystem, notificationsEnabled {
            for event in fresh where notificationRules.announces(event.kind) {
                guard let account = accounts.first(where: { $0.id == event.accountID }) else { continue }
                // The reset-date reminder already covers normal resets. Do not send it twice.
                if event.kind == .weeklyReset { continue }
                let content = UNMutableNotificationContent()
                content.title = "\(account.title): \(event.kind.title.lowercased())"
                content.body = event.detail.isEmpty ? "Open Requota for details." : event.detail
                content.sound = .default; content.userInfo = ["accountID": account.id.uuidString]
                Task { try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "observed-" + event.id, content: content, trigger: nil)) }
            }
        }
    }
    private func scheduleNotifications() async {
        guard integratesWithSystem, notificationsEnabled else { return }
        notificationGeneration += 1; let generation = notificationGeneration
        let center = UNUserNotificationCenter.current()
        let old = await center.pendingNotificationRequests()
        guard generation == notificationGeneration, notificationsEnabled else { return }
        center.removePendingNotificationRequests(withIdentifiers: old.filter { $0.identifier.hasPrefix("reminder-") || $0.identifier.hasPrefix("reset-") }.map(\.identifier))
        for reminder in ResetReminderPlan.make(accounts: accounts, rules: notificationRules) {
            guard generation == notificationGeneration, notificationsEnabled else { return }
            let content = UNMutableNotificationContent()
            content.title = reminder.title; content.body = reminder.body; content.sound = .default
            content.userInfo = ["accountID": reminder.accountID.uuidString]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, reminder.date.timeIntervalSinceNow), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
        }
    }
    private func persist() {
        guard loadedAccounts else { return }
        do {
            try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(accounts).write(to: location, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            if isDemo { publishWidgets() }
            else if integratesWithSystem {
                publishWidgets()
                Task { await scheduleNotifications() }
            }
        } catch { self.error = "Your changes could not be saved. Please try again." }
    }

    func resetDemo(now: Date = .now) {
        guard isDemo, loadedAccounts, loadedEvents else { return }
        for id in histories.keys { try? historyStore.remove(id) }
        accounts = DemoData.accounts(now: now); histories = [:]
        for account in accounts {
            let samples = DemoData.history(for: account, now: now)
            do { try historyStore.write(samples, id: account.id); histories[account.id] = samples }
            catch { self.error = "Demo history could not be saved." }
        }
        events = DemoData.events(accounts: accounts, now: now); saveEvents(); persist()
    }
    func simulateDemoReset(now: Date = .now) {
        guard isDemo, let index = accounts.firstIndex(where: { $0.provider == .codex }), var snapshot = accounts[index].snapshot else { return }
        let id = accounts[index].id
        let previous = snapshot
        snapshot.updatedAt = max(now, previous.updatedAt.addingTimeInterval(1))
        for i in snapshot.windows.indices { snapshot.windows[i].usedPercent = 0 }
        if let banked = snapshot.bankedResets, !banked.isEmpty { snapshot.bankedResets = [] }
        accounts[index].snapshot = observe(snapshot, previous: previous, id: id)
        recordHistory(snapshot, id: id); persist()
    }
    func addDemoAccount(provider: Provider, name: String) {
        guard isDemo, loadedAccounts, var account = DemoData.accounts().first(where: { $0.provider == provider }) else { return }
        let random = UUID().uuidString
        account.id = UUID(uuidString: "DE000000" + random.dropFirst(8))!
        account.label = "Demo · " + (name.isEmpty ? provider.name : String(name.prefix(80)))
        accounts.append(account)
        let samples = DemoData.history(for: account)
        do { try historyStore.write(samples, id: account.id); histories[account.id] = samples }
        catch { self.error = "Demo history could not be saved." }
        persist()
    }
}
