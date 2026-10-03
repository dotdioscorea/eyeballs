#if DEBUG
import Foundation

// Internal simulator/UI-test fixtures, separate from the shipping Demo mode.
enum SimulatorFixtures {
    static var widgetEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--widget-fixture") }
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--ui-fixture") || widgetEnabled }
    static func accounts(now: Date = .now) -> [AgentAccount] {
        (0..<8).map { index in
            if index == 5, ProcessInfo.processInfo.arguments.contains("--perplexity-count-fixture") {
                return AgentAccount(id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!, provider: .perplexity, label: "Studio", snapshot: UsageSnapshot(windows: [], plan: "Free", updatedAt: now.addingTimeInterval(-120), source: "UI Test Fixture", remainingAllowances: [.init(id: "pro_search", title: "Pro searches", remaining: 3, available: true)]), addedAt: now)
            }
            let provider = Provider.allCases[index % 3]
            var windows = [UsageWindow(id: "session", title: "5-hour window", usedPercent: Double(12 + index * 9), resetsAt: now.addingTimeInterval(10800 - Double(index * 600)), duration: 18000), UsageWindow(id: "week", title: "Weekly", usedPercent: Double(20 + index * 8), resetsAt: now.addingTimeInterval(259200 + Double(index * 14400)), duration: 604800)]
            let boundary = ProcessInfo.processInfo.arguments.contains("--ring-boundaries")
            if boundary && index == 0 { windows[1].usedPercent = 0 }
            if boundary && index == 3 { windows[1].usedPercent = 100 }
            let display = boundary && index == 0 ? AccountDisplay(rings: [RingDefinition(windowID: "session"), RingDefinition(windowID: "week"), RingDefinition(windowID: "session", kind: .time), RingDefinition(windowID: "week", kind: .time)]) : nil
            return AgentAccount(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!, provider: provider, label: ["Personal", "Work", "Research", "Mac mini", "Travel", "Studio", "Weekend", "Archive"][index], snapshot: UsageSnapshot(windows: windows, plan: "Pro", creditBalance: boundary && index == 3 ? "15.00" : nil, updatedAt: now.addingTimeInterval(-120), source: "UI Test Fixture"), display: display, addedAt: now)
        }
    }
}
#endif
