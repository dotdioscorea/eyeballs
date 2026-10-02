import SwiftUI

struct UsageRing: View {
    var windows: [UsageWindow]
    var color: Color
    var size: CGFloat = 100
    var lineWidth: CGFloat = 8
    var showsNumber: Bool = true
    var body: some View {
        ZStack {
            ForEach(Array(windows.prefix(2).enumerated()), id: \.offset) { index, window in
                let inset = CGFloat(index) * (lineWidth + 5)
                Circle().stroke(color.opacity(0.12), lineWidth: lineWidth).padding(inset)
                if let percent = window.safePercent {
                    Circle().trim(from: 0, to: max(0.004, percent / 100))
                        .stroke(index == 0 ? color : color.opacity(0.48), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90)).padding(inset)
                }
            }
            if windows.isEmpty {
                Circle().stroke(color.opacity(0.15), style: StrokeStyle(lineWidth: lineWidth, dash: [3, 6]))
            }
            if showsNumber {
                VStack(spacing: 1) {
                    Text(windows.first?.safePercent.map { "\(Int($0.rounded()))%" } ?? "—")
                        .font(.system(size: size * 0.235, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("USED").font(.system(size: max(8, size * 0.08), weight: .medium)).tracking(1.5).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(windows.map { "\($0.title), \($0.safePercent.map { "\(Int($0)) percent used" } ?? "usage unavailable")" }.joined(separator: ", "))
    }
}

struct ProviderMark: View {
    var provider: Provider
    var size: CGFloat = 36
    var body: some View {
        Image(systemName: provider.symbol).font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(provider.color).frame(width: size, height: size)
            .background(provider.color.opacity(0.1), in: RoundedRectangle(cornerRadius: size * 0.3))
            .accessibilityHidden(true)
    }
}

enum ResetText {
    static func relative(_ date: Date, now: Date = .now) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "Reset due" }
        if seconds < 60 { return "Less than a minute" }
        if seconds < 3600 { return "\(Int(ceil(seconds / 60)))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60))m" }
        return "\(Int(seconds / 86400))d \(Int(seconds.truncatingRemainder(dividingBy: 86400) / 3600))h"
    }
}
