import SwiftUI

struct PocketCatDisplay<Content: View>: View {
    let state: PocketCatState
    /// Read out with the image where the name is drawn inside the rotating layers (the Lock
    /// Screen and the watch); the island passes none.
    let name: String?
    @ViewBuilder let content: (PocketCatMood) -> Content

    init(state: PocketCatState, name: String? = nil, @ViewBuilder content: @escaping (PocketCatMood) -> Content) {
        self.state = state
        self.name = name
        self.content = content
    }

    private var label: Text {
        if let name { Text("\(name), pixel cat with changing expressions", tableName: "PocketCat") }
        else { Text("Pixel cat with changing expressions", tableName: "PocketCat") }
    }

    var body: some View {
        if let rotation = state.rotation {
            let now = Date.now
            ZStack {
                ForEach(Array(rotation.order.enumerated()), id: \.element) { index, mood in
                    content(mood)
                        .mask { PocketCatPhaseMask(rotation: rotation, index: index, date: now) }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier("pocket-rotating-cat")
        } else {
            content(state.mood)
        }
    }
}

private struct PocketCatPhaseMask: View {
    let rotation: PocketCatRotation
    let index: Int
    let date: Date

    var body: some View {
        GeometryReader { geometry in
            let side = max(geometry.size.width, geometry.size.height)
            // The system keeps this duration live when the app is suspended. The bundled font
            // draws an opaque square only during minutes 00–04 and 30–34 of each hour.
            Text(.durationOffset(to: rotation.clockAnchor(for: index, at: date)), format: format)
                .font(.custom("PocketCatPhase", fixedSize: side * 3))
                .frame(width: side * 4, height: side * 4)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }

    private var format: Duration.TimeFormatStyle {
        var pattern = Duration.TimeFormatStyle.Pattern.hourMinute(padHourToLength: 1, roundSeconds: .towardZero)
        if rotation.interval == 5 {
            pattern = .minuteSecond(padMinuteToLength: 1, roundFractionalSeconds: .towardZero)
        }
        return .init(pattern: pattern, locale: Locale(identifier: "en_US_POSIX"))
    }
}
