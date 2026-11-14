import Testing
@testable import MeowverseCore

/// The hop between two footholds at different heights (BellaActor). A fixed 0.26-cell arc on a
/// straight line let her body pass through the lip of the higher level on tall climbs.
@Suite struct CatHopTests {
    private func horizontal(_ hop: CatHop, _ t: Double) -> Double {
        let p = hop.position(at: t), a = hop.from, b = hop.to
        let total = ((b.x - a.x) * (b.x - a.x) + (b.z - a.z) * (b.z - a.z)).squareRoot()
        return (((p.x - a.x) * (p.x - a.x) + (p.z - a.z) * (p.z - a.z)).squareRoot()) / total
    }

    private let samples = (0...400).map { Double($0) / 400 }

    @Test func endsAreExact() {
        for (a, b) in [(SIMD3(0.0, 0, 0), SIMD3(0.8, 1.1, 0.3)), (SIMD3(1.0, 1.4, 0), SIMD3(0, 0.2, -0.5))] {
            let hop = CatHop(from: a, to: b)
            #expect(hop.position(at: 0) == a)
            let end = hop.position(at: 1)
            #expect(abs(end.x - b.x) < 1e-9 && abs(end.y - b.y) < 1e-9 && abs(end.z - b.z) < 1e-9)
        }
    }

    /// Between footholds at one height it is the old arc: 0.26 cells up at the middle, evenly paced.
    @Test func aLevelHopKeepsTheOldArc() {
        let hop = CatHop(from: [0, 0.5, 0], to: [1, 0.5, 0])
        for t in samples {
            let p = hop.position(at: t)
            #expect(abs(p.y - (0.5 + 4 * 0.26 * t * (1 - t))) < 1e-9)
            #expect(abs(p.x - t) < 1e-9)
        }
    }

    /// Climbing, her feet are the lip clearance above the higher level by the time she has covered
    /// `lipShare` of the way across, and never below it after that, so she cannot pass through
    /// the edge she lands on.
    @Test(arguments: [0.3, 0.6, 1.1, 1.6])
    func aClimbClearsTheLipItLandsOn(rise: Double) {
        let hop = CatHop(from: [0, 0.2, 0], to: [0.7, 0.2 + rise, 0.4])
        let high = 0.2 + rise
        let over = samples.filter { horizontal(hop, $0) >= CatHop.lipShare }
        #expect(hop.position(at: over[0]).y >= high + CatHop.lipClearance - 1e-9)
        for t in over { #expect(hop.position(at: t).y >= high - 1e-9, "t \(t)") }
        #expect(hop.apex >= high + CatHop.apexClearance - 1e-9)
    }

    /// Going down it mirrors: she clears the lip she leaves before she drops.
    @Test(arguments: [0.3, 1.1, 1.6])
    func aDropClearsTheLipItLeaves(rise: Double) {
        let hop = CatHop(from: [0, 0.2 + rise, 0], to: [-0.6, 0.2, 0.5])
        let high = 0.2 + rise
        let over = samples.filter { horizontal(hop, $0) <= 1 - CatHop.lipShare }
        #expect(hop.position(at: over[over.count - 1]).y >= high + CatHop.lipClearance - 1e-9)
        for t in over { #expect(hop.position(at: t).y >= high - 1e-9, "t \(t)") }
    }

    /// The apex above the straight line's midpoint grows with the rise, and she never moves
    /// backwards across the floor plan.
    @Test func theApexScalesWithTheRiseAndTheMotionIsMonotone() {
        var last = -1.0
        for rise in [0.0, 0.4, 0.8, 1.2] {
            let hop = CatHop(from: [0, 0, 0], to: [0.8, rise, 0])
            let overMidpoint = hop.apex - rise / 2
            #expect(overMidpoint > last)
            last = overMidpoint
            var previous = 0.0
            for t in samples {
                let h = horizontal(hop, t)
                #expect(h >= previous - 1e-12)
                previous = h
            }
        }
    }

    /// A vertical hop (no horizontal travel) stays well defined.
    @Test func aStraightUpHopIsFinite() {
        let hop = CatHop(from: [0.3, 0, 0.3], to: [0.3, 1, 0.3])
        for t in samples {
            let p = hop.position(at: t)
            #expect(p.x.isFinite && p.y.isFinite && p.z.isFinite)
        }
    }
}
