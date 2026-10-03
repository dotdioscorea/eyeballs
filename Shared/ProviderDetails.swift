import Foundation

// Provider-reported facts. A balance, availability flag or usage share does not
// establish active credit charging, a token count or an allowance percentage.
struct ProviderDetails: Codable, Equatable, Sendable {
    var credits: CreditDetails?
    var spending: [SpendingDetails] = []
    var breakdowns: [UsageBreakdown] = []
    var models: [ModelAccess] = []
    var isEmpty: Bool { credits == nil && spending.isEmpty && breakdowns.isEmpty && models.isEmpty }
}

struct CreditDetails: Codable, Equatable, Sendable {
    var available: Bool?
    var unlimited: Bool?
    var overageLimitReached: Bool?
    var spendLimitReached: Bool?
    var localMessages: MessageEstimate?
    var cloudMessages: MessageEstimate?
}

struct MessageEstimate: Codable, Equatable, Sendable {
    var lower: Int
    var upper: Int
    var text: String { lower == upper ? lower.formatted() : lower.formatted() + "–" + upper.formatted() }
}

struct SpendingDetails: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var used: Double?
    var limit: Double?
    var balance: Double?
    var currency: String?
    var unit: String?
    var enabled: Bool?
    var stoppedReason: String?
    var resetsAt: Date?
    func amount(_ value: Double) -> String {
        if let currency { return value.formatted(.currency(code: currency)) }
        return value.formatted(.number.precision(.fractionLength(0...4))) + (unit.map { " " + $0 } ?? "")
    }
}

struct UsageBreakdown: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var asOf: Date?
    var startedAt: Date?
    var rows: [Row]
    struct Row: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var title: String
        var percent: Double
    }
}

struct ModelAccess: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var available: Bool?
    var creditsWouldEnable: Bool?
    var availableAt: Date?
    var status: String {
        if available == true { return "Available" }
        if creditsWouldEnable == true { return "Needs credits" }
        return available == false ? "Unavailable" : "Unknown"
    }
}
