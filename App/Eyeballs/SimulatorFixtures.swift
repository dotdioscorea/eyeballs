#if DEBUG
import Foundation

// Internal simulator/UI-test fixtures, separate from the shipping Demo mode.
enum SimulatorFixtures {
    static var widgetEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--widget-fixture") }
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--ui-fixture") || widgetEnabled }
    static func accounts(now: Date = .now) -> [AgentAccount] {
        (0..<8).map { index in
            let provider = Provider.allCases[index % 3]
            let windows = [UsageWindow(id: "session", title: "5-hour window", usedPercent: Double(12 + index * 9), resetsAt: now.addingTimeInterval(10800 - Double(index * 600)), duration: 18000), UsageWindow(id: "week", title: "Weekly", usedPercent: Double(20 + index * 8), resetsAt: now.addingTimeInterval(259200 + Double(index * 14400)), duration: 604800)]
            return AgentAccount(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!, provider: provider, label: ["Personal", "Work", "Research", "Mac mini", "Travel", "Studio", "Weekend", "Archive"][index], snapshot: UsageSnapshot(windows: windows, plan: "Pro", updatedAt: now.addingTimeInterval(-120), source: "UI Test Fixture"), addedAt: now)
        }
    }
}
#endif
