#if DEBUG
import Foundation

// Internal simulator/UI-test fixtures, separate from the shipping Demo mode.
enum SimulatorFixtures {
    static var storeCaptureEnabled: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--store-screenshots")
        #else
        false
        #endif
    }
    static var captureScreen: String {
        guard storeCaptureEnabled, let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--store-screen"),
              ProcessInfo.processInfo.arguments.indices.contains(index + 1) else { return "tiles" }
        return ProcessInfo.processInfo.arguments[index + 1]
    }
    static var widgetEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--widget-fixture") }
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--ui-fixture") || widgetEnabled || storeCaptureEnabled }
    static var activationEnabled: Bool {
        #if targetEnvironment(simulator)
        enabled && ProcessInfo.processInfo.arguments.contains("--activation-fixture")
        #else
        false
        #endif
    }
    static func accounts(now: Date = .now) -> [AgentAccount] {
        var accounts = (0..<8).map { index in
            if index == 1, ProcessInfo.processInfo.arguments.contains("--claude-reset-fixture") {
                let spent = ProcessInfo.processInfo.arguments.contains("--claude-spent-reset-fixture")
                var snapshot = try! UsageParser.claude([
                    "five_hour": ["utilization": 12, "resets_at": now.addingTimeInterval(3600).timeIntervalSince1970],
                    "seven_day": ["utilization": 30, "resets_at": now.addingTimeInterval(86400).timeIntervalSince1970],
                    "cedar_ember": ["eligible": true, "grants": [["id": "fixture-grant", "resets_total": 1, "resets_left": spent ? 0 : 1,
                        "paused": false, "usable_now": false, "ends_at": now.addingTimeInterval(7 * 86400).timeIntervalSince1970, "clears": ["five_hour", "seven_day"]]]]
                ], now: now)
                snapshot.source = "UI Test Fixture"
                return AgentAccount(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, provider: .claude, label: "Work", snapshot: snapshot, addedAt: now)
            }
            if ProcessInfo.processInfo.arguments.contains("--provider-stats-fixture"), [2, 4, 5].contains(index) {
                let provider: Provider = index == 2 ? .grok : index == 4 ? .copilot : .gemini
                let snapshot: UsageSnapshot
                if index == 2 { snapshot = try! UsageParser.grok(["config": ["creditUsagePercent": 100, "onDemandUsed": ["val": "1234"]]]) }
                else if index == 4 { snapshot = try! UsageParser.copilot(["token_based_billing": true, "quota_snapshots": ["premium_interactions": ["entitlement": 1500, "credits_used": 1500, "percent_remaining": 0, "overage_count": 40, "overage_entitlement": 100, "overage_permitted": true], "chat": ["unlimited": true, "credits_used": 2.5]]]) }
                else { snapshot = try! UsageParser.gemini(["buckets": [["modelId": "gemini-2.5-pro", "tokenType": "REQUESTS", "remainingFraction": 0.5, "remainingAmount": "123"]]]) }
                return AgentAccount(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!, provider: provider, label: index == 2 ? "Research" : index == 4 ? "Travel" : "Studio", snapshot: snapshot, addedAt: now)
            }
            if ProcessInfo.processInfo.arguments.contains("--credit-tile-fixture"), index == 2 {
                return AgentAccount(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, provider: .cline, label: "Research", snapshot: UsageSnapshot(creditBalance: "0.500012345678", updatedAt: now.addingTimeInterval(-120), source: "UI Test Fixture"), addedAt: now)
            }
            if ProcessInfo.processInfo.arguments.contains("--native-provider-fixture"), index == 4 || index == 5 {
                let provider: Provider = index == 4 ? .devin : .amp
                let windows: [UsageWindow] = index == 4 ? [.init(id: "daily", title: "Daily", usedPercent: 35, resetsAt: now.addingTimeInterval(8 * 3600), duration: 86400), .init(id: "weekly", title: "Weekly", usedPercent: 62, resetsAt: now.addingTimeInterval(3 * 86400), duration: 604800)] : []
                return AgentAccount(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!, provider: provider, label: index == 4 ? "Travel" : "Studio", snapshot: UsageSnapshot(windows: windows, plan: index == 4 ? "Free" : nil, creditBalance: index == 5 ? "$5.00" : nil, updatedAt: now.addingTimeInterval(-120), source: "UI Test Fixture"), addedAt: now)
            }
            if index == 5, ProcessInfo.processInfo.arguments.contains("--perplexity-count-fixture") {
                return AgentAccount(id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!, provider: .perplexity, label: "Studio", snapshot: UsageSnapshot(windows: [], plan: "Free", updatedAt: now.addingTimeInterval(-120), source: "UI Test Fixture", remainingAllowances: [.init(id: "pro_search", title: "Pro searches", remaining: 3, available: true)]), addedAt: now)
            }
            let provider = Provider.allCases[index % 3]
            var windows = [UsageWindow(id: "session", title: "5-hour window", usedPercent: Double(12 + index * 9), resetsAt: now.addingTimeInterval(10800 - Double(index * 600)), duration: 18000), UsageWindow(id: "week", title: "Weekly", usedPercent: Double(20 + index * 8), resetsAt: now.addingTimeInterval(259200 + Double(index * 14400)), duration: 604800)]
            if ProcessInfo.processInfo.arguments.contains("--notification-fixture"), index < 3 {
                windows[1].usedPercent = index == 0 ? 95 : 40
                windows[1].resetsAt = now.addingTimeInterval(index == 2 ? 45 : 12 * 3600)
            }
            let boundary = ProcessInfo.processInfo.arguments.contains("--ring-boundaries")
            if boundary && index == 0 { windows[1].usedPercent = 0 }
            if boundary && index == 3 { windows[1].usedPercent = 100 }
            let display = boundary && index == 0 ? AccountDisplay(rings: [RingDefinition(windowID: "session"), RingDefinition(windowID: "week"), RingDefinition(windowID: "session", kind: .time), RingDefinition(windowID: "week", kind: .time)]) : nil
            let credits = ProcessInfo.processInfo.arguments.contains("--credit-tile-fixture") && index == 0 ? "1234.567891234" : boundary && index == 3 ? "15.00" : nil
            return AgentAccount(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!, provider: provider, label: ["Personal", "Work", "Research", "Mac mini", "Travel", "Studio", "Weekend", "Archive"][index], snapshot: UsageSnapshot(windows: windows, plan: "Pro", creditBalance: credits, updatedAt: now.addingTimeInterval(-120), source: "UI Test Fixture"), display: display, addedAt: now)
        }
        if activationEnabled {
            for index in accounts.indices where AllowanceActivation.supported(accounts[index].provider) {
                let windowID = accounts[index].provider == .claude ? "seven_day" : "primary_window"
                accounts[index].snapshot?.windows = [UsageWindow(id: windowID, title: "Weekly", usedPercent: 0, duration: 604800, clockReported: true)]
                accounts[index].snapshot?.includedUsageAllowed = true
            }
        }
        return accounts
    }
}
#endif
