import SwiftUI
import UIKit

enum MetricColor {
    static func color(_ index: Int, base: Color) -> Color {
        var palette = [base]
        for candidate in [Color(hex: 0x91C7EE), Color(hex: 0xF2AD8B), Color(hex: 0xAAA5FF), Color(hex: 0xB9F577), Color(hex: 0x79D6B3), Color(hex: 0xF29BCB)] {
            guard palette.count < 4 else { break }
            if palette.allSatisfy({ distinctHue(candidate, $0) }) { palette.append(candidate) }
        }
        return palette[index % palette.count]
    }
    private static func distinctHue(_ first: Color, _ second: Color) -> Bool {
        var h1: CGFloat = 0, s1: CGFloat = 0, h2: CGFloat = 0, s2: CGFloat = 0
        guard UIColor(first).getHue(&h1, saturation: &s1, brightness: nil, alpha: nil),
              UIColor(second).getHue(&h2, saturation: &s2, brightness: nil, alpha: nil), s1 > 0.15, s2 > 0.15 else { return true }
        let distance = abs(h1 - h2)
        return min(distance, 1 - distance) >= 1 / 12
    }
}
extension AgentAccount {
    func usageColor(for windowID: String) -> Color {
        let index = displaySettings.rings.firstIndex { $0.windowID == windowID && $0.kind == .usage }
            ?? snapshot?.windows.firstIndex { $0.id == windowID } ?? 0
        return MetricColor.color(index, base: color)
    }
}
struct UsageRing: View {
    var readings: [MetricReading]
    var color: Color
    var size: CGFloat = 100
    var lineWidth: CGFloat = 8
    var showsNumber: Bool = true
    var showsCaption: Bool = true
    var body: some View {
        let count = min(4, readings.count)
        let gap: CGFloat = size < 110 ? 2 : 4
        let stroke = min(lineWidth, max(1.5, (size * 0.45 - 2 * gap * CGFloat(max(0, count - 1))) / CGFloat(max(1, 2 * count - 1))))
        let hole = max(1, size - CGFloat(max(0, count - 1)) * 2 * (stroke + gap) - stroke - 4)
        let value = readings.primary?.value ?? "—"
        let caption = showsCaption && hole >= 40 ? readings.primary?.centerCaption ?? "" : ""
        let captionSize = max(6, min(size * 0.075, hole * 0.14))
        ZStack {
            ForEach(Array(readings.prefix(4).enumerated()), id: \.element.id) { index, reading in
                let inset = CGFloat(index) * (stroke + gap)
                let tint = MetricColor.color(index, base: color)
                Circle().stroke(tint.opacity(0.13), lineWidth: stroke).padding(inset)
                if let percent = reading.percent, percent > 0 {
                    Circle().trim(from: 0, to: percent / 100)
                        .stroke(tint, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                        .rotationEffect(.degrees(-90)).padding(inset)
                } else if reading.percent == nil {
                    Circle().stroke(tint.opacity(0.3), style: StrokeStyle(lineWidth: stroke, dash: [2, 5])).padding(inset)
                }
            }
            if readings.isEmpty { Circle().stroke(color.opacity(0.15), style: StrokeStyle(lineWidth: lineWidth, dash: [3, 6])) }
            if showsNumber {
                VStack(spacing: 1) {
                    Text(value).font(.system(size: fittedSize(value, caption: caption, captionSize: captionSize, hole: hole), weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).fixedSize()
                    if !caption.isEmpty { Text(caption).font(.system(size: captionSize, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).fixedSize() }
                }.frame(width: hole)
            }
        }.frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(readings.map { "\($0.title), \($0.value) \($0.caption)" }.joined(separator: ", "))
    }
    private func fittedSize(_ value: String, caption: String, captionSize: CGFloat, hole: CGFloat) -> CGFloat {
        var pointSize = min(size * 0.235, hole * 0.55)
        for _ in 0..<20 {
            let descriptor = UIFont.monospacedDigitSystemFont(ofSize: pointSize, weight: .semibold).fontDescriptor
            let font = UIFont(descriptor: descriptor.withDesign(.rounded) ?? descriptor, size: pointSize)
            let bounds = (value as NSString).size(withAttributes: [.font: font])
            let captionHeight = caption.isEmpty ? 0 : captionSize * 1.25 + 1
            if hypot(bounds.width + 2, bounds.height + captionHeight) <= hole { break }
            pointSize *= 0.95
        }
        return pointSize
    }
}
struct MetricBars: View {
    var readings: [MetricReading]
    var color: Color
    var dense = false
    var body: some View {
        VStack(alignment: .leading, spacing: dense ? 4 : 13) {
            ForEach(Array(readings.enumerated()), id: \.element.id) { index, reading in
                VStack(spacing: dense ? 2 : 6) {
                    HStack {
                        Text(reading.title).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(reading.value) \(reading.caption)").monospacedDigit().fixedSize().foregroundStyle(.primary).fontWeight(.medium)
                    }.font(dense ? .system(size: 10) : .caption).foregroundStyle(.secondary)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(MetricColor.color(index, base: color).opacity(0.13))
                            if let percent = reading.percent {
                                Capsule().fill(MetricColor.color(index, base: color)).frame(width: geometry.size.width * percent / 100)
                            }
                        }
                    }.frame(height: dense ? 3 : 6).accessibilityHidden(true)
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
