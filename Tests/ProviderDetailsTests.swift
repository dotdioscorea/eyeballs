import XCTest
@testable import Requota

final class ProviderDetailsTests: XCTestCase {
    func testStructuredClaudeLimitsFillMissingLegacyReadingsWithoutDuplicateRings() throws {
        let snapshot = try UsageParser.claude(["seven_day": ["utilization": NSNull()], "limits": [["kind": "weekly_all", "group": "weekly", "percent": 40, "resets_at": "2026-10-04T12:00:00Z"]]])
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 40)
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
        let badScale = try UsageParser.claude(["seven_day": [:], "extra_usage": ["used_credits": 150, "monthly_limit": 2000, "currency": "GBP", "decimal_places": 20]])
        XCTAssertNil(badScale.details?.spending.first?.used)
        XCTAssertNil(badScale.details?.spending.first?.limit)
        XCTAssertFalse(badScale.windows.contains { $0.id == "claude-spend" })
    }
    func testCodexCreditsAndModelAccessDoNotInventUsage() throws {
        let raw: [String: Any] = ["rate_limit": [:], "credits": ["balance": "0.00000123", "has_credits": true, "unlimited": false, "overage_limit_reached": true, "approx_local_messages": [2, 8], "approx_cloud_messages": [1, 3]], "spend_control": ["reached": true], "model_usage": ["gpt-example": ["available": false, "credits_would_enable": true]]]
        let snapshot = try UsageParser.codex(raw)
        XCTAssertEqual(snapshot.creditBalance, "0.00000123")
        XCTAssertTrue(snapshot.windows.isEmpty)
        let details = try XCTUnwrap(snapshot.details)
        XCTAssertEqual(details.credits?.localMessages?.text, "2–8")
        XCTAssertEqual(details.credits?.overageLimitReached, true)
        XCTAssertEqual(details.credits?.spendLimitReached, true)
        XCTAssertEqual(details.models.first?.status, "Needs credits")
        XCTAssertNil(UsageParser.messageEstimate([true, 3])); XCTAssertNil(UsageParser.messageEstimate([5, 1]))
        XCTAssertNil(UsageParser.messageEstimate([1.3, 2])); XCTAssertNil(UsageParser.messageEstimate([1, "NaN"]))
    }
    func testClaudeCurrencyExponentAndScopedLimitsFromModernSchema() throws {
        let raw: [String: Any] = ["limits": [
            ["kind": "session", "group": "session", "percent": 25, "resets_at": "2026-10-03T12:00:00Z"],
            ["kind": "weekly_scoped", "group": "weekly", "percent": 9, "scope": ["model": ["display_name": "Fast mode", "id": "fast"]]]
        ], "spend": ["used": ["amount_minor": 125, "currency": "GBP", "exponent": 2], "limit": ["amount_minor": 1000, "currency": "GBP", "exponent": 2], "balance": ["amount_minor": 2500, "currency": "GBP", "exponent": 2], "enabled": true, "percent": 12.5]]
        let snapshot = try UsageParser.claude(raw)
        let spend = try XCTUnwrap(snapshot.details?.spending.first)
        XCTAssertEqual(spend.used, 1.25); XCTAssertEqual(spend.limit, 10); XCTAssertEqual(spend.balance, 25)
        XCTAssertEqual(spend.currency, "GBP")
        XCTAssertEqual(snapshot.windows.first?.id, "five_hour")
        XCTAssertEqual(snapshot.windows[1].title, "Fast mode weekly")
        let amount = try XCTUnwrap(snapshot.windows.first { $0.id == "claude-spend" })
        XCTAssertEqual(amount.usedAmount, 1.25); XCTAssertEqual(amount.amountUnit, "GBP")
        XCTAssertNil(amount.duration); XCTAssertNil(amount.resetsAt)
    }
    func testModernClaudeSpendTakesPrecedenceAndWeeklySharesRemainShares() throws {
        let raw: [String: Any] = ["five_hour": ["utilization": 30], "extra_usage": ["used_credits": 900, "monthly_limit": 1000, "currency": "USD", "is_enabled": true], "spend": ["used": ["amount_minor": 150, "currency": "GBP", "exponent": 2], "limit": ["amount_minor": 2000, "currency": "GBP", "exponent": 2], "enabled": false, "disabled_reason": "out_of_credits"], "seven_day_breakdown": ["rows": [["key": "code", "display_name": "Claude Code", "percent": 70], ["key": "chat", "display_name": "Chats", "percent": 30]]]]
        let snapshot = try UsageParser.claude(raw)
        XCTAssertEqual(snapshot.details?.spending.count, 1)
        XCTAssertEqual(snapshot.details?.spending.first?.used, 1.5)
        XCTAssertEqual(snapshot.details?.spending.first?.stoppedReason, "Credit balance exhausted")
        XCTAssertEqual(snapshot.details?.breakdowns.first?.rows.map(\.percent), [70, 30])
        XCTAssertFalse(snapshot.windows.contains { $0.title == "Claude Code" })
    }
    func testLegacyClaudeExtraSpendDoesNotAssumeDollarsOrResetDates() throws {
        let snapshot = try UsageParser.claude(["seven_day": [:], "extra_usage": ["used_credits": 1.25, "monthly_limit": 20, "utilization": 6.25, "is_enabled": true]])
        XCTAssertEqual(snapshot.details?.spending.first?.used, 1.25)
        XCTAssertNil(snapshot.details?.spending.first?.currency)
        XCTAssertEqual(snapshot.windows.last?.amountUnit, "credits")
        XCTAssertNil(snapshot.windows.last?.resetsAt)
        XCTAssertNil(UsageParser.Money.read(["amount_minor": true, "currency": "USD", "exponent": 2]))
        XCTAssertNil(UsageParser.Money.read(["amount_minor": 1, "currency": "USD", "exponent": 7]))
        XCTAssertNil(UsageParser.Money.read(["amount_minor": 1, "currency": "unknown", "exponent": 2]))
    }
    func testScopedModelIdsDoNotChangeWhenProviderReordersLimits() throws {
        let limits: [[String: Any]] = ["Opus", "Sonnet", "Example"].map { ["kind": "weekly_scoped", "group": "weekly", "percent": 7, "scope": ["model": ["display_name": $0]]] }
        let first = try UsageParser.claude(["limits": limits])
        let second = try UsageParser.claude(["limits": Array(limits.reversed())])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: first.windows.map { ($0.title, $0.id) }), Dictionary(uniqueKeysWithValues: second.windows.map { ($0.title, $0.id) }))
        XCTAssertEqual(first.windows.first?.id, "seven_day_opus")
    }
    func testCodexAdditionalLimitsKeepFeatureIdentityAndBothPeriods() throws {
        let entry: (String) -> [String: Any] = { ["limit_name": $0, "metered_feature": $0.lowercased(), "rate_limit": ["primary_window": ["used_percent": 20, "limit_window_seconds": 18000], "secondary_window": ["used_percent": 40, "limit_window_seconds": 604800]]] }
        let first = try UsageParser.codex(["rate_limit": [:], "additional_rate_limits": [entry("Fast"), entry("Model")]])
        let reordered = try UsageParser.codex(["rate_limit": [:], "additional_rate_limits": [entry("Model"), entry("Fast")]])
        XCTAssertEqual(first.windows.count, 4)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: first.windows.map { ($0.title, $0.id) }), Dictionary(uniqueKeysWithValues: reordered.windows.map { ($0.title, $0.id) }))
        let old = UsageWindow(id: "additional-0", title: "Fast", usedPercent: 10, duration: 18000)
        let original = AgentAccount(provider: .codex, snapshot: UsageSnapshot(windows: [old]), display: AccountDisplay(rings: [RingDefinition(windowID: old.id, kind: .time, direction: .used)]))
        let migrated = MetricIdentityMigration.account(original, matching: first.windows)
        XCTAssertEqual(migrated.display?.rings.first?.windowID, first.windows.first?.id)
        XCTAssertEqual(migrated.display?.rings.first?.direction, .used)
        XCTAssertEqual(migrated.snapshot?.windows.first?.id, first.windows.first?.id)
        XCTAssertNil(MetricIdentityMigration.replacement(old, in: [first.windows[0], first.windows[0]]))
    }
    func testDetailsArePrivateToAppAndOldSnapshotsStillDecode() throws {
        var snapshot = UsageSnapshot(windows: [], details: ProviderDetails(credits: CreditDetails(available: true), spending: [SpendingDetails(id: "spend", title: "Usage credits", used: 12, currency: "GBP")]))
        let account = AgentAccount(provider: .claude, snapshot: snapshot)
        XCTAssertNil(WidgetCache.sanitized([account]).first?.snapshot?.details)
        snapshot.details = nil
        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertNil(try JSONDecoder().decode(UsageSnapshot.self, from: encoded).details)
        let diagnostic = UsageParsingDiagnostic.make(provider: .claude, raw: ["spend": ["used": ["amount_minor": 123456, "currency": "GBP"]], "seven_day_breakdown": ["rows": []]], snapshot: nil)
        XCTAssertEqual(diagnostic.fields[.spend], .object)
        let text = String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self)
        XCTAssertFalse(text.contains("123456")); XCTAssertFalse(text.contains("GBP"))
    }
}
