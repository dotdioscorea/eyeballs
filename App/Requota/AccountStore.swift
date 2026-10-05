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
    @Published var notificationProviderRules = UserDefaults.standard.data(forKey: "notification-provider-rules").flatMap { try? JSONDecoder().decode([String: ResetNotificationRules].self, from: $0) } ?? [:]
    @Published var refreshing: Set<UUID> = []
    @Published private(set) var activating: Set<UUID> = []
    @Published private(set) var activationMessages: [UUID: String] = [:]
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
    private let activator: (AccountCredential) async throws -> Void
    init(location: URL? = nil, vault: any CredentialStorage = CredentialVault(), integratesWithSystem: Bool = true, isDemo: Bool = false,
         fetcher: @escaping (AgentAccount, AccountCredential) async throws -> UsageSnapshot = { try await UsageClient.fetch(account: $0, credential: $1) },
         renewer: @escaping (AccountCredential) async throws -> AccountCredential = { try await ProviderAuth.refresh($0) },
         legacyActivationProviders: [String: Bool]? = nil,
         activator: @escaping (AccountCredential) async throws -> Void = { try await AllowanceActivation.send($0) }) {
        #if DEBUG
        if SimulatorFixtures.enabled, ProcessInfo.processInfo.arguments.contains("--reset-activation-settings") { UserDefaults.standard.removeObject(forKey: "activation-providers") }
        #endif
        self.isDemo = isDemo
        let legacyActivationProviders = legacyActivationProviders ?? (integratesWithSystem && !isDemo ? UserDefaults.standard.data(forKey: "activation-providers").flatMap { try? JSONDecoder().decode([String: Bool].self, from: $0) } ?? [:] : [:])
        var selectedLocation = location ?? (isDemo ? DemoData.location : nil)
        #if DEBUG
        if !isDemo, location == nil, SimulatorFixtures.enabled, !SimulatorFixtures.widgetEnabled { selectedLocation = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RequotaUITest/accounts.json") }
        if !isDemo, location == nil, SimulatorFixtures.activationEnabled {
            selectedLocation = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RequotaActivationUITest/accounts.json")
            if ProcessInfo.processInfo.arguments.contains("--reset-activation-fixture") { try? FileManager.default.removeItem(at: selectedLocation!.deletingLastPathComponent()) }
        }
        if !isDemo, location == nil, SimulatorFixtures.storeCaptureEnabled {
            selectedLocation = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RequotaStoreCapture/accounts.json")
            UserDefaults.standard.set("manual", forKey: "dashboard-sort")
            UserDefaults.standard.set(["cards", "bars"].contains(SimulatorFixtures.captureScreen) ? SimulatorFixtures.captureScreen : "tiles", forKey: "dashboard-layout")
            UserDefaults.standard.set(true, forKey: "chart-smooth")
        }
        #endif
        self.location = selectedLocation ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Eyeballs/accounts.json")
        self.eventFile = AccountEventFile(location: self.location.deletingLastPathComponent().appendingPathComponent("events.json"))
        self.historyStore = UsageHistoryStore(directory: self.location.deletingLastPathComponent().appendingPathComponent("history"))
        self.integratesWithSystem = integratesWithSystem && !isDemo
        self.publishesWidgetSummaries = integratesWithSystem
        #if DEBUG && targetEnvironment(simulator)
        if !isDemo, location == nil, SimulatorFixtures.activationEnabled {
            let fixture = ActivationUIFixture(location: self.location)
            self.vault = fixture; self.fetcher = fixture.fetch; self.activator = fixture.activate
        } else { self.vault = vault; self.fetcher = fetcher; self.activator = activator }
        #else
        self.vault = vault; self.fetcher = fetcher; self.activator = activator
        #endif
        self.renewer = renewer
        if isDemo { notificationsEnabled = false }
        #if DEBUG
        if SimulatorFixtures.activationEnabled {
            notificationsEnabled = false
            if ProcessInfo.processInfo.arguments.contains("--reset-activation-fixture") {
                UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
                UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            }
        }
        #endif
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
        if !isDemo, SimulatorFixtures.enabled, !SimulatorFixtures.storeCaptureEnabled, accounts.isEmpty { accounts = SimulatorFixtures.accounts() }
        if !isDemo, SimulatorFixtures.widgetEnabled { persist() }
        #endif
        // Preserve the old opt-in for existing connections only. New accounts
        // default to off and never inherit a provider-wide setting.
        if !isDemo, accounts.contains(where: { $0.automaticActivation == nil }) {
            for index in accounts.indices where accounts[index].automaticActivation == nil {
                accounts[index].automaticActivation = AllowanceActivation.supported(accounts[index].provider) && legacyActivationProviders[accounts[index].provider.rawValue] == true
            }
            persist()
        }
        #if DEBUG
        if !isDemo, SimulatorFixtures.enabled, ProcessInfo.processInfo.arguments.contains("--reset-activation-settings") {
            for index in accounts.indices { accounts[index].automaticActivation = false }
            persist()
        }
        #endif
        for account in accounts { histories[account.id] = historyStore.read(account.id); if let snapshot = account.snapshot { recordHistory(snapshot, id: account.id) } }
        #if DEBUG
        if !isDemo, SimulatorFixtures.enabled, !SimulatorFixtures.storeCaptureEnabled {
            let fresh = SimulatorFixtures.accounts()
            for index in accounts.indices { if let sample = fresh.first(where: { $0.id == accounts[index].id }) {
                accounts[index].snapshot = sample.snapshot
                accounts[index].provider = sample.provider
                if ProcessInfo.processInfo.arguments.contains("--ring-boundaries") { accounts[index].display = sample.display }
            } }
            for account in accounts {
                histories[account.id] = (0..<72).map { index in
                    var windows = account.snapshot!.windows
                    if windows.indices.contains(0) { windows[0].usedPercent = Double((index * 7) % 100) }
                    if windows.indices.contains(1) { windows[1].usedPercent = min(100, Double(index) * 0.55 + (account.snapshot?.windows[1].safePercent ?? 0) * 0.6) }
                    return UsageHistorySample(date: Date.now.addingTimeInterval(Double(index - 72) * 3600), windows: windows, remainingAllowances: account.snapshot?.remainingAllowances)
                }
            }
        }
        if !isDemo, SimulatorFixtures.storeCaptureEnabled {
            let now = Date.now.addingTimeInterval(-120)
            accounts = Array(DemoData.accounts(now: now).prefix(UIDevice.current.userInterfaceIdiom == .pad ? 13 : SimulatorFixtures.captureScreen == "tiles" ? 6 : 8)).enumerated().map { index, sample in
                var copy = sample
                copy.id = UUID(uuidString: String(format: "A9000000-0000-0000-0000-%012d", index + 1))!
                copy.snapshot?.source = "Store screenshot fixture"
                copy.favorite = index < 6
                return copy
            }
            for account in accounts {
                let samples = DemoData.history(for: account, now: now)
                histories[account.id] = samples
                try? historyStore.write(samples, id: account.id)
            }
            events = DemoData.events(accounts: accounts, now: now)
            saveEvents(); persist()
        }
        #endif
        #if DEBUG && targetEnvironment(simulator)
        if SignInUIFixture.enabled, let index = accounts.firstIndex(where: { $0.id == SignInUIFixture.existingID }) {
            accounts[index].snapshot?.identity = SignInUIFixture.credential().registrationIdentity
        }
        #endif
        if publishesWidgetSummaries, loadedAccounts { publishWidgets() }
        if self.integratesWithSystem, loadedAccounts { Task { await scheduleNotifications() } }
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
    func existingConnection(for credential: AccountCredential) -> AgentAccount? {
        accounts.first { $0.provider == credential.provider && $0.snapshot?.identity == credential.registrationIdentity }
    }
    @discardableResult
    func connect(_ account: AgentAccount, credential: AccountCredential) throws -> UUID {
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
            connected.automaticActivation = account.automaticActivation ?? false
            if let snapshot = connected.snapshot { connected.snapshot = observe(snapshot, previous: nil, id: connected.id) }
            revisions[account.id, default: 0] += 1
            accounts.append(connected)
            if let snapshot = connected.snapshot { recordHistory(snapshot, id: connected.id) }
        }
        persist()
        return existing.map { accounts[$0].id } ?? account.id
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
        activationMessages[id] = nil
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
    @discardableResult
    func refreshAll(minimumAge: TimeInterval = 0) async -> RefreshSummary {
        var summary = RefreshSummary()
        guard !Task.isCancelled else { summary.cancelled = true; return summary }
        if isDemo {
            for account in accounts { summary.include(await refresh(account.id)) }
            return summary
        }
        reloadAccountsIfNeeded()
        guard loadedAccounts else { summary.metadataUnavailable = true; return summary }
        #if DEBUG
        if SimulatorFixtures.enabled && !SimulatorFixtures.activationEnabled { return summary }
        #endif
        // Oldest readings go first so a short background grant does not always
        // refresh the same accounts. Bound concurrent provider requests to three.
        var pending = accounts.sorted { ($0.snapshot?.updatedAt ?? .distantPast) < ($1.snapshot?.updatedAt ?? .distantPast) }.map(\.id).makeIterator()
        await withTaskGroup(of: RefreshOutcome.self) { group in
            for _ in 0..<3 { if let id = pending.next() { group.addTask { await self.refresh(id, minimumAge: minimumAge) } } }
            while let outcome = await group.next() {
                summary.include(outcome)
                if Task.isCancelled { summary.cancelled = true; group.cancelAll(); continue }
                if let id = pending.next() { group.addTask { await self.refresh(id, minimumAge: minimumAge) } }
            }
        }
        return summary
    }
    private func renewCredential(_ credential: AccountCredential, account: AgentAccount) async throws -> AccountCredential {
        try await Diagnostics.$context.withValue(.init(provider: account.provider, accountID: account.id)) {
            try await renewer(credential)
        }
    }
    @discardableResult
    func refresh(_ id: UUID, minimumAge: TimeInterval = 0, allowsActivation: Bool = true) async -> RefreshOutcome {
        guard !Task.isCancelled else { return .cancelled }
        if isDemo {
            guard let index = accounts.firstIndex(where: { $0.id == id }), var snapshot = accounts[index].snapshot else { return .skipped }
            snapshot.updatedAt = .now; accounts[index].snapshot = snapshot; recordHistory(snapshot, id: id); persist(); return .updated
        }
        #if DEBUG
        if SimulatorFixtures.enabled && !SimulatorFixtures.activationEnabled { return .skipped }
        #endif
        guard !refreshing.contains(id), let account = accounts.first(where: { $0.id == id }), !account.needsLogin else { return .skipped }
        #if DEBUG
        if account.snapshot?.source == "UI Test Fixture" && !SimulatorFixtures.activationEnabled { return .skipped }
        #endif
        if let cooldown = cooldowns[id], cooldown > .now { return .skipped }
        if minimumAge > 0, let snapshot = account.snapshot, Date.now.timeIntervalSince(snapshot.updatedAt) < minimumAge, !snapshot.windows.contains(where: { $0.resetDue() }) { return .skipped }
        let revision = revisions[id, default: 0]
        refreshing.insert(id); defer { refreshing.remove(id) }
        do {
            guard var credential = try vault.load(id: id) else { throw UsageError.signedOut }
            var renewed = false
            if credential.provider == .perplexity || credential.expiresAt < .now.addingTimeInterval(60) {
                credential = try await renewCredential(credential, account: account)
                renewed = true
                guard revisions[id, default: 0] == revision, accounts.contains(where: { $0.id == id }) else { return .skipped }
                // Save rotating tokens before the usage request, even if that later request fails.
                try vault.save(credential, id: id)
                try Task.checkCancellation()
            }
            let snapshot: UsageSnapshot
            do { snapshot = try await fetcher(account, credential) }
            catch UsageError.usageAccessDenied where !renewed {
                // One refresh can recover a revoked/expired access token. If the fresh
                // token is also denied, retain the connection and report permission
                // failure; only a terminal refresh error requests another sign-in.
                credential = try await renewCredential(credential, account: account)
                guard revisions[id, default: 0] == revision, accounts.contains(where: { $0.id == id }) else { return .skipped }
                try vault.save(credential, id: id)
                try Task.checkCancellation()
                snapshot = try await fetcher(account, credential)
            }
            try Task.checkCancellation()
            guard revisions[id, default: 0] == revision, let index = accounts.firstIndex(where: { $0.id == id }) else { return .skipped }
            migrateMetrics(at: index, matching: snapshot)
            recordHistory(snapshot, id: id)
            accounts[index].retainMetricNames()
            accounts[index].snapshot = observe(snapshot, previous: accounts[index].snapshot, id: id); accounts[index].issue = nil; accounts[index].needsLogin = false; accounts[index].needsReport = nil
            observeActivationClock(snapshot, id: id)
            if integratesWithSystem { Diagnostics.record(.refreshSucceeded, provider: account.provider) }
            persist()
            if allowsActivation, accounts[index].automaticActivation == true, !activating.contains(id),
               AllowanceActivation.permitted(credential),
               AllowanceActivation.mayAutomaticallyAttempt(snapshot, provider: account.provider, record: accounts[index].activation) {
                activating.insert(id)
                await attemptActivation(id, credential: credential, before: snapshot)
                activating.remove(id)
            } else if let used = AllowanceActivation.weekly(snapshot, provider: account.provider)?.safePercent, accounts[index].activation != nil {
                accounts[index].activation?.lastObservedUsed = used
                if used > 0 { accounts[index].activation?.usedSinceAttempt = true }
                persist()
            }
            return .updated
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
            guard revisions[id, default: 0] == revision, let index = accounts.firstIndex(where: { $0.id == id }) else { return .skipped }
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
        return .failed
    }
    func setAutomaticActivation(_ enabled: Bool, for id: UUID) {
        guard !isDemo, let index = accounts.firstIndex(where: { $0.id == id }),
              AllowanceActivation.supported(accounts[index].provider) else { return }
        accounts[index].automaticActivation = enabled
        persist()
    }
    func activationPermitted(_ id: UUID) -> Bool {
        (try? savedCredential(for: id)).map(AllowanceActivation.permitted) ?? false
    }
    func startAllowance(_ id: UUID) async {
        guard !isDemo, !activating.contains(id), !refreshing.contains(id) else { return }
        activating.insert(id); defer { activating.remove(id) }
        activationMessages[id] = nil
        // Always recheck current plan, limits and identity immediately before POST.
        guard await refresh(id, allowsActivation: false) == .updated,
              let account = accounts.first(where: { $0.id == id }), let snapshot = account.snapshot else { return }
        do {
            guard let credential = try vault.load(id: id), AllowanceActivation.permitted(credential) else { throw ActivationError.permissionRequired }
            guard AllowanceActivation.candidate(snapshot, provider: account.provider) else {
                if let week = AllowanceActivation.weekly(snapshot, provider: account.provider), week.safePercent.map({ $0 > 0 }) == true || week.resetsAt.map({ $0.timeIntervalSinceNow < 604500 }) == true { throw ActivationError.alreadyActive }
                throw ActivationError.allowanceUnknown
            }
            if let record = account.activation, Date.now.timeIntervalSince(record.attemptedAt) < 600 { throw ActivationError.recentlyAttempted }
            await attemptActivation(id, credential: credential, before: snapshot)
        } catch { activationMessages[id] = error.localizedDescription }
    }
    private func attemptActivation(_ id: UUID, credential: AccountCredential, before: UsageSnapshot) async {
        guard let index = accounts.firstIndex(where: { $0.id == id }), before.identity == credential.registrationIdentity,
              !Task.isCancelled else { return }
        let account = accounts[index], revision = revisions[id, default: 0], attemptedAt = Date.now
        let week = AllowanceActivation.weekly(before, provider: account.provider)
        accounts[index].activation = ActivationRecord(attemptedAt: attemptedAt, status: .attempted,
            windowID: week?.id, previousResetAt: week?.resetsAt, plan: before.plan, allowanceContext: before.allowanceContext)
        // An uncertain request must survive termination and relaunch. If the
        // record cannot be saved, do not send anything.
        guard persist() else {
            accounts[index].activation?.status = .failed
            accounts[index].activation?.retryAfter = .now.addingTimeInterval(300)
            activationMessages[id] = "The activation attempt could not be saved. No request was sent."
            return
        }
        do {
            try await Diagnostics.$context.withValue(.init(provider: account.provider, accountID: id)) { Diagnostics.record(.activationAttempted); try await activator(credential); Diagnostics.record(.activationCompleted) }
            guard revisions[id, default: 0] == revision, let currentIndex = accounts.firstIndex(where: { $0.id == id }) else { return }
            accounts[currentIndex].activation?.status = .completed
            activationMessages[id] = "Request completed."
            appendEvents([AccountEvent(id: "\(id):activation:\(attemptedAt.timeIntervalSince1970)", accountID: id, kind: .activationSent, date: attemptedAt, detectedAt: .now)])
            persist()
            // Completion proves consumption, not that the weekly clock changed.
            let after = try await fetcher(account, credential)
            try Task.checkCancellation()
            guard revisions[id, default: 0] == revision, let latest = accounts.firstIndex(where: { $0.id == id }) else { return }
            guard after.identity == credential.registrationIdentity else { throw UsageError.wrongAccount }
            accounts[latest].snapshot = observe(after, previous: accounts[latest].snapshot, id: id)
            recordHistory(after, id: id)
            observeActivationClock(after, id: id)
            persist()
        } catch {
            Diagnostics.$context.withValue(.init(provider: account.provider, accountID: id)) { Diagnostics.record(.activationFailed, failure: .category(error)) }
            guard revisions[id, default: 0] == revision, let latest = accounts.firstIndex(where: { $0.id == id }) else { return }
            // Keep completed status when only the follow-up usage read failed.
            if accounts[latest].activation?.status == .attempted { accounts[latest].activation?.status = .failed }
            if let failure = error as? ActivationPreparationFailure {
                accounts[latest].activation?.retryAfter = failure.retryAfter
                if case UsageError.invalidResponse = failure.cause {
                    accounts[latest].needsReport = true; reportAccountID = id
                    appendEvents([AccountEvent(id: "\(id):activation-parse:\(attemptedAt.timeIntervalSince1970)", accountID: id,
                        kind: .parsingFailure, date: .now, detectedAt: .now)])
                }
            }
            activationMessages[id] = accounts[latest].activation?.status == .completed ? "Request completed. Usage could not be updated yet." : error.localizedDescription
            persist()
        }
    }
    private func observeActivationClock(_ snapshot: UsageSnapshot, id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }), let record = accounts[index].activation,
              record.status == .completed, let week = AllowanceActivation.weekly(snapshot, provider: accounts[index].provider),
              week.id == record.windowID, week.clockReported == true else { return }
        if AllowanceActivation.confirmedStart(record: record, snapshot: snapshot, provider: accounts[index].provider) {
            accounts[index].activation?.status = .started
            activationMessages[id] = "Weekly window active."
            let detectedAt = Date.now
            appendEvents([AccountEvent(id: "\(id):started:\(record.attemptedAt.timeIntervalSince1970)", accountID: id,
                kind: .windowStarted, date: detectedAt, detectedAt: detectedAt, window: "Weekly", windowID: week.id)])
        } else if record.resetAt != week.resetsAt || record.resetObservedAt == nil {
            accounts[index].activation?.resetAt = week.resetsAt
            accounts[index].activation?.resetObservedAt = snapshot.updatedAt
        }
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
        if let data = try? JSONEncoder().encode(notificationProviderRules) { UserDefaults.standard.set(data, forKey: "notification-provider-rules") }
        Task { await scheduleNotifications() }
    }
    private func observe(_ snapshot: UsageSnapshot, previous: UsageSnapshot?, id: UUID) -> UsageSnapshot {
        let result = EventDetection.compare(accountID: id, previous: previous, current: snapshot)
        if let provider = accounts.first(where: { $0.id == id })?.provider {
            Diagnostics.$context.withValue(.init(provider: provider, accountID: id)) {
                Diagnostics.record(.resetCompared, resets: .make(previous: previous, current: snapshot, events: result.events))
            }
        }
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
            for event in fresh {
                guard let account = accounts.first(where: { $0.id == event.accountID }), (notificationProviderRules[account.provider.rawValue] ?? notificationRules).announces(event.kind) else { continue }
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
    func scheduleNotifications() async {
        guard integratesWithSystem else { return }
        await NotificationDelivery.shared.update(accounts: accounts, rules: notificationRules, overrides: notificationProviderRules, enabled: notificationsEnabled)
    }
    @discardableResult
    private func persist() -> Bool {
        guard loadedAccounts else { return false }
        do {
            try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(accounts).write(to: location, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            if isDemo { publishWidgets() }
            else if integratesWithSystem {
                publishWidgets()
                Task { await scheduleNotifications() }
                if accounts.contains(where: { !$0.needsLogin }) {
                    Task { await BackgroundRefreshScheduler.shared.ensureScheduled(source: .foreground) }
                }
            }
            return true
        } catch { self.error = "Your changes could not be saved. Please try again."; return false }
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
        account.label = name.isEmpty ? provider.name : String(name.prefix(80))
        accounts.append(account)
        let samples = DemoData.history(for: account)
        do { try historyStore.write(samples, id: account.id); histories[account.id] = samples }
        catch { self.error = "Demo history could not be saved." }
        persist()
    }
}
