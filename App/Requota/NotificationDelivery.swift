import Foundation
import UserNotifications

struct NotificationDeliveryStatus: Codable {
    var enabledByUser = false
    var authorization = "Not checked"
    var alerts = "Not checked"
    var sounds = "Not checked"
    var scheduled = 0
    var lowWarnings = 0
    var resetWarnings = 0
    var lastChecked: Date?
    var schedulingFailed = false
    var plannedLowWarnings = 0
    var plannedResetWarnings = 0
    var addedRequests = 0
    var suppressedRepeats = 0
    var lastWarningScheduled: Date?
    static var saved: Self { UserDefaults.standard.data(forKey: "notification-delivery-status").flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self() }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "notification-delivery-status") } }
}
enum ReminderLedger {
    // Previously scheduled requests that became due count as sent even if the
    // user cleared Notification Center. Future cancelled requests may be re-added.
    static func shouldAdd(_ reminder: PlannedReminder, ledger: [String: Date], now: Date) -> Bool { ledger[reminder.id].map { $0 > now } ?? true }
    static func rearmRecovered(_ ledger: [String: Date], accounts: [AgentAccount], rules: ResetNotificationRules, overrides: [String: ResetNotificationRules], now: Date) -> [String: Date] {
        var ledger = ledger
        for account in accounts {
            let rules = overrides[account.provider.rawValue] ?? rules
            guard let snapshot = account.snapshot, now.timeIntervalSince(snapshot.updatedAt) <= 6 * 3600 else { continue }
            for window in snapshot.windows where window.resetsAt == nil {
                if let used = window.safePercent, 100 - used > Double(rules.lowThreshold) {
                    let prefix = "reminder-\(account.id)-\(window.id)-"
                    ledger = ledger.filter { !$0.key.hasPrefix(prefix) || !$0.key.hasSuffix("-low") }
                }
            }
        }
        return ledger
    }
    static func pendingPlan(_ plan: [PlannedReminder], ledger: [String: Date], now: Date) -> [PlannedReminder] {
        var seen = Set<String>()
        return Array(plan.filter { shouldAdd($0, ledger: ledger, now: now) && seen.insert($0.id).inserted }.sorted { $0.date < $1.date }.prefix(50))
    }
    static func reconcile(_ ledger: [String: Date], plan: [PlannedReminder], now: Date) -> [String: Date] {
        let ids = Set(plan.map(\.id))
        return ledger.filter { key, date in date > now.addingTimeInterval(-90 * 86400) && (date <= now || ids.contains(key)) }
    }
}
actor NotificationDelivery {
    static let shared = NotificationDelivery()
    #if DEBUG
    private var fixturePrepared = false
    private func prepareNotificationFixture() async {
        guard !fixturePrepared, SimulatorFixtures.enabled, ProcessInfo.processInfo.arguments.contains("--reset-notification-fixture") else { return }
        fixturePrepared = true
        let ids = Set(SimulatorFixtures.accounts().filter { $0.snapshot?.source == "UI Test Fixture" }.map { $0.id.uuidString })
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests(), delivered = await center.deliveredNotifications()
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { ids.contains($0.content.userInfo["accountID"] as? String ?? "") }.map(\.identifier))
        center.removeDeliveredNotifications(withIdentifiers: delivered.filter { ids.contains($0.request.content.userInfo["accountID"] as? String ?? "") }.map { $0.request.identifier })
        var ledger = UserDefaults.standard.data(forKey: "notification-reminder-ledger").flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
        ledger = ledger.filter { key, _ in !ids.contains { key.hasPrefix("reminder-\($0)-") } }
        if let data = try? JSONEncoder().encode(ledger) { UserDefaults.standard.set(data, forKey: "notification-reminder-ledger") }
    }
    #endif
    private var busy = false
    private var queued: ([AgentAccount], ResetNotificationRules, [String: ResetNotificationRules], Bool)?
    func update(accounts: [AgentAccount], rules: ResetNotificationRules, overrides: [String: ResetNotificationRules], enabled: Bool) async {
        // A new store can be created for background work. Coalesce across stores,
        // so stale scheduling tasks cannot remove a newer store's requests.
        queued = (accounts, rules, overrides, enabled)
        guard !busy else { return }
        busy = true
        while let next = queued { queued = nil; await apply(accounts: next.0, rules: next.1, overrides: next.2, enabled: next.3) }
        busy = false
    }
    func status() async -> NotificationDeliveryStatus {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        var result = NotificationDeliveryStatus.saved
        result.enabledByUser = UserDefaults.standard.bool(forKey: "reset-notifications")
        switch settings.authorizationStatus {
        case .authorized: result.authorization = "Allowed"
        case .provisional: result.authorization = "Quiet delivery"
        case .ephemeral: result.authorization = "Temporary"
        case .denied: result.authorization = "Denied"
        default: result.authorization = "Not requested"
        }
        result.alerts = settings.alertSetting == .enabled ? "On" : "Off"
        result.sounds = settings.soundSetting == .enabled ? "On" : "Off"
        let pending = await center.pendingNotificationRequests()
        result.scheduled = pending.filter { $0.identifier.hasPrefix("reminder-") }.count
        result.lowWarnings = pending.filter { $0.identifier.hasSuffix("-low") }.count
        result.resetWarnings = pending.filter { $0.identifier.hasSuffix("-allowance") }.count
        result.lastChecked = .now; result.save(); return result
    }
    private func apply(accounts: [AgentAccount], rules: ResetNotificationRules, overrides: [String: ResetNotificationRules], enabled: Bool) async {
        #if DEBUG
        await prepareNotificationFixture()
        #endif
        let center = UNUserNotificationCenter.current(), now = Date.now
        let old = await center.pendingNotificationRequests()
        let settings = await center.notificationSettings()
        let authorized = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
        let plan = enabled && authorized ? ResetReminderPlan.make(accounts: accounts, rules: rules, overrides: overrides, now: now) : []
        var ledger = UserDefaults.standard.data(forKey: "notification-reminder-ledger").flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
        // Removing an account also removes its local notification ledger.
        ledger = ledger.filter { key, _ in accounts.contains { key.hasPrefix("reminder-\($0.id)-") } }
        ledger = ReminderLedger.reconcile(ledger, plan: plan, now: now)
        ledger = ReminderLedger.rearmRecovered(ledger, accounts: accounts, rules: rules, overrides: overrides, now: now)
        let selected = ReminderLedger.pendingPlan(plan, ledger: ledger, now: now)
        let ids = Set(selected.map(\.id))
        center.removePendingNotificationRequests(withIdentifiers: old.filter { ($0.identifier.hasPrefix("reminder-") && !ids.contains($0.identifier)) || $0.identifier.hasPrefix("reset-") }.map(\.identifier))
        ledger = ReminderLedger.reconcile(ledger, plan: selected, now: now)
        var failed = false, added = 0
        let suppressed = plan.filter { !ReminderLedger.shouldAdd($0, ledger: ledger, now: now) }.count
        var warningScheduled = false
        for reminder in selected {
            // Keep imminent requests intact during repeated foreground refreshes.
            if old.contains(where: { $0.identifier == reminder.id }), reminder.date.timeIntervalSince(now) < 60 { continue }
            guard ReminderLedger.shouldAdd(reminder, ledger: ledger, now: now) else { continue }
            let content = UNMutableNotificationContent()
            content.title = reminder.title; content.body = reminder.body; content.sound = .default
            content.userInfo = ["accountID": reminder.accountID.uuidString]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, reminder.date.timeIntervalSinceNow), repeats: false)
            do { try await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger)); ledger[reminder.id] = reminder.date; added += 1; if reminder.date.timeIntervalSince(now) < 60 { warningScheduled = true } }
            catch { failed = true }
        }
        if let data = try? JSONEncoder().encode(ledger) { UserDefaults.standard.set(data, forKey: "notification-reminder-ledger") }
        var result = await status(); result.schedulingFailed = failed
        result.plannedLowWarnings = plan.filter { $0.id.hasSuffix("-low") }.count
        result.plannedResetWarnings = plan.filter { $0.id.hasSuffix("-allowance") }.count
        result.addedRequests = added; result.suppressedRepeats = suppressed
        if warningScheduled { result.lastWarningScheduled = now }
        result.save()
    }
    func test() async throws {
        guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) else { return }
        let content = UNMutableNotificationContent(); content.title = "Requota test"; content.body = "Notifications are working."; content.sound = .default
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "requota-notification-test", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)))
    }
}
