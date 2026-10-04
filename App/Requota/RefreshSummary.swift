import Foundation

enum RefreshOutcome { case updated, failed, skipped, cancelled }
struct RefreshSummary: Codable, Equatable {
    var updated = 0
    var failed = 0
    var skipped = 0
    var cancelled = false
    var metadataUnavailable = false
    var succeeded: Bool { !cancelled && !metadataUnavailable && (updated > 0 || failed == 0) }
    mutating func include(_ outcome: RefreshOutcome) {
        switch outcome {
        case .updated: updated += 1
        case .failed: failed += 1
        case .skipped: skipped += 1
        case .cancelled: cancelled = true
        }
    }
}

struct RefreshCycleDiagnostic: Codable {
    var trigger: RefreshTrigger
    var startedAt: Date
    var finishedAt: Date
    var summary: RefreshSummary
}
