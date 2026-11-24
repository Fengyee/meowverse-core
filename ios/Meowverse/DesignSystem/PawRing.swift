import SwiftUI

/// A cat's paw print, toes up: four oval toe beans fanned over a wide, low palm pad, the whole
/// print wider than tall (art-craft: the system `pawprint` has round toes and a triangular pad
/// and reads as a dog's). Drawn in a unit square; the print spans x 0…1, y 0.06…0.92.
nonisolated struct CatPawShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func oval(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, tilt: Angle) -> Path {
            let box = CGRect(x: -rx * w, y: -ry * h, width: 2 * rx * w, height: 2 * ry * h)
            return Path(ellipseIn: box).applying(
                CGAffineTransform(rotationAngle: tilt.radians)
                    .concatenating(CGAffineTransform(translationX: rect.minX + cx * w, y: rect.minY + cy * h)))
        }
        var path = Path()
        // Toe beans: narrow ovals fanned outwards, gaps of about 0.1 between neighbours.
        path.addPath(oval(0.12, 0.42, 0.095, 0.13, tilt: .degrees(-32)))
        path.addPath(oval(0.36, 0.18, 0.095, 0.13, tilt: .degrees(-10)))
        path.addPath(oval(0.64, 0.18, 0.095, 0.13, tilt: .degrees(10)))
        path.addPath(oval(0.88, 0.42, 0.095, 0.13, tilt: .degrees(32)))
        // Palm pad: a domed top with a flatter, wider base.
        let top = rect.minY + 0.5 * h, bottom = rect.minY + 0.92 * h
        path.move(to: CGPoint(x: rect.minX + 0.24 * w, y: rect.minY + 0.8 * h))
        path.addCurve(to: CGPoint(x: rect.minX + 0.5 * w, y: top),
                      control1: CGPoint(x: rect.minX + 0.22 * w, y: rect.minY + 0.62 * h),
                      control2: CGPoint(x: rect.minX + 0.36 * w, y: top))
        path.addCurve(to: CGPoint(x: rect.minX + 0.76 * w, y: rect.minY + 0.8 * h),
                      control1: CGPoint(x: rect.minX + 0.64 * w, y: top),
                      control2: CGPoint(x: rect.minX + 0.78 * w, y: rect.minY + 0.62 * h))
        path.addCurve(to: CGPoint(x: rect.minX + 0.5 * w, y: bottom),
                      control1: CGPoint(x: rect.minX + 0.75 * w, y: bottom),
                      control2: CGPoint(x: rect.minX + 0.6 * w, y: bottom - 0.04 * h))
        path.addCurve(to: CGPoint(x: rect.minX + 0.24 * w, y: rect.minY + 0.8 * h),
                      control1: CGPoint(x: rect.minX + 0.4 * w, y: bottom - 0.04 * h),
                      control2: CGPoint(x: rect.minX + 0.25 * w, y: bottom))
        path.closeSubpath()
        return path
    }
}

/// An endless loading ring: paw prints step clockwise round a circle, one at a time, as if a
/// cat walked it; once the ring is closed it fades and the walk starts again. Under Reduce
/// Motion the ring stands complete and still. Decorative: the caller says what is loading.
struct PawRing: View {
    var diameter: CGFloat = 176
    var count = 16
    var pawSize: CGFloat = 16
    var color: Color = RoomPaper.clay
    /// Steps taken, held still (the gallery); nil walks.
    var frozenSteps: Double? = nil
    /// One step every this many seconds; the closed ring then holds for `hold` steps.
    static let step = 0.12
    static let hold = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let shown = frozenSteps ?? (reduceMotion ? nil : progress(at: context.date))
            ZStack {
                ForEach(0..<count, id: \.self) { index in
                    paw(index, opacity: shown.map { opacity(index, $0) } ?? 0.75)
                }
            }
            .frame(width: diameter + pawSize, height: diameter + pawSize)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    /// Steps taken in this cycle, fractional; `count + hold` steps make one cycle.
    private func progress(at date: Date) -> Double {
        let cycle = Double(count + Self.hold)
        return (date.timeIntervalSinceReferenceDate / Self.step).truncatingRemainder(dividingBy: cycle)
    }

    private func opacity(_ index: Int, _ steps: Double) -> Double {
        let appear = min(max(steps - Double(index), 0), 1) // each print presses in over one step
        let fade = steps > Double(count) ? max(0, 1 - (steps - Double(count)) / Double(Self.hold)) : 1
        return 0.85 * appear * fade
    }

    /// Prints walk clockwise from 12 o'clock, toes along the way round, left and right feet a
    /// little inside and outside the line.
    private func paw(_ index: Int, opacity: Double) -> some View {
        let angle = Angle.degrees(Double(index) / Double(count) * 360)
        let radius = diameter / 2 + (index.isMultiple(of: 2) ? -3 : 3)
        return CatPawShape()
            .fill(color)
            .frame(width: pawSize, height: pawSize)
            .rotationEffect(angle + .degrees(90))
            .offset(x: radius * sin(angle.radians), y: -radius * cos(angle.radians))
            .opacity(opacity)
    }
}
