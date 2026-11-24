import Foundation

nonisolated enum PocketCatMood: String, CaseIterable, Codable, Sendable {
    case sleeping, playing, zoomies, thinking, eating, watching

    var next: Self {
        let moods = Self.allCases
        let index = moods.firstIndex(of: self)!
        return moods[(index + 1) % moods.count]
    }
}

nonisolated struct PocketCatRotation: Codable, Hashable {
    let startedAt: Date
    let interval: TimeInterval
    let order: [PocketCatMood]

    static let standardInterval: TimeInterval = 5 * 60

    init(startingWith mood: PocketCatMood, at date: Date, interval: TimeInterval) {
        self.startedAt = date
        self.interval = interval
        self.order = [mood] + PocketCatMood.allCases.filter { $0 != mood }.shuffled()
    }

    private func step(at date: Date) -> Int {
        Int(floor(date.timeIntervalSince(startedAt) / interval))
    }

    func mood(at date: Date) -> PocketCatMood {
        let index = step(at: date) % order.count
        return order[index < 0 ? index + order.count : index]
    }

    func nextChange(after date: Date) -> Date {
        startedAt.addingTimeInterval(Double(step(at: date) + 1) * interval)
    }

    func clockAnchor(for index: Int, at date: Date) -> Date {
        let cycle = Double(order.count) * interval
        // Use the latest cycle boundary, with one spare cycle for small backward clock
        // corrections. A very large elapsed duration can exceed the compact timer's layout.
        let elapsedCycles = floor(date.timeIntervalSince(startedAt) / cycle)
        let offset = Double((order.count - index) % order.count) * interval
        return startedAt.addingTimeInterval((elapsedCycles - 1) * cycle - offset)
    }
}

nonisolated struct PocketCatState: Codable, Hashable {
    let mood: PocketCatMood
    let rotation: PocketCatRotation?

    init(startingWith mood: PocketCatMood, at date: Date, interval: TimeInterval) {
        self.mood = mood
        self.rotation = PocketCatRotation(startingWith: mood, at: date, interval: interval)
    }

    func mood(at date: Date) -> PocketCatMood {
        rotation?.mood(at: date) ?? mood
    }

    func nextChange(after date: Date) -> Date? {
        rotation?.nextChange(after: date)
    }

    /// `mood` chosen at `date`: a new rotation from there, at this companion's pace.
    func showing(_ mood: PocketCatMood, at date: Date) -> PocketCatState {
        PocketCatState(startingWith: mood, at: date, interval: rotation?.interval ?? PocketCatRotation.standardInterval)
    }

    /// "Change expression" (the Live Activity's button, and the widgets' while company runs):
    /// the expression after the one showing at `date`.
    func changed(at date: Date) -> PocketCatState {
        showing(mood(at: date).next, at: date)
    }
}
