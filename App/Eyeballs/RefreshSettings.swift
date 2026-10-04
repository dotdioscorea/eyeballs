import UIKit

enum RefreshSettings {
    static let intervals = [1, 2, 5, 10]
    static var foregroundMinutes: Int {
        let value = UserDefaults.standard.integer(forKey: "foreground-refresh-minutes")
        return intervals.contains(value) ? value : 1
    }
    @MainActor static var backgroundStatus: String {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available: return "Available"
        case .denied: return "Disabled"
        case .restricted: return "Restricted"
        @unknown default: return "Unknown"
        }
    }
}
