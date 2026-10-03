import Foundation

extension UsageParser {
    static func amp(_ raw: Any, profile: Any, subject: String) throws -> UsageSnapshot {
        let verified: (subject: String, email: String?)
        do { verified = try AmpAuth.identity(profile) } catch { throw UsageError.invalidResponse }
        guard verified.subject == subject else { throw UsageError.wrongAccount }
        let result = try AmpAuth.unwrap(raw)
        guard let text = result["displayText"] as? String, text.count < 20_000 else { throw UsageError.invalidResponse }
        // Amp's native CLI RPC supplies displayText, not numeric balance JSON.
        // Read only its explicit, anchored credit amount. Unknown formats fail
        // visibly and retain the last reading; no HTML or browser data is used.
        let lines = text.components(separatedBy: .newlines)
        if let email = verified.email {
            guard lines.contains(where: { $0.lowercased() == "signed in as " + email.lowercased() }) else { throw UsageError.wrongAccount }
        }
        let pattern = "^Individual credits: \\$((?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\\.[0-9]+)?) remaining(?: - https://ampcode\\.com/settings)?$"
        let regex = try NSRegularExpression(pattern: pattern)
        let readings = lines.compactMap { line -> Double? in
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let range = Range(match.range(at: 1), in: line), let amount = Double(line[range].replacingOccurrences(of: ",", with: "")), amount.isFinite else { return nil }
            return amount
        }
        guard readings.count == 1, let balance = readings.first else { throw UsageError.invalidResponse }
        return UsageSnapshot(creditBalance: balance.formatted(.currency(code: "USD")), details: ProviderDetails(spending: [SpendingDetails(id: "amp-personal-credits", title: "Personal credits", balance: balance, currency: "USD")]))
    }
}
