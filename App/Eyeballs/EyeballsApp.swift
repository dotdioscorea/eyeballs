import SwiftUI
import BackgroundTasks
import UserNotifications


@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let session = AccountSession(live: AccountStore())
    var store: AccountStore { session.live }
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.dotdioscorea.eyeballs.refresh", using: nil) { [weak self] task in
            let operation = Task { @MainActor in
                guard let self else { task.setTaskCompleted(success: false); return }
                if !self.session.isDemo { await self.store.refreshAll() }
                task.setTaskCompleted(success: !Task.isCancelled)
                Self.scheduleRefresh()
            }
            task.expirationHandler = { operation.cancel() }
        }
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
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "com.dotdioscorea.eyeballs.refresh")
        request.earliestBeginDate = .now.addingTimeInterval(20 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

@main
struct EyeballsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            AccountSessionView(session: delegate.session).preferredColorScheme(.dark).tint(Theme.accent)
                .task(id: phase) {
                    guard phase == .active else { return }
                    while !Task.isCancelled {
                        if !delegate.session.isDemo { await delegate.store.refreshAll() }
                        do { try await Task.sleep(for: .seconds(300)) } catch { break }
                    }
                }
                .onChange(of: phase) { _, value in
                    if value == .background { AppDelegate.scheduleRefresh() }
                }
        }
    }
}
