import SwiftUI
import WidgetKit

/// Control Center (and the Lock Screen's controls and the Action button). The names carry no
/// cat's name, since Control Center opens over a locked phone.
///
/// "Keep Me Company" is a toggle, like the flashlight (owner, round 11): on while a companion
/// runs, as the app left it in the App Group (`PocketCatCompanyToggle`); a tap starts or ends
/// company without opening the app. The kind is the one the earlier button had, so a control
/// already in Control Center becomes the toggle.
///
/// It can be set (edit Control Center, tap the control) to start with a chosen expression; the
/// title names it, "Keep Me Company · Playing". Same kind as before, and the setting defaults to
/// asleep, so a control placed before it had settings carries on as it was. Adding one doesn't
/// ask for the setting first (`promptsForUserConfiguration`): the default is what most people
/// want, and the question would stand between them and the control.
struct PocketCatCompanyControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: PocketCatCompanyToggle.kind, provider: PocketCatCompanyValue()) { value in
            ControlWidgetToggle(isOn: value.isOn, action: SetPocketCatCompany(mood: value.mood)) {
                Label {
                    Text(PocketCatCompanyToggle.title(value.mood))
                } icon: {
                    Image(PocketCatControlFace.company.symbol)
                }
            } valueLabel: { isOn in
                Text(isOn ? PocketCatControlCopy.on : PocketCatControlCopy.off)
            }
            // The companion page's ink green (`RoomPaper` moss, light): white reads on it at about 6:1.
            .tint(Color(red: 0x4C / 255, green: 0x67 / 255, blue: 0x4D / 255))
        }
        .displayName(PocketCatControlCopy.company)
        .description(LocalizedStringResource("Your pixel cat comes to the Lock Screen without opening the app.", table: "PocketCat"))
    }
}

/// Whether company is on, and the expression the control starts it with.
struct PocketCatCompanyControlValue {
    let isOn: Bool
    let mood: PocketCatMood
}

/// Read in the extension, which can't see the app's Live Activities: the App Group copy.
struct PocketCatCompanyValue: AppIntentControlValueProvider {
    func previewValue(configuration: PocketCatCompanyConfiguration) -> PocketCatCompanyControlValue {
        .init(isOn: false, mood: configuration.mood)
    }

    func currentValue(configuration: PocketCatCompanyConfiguration) async throws -> PocketCatCompanyControlValue {
        .init(isOn: PocketCatCompanyToggle.isOn(.shared, at: .now), mood: configuration.mood)
    }
}

struct PocketCatTakePhotoControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.meowverse.control.camera") {
            ControlWidgetButton(action: TakePhotoToAdd()) {
                Label { Text(PocketCatControlCopy.camera) } icon: { Image(PocketCatControlFace.camera.symbol) }
            }
        }
        .displayName(PocketCatControlCopy.camera)
        .description(LocalizedStringResource("Opens Meowverse to take a photo for your cat’s home.", table: "PocketCat"))
    }
}

struct PocketCatAddFromPhotosControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.meowverse.control.library") {
            ControlWidgetButton(action: AddFromPhotos()) {
                Label { Text(PocketCatControlCopy.library) } icon: { Image(PocketCatControlFace.library.symbol) }
            }
        }
        .displayName(PocketCatControlCopy.library)
        .description(LocalizedStringResource("Opens Meowverse to choose photos for your cat’s home.", table: "PocketCat"))
    }
}

/// Title case in English, like the Home Screen quick actions with the same names.
private enum PocketCatControlCopy {
    static let company = PocketCatControlFace.company.title
    /// The toggle's state, as the flashlight shows On / Off.
    static let on = LocalizedStringResource("Keeping company", table: "PocketCat")
    static let off = LocalizedStringResource("Not keeping company", table: "PocketCat")
    static let camera = PocketCatControlFace.camera.title
    static let library = PocketCatControlFace.library.title
}
