import Foundation
import CoreFoundation
import UIKit

enum DiagnosticStage: String, Codable { case signInStarted, identityVerified, usageVerified, signInFailed, refreshSucceeded, refreshFailed, http, usageParsed }
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
enum DiagnosticEndpoint: String, Codable { case token, identity, usage, bankedResets, identityKeys, deviceAuthorization, other
    static func identify(_ url: URL?) -> Self {
        guard let url else { return .other }
        switch url.path {
        case "/api/v1/auth/register", "/api/v1/auth/refresh", "/token", "/oauth/token", "/api/accounts/oauth/token", "/v1/oauth/token", "/oauth2/token", "/login/oauth/access_token": return .token
        case "/user_management/authorize/device", "/user_management/authenticate", "/auth/poll", "/login/device/code": return .deviceAuthorization
        case "/api/v1/users/me", "/aiserver.v1.DashboardService/GetMe", "/api/oauth/profile", "/oauth2/v2/userinfo", "/user": return .identity
        case "/aiserver.v1.DashboardService/GetCurrentPeriodUsage", "/aiserver.v1.DashboardService/GetPlanInfo", "/v1internal:loadCodeAssist", "/v1internal:retrieveUserQuota", "/backend-api/wham/usage", "/api/oauth/usage", "/v1/billing", "/copilot_internal/user": return .usage
        case "/backend-api/wham/rate-limit-reset-credits": return .bankedResets
        case "/.well-known/jwks.json": return .identityKeys
        default: return url.host == "api.cline.bot" && url.path.range(of: "^/api/v1/users/[A-Za-z0-9_-]{1,160}/balance$", options: .regularExpression) != nil ? .usage : .other
        }
    }
}
struct DiagnosticEvent: Codable {
    var date: Date
    var provider: Provider?
    var stage: DiagnosticStage
    var status: Int?
    var endpoint: DiagnosticEndpoint?
    var failure: DiagnosticFailure?
    var privateSession: Bool?
    var parsing: UsageParsingDiagnostic?
    // Local only; replaced with a bundle-local alias during export.
    var connection: String?
}
enum DiagnosticValueType: String, Codable { case missing, null, number, string, boolean, object, array, other }
enum UsageCalculation: String, Codable { case reportedPercentage, protoZero, legacyIncludedBudget, onDemandBudget, unavailable, providerWindows }
enum DiagnosticReading: String, Codable { case missing, zeroUsed, partialUsed, fullUsed, invalid }
struct UsageParsingDiagnostic: Codable {
    // Names are selected by code, never copied from arbitrary response keys.
    var fields: [KnownUsageField: DiagnosticValueType]
    var calculation: UsageCalculation
    var readings: [DiagnosticReading]
    enum KnownUsageField: String, Codable, CaseIterable {
        case creditUsagePercent, currentPeriod, periodType, periodStart, periodEnd, isUnifiedBillingUser
        case monthlyLimit, used, onDemandCap, onDemandUsed, prepaidBalance
        case creditBalance, rateLimit, primaryWindow, secondaryWindow, fiveHour, sevenDay, quotaBuckets, quotaSnapshots, remainingFraction, remainingAmount, quotaResetTime, planUsage, totalPercentUsed, autoPercentUsed, apiPercentUsed, billingCycleStart, billingCycleEnd
    }
    enum CodingKeys: String, CodingKey { case fields, calculation, readings }
    init(fields: [KnownUsageField: DiagnosticValueType], calculation: UsageCalculation, readings: [DiagnosticReading]) {
        self.fields = fields; self.calculation = calculation; self.readings = readings
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode([String: DiagnosticValueType].self, forKey: .fields)
        fields = raw.reduce(into: [:]) { result, pair in
            if let field = KnownUsageField(rawValue: pair.key) { result[field] = pair.value }
        }
        calculation = try container.decode(UsageCalculation.self, forKey: .calculation)
        readings = try container.decode([DiagnosticReading].self, forKey: .readings)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Dictionary(uniqueKeysWithValues: fields.map { ($0.key.rawValue, $0.value) }), forKey: .fields)
        try container.encode(calculation, forKey: .calculation)
        try container.encode(readings, forKey: .readings)
    }
    static func type(_ value: Any?) -> DiagnosticValueType {
        guard let value else { return .missing }
        if value is NSNull { return .null }
        if let number = value as? NSNumber { return CFGetTypeID(number) == CFBooleanGetTypeID() ? .boolean : .number }
        if value is String { return .string }
        if value is [String: Any] { return .object }
        if value is [Any] { return .array }
        return .other
    }
    static func make(provider: Provider, raw: Any, snapshot: UsageSnapshot?) -> Self {
        let object = raw as? [String: Any] ?? [:]
        var fields: [KnownUsageField: DiagnosticValueType] = [:]
        var calculation: UsageCalculation = .providerWindows
        switch provider {
        case .grok:
            let config = object["config"] as? [String: Any] ?? [:]
            let period = config["currentPeriod"] as? [String: Any] ?? [:]
            for field in [KnownUsageField.creditUsagePercent, .currentPeriod, .isUnifiedBillingUser, .monthlyLimit, .used, .onDemandCap, .onDemandUsed, .prepaidBalance] { fields[field] = type(config[field.rawValue]) }
            fields[.periodType] = type(period["type"]); fields[.periodStart] = type(period["start"]); fields[.periodEnd] = type(period["end"])
            if UsageParser.percent(config["creditUsagePercent"]) != nil { calculation = .reportedPercentage }
            else if config["creditUsagePercent"] == nil, config["isUnifiedBillingUser"] as? Bool == true,
                    ["USAGE_PERIOD_TYPE_WEEKLY", "USAGE_PERIOD_TYPE_MONTHLY"].contains(period["type"] as? String ?? "") { calculation = .protoZero }
            else if UsageParser.cent(config["monthlyLimit"]).map({ $0 > 0 }) == true, UsageParser.cent(config["used"]) != nil { calculation = .legacyIncludedBudget }
            else { calculation = .unavailable }
        case .codex:
            let limits = object["rate_limit"] as? [String: Any] ?? [:]
            fields[.rateLimit] = type(object["rate_limit"]); fields[.primaryWindow] = type(limits["primary_window"]); fields[.secondaryWindow] = type(limits["secondary_window"])
        case .gemini:
            fields[.quotaBuckets] = type(object["buckets"])
            let bucket = (object["buckets"] as? [[String: Any]])?.first ?? [:]
            fields[.remainingFraction] = type(bucket["remainingFraction"]); fields[.remainingAmount] = type(bucket["remainingAmount"]); fields[.quotaResetTime] = type(bucket["resetTime"])
        case .copilot:
            fields[.quotaSnapshots] = type(object["quota_snapshots"])
            fields[.quotaResetTime] = type(object["quota_reset_date_utc"])
        case .cline:
            fields[.creditBalance] = type((object["data"] as? [String: Any])?["balance"])
        case .cursor:
            let plan = object["planUsage"] as? [String: Any] ?? [:]
            fields[.planUsage] = type(object["planUsage"])
            fields[.billingCycleStart] = type(object["billingCycleStart"]); fields[.billingCycleEnd] = type(object["billingCycleEnd"])
            for field in [KnownUsageField.totalPercentUsed, .autoPercentUsed, .apiPercentUsed] { fields[field] = type(plan[field.rawValue]) }
        case .claude:
            fields[.fiveHour] = type(object["five_hour"]); fields[.sevenDay] = type(object["seven_day"])
        }
        let readings = (snapshot?.windows ?? []).map { window -> DiagnosticReading in
            guard let raw = window.usedPercent else { return .missing }
            guard raw.isFinite, raw >= 0 else { return .invalid }
            return raw == 0 ? .zeroUsed : raw >= 100 ? .fullUsed : .partialUsed
        }
        return Self(fields: fields, calculation: calculation, readings: readings)
    }
}
struct DebugBundle: Codable {
    var schemaVersion = 2
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
        var connection: String
        var needsLogin: Bool
        var readingAgeSeconds: Int?
        var windowCount: Int
        var configuredMetricCount: Int
        var missingUsageCount: Int
        var missingTimeCount: Int
    }
}
enum Diagnostics {
    struct Context: Sendable { var provider: Provider; var accountID: UUID }
    @TaskLocal static var context: Context?
    private static let lock = NSLock()
    private static let location = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Eyeballs/diagnostics.json")
    // Only typed fields are accepted. Never store URLs, HTTP bodies, error messages,
    // OAuth state, labels, email addresses or credentials. Local UUIDs are
    // retained for correlation and replaced with anonymous aliases in exports.
    static func record(_ stage: DiagnosticStage, provider: Provider? = nil, status: Int? = nil, failure: DiagnosticFailure? = nil, privateSession: Bool? = nil, endpoint: DiagnosticEndpoint? = nil, parsing: UsageParsingDiagnostic? = nil) {
        lock.lock(); defer { lock.unlock() }
        var events = load().filter { $0.date > Date.now.addingTimeInterval(-7 * 86400) }
        events.append(DiagnosticEvent(date: .now, provider: provider ?? context?.provider, stage: stage, status: status, endpoint: endpoint, failure: failure, privateSession: privateSession, parsing: parsing, connection: context?.accountID.uuidString))
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
        var aliases = Dictionary(uniqueKeysWithValues: accounts.enumerated().map { ($0.element.id.uuidString, "account-\($0.offset + 1)") })
        let recordedEvents = events()
        var unlistedCount = 0
        for event in recordedEvents {
            if let connection = event.connection, aliases[connection] == nil {
                unlistedCount += 1
                aliases[connection] = "connection-\(unlistedCount)"
            }
        }
        let safeEvents = recordedEvents.map { event in
            var copy = event
            copy.connection = event.connection.flatMap { aliases[$0] }
            return copy
        }
        return DebugBundle(createdAt: now, appVersion: version, systemVersion: UIDevice.current.systemVersion,
                    device: UIDevice.current.model, widgetCacheAvailable: WidgetCache.location != nil,
                    widgetAccountCount: WidgetCache.read().count,
                    accounts: accounts.map { account in
                        DebugBundle.AccountStatus(provider: account.provider, connection: aliases[account.id.uuidString]!, needsLogin: account.needsLogin,
                                                  readingAgeSeconds: account.snapshot.map { Int(max(0, min(315_360_000, now.timeIntervalSince($0.updatedAt)))) },
                                                  windowCount: account.snapshot?.windows.count ?? 0,
                                                  configuredMetricCount: account.displaySettings.rings.count,
                                                  missingUsageCount: account.snapshot?.windows.filter { $0.safePercent == nil }.count ?? 0,
                                                  missingTimeCount: account.readings(at: now).filter { $0.definition.kind == .time && $0.percent == nil }.count)
                    }, events: safeEvents)
    }
    static var version: String { "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))" }
    static func encode(_ bundle: DebugBundle) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }
    static func export(_ data: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EyeballsReports")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("requota-debug.json")
        try data.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return path
    }
}
