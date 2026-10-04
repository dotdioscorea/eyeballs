import XCTest
import BackgroundTasks
@testable import Requota

final class RefreshSchedulingTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_791_100_000)
    func testEarlierPendingRequestsArePreservedAcrossRepeatedAppOpenings() async {
        let host = SchedulingHost()
        host.requests = [.init(identifier: BackgroundRefreshScheduler.refreshID, earliestBeginDate: now.addingTimeInterval(120)), .init(identifier: BackgroundRefreshScheduler.processingID, earliestBeginDate: nil)]
        let scheduler = host.scheduler()
        let first = await scheduler.ensureScheduled(source: .foreground, now: now)
        let second = await scheduler.ensureScheduled(source: .foreground, now: now.addingTimeInterval(60))
        XCTAssertTrue(first.refreshScheduled && first.processingScheduled && second.refreshScheduled)
        XCTAssertTrue(host.submissions.isEmpty)
    }
    func testStaleWidgetMovesLaterRefreshForwardWithoutPostponingProcessing() async {
        let host = SchedulingHost()
        host.requests = [.init(identifier: BackgroundRefreshScheduler.refreshID, earliestBeginDate: now.addingTimeInterval(900)), .init(identifier: BackgroundRefreshScheduler.processingID, earliestBeginDate: now.addingTimeInterval(120))]
        await host.scheduler().ensureScheduled(source: .widget, now: now, staleWidget: true)
        XCTAssertEqual(host.submissions, [.init(identifier: BackgroundRefreshScheduler.refreshID, earliestBeginDate: now)])
    }
    func testConcurrentWidgetAndAppRequestsCoalesce() async {
        let host = SchedulingHost(); host.delay = true
        let scheduler = host.scheduler()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { await scheduler.ensureScheduled(source: .foreground, now: self.now) } }
        }
        XCTAssertEqual(host.submissions.count, 2)
        XCTAssertEqual(host.submissions.map(\.identifier), [BackgroundRefreshScheduler.refreshID, BackgroundRefreshScheduler.processingID])
    }
    func testInterruptedRefreshStillQueuesItsSuccessorAndSchedulingFailuresCanRetry() async {
        let host = SchedulingHost(); host.delay = true
        let scheduler = host.scheduler()
        let task = Task { await scheduler.ensureScheduled(source: .backgroundRefresh, now: now) }
        task.cancel()
        let scheduled = await task.value
        XCTAssertTrue(scheduled.refreshScheduled && scheduled.processingScheduled)
        let denied = SchedulingHost(); denied.failure = NSError(domain: BGTaskScheduler.errorDomain, code: BGTaskScheduler.Error.Code.notPermitted.rawValue)
        let retryScheduler = denied.scheduler()
        let failed = await retryScheduler.ensureScheduled(source: .foreground, now: now)
        XCTAssertEqual(failed.failure, .notPermitted); XCTAssertFalse(failed.refreshScheduled || failed.processingScheduled)
        denied.failure = nil
        let retried = await retryScheduler.ensureScheduled(source: .foreground, now: now)
        XCTAssertNil(retried.failure); XCTAssertTrue(retried.refreshScheduled && retried.processingScheduled)
    }
}

private final class SchedulingHost {
    var requests: [PendingRefreshRequest] = []
    var submissions: [PendingRefreshRequest] = []
    var delay = false
    var failure: Error?
    func scheduler() -> BackgroundRefreshScheduler {
        BackgroundRefreshScheduler(pending: { [self] in
            if delay { try? await Task.sleep(for: .milliseconds(40)) }
            return requests
        }, submit: { [self] identifier, date in
            if let failure { throw failure }
            let request = PendingRefreshRequest(identifier: identifier, earliestBeginDate: date)
            submissions.append(request); requests.removeAll { $0.identifier == identifier }; requests.append(request)
        }, record: { _, _ in })
    }
}
