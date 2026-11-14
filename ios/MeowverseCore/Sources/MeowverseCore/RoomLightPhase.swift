import Foundation

public enum RoomLightPhase: Int, Sendable {
    case dawn = 6
    case daylight = 9
    case dusk = 17
    case night = 21

    public static func local(at date: Date, in calendar: Calendar = .autoupdatingCurrent) -> Self {
        switch calendar.component(.hour, from: date) {
        case dawn.rawValue..<daylight.rawValue: .dawn
        case daylight.rawValue..<dusk.rawValue: .daylight
        case dusk.rawValue..<night.rawValue: .dusk
        default: .night
        }
    }

    public static func nextChange(after date: Date, in calendar: Calendar = .autoupdatingCurrent) -> Date? {
        let next: Self = switch local(at: date, in: calendar) {
        case .night: .dawn
        case .dawn: .daylight
        case .daylight: .dusk
        case .dusk: .night
        }
        return calendar.nextDate(after: date, matching: DateComponents(hour: next.rawValue, minute: 0, second: 0),
                                 matchingPolicy: .nextTime, repeatedTimePolicy: .first)
    }
}
