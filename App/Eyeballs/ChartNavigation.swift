import SwiftUI
import UIKit

// A bounded viewport is shared by pinch, pan and accessibility actions.
enum ChartViewport {
    static func clamp(_ range: ClosedRange<Date>, to bounds: ClosedRange<Date>) -> ClosedRange<Date> {
        let length = min(bounds.upperBound.timeIntervalSince(bounds.lowerBound), max(1, range.upperBound.timeIntervalSince(range.lowerBound)))
        let start = min(bounds.upperBound.addingTimeInterval(-length), max(bounds.lowerBound, range.lowerBound))
        return start...start.addingTimeInterval(length)
    }
    static func advanced(_ viewport: ClosedRange<Date>?, from old: ClosedRange<Date>, to new: ClosedRange<Date>, bounds: ClosedRange<Date>) -> ClosedRange<Date>? {
        guard let viewport else { return nil }
        // Changing the period resets the view. New observations preserve a
        // historical position, or advance a zoomed view that followed the latest.
        guard abs(new.upperBound.timeIntervalSince(new.lowerBound) - old.upperBound.timeIntervalSince(old.lowerBound)) < 1 else { return nil }
        let offset = abs(viewport.upperBound.timeIntervalSince(old.upperBound)) < 1 ? new.upperBound.timeIntervalSince(old.upperBound) : 0
        return clamp(viewport.lowerBound.addingTimeInterval(offset)...viewport.upperBound.addingTimeInterval(offset), to: bounds)
    }
    static func zoom(_ range: ClosedRange<Date>, scale: Double, anchor: Double, bounds: ClosedRange<Date>) -> ClosedRange<Date> {
        guard scale.isFinite, scale > 0 else { return clamp(range, to: bounds) }
        let old = range.upperBound.timeIntervalSince(range.lowerBound)
        let length = max(min(900, bounds.upperBound.timeIntervalSince(bounds.lowerBound)), min(bounds.upperBound.timeIntervalSince(bounds.lowerBound), old / scale))
        let fraction = max(0, min(1, anchor))
        let start = range.lowerBound.addingTimeInterval((old - length) * fraction)
        return clamp(start...start.addingTimeInterval(length), to: bounds)
    }
    static func pan(_ range: ClosedRange<Date>, fraction: Double, bounds: ClosedRange<Date>) -> ClosedRange<Date> {
        guard fraction.isFinite else { return range }
        let offset = -fraction * range.upperBound.timeIntervalSince(range.lowerBound)
        return clamp(range.lowerBound.addingTimeInterval(offset)...range.upperBound.addingTimeInterval(offset), to: bounds)
    }
}

// Horizontal pan owns only the plot area. Vertical drags remain available to the
// enclosing page; holding selects readings, and two fingers zoom around the pinch.
struct ChartGestures: UIViewRepresentable {
    var pan: (Double, Bool) -> Void
    var zoom: (Double, Double, Bool) -> Void
    var select: (Double) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panned(_:)))
        pan.maximumNumberOfTouches = 1; pan.delegate = context.coordinator
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinched(_:)))
        pinch.delegate = context.coordinator
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.held(_:)))
        hold.minimumPressDuration = 0.35; hold.delegate = context.coordinator
        context.coordinator.hold = hold
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.require(toFail: hold)
        for gesture in [pan, pinch, hold, tap] { view.addGestureRecognizer(gesture) }
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { context.coordinator.owner = self }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var owner: ChartGestures
        weak var hold: UILongPressGestureRecognizer?
        init(_ owner: ChartGestures) { self.owner = owner }
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            if let pan = gesture as? UIPanGestureRecognizer {
                let speed = pan.velocity(in: pan.view)
                return abs(speed.x) > abs(speed.y) && hold?.state != .began && hold?.state != .changed
            }
            return true
        }
        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { gesture.view === other.view }
        @objc func panned(_ gesture: UIPanGestureRecognizer) {
            let delta = gesture.translation(in: gesture.view).x / max(1, gesture.view?.bounds.width ?? 1)
            gesture.setTranslation(.zero, in: gesture.view)
            guard hold?.state != .began, hold?.state != .changed else { return }
            owner.pan(delta, gesture.state == .ended || gesture.state == .cancelled)
        }
        @objc func pinched(_ gesture: UIPinchGestureRecognizer) {
            let scale = gesture.scale
            gesture.scale = 1
            owner.zoom(scale, gesture.location(in: gesture.view).x / max(1, gesture.view?.bounds.width ?? 1), gesture.state == .ended || gesture.state == .cancelled)
        }
        @objc func held(_ gesture: UILongPressGestureRecognizer) { if gesture.state == .began || gesture.state == .changed { picked(gesture) } }
        @objc func tapped(_ gesture: UITapGestureRecognizer) { picked(gesture) }
        private func picked(_ gesture: UIGestureRecognizer) { owner.select(max(0, min(1, gesture.location(in: gesture.view).x / max(1, gesture.view?.bounds.width ?? 1)))) }
    }
}

struct ChartLegendLayout: Layout {
    var spacing: CGFloat = 12
    private func positions(_ views: Subviews, width: CGFloat) -> ([CGPoint], CGSize) {
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, points: [CGPoint] = []
        for view in views {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > width { x = 0; y += row + 8; row = 0 }
            points.append(CGPoint(x: x, y: y)); x += size.width + spacing; row = max(row, size.height)
        }
        return (points, CGSize(width: width, height: y + row))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { positions(subviews, width: proposal.width ?? 320).1 }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let points = positions(subviews, width: bounds.width).0
        for (index, view) in subviews.enumerated() { view.place(at: CGPoint(x: bounds.minX + points[index].x, y: bounds.minY + points[index].y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil)) }
    }
}
