import SwiftUI

/// Preserve readable text instead of compressing two competing columns.
struct AccessibleValueRow: View {
    var title: String
    var value: String
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        Group {
            if textSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).foregroundStyle(.secondary)
                    Text(value).monospacedDigit()
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(value).monospacedDigit().multilineTextAlignment(.trailing)
                }
            }
        }.fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine)
    }
}

struct AccessibleStack<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var textSize
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        let layout = textSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: .center, spacing: spacing))
        layout { content }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Rings are a fixed-size graphic; their values also need scalable text.
struct AccessibleUsageRing: View {
    var readings: [MetricReading]
    var color: Color
    var size: CGFloat
    var lineWidth: CGFloat = 8
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        VStack(spacing: 8) {
            UsageRing(readings: readings, color: color, size: size, lineWidth: lineWidth, showsNumber: !textSize.isAccessibilitySize)
            if textSize.isAccessibilitySize, let primary = readings.primary {
                Text(primary.value).font(.title2.weight(.semibold)).monospacedDigit()
                Text(primary.centerCaption).font(.caption).foregroundStyle(.secondary)
            }
        }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: textSize.isAccessibilitySize ? .infinity : nil)
    }
}
