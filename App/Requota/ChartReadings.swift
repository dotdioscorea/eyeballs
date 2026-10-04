import Foundation

// Render simplification removes sub-percent quantization zigzags. Stored samples
// and inspected readings are untouched; exact zero/full plateaus keep both edges.
enum ChartSmoothing {
    static func points(_ source: [HistorySeries.Point], amount: Bool = false) -> [HistorySeries.Point] {
        guard source.count > 2 else { return source }
        let tolerance = amount ? max(0.000001, ((source.map(\.usedPercent).max() ?? 0) - (source.map(\.usedPercent).min() ?? 0)) * 0.005) : 0.75
        var retained: Set<Int> = [0, source.count - 1]
        if !amount {
            for index in source.indices where source[index].usedPercent == 0 || source[index].usedPercent == 100 {
                if index == 0 || index == source.count - 1 || source[index - 1].usedPercent != source[index].usedPercent || source[index + 1].usedPercent != source[index].usedPercent { retained.insert(index) }
            }
        }
        let anchors = retained.sorted()
        var work = zip(anchors, anchors.dropFirst()).map { ($0.0, $0.1) }
        while let (first, last) = work.popLast() {
            guard last > first + 1 else { continue }
            let a = source[first], b = source[last], span = b.date.timeIntervalSince(a.date)
            guard span > 0 else { continue }
            var largest = tolerance, chosen: Int?
            for index in (first + 1)..<last {
                let expected = a.usedPercent + (b.usedPercent - a.usedPercent) * source[index].date.timeIntervalSince(a.date) / span
                let error = abs(source[index].usedPercent - expected)
                if error > largest { largest = error; chosen = index }
            }
            if let chosen { retained.insert(chosen); work.append((first, chosen)); work.append((chosen, last)) }
        }
        return retained.sorted().map { source[$0] }
    }
    // Weighted harmonic tangents preserve monotonicity and flat boundaries.
    // https://docs.scipy.org/doc/scipy/reference/generated/scipy.interpolate.PchipInterpolator.html
    // Sample the explicit Hermite curve so drawing and inspection share one path.
    static func curve(_ anchors: [HistorySeries.Point]) -> [HistorySeries.Point] {
        guard anchors.count > 2 else { return anchors }
        let widths = zip(anchors, anchors.dropFirst()).map { $1.date.timeIntervalSince($0.date) }
        guard widths.allSatisfy({ $0 > 0 }) else { return anchors }
        let slopes = widths.indices.map { (anchors[$0 + 1].usedPercent - anchors[$0].usedPercent) / widths[$0] }
        var tangents = [Double](repeating: 0, count: anchors.count)
        tangents[0] = slopes[0]; tangents[anchors.count - 1] = slopes.last!
        for i in 1..<(anchors.count - 1) {
            let a = slopes[i - 1], b = slopes[i]
            guard a != 0, b != 0, (a > 0) == (b > 0) else { continue }
            let w1 = 2 * widths[i] + widths[i - 1], w2 = widths[i] + 2 * widths[i - 1]
            tangents[i] = (w1 + w2) / (w1 / a + w2 / b)
        }
        var result: [HistorySeries.Point] = [anchors[0]]
        for i in widths.indices {
            let a = anchors[i], b = anchors[i + 1], span = widths[i]
            if tangents[i] != slopes[i] || tangents[i + 1] != slopes[i] {
                for step in 1..<16 {
                    let t = Double(step) / 16, t2 = t * t, t3 = t2 * t
                    let value = (2 * t3 - 3 * t2 + 1) * a.usedPercent + (t3 - 2 * t2 + t) * span * tangents[i] + (-2 * t3 + 3 * t2) * b.usedPercent + (t3 - t2) * span * tangents[i + 1]
                    guard value.isFinite else { return anchors }
                    result.append(.init(date: a.date.addingTimeInterval(span * t), usedPercent: min(max(a.usedPercent, b.usedPercent), max(min(a.usedPercent, b.usedPercent), value))))
                }
            }
            result.append(b)
        }
        return result
    }
}
struct ChartReading: Equatable {
    var value: Double
    var estimated: Bool
}
enum ChartReadings {
    static func at(_ date: Date, segments: [[HistorySeries.Point]], stepped: Bool = false) -> ChartReading? {
        for segment in segments {
            guard let first = segment.first, let last = segment.last, date >= first.date, date <= last.date else { continue }
            var lower = 0, upper = segment.count
            while lower < upper {
                let mid = (lower + upper) / 2
                if segment[mid].date < date { lower = mid + 1 } else { upper = mid }
            }
            if lower < segment.count, abs(segment[lower].date.timeIntervalSince(date)) < 0.001 { return .init(value: segment[lower].usedPercent, estimated: false) }
            guard lower > 0, lower < segment.count else { return nil }
            let a = segment[lower - 1], b = segment[lower]
            let fraction = date.timeIntervalSince(a.date) / b.date.timeIntervalSince(a.date)
            return .init(value: stepped ? a.usedPercent : a.usedPercent + (b.usedPercent - a.usedPercent) * fraction, estimated: true)
        }
        return nil
    }
}
