import SwiftUI
import BackgroundTasks
import UserNotifications


@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let session = AccountSession(live: AccountStore())
    var store: AccountStore { session.live }
    private var foregroundOperation: Task<Void, Never>?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        for identifier in [BackgroundRefreshScheduler.refreshID, BackgroundRefreshScheduler.processingID] {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
                let operation = Task { @MainActor in
                    guard let self else { task.setTaskCompleted(success: false); return }
                    // Queue the successor before network work: expiration must not
                    // break the refresh chain. Keep an existing earlier request.
                    await BackgroundRefreshScheduler.shared.ensureScheduled(source: .backgroundRefresh)
                    let started = Date.now
                    let trigger: RefreshTrigger = task is BGProcessingTask ? .backgroundProcessing : .backgroundRefresh
                    let summary = self.session.isDemo ? RefreshSummary() : await self.store.refreshAll(minimumAge: 5 * 60)
                    if !self.session.isDemo { Diagnostics.record(.refreshCycle, refresh: .init(trigger: trigger, startedAt: started, finishedAt: .now, summary: summary)) }
                    task.setTaskCompleted(success: summary.succeeded && !Task.isCancelled)
                }
                task.expirationHandler = { operation.cancel() }
            }
        }
        scheduleRefresh()
        return true
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let value = response.notification.request.content.userInfo["accountID"] as? String, let id = UUID(uuidString: value) {
            Task { @MainActor [weak self] in self?.session.open(URL(string: "eyeballs://account/\(id.uuidString)")!) }
        }
        completionHandler()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    func scheduleRefresh() {
        guard !session.isDemo, store.accounts.contains(where: { !$0.needsLogin }) else { return }
        Task { await BackgroundRefreshScheduler.shared.ensureScheduled(source: .foreground) }
    }

    func refreshForeground() async {
        guard !Task.isCancelled, !session.isDemo else { return }
        if let foregroundOperation { await foregroundOperation.value; return }
        // Let an already-started refresh finish if the user leaves the app.
        // This assertion ends immediately on completion or system expiration;
        // it never starts another poll while the app is in the background.
        var assertion = UIBackgroundTaskIdentifier.invalid
        assertion = UIApplication.shared.beginBackgroundTask(withName: "Finish usage refresh") { [weak self] in
            self?.foregroundOperation?.cancel()
            if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion); assertion = .invalid }
        }
        let operation = Task { @MainActor in
            defer {
                if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion); assertion = .invalid }
                foregroundOperation = nil
            }
            let started = Date.now
            let summary = await store.refreshAll(minimumAge: 60)
            Diagnostics.record(.refreshCycle, refresh: .init(trigger: .foreground, startedAt: started, finishedAt: .now, summary: summary))
        }
        foregroundOperation = operation
        await operation.value
    }
}

@main
struct EyeballsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase
    @AppStorage("foreground-refresh-minutes") private var foregroundInterval = 1
    var body: some Scene {
        WindowGroup {
            AccountSessionView(session: delegate.session).preferredColorScheme(.dark).tint(Theme.accent)
                .task(id: phase == .active ? foregroundInterval : 0) {
                    guard phase == .active else { return }
                    while !Task.isCancelled {
                        await delegate.refreshForeground()
                        do { try await Task.sleep(for: .seconds(RefreshSettings.foregroundMinutes * 60)) } catch { break }
                    }
                }
                .onChange(of: phase) { _, value in
                    if value == .active || value == .background { delegate.scheduleRefresh() }
                }
                .onChange(of: delegate.store.accounts.count) { _, _ in delegate.scheduleRefresh() }
        }
    }
}
