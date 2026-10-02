import SwiftUI
import BackgroundTasks

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    let store = AccountStore()
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.dotdioscorea.eyeballs.refresh", using: nil) { [weak self] task in
            let operation = Task { @MainActor in
                guard let self else { task.setTaskCompleted(success: false); return }
                await self.store.refreshAll()
                task.setTaskCompleted(success: !Task.isCancelled)
                Self.scheduleRefresh()
            }
            task.expirationHandler = { operation.cancel() }
        }
        return true
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
            RootView().environmentObject(delegate.store).preferredColorScheme(.dark).tint(Theme.accent)
                .task(id: phase) {
                    guard phase == .active else { return }
                    while !Task.isCancelled {
                        await delegate.store.refreshAll()
                        do { try await Task.sleep(for: .seconds(300)) } catch { break }
                    }
                }
                .onChange(of: phase) { _, value in
                    if value == .background { AppDelegate.scheduleRefresh() }
                }
        }
    }
}
