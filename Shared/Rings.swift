import SwiftUI

enum MetricColor {
    static func color(_ index: Int, base: Color) -> Color {
        [base, Color(hex: 0x91C7EE), Color(hex: 0xF2AD8B), Color(hex: 0xAAA5FF)][index % 4]
    }
}
struct UsageRing: View {
    var readings: [MetricReading]
    var color: Color
    var size: CGFloat = 100
    var lineWidth: CGFloat = 8
    var showsNumber: Bool = true
    var body: some View {
        ZStack {
            ForEach(Array(readings.prefix(4).enumerated()), id: \.element.id) { index, reading in
                let inset = CGFloat(index) * (lineWidth + 4)
                let tint = MetricColor.color(index, base: color)
                Circle().stroke(tint.opacity(0.13), lineWidth: lineWidth).padding(inset)
                if let percent = reading.percent, percent > 0 {
                    Circle().trim(from: 0, to: percent / 100)
                        .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90)).padding(inset)
                } else if reading.percent == nil {
                    Circle().stroke(tint.opacity(0.3), style: StrokeStyle(lineWidth: lineWidth, dash: [2, 5])).padding(inset)
                }
            }
            if readings.isEmpty { Circle().stroke(color.opacity(0.15), style: StrokeStyle(lineWidth: lineWidth, dash: [3, 6])) }
            if showsNumber, readings.count <= 2 {
                VStack(spacing: 1) {
                    Text(readings.first?.value ?? "—").font(.system(size: size * 0.235, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(readings.first?.centerCaption ?? "").font(.system(size: max(7, size * 0.075), weight: .medium)).foregroundStyle(.secondary)
                }
            }
        }.frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(readings.map { "\($0.title), \($0.value) \($0.caption)" }.joined(separator: ", "))
    }
}
struct MetricBars: View {
    var readings: [MetricReading]
    var color: Color
    var dense = false
    var body: some View {
        VStack(alignment: .leading, spacing: dense ? 5 : 13) {
            ForEach(Array(readings.enumerated()), id: \.element.id) { index, reading in
                VStack(spacing: dense ? 3 : 6) {
                    HStack {
                        Text(reading.title).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(reading.value) \(reading.caption)").monospacedDigit().fixedSize()
                    }.font(dense ? .system(size: 10) : .caption).foregroundStyle(.secondary)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(MetricColor.color(index, base: color).opacity(0.13))
                            if let percent = reading.percent {
                                Capsule().fill(MetricColor.color(index, base: color)).frame(width: geometry.size.width * percent / 100)
                            }
                        }
                    }.frame(height: dense ? 4 : 6).accessibilityHidden(true)
                }
            }
        }
    }
}
struct MetricLegend: View {
    var readings: [MetricReading]
    var color: Color
    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(readings.enumerated()), id: \.element.id) { index, reading in
                HStack(spacing: 6) {
                    Circle().fill(MetricColor.color(index, base: color)).frame(width: 5, height: 5)
                    Text(reading.title).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 2)
                    Text("\(reading.value) \(reading.caption)").monospacedDigit().fixedSize()
                }.font(.caption)
            }
        }
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
