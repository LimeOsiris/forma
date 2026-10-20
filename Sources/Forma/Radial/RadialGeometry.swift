import CoreGraphics
import Foundation

/// Pure geometry for the wheel: which segment is under a point, where labels go.
/// Angles are in radians, measured clockwise from 12 o'clock, in a y-down view space.
struct RadialGeometry: Equatable {
    var count: Int
    var outerRadius: CGFloat
    var innerRadius: CGFloat
    /// Gap between segments, in radians at the outer edge.
    var gap: CGFloat = 0.035

    var segmentAngle: CGFloat { count > 0 ? (2 * .pi) / CGFloat(count) : 0 }

    /// Center angle of segment `i`; segment 0 sits at the top.
    func centerAngle(_ i: Int) -> CGFloat { CGFloat(i) * segmentAngle }

    func startAngle(_ i: Int) -> CGFloat { centerAngle(i) - segmentAngle / 2 + gap / 2 }
    func endAngle(_ i: Int) -> CGFloat { centerAngle(i) + segmentAngle / 2 - gap / 2 }

    /// Clockwise-from-top angle for a vector from the center (y grows downward).
    static func angle(dx: CGFloat, dy: CGFloat) -> CGFloat {
        var a = atan2(dx, -dy)
        if a < 0 { a += 2 * .pi }
        return a
    }

    enum Region: Equatable { case outside, hub, segment(Int) }

    /// Hit-tests a point relative to the wheel center.
    func region(dx: CGFloat, dy: CGFloat, slack: CGFloat = 18) -> Region {
        let r = hypot(dx, dy)
        if r <= innerRadius { return .hub }
        if r > outerRadius + slack || count == 0 { return .outside }
        let a = Self.angle(dx: dx, dy: dy)
        let shifted = (a + segmentAngle / 2).truncatingRemainder(dividingBy: 2 * .pi)
        return .segment(min(count - 1, Int(shifted / segmentAngle)))
    }

    /// Point (relative to center, y-down) at the middle of segment `i`.
    func labelPosition(_ i: Int) -> CGPoint {
        let mid = (outerRadius + innerRadius) / 2
        let a = centerAngle(i)
        return CGPoint(x: sin(a) * mid, y: -cos(a) * mid)
    }

    /// Unit vector pointing outward through segment `i` (for the hover nudge).
    func outward(_ i: Int) -> CGVector {
        let a = centerAngle(i)
        return CGVector(dx: sin(a), dy: -cos(a))
    }

    /// Next index for keyboard navigation, wrapping around.
    func step(from i: Int?, by delta: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let i else { return delta >= 0 ? 0 : count - 1 }
        return ((i + delta) % count + count) % count
    }

    /// Maps an arrow key to the segment closest to that direction.
    func index(forDirection dx: CGFloat, _ dy: CGFloat) -> Int? {
        guard count > 0 else { return nil }
        if case .segment(let i) = region(dx: dx * (innerRadius + 1), dy: dy * (innerRadius + 1), slack: .infinity) { return i }
        return nil
    }
}

/// Places the wheel so it's centered on the cursor but fully on-screen.
enum WheelPlacement {
    static func frame(size: CGSize, centeredAt point: CGPoint, in visible: CGRect) -> CGRect {
        var origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }
}
