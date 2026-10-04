import Foundation
import SwiftUI

struct RemainingAllowance: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var remaining: Int?
    var available: Bool?
    var value: String { remaining.map { $0.formatted() + " left" } ?? available.map { $0 ? "Available" : "Unavailable" } ?? "—" }
    var summary: String { title + " · " + value }
}

struct RemainingAllowancesView: View {
    let allowances: [RemainingAllowance]
    var dense = false
    var body: some View {
        VStack(spacing: dense ? 4 : 12) {
            ForEach(allowances) { allowance in
                HStack { Text(allowance.title).foregroundStyle(.secondary); Spacer(minLength: 12); Text(allowance.value).monospacedDigit() }
            }
        }.font(dense ? .caption : .subheadline)
    }
}

extension AgentAccount {
    var primaryAllowance: RemainingAllowance? { snapshot?.remainingAllowances?.first { $0.id == "pro_search" } ?? snapshot?.remainingAllowances?.first }
    var allowanceSummary: String? { primaryAllowance?.summary }
}
