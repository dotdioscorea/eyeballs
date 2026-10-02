import Foundation
import UIKit

enum DiagnosticStage: String, Codable { case signInStarted, identityVerified, usageVerified, signInFailed, refreshSucceeded, refreshFailed, http }
enum DiagnosticFailure: String, Codable {
    case cancelled, timeout, callback, identity, signedOut, permission, throttled, response, accountMismatch, network, other
    static func category(_ error: Error) -> Self {
        if let error = error as? AuthError {
            switch error { case .cancelled: return .cancelled; case .timedOut: return .timeout; case .invalidCallback: return .callback; case .invalidIdentity: return .identity; case .unavailable: return .network }
        }
        if let error = error as? UsageError {
            switch error { case .signedOut: return .signedOut; case .usageAccessDenied: return .permission; case .throttled: return .throttled; case .invalidResponse: return .response; case .wrongAccount: return .accountMismatch; default: return .other }
        }
        if error is CancellationError { return .cancelled }
        if error is URLError { return .network }
        return .other
    }
}
struct DiagnosticEvent: Codable {
    var date: Date
    var provider: Provider?
    var stage: DiagnosticStage
    var status: Int?
    var failure: DiagnosticFailure?
    var privateSession: Bool?
}
struct DebugBundle: Codable {
    var schemaVersion = 1
    var createdAt: Date
    var appVersion: String
    var systemVersion: String
    var device: String
    var widgetCacheAvailable: Bool
    var widgetAccountCount: Int
    var accounts: [AccountStatus]
    var events: [DiagnosticEvent]
    struct AccountStatus: Codable {
        var provider: Provider
        var needsLogin: Bool
        var readingAgeSeconds: Int?
        var windowCount: Int
        var configuredMetricCount: Int
    }
}
enum Diagnostics {
    private static let lock = NSLock()
    private static let location = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Eyeballs/diagnostics.json")
    // Only typed fields are accepted. Never store URLs, HTTP bodies, error messages,
    // OAuth state, account IDs, labels, email addresses or credentials.
    static func record(_ stage: DiagnosticStage, provider: Provider? = nil, status: Int? = nil, failure: DiagnosticFailure? = nil, privateSession: Bool? = nil) {
        lock.lock(); defer { lock.unlock() }
        var events = load().filter { $0.date > Date.now.addingTimeInterval(-7 * 86400) }
        events.append(DiagnosticEvent(date: .now, provider: provider, stage: stage, status: status, failure: failure, privateSession: privateSession))
        events = Array(events.suffix(100))
        do {
            try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(events).write(to: location, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { }
    }
    private static func load() -> [DiagnosticEvent] {
        guard let size = try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 100_000,
              let data = try? Data(contentsOf: location) else { return [] }
        return (try? JSONDecoder().decode([DiagnosticEvent].self, from: data)) ?? []
    }
    static func events() -> [DiagnosticEvent] {
        lock.lock(); defer { lock.unlock() }
        return load().filter { $0.date > Date.now.addingTimeInterval(-7 * 86400) }
    }
    static func clear() { lock.lock(); defer { lock.unlock() }; try? FileManager.default.removeItem(at: location) }
    @MainActor
    static func bundle(accounts: [AgentAccount], now: Date = .now) -> DebugBundle {
        DebugBundle(createdAt: now, appVersion: version, systemVersion: UIDevice.current.systemVersion,
                    device: UIDevice.current.model, widgetCacheAvailable: WidgetCache.location != nil,
                    widgetAccountCount: WidgetCache.read().count,
                    accounts: accounts.map { account in
                        DebugBundle.AccountStatus(provider: account.provider, needsLogin: account.needsLogin,
                                                  readingAgeSeconds: account.snapshot.map { max(0, Int(now.timeIntervalSince($0.updatedAt))) },
                                                  windowCount: account.snapshot?.windows.count ?? 0,
                                                  configuredMetricCount: account.displaySettings.rings.count)
                    }, events: events())
    }
    static var version: String { "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))" }
    static func encode(_ bundle: DebugBundle) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }
    static func export(_ data: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EyeballsReports")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("eyeballs-debug.json")
        try data.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return path
    }
}
