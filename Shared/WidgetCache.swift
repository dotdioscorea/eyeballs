import Foundation

enum WidgetCache {
    static let group = "group.com.dotdioscorea.eyeballs"
    static let key = "account-summaries-v1"
    static var location: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("account-summaries-v2.json")
    }
    static func sanitized(_ accounts: [AgentAccount]) -> [AgentAccount] {
        accounts.map { original in
            var copy = original
            copy.notes = ""
            copy.snapshot?.email = nil
            copy.snapshot?.identity = nil
            copy.issue = copy.needsLogin ? "Reconnect in Eyeballs" : nil
            return copy
        }
    }
    static func read() -> [AgentAccount] {
        if let location, let values = read(from: location) { return values }
        // Existing widgets can read their previous cache until the app next opens.
        guard let data = UserDefaults(suiteName: group)?.data(forKey: key) else { return [] }
        return sanitized((try? JSONDecoder().decode([AgentAccount].self, from: data)) ?? [])
    }
    static func read(from location: URL) -> [AgentAccount]? {
        guard let size = try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 5_000_000,
              let data = try? Data(contentsOf: location),
              let accounts = try? JSONDecoder().decode([AgentAccount].self, from: data) else { return nil }
        return sanitized(accounts)
    }
    static func write(_ accounts: [AgentAccount]) {
        guard let location else { return }
        do {
            try write(accounts, to: location)
            UserDefaults(suiteName: group)?.removeObject(forKey: key)
        } catch { /* Preserve the last complete cache if the device is locked or storage is unavailable. */ }
    }
    static func write(_ accounts: [AgentAccount], to location: URL) throws {
        let data = try JSONEncoder().encode(sanitized(accounts))
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: location, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
