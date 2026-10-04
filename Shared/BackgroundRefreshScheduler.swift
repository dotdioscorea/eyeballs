import Foundation
import BackgroundTasks

enum RefreshTrigger: String, Codable { case foreground, backgroundRefresh, backgroundProcessing, widget }
enum RefreshSchedulingFailure: String, Codable { case unavailable, notPermitted, tooManyPending, other }

struct RefreshSchedulingStatus: Codable, Equatable {
    var attemptedAt: Date
    var refreshScheduled: Bool
    var processingScheduled: Bool
    var failure: RefreshSchedulingFailure?
}

enum RefreshSchedulingDiagnostics {
    static func record(_ status: RefreshSchedulingStatus, source: RefreshTrigger) {
        if let data = try? JSONEncoder().encode(status) {
            UserDefaults(suiteName: WidgetCache.group)?.set(data, forKey: "refresh-scheduling-\(source == .widget ? "widget" : "app")")
        }
    }
    static func read(widget: Bool) -> RefreshSchedulingStatus? {
        UserDefaults(suiteName: WidgetCache.group)?.data(forKey: "refresh-scheduling-\(widget ? "widget" : "app")")
            .flatMap { try? JSONDecoder().decode(RefreshSchedulingStatus.self, from: $0) }
    }
}

struct PendingRefreshRequest: Equatable {
    var identifier: String
    var earliestBeginDate: Date?
}

actor BackgroundRefreshScheduler {
    static let refreshID = "com.dotdioscorea.eyeballs.refresh"
    static let processingID = "com.dotdioscorea.eyeballs.processing"
    static let shared = BackgroundRefreshScheduler()
    private let pending: () async -> [PendingRefreshRequest]
    private let submit: (String, Date) throws -> Void
    private let record: (RefreshSchedulingStatus, RefreshTrigger) -> Void
    private var scheduling: Task<RefreshSchedulingStatus, Never>?

    init(pending: @escaping () async -> [PendingRefreshRequest] = {
        await withCheckedContinuation { continuation in
            BGTaskScheduler.shared.getPendingTaskRequests { requests in
                continuation.resume(returning: requests.map { PendingRefreshRequest(identifier: $0.identifier, earliestBeginDate: $0.earliestBeginDate) })
            }
        }
    }, submit: @escaping (String, Date) throws -> Void = { identifier, date in
        let request: BGTaskRequest
        if identifier == processingID {
            let processing = BGProcessingTaskRequest(identifier: identifier)
            processing.requiresNetworkConnectivity = true
            processing.requiresExternalPower = false
            request = processing
        } else { request = BGAppRefreshTaskRequest(identifier: identifier) }
        request.earliestBeginDate = date
        try BGTaskScheduler.shared.submit(request)
    }, record: @escaping (RefreshSchedulingStatus, RefreshTrigger) -> Void = { RefreshSchedulingDiagnostics.record($0, source: $1) }) {
        self.pending = pending; self.submit = submit; self.record = record
    }

    // Preserve an earlier request: submitting the same identifier replaces it.
    // These dates express eligibility, never a guaranteed polling interval.
    @discardableResult
    func ensureScheduled(source: RefreshTrigger, now: Date = .now, staleWidget: Bool = false) async -> RefreshSchedulingStatus {
        if let scheduling { return await scheduling.value }
        let pending = self.pending, submit = self.submit
        let operation = Task {
            let requests = await pending()
            var status = RefreshSchedulingStatus(attemptedAt: now, refreshScheduled: false, processingScheduled: false)
            for (identifier, delay) in [(Self.refreshID, staleWidget ? 0.0 : 15 * 60.0), (Self.processingID, 30 * 60.0)] {
                let proposed = now.addingTimeInterval(delay)
                do {
                    if !requests.contains(where: { $0.identifier == identifier && ($0.earliestBeginDate ?? .distantPast) <= proposed }) {
                        try submit(identifier, proposed)
                    }
                    if identifier == Self.refreshID { status.refreshScheduled = true } else { status.processingScheduled = true }
                } catch {
                    let error = error as NSError
                    if error.domain == BGTaskScheduler.errorDomain {
                        switch BGTaskScheduler.Error.Code(rawValue: error.code) {
                        case .unavailable: status.failure = .unavailable
                        case .notPermitted: status.failure = .notPermitted
                        case .tooManyPendingTaskRequests: status.failure = .tooManyPending
                        default: status.failure = .other
                        }
                    } else { status.failure = .other }
                }
            }
            return status
        }
        scheduling = operation
        let status = await operation.value
        scheduling = nil
        record(status, source)
        return status
    }

    static func requestFromWidget(accounts: [AgentAccount], now: Date = .now) async {
        guard !WidgetCache.demoActive, accounts.contains(where: { !$0.needsLogin }) else { return }
        let stale = accounts.contains { !$0.needsLogin && ($0.snapshot.map { now.timeIntervalSince($0.updatedAt) >= 15 * 60 || $0.windows.contains { $0.resetDue(at: now) } } ?? true) }
        await shared.ensureScheduled(source: .widget, now: now, staleWidget: stale)
    }
}
