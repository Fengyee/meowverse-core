import SwiftUI
import UIKit

/// Furniture hotspots are SwiftUI siblings of the renderer. Observe their common window,
/// restricted to the visible room, so a pinch may start over furniture or over empty floor.
final class RoomCameraGestures: NSObject, UIGestureRecognizerDelegate {
    private weak var room: UIView?
    private weak var host: UIWindow?
    private let pinch = UIPinchGestureRecognizer()
    private let pan = UIPanGestureRecognizer()
    var onChange: ((CGFloat, CGPoint, CGSize) -> Void)?
    var isZoomed = false
    var playing = false {
        didSet {
            if oldValue != playing { pan.minimumNumberOfTouches = playing ? 2 : 1 }
        }
    }

    override init() {
        super.init()
        pinch.name = Self.pinchName
        pinch.addTarget(self, action: #selector(pinched))
        pan.addTarget(self, action: #selector(panned))
        pinch.delegate = self
        pan.delegate = self
    }

    fileprivate static let pinchName = "room-camera-pinch"

    func attach(to room: UIView?) {
        self.room = room
        guard room?.window !== host else { return }
        host?.removeGestureRecognizer(pinch)
        host?.removeGestureRecognizer(pan)
        host = room?.window
        host?.addGestureRecognizer(pinch)
        host?.addGestureRecognizer(pan)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let room, onChange != nil, host?.rootViewController?.presentedViewController == nil else { return false }
        return room.bounds.contains(touch.location(in: room))
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        onChange != nil && (recognizer === pinch || isZoomed)
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // A touch may land on a SwiftUI hotspot, or on the one-finger toy gesture. UIKit still
        // sends it to the camera as the second finger arrives or the user starts to pan.
        true
    }

    @objc private func pinched() {
        guard pinch.state == .began || pinch.state == .changed else { return }
        onChange?(pinch.scale, pinch.location(in: room), .zero)
        pinch.scale = 1
    }

    @objc private func panned() {
        guard pan.state == .began || pan.state == .changed else { return }
        let delta = pan.translation(in: room)
        onChange?(1, .zero, CGSize(width: delta.x, height: delta.y))
        pan.setTranslation(.zero, in: room)
    }
}

/// One recognizer handles both lifting and carrying. It fails if the finger moves before
/// the hold completes, leaving that drag available to the room camera.
struct LiftFurnitureGesture: UIGestureRecognizerRepresentable {
    let moved: (CGPoint) -> Void
    let ended: () -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ hold: UIGestureRecognizer) -> Bool {
            // The second finger may be on a sibling hotspot, outside the long press's view.
            let pinch = hold.view?.window?.gestureRecognizers?.first { $0.name == RoomCameraGestures.pinchName }
            return (pinch?.numberOfTouches ?? 0) < 2
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let hold = UILongPressGestureRecognizer()
        hold.minimumPressDuration = 0.4
        hold.delegate = context.coordinator
        return hold
    }

    func handleUIGestureRecognizerAction(_ hold: UILongPressGestureRecognizer, context: Context) {
        switch hold.state {
        case .began, .changed: moved(context.converter.location(in: .named(RoomEditMode.space)))
        case .ended, .cancelled: ended()
        default: break
        }
    }
}
