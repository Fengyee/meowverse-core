import Foundation

/// Bella's hop between two footholds at different heights, in room cells (+Y up, feet at the
/// position). The old hop was a fixed 0.26-cell parabola over a straight line, so on a tall
/// climb her feet were still below the platform when she crossed its edge, and her body passed
/// through the lip. Here:
///
/// * the apex is `apexClearance` above the higher end, so it grows with the rise;
/// * the height follows a quadratic Bézier through both ends with that apex;
/// * the floor-plan motion waits for the height: climbing, she covers at most `lipShare` of the
///   way across before her feet are `lipClearance` above the level she lands on; dropping, she
///   covers at least `1 - lipShare` before she sinks below that height over the level she leaves.
///
/// Between footholds at one height (and whenever the even pace already clears the lip) the
/// floor-plan pace stays even, and the path is the old arc.
public struct CatHop: Sendable, Equatable {
    /// Feet above the higher end at the top of the hop (the old fixed lift).
    public static let apexClearance = 0.26
    /// Feet above a lip when she passes over it: a cushion rim or a platform's edge trim.
    public static let lipClearance = 0.1
    /// The share of the floor-plan distance she may cover before clearing the lip.
    public static let lipShare = 0.25

    public let from: SIMD3<Double>
    public let to: SIMD3<Double>
    /// Highest point of the feet.
    public let apex: Double
    private let control: Double
    /// Floor-plan pace: (time, share covered) through which it is piecewise linear.
    private let knot: (t: Double, share: Double)?

    public init(from: SIMD3<Double>, to: SIMD3<Double>) {
        self.from = from
        self.to = to
        let high = max(from.y, to.y)
        apex = high + Self.apexClearance
        // The Bézier control height whose curve peaks at `apex`.
        control = apex + ((apex - from.y) * (apex - to.y)).squareRoot()
        let threshold = high + Self.lipClearance
        let climbing = to.y > from.y
        // When the feet cross the lip height: first crossing on the way up, last on the way down.
        let crossing = Self.solve(y0: from.y, c: control, y1: to.y, y: threshold, first: climbing)
        if let tc = crossing {
            if climbing, tc > Self.lipShare {
                knot = (tc, Self.lipShare)
            } else if !climbing, tc < 1 - Self.lipShare {
                knot = (tc, 1 - Self.lipShare)
            } else {
                knot = nil
            }
        } else {
            knot = nil
        }
    }

    public static func == (a: CatHop, b: CatHop) -> Bool { a.from == b.from && a.to == b.to }

    /// Where her feet are at time `t` in 0...1.
    public func position(at t: Double) -> SIMD3<Double> {
        let t = min(max(t, 0), 1)
        let y = (1 - t) * (1 - t) * from.y + 2 * t * (1 - t) * control + t * t * to.y
        let share = shareCovered(at: t)
        return SIMD3(from.x + (to.x - from.x) * share, y, from.z + (to.z - from.z) * share)
    }

    private func shareCovered(at t: Double) -> Double {
        guard let knot else { return t }
        if t <= knot.t { return knot.share * t / knot.t }
        return knot.share + (1 - knot.share) * (t - knot.t) / (1 - knot.t)
    }

    /// Roots in 0...1 of the quadratic Bézier height minus `y`; the first or the last one.
    private static func solve(y0: Double, c: Double, y1: Double, y: Double, first: Bool) -> Double? {
        // (y0 - 2c + y1) t² + 2 (c - y0) t + (y0 - y) = 0
        let a = y0 - 2 * c + y1, b = 2 * (c - y0), k = y0 - y
        var roots: [Double] = []
        if abs(a) < 1e-12 {
            if abs(b) > 1e-12 { roots = [-k / b] }
        } else {
            let disc = b * b - 4 * a * k
            guard disc >= 0 else { return nil }
            let r = disc.squareRoot()
            roots = [(-b - r) / (2 * a), (-b + r) / (2 * a)]
        }
        let inside = roots.filter { $0 > 0 && $0 < 1 }.sorted()
        return first ? inside.first : inside.last
    }
}
