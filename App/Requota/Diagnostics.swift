import Foundation
import CoreFoundation
import UIKit

enum DiagnosticStage: String, Codable { case signInStarted, identityVerified, usageVerified, signInFailed, refreshSucceeded, refreshFailed, refreshCycle, http, usageParsed, resetCompared, activationAttempted, activationCompleted, activationFailed }
enum DiagnosticFailure: String, Codable {
    case cancelled, timeout, callback, identity, signedOut, permission, throttled, response, accountMismatch, network, other
    static func category(_ error: Error) -> Self {
        if let error = error as? ActivationPreparationFailure { return category(error.cause) }
        if let error = error as? ActivationError {
            switch error { case .permissionRequired: return .permission; case .incomplete, .allowanceUnknown: return .response; default: return .other }
        }
        if let error = error as? AuthError {
            switch error { case .cancelled: return .cancelled; case .timedOut: return .timeout; case .invalidCallback: return .callback; case .invalidIdentity: return .identity; case .unavailable: return .network }
        }
        if let error = error as? UsageError {
            switch error { case .signedOut: return .signedOut; case .usageAccessDenied: return .permission; case .throttled: return .throttled; case .invalidResponse: return .response; case .wrongAccount: return .accountMismatch; default: return .other }
        }
        if error is CancellationError { return .cancelled }
        if let error = error as? PerplexityAuth.LoginError { return error == .code ? .callback : .identity }
        if error is URLError { return .network }
        return .other
    }
}
enum DiagnosticEndpoint: String, Codable { case token, identity, usage, bankedResets, identityKeys, deviceAuthorization, activation, models, other
    static func identify(_ url: URL?) -> Self {
        guard let url else { return .other }
        if url.host == "ampcode.com", url.path == "/api/internal" {
            return url.query == "getUserInfo" ? .identity : url.query == "userDisplayBalanceInfo" ? .usage : .other
        }
        switch url.path {
        case "/exa.seat_management_pb.SeatManagementService/ExchangeDevinCLIPKCECode", "/api/auth/csrf", "/api/auth/signin/email", "/api/auth/callback/email", "/api/auth/session", "/api/oauth/token", "/api/v1/auth/register", "/api/v1/auth/refresh", "/token", "/oauth/token", "/api/accounts/oauth/token", "/v1/oauth/token", "/oauth2/token", "/login/oauth/access_token": return .token
        case "/api/oauth/device_authorization", "/user_management/authorize/device", "/user_management/authenticate", "/auth/poll", "/login/device/code": return .deviceAuthorization
        case "/api/user", "/coding/v1/me", "/api/v1/users/me", "/aiserver.v1.DashboardService/GetMe", "/api/oauth/profile", "/oauth2/v2/userinfo", "/user": return .identity
        case "/exa.seat_management_pb.SeatManagementService/GetUserStatus", "/rest/rate-limit/status", "/coding/v1/usages", "/aiserver.v1.DashboardService/GetCurrentPeriodUsage", "/aiserver.v1.DashboardService/GetPlanInfo", "/v1internal:loadCodeAssist", "/v1internal:retrieveUserQuota", "/backend-api/wham/usage", "/api/oauth/usage", "/v1/billing", "/copilot_internal/user": return .usage
        case "/backend-api/wham/rate-limit-reset-credits": return .bankedResets
        case "/backend-api/codex/responses", "/v1/messages": return .activation
        case "/backend-api/codex/models", "/v1/models": return .models
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
    var refresh: RefreshCycleDiagnostic?
    // Local only; replaced with a bundle-local alias during export.
    var connection: String?
    var resets: ResetComparisonDiagnostic?
}
struct ResetComparisonDiagnostic: Codable {
    var previousAvailable: Int?
    var currentAvailable: Int?
    var previousGrantRemaining: Int?
    var currentGrantRemaining: Int?
    var previousWeeklyUsed: Double?
    var currentWeeklyUsed: Double?
    var events: [AccountEvent.Kind]
    static func make(previous: UsageSnapshot?, current: UsageSnapshot, events: [AccountEvent]) -> Self {
        Self(previousAvailable: previous?.bankedResets.map { $0.reduce(0) { $0 + $1.count } },
             currentAvailable: current.bankedResets.map { $0.reduce(0) { $0 + $1.count } },
             previousGrantRemaining: previous?.resetInventory.map { $0.grants.reduce(0) { $0 + $1.remaining } },
             currentGrantRemaining: current.resetInventory.map { $0.grants.reduce(0) { $0 + $1.remaining } },
             previousWeeklyUsed: previous?.windows.first(where: EventDetection.weekly)?.safePercent,
             currentWeeklyUsed: current.windows.first(where: EventDetection.weekly)?.safePercent, events: events.map(\.kind))
    }
}
enum DiagnosticValueType: String, Codable { case missing, null, number, string, boolean, object, array, other }
enum UsageCalculation: String, Codable { case reportedPercentage, protoZero, legacyIncludedBudget, onDemandBudget, unavailable, providerWindows }
enum DiagnosticReading: String, Codable { case missing, zeroUsed, partialUsed, fullUsed, invalid }
struct UsageParsingDiagnostic: Codable {
    // Names are selected by code, never copied from arbitrary response keys.
    var fields: [KnownUsageField: DiagnosticValueType]
    var calculation: UsageCalculation
    var readings: [DiagnosticReading]
    var resetResponse: ResetResponse?
    enum ResetResponse: String, Codable { case missing, null, parsed, surface, clientVersion, ineligible, invalid }
    enum KnownUsageField: String, Codable, CaseIterable {
        case creditUsagePercent, currentPeriod, periodType, periodStart, periodEnd, isUnifiedBillingUser
        case monthlyLimit, used, onDemandCap, onDemandUsed, prepaidBalance
        case creditBalance, rateLimit, primaryWindow, secondaryWindow, fiveHour, sevenDay, quotaBuckets, quotaSnapshots, remainingFraction, remainingAmount, quotaResetTime, planUsage, totalPercentUsed, autoPercentUsed, apiPercentUsed, billingCycleStart, billingCycleEnd
        case perplexityModes, remainingDetail, remainingKind, remainingCount, proSearchAvailable
        case kimiUsages, kimiWallet, kimiLegacyUsage
        case ampUsageText
        case devinUserStatus, devinPlanStatus, dailyQuotaRemainingPercent, weeklyQuotaRemainingPercent, dailyQuotaResetAtUnix, weeklyQuotaResetAtUnix, overageBalanceMicros, acuConsumed, acuLimit, devinModels
        case credits, spend, modelUsage, additionalRateLimits, extraUsage, scopedLimits, weeklyBreakdown, resetProgram, resetGrants, resetEligibility
    }
    enum CodingKeys: String, CodingKey { case fields, calculation, readings, resetResponse }
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
        resetResponse = try container.decodeIfPresent(ResetResponse.self, forKey: .resetResponse)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Dictionary(uniqueKeysWithValues: fields.map { ($0.key.rawValue, $0.value) }), forKey: .fields)
        try container.encode(calculation, forKey: .calculation)
        try container.encode(readings, forKey: .readings)
        try container.encodeIfPresent(resetResponse, forKey: .resetResponse)
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
            fields[.credits] = type(object["credits"]); fields[.spend] = type(object["spend_control"])
            fields[.modelUsage] = type(object["model_usage"]); fields[.additionalRateLimits] = type(object["additional_rate_limits"])
        case .gemini:
            fields[.quotaBuckets] = type(object["buckets"])
            let bucket = (object["buckets"] as? [[String: Any]])?.first ?? [:]
            fields[.remainingFraction] = type(bucket["remainingFraction"]); fields[.remainingAmount] = type(bucket["remainingAmount"]); fields[.quotaResetTime] = type(bucket["resetTime"])
        case .copilot:
            fields[.quotaSnapshots] = type(object["quota_snapshots"])
            fields[.quotaResetTime] = type(object["quota_reset_date_utc"])
        case .amp:
            fields[.ampUsageText] = type((object["result"] as? [String: Any])?["displayText"])
        case .devin:
            let user = object["userStatus"] as? [String: Any] ?? [:]
            let plan = user["planStatus"] as? [String: Any] ?? [:]
            fields[.devinUserStatus] = type(object["userStatus"]); fields[.devinPlanStatus] = type(user["planStatus"])
            for field in [KnownUsageField.dailyQuotaRemainingPercent, .weeklyQuotaRemainingPercent, .dailyQuotaResetAtUnix, .weeklyQuotaResetAtUnix, .overageBalanceMicros, .acuConsumed, .acuLimit] { fields[field] = type(plan[field.rawValue]) }
            fields[.devinModels] = type((user["cascadeModelConfigData"] as? [String: Any])?["clientModelConfigs"])
        case .perplexity:
            fields[.perplexityModes] = type(object["modes"])
            let pro = (object["modes"] as? [String: Any])?["pro_search"] as? [String: Any] ?? [:]
            let detail = pro["remaining_detail"] as? [String: Any] ?? [:]
            fields[.remainingDetail] = type(pro["remaining_detail"])
            fields[.remainingKind] = type(detail["kind"])
            fields[.remainingCount] = type(detail["remaining"])
            fields[.proSearchAvailable] = type(pro["available"])
        case .kimi:
            fields[.kimiUsages] = type(object["usages"]); fields[.kimiWallet] = type(object["boosterWallet"]); fields[.kimiLegacyUsage] = type(object["usage"])
        case .cline:
            fields[.creditBalance] = type((object["data"] as? [String: Any])?["balance"])
        case .cursor:
            let plan = object["planUsage"] as? [String: Any] ?? [:]
            fields[.planUsage] = type(object["planUsage"])
            fields[.billingCycleStart] = type(object["billingCycleStart"]); fields[.billingCycleEnd] = type(object["billingCycleEnd"])
            for field in [KnownUsageField.totalPercentUsed, .autoPercentUsed, .apiPercentUsed] { fields[field] = type(plan[field.rawValue]) }
        case .claude:
            fields[.fiveHour] = type(object["five_hour"]); fields[.sevenDay] = type(object["seven_day"])
            fields[.extraUsage] = type(object["extra_usage"]); fields[.spend] = type(object["spend"])
            fields[.scopedLimits] = type(object["limits"]); fields[.weeklyBreakdown] = type(object["seven_day_breakdown"])
            fields[.resetProgram] = type(object["cedar_ember"])
            let program = object["cedar_ember"] as? [String: Any] ?? [:]
            fields[.resetGrants] = type(program["grants"]); fields[.resetEligibility] = type(program["eligible"])
        }
        let readings = (snapshot?.windows ?? []).map { window -> DiagnosticReading in
            guard let raw = window.usedPercent else { return .missing }
            guard raw.isFinite, raw >= 0 else { return .invalid }
            return raw == 0 ? .zeroUsed : raw >= 100 ? .fullUsed : .partialUsed
        }
        var diagnostic = Self(fields: fields, calculation: calculation, readings: readings)
        if provider == .claude {
            let program = object["cedar_ember"] as? [String: Any] ?? [:]
            if object["cedar_ember"] == nil { diagnostic.resetResponse = .missing }
            else if object["cedar_ember"] is NSNull { diagnostic.resetResponse = .null }
            else if snapshot?.resetInventory != nil { diagnostic.resetResponse = .parsed }
            else if program["ineligible_reason"] as? String == "surface" { diagnostic.resetResponse = .surface }
            else if program["ineligible_reason"] as? String == "cli_version" { diagnostic.resetResponse = .clientVersion }
            else if program["eligible"] as? Bool == false { diagnostic.resetResponse = .ineligible }
            else { diagnostic.resetResponse = .invalid }
        }
        return diagnostic
    }
}
struct DebugBundle: Codable {
    var schemaVersion = 5
    var createdAt: Date
    var appVersion: String
    var systemVersion: String
    var device: String
    var widgetCacheAvailable: Bool
    var widgetAccountCount: Int
    var notificationRules: ResetNotificationRules
    var notificationProviderRules: [String: ResetNotificationRules]
    var notifications: NotificationDeliveryStatus
    var refresh: RefreshStatus
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
        var bankedResetCount: Int?
        var resetInventoryAgeSeconds: Int?
        var activationStatus: ActivationRecord.Status?
        var activationAgeSeconds: Int?
        var activationCandidate: Bool?
        var activationClockReported: Bool?
        var activationDeadlineInMinutes: Int?
        var activationClockObservationAgeMinutes: Int?
    }
    struct RefreshStatus: Codable {
        var backgroundRefresh: String
        var lowPowerMode: Bool
        var foregroundIntervalMinutes: Int
        var appScheduling: RefreshSchedulingStatus?
        var widgetScheduling: RefreshSchedulingStatus?
        var lastForegroundCycle: RefreshCycleDiagnostic?
        var lastBackgroundCycle: RefreshCycleDiagnostic?
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
    static func record(_ stage: DiagnosticStage, provider: Provider? = nil, status: Int? = nil, failure: DiagnosticFailure? = nil, privateSession: Bool? = nil, endpoint: DiagnosticEndpoint? = nil, parsing: UsageParsingDiagnostic? = nil, refresh: RefreshCycleDiagnostic? = nil, resets: ResetComparisonDiagnostic? = nil) {
        lock.lock(); defer { lock.unlock() }
        var events = load().filter { $0.date > Date.now.addingTimeInterval(-7 * 86400) }
        events.append(DiagnosticEvent(date: .now, provider: provider ?? context?.provider, stage: stage, status: status, endpoint: endpoint, failure: failure, privateSession: privateSession, parsing: parsing, refresh: refresh, connection: context?.accountID.uuidString, resets: resets))
        events = Array(events.suffix(100))
        do {
            try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(events).write(to: location, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { }
        if let refresh, let data = try? JSONEncoder().encode(refresh) {
            UserDefaults.standard.set(data, forKey: refresh.trigger == .foreground ? "last-foreground-refresh-cycle" : "last-background-refresh-cycle")
        }
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
    static func clear() {
        lock.lock(); defer { lock.unlock() }; try? FileManager.default.removeItem(at: location)
        for key in ["last-foreground-refresh-cycle", "last-background-refresh-cycle"] { UserDefaults.standard.removeObject(forKey: key) }
        for key in ["refresh-scheduling-app", "refresh-scheduling-widget"] { UserDefaults(suiteName: WidgetCache.group)?.removeObject(forKey: key) }
    }
    private static func lastCycle(background: Bool) -> RefreshCycleDiagnostic? {
        UserDefaults.standard.data(forKey: background ? "last-background-refresh-cycle" : "last-foreground-refresh-cycle")
            .flatMap { try? JSONDecoder().decode(RefreshCycleDiagnostic.self, from: $0) }
            .flatMap { $0.finishedAt > Date.now.addingTimeInterval(-7 * 86400) ? $0 : nil }
    }
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
                    notificationRules: UserDefaults.standard.data(forKey: "notification-rules").flatMap { try? JSONDecoder().decode(ResetNotificationRules.self, from: $0) } ?? ResetNotificationRules(),
                    notificationProviderRules: UserDefaults.standard.data(forKey: "notification-provider-rules").flatMap { try? JSONDecoder().decode([String: ResetNotificationRules].self, from: $0) } ?? [:], notifications: .saved,
                    refresh: DebugBundle.RefreshStatus(backgroundRefresh: RefreshSettings.backgroundStatus, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                                       foregroundIntervalMinutes: RefreshSettings.foregroundMinutes,
                                                       appScheduling: RefreshSchedulingDiagnostics.read(widget: false), widgetScheduling: RefreshSchedulingDiagnostics.read(widget: true),
                                                       lastForegroundCycle: lastCycle(background: false), lastBackgroundCycle: lastCycle(background: true)),
                    accounts: accounts.map { account in
                        DebugBundle.AccountStatus(provider: account.provider, connection: aliases[account.id.uuidString]!, needsLogin: account.needsLogin,
                                                  readingAgeSeconds: account.snapshot.map { Int(max(0, min(315_360_000, now.timeIntervalSince($0.updatedAt)))) },
                                                  windowCount: account.snapshot?.windows.count ?? 0,
                                                  configuredMetricCount: account.displaySettings.rings.count,
                                                  missingUsageCount: account.snapshot?.windows.filter { $0.safePercent == nil }.count ?? 0,
                                                  missingTimeCount: account.readings(at: now).filter { $0.definition.kind == .time && $0.percent == nil }.count,
                                                  bankedResetCount: account.snapshot?.bankedResets.map { $0.reduce(0) { $0 + $1.count } },
                                                  resetInventoryAgeSeconds: account.snapshot?.resetInventory.map { Int(max(0, min(315_360_000, now.timeIntervalSince($0.checkedAt)))) },
                                                  activationStatus: account.activation?.status,
                                                  activationAgeSeconds: account.activation.map { Int(max(0, min(315_360_000, now.timeIntervalSince($0.attemptedAt)))) },
                                                  activationCandidate: AllowanceActivation.supported(account.provider) ? account.snapshot.map { AllowanceActivation.candidate($0, provider: account.provider, now: now) } : nil,
                                                  activationClockReported: account.snapshot.flatMap { AllowanceActivation.weekly($0, provider: account.provider)?.clockReported },
                                                  activationDeadlineInMinutes: account.snapshot.flatMap { AllowanceActivation.weekly($0, provider: account.provider)?.resetsAt }.flatMap { minutes($0.timeIntervalSince(now)) },
                                                  activationClockObservationAgeMinutes: account.activation?.resetObservedAt.flatMap { minutes(now.timeIntervalSince($0)) })
                    }, events: safeEvents)
    }
    static var version: String { "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))" }
    private static func minutes(_ seconds: TimeInterval) -> Int? {
        guard seconds.isFinite else { return nil }
        return Int(max(-5_256_000, min(5_256_000, seconds / 60)))
    }
    static func encode(_ bundle: DebugBundle) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }
    static func export(_ data: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RequotaReports")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("requota-debug.json")
        try data.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return path
    }
}
