import Foundation

enum WidgetCache {
    static let group = "group.com.dotdioscorea.eyeballs"
    static let key = "account-summaries-v1"
    static let demoKey = "demo-active-v1"
    static var demoActive: Bool {
        get { UserDefaults(suiteName: group)?.bool(forKey: demoKey) ?? false }
        set { UserDefaults(suiteName: group)?.set(newValue, forKey: demoKey) }
    }
    static var demoLocation: URL? { location?.deletingLastPathComponent().appendingPathComponent("demo-summaries-v1.json") }
    static var location: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("account-summaries-v2.json")
    }
    static func sanitized(_ accounts: [AgentAccount]) -> [AgentAccount] {
        accounts.map { original in
            var copy = original
            copy.notes = ""
            copy.snapshot?.email = nil
            copy.snapshot?.identity = nil
            copy.issue = copy.needsLogin ? "Reconnect in Requota" : nil
            return copy
        }
    }
    static func read() -> [AgentAccount] {
        if demoActive { return demoLocation.flatMap { read(from: $0) } ?? [] }
        if let location, let values = read(from: location) { return values }
        // Existing widgets can read their previous cache until the app next opens.
        guard let data = UserDefaults(suiteName: group)?.data(forKey: key) else { return [] }
        return decode(data) ?? []
    }
    static func read(from location: URL) -> [AgentAccount]? {
        guard let size = try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 5_000_000,
              let data = try? Data(contentsOf: location) else { return nil }
        return decode(data)
    }
    private static func decode(_ data: Data) -> [AgentAccount]? {
        guard data.count < 5_000_000,
              let entries = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        let decoder = JSONDecoder()
        // A future provider or one malformed summary must not hide every other
        // saved account while iOS replaces an older widget process.
        let accounts = entries.compactMap { entry -> AgentAccount? in
            guard JSONSerialization.isValidJSONObject(entry), let data = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
            return try? decoder.decode(AgentAccount.self, from: data)
        }
        return sanitized(accounts)
    }
    static func write(_ accounts: [AgentAccount]) {
        guard let location else { return }
        do {
            try write(accounts, to: location)
            UserDefaults(suiteName: group)?.removeObject(forKey: key)
        } catch { /* Preserve the last complete cache if the device is locked or storage is unavailable. */ }
    }
    static func writeDemo(_ accounts: [AgentAccount]) {
        guard let demoLocation else { return }
        try? write(accounts, to: demoLocation)
    }
    static func write(_ accounts: [AgentAccount], to location: URL) throws {
        let data = try JSONEncoder().encode(sanitized(accounts))
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: location, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
