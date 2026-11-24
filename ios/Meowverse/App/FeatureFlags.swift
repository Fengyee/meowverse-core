/// Compile-time switches for features that can be turned off as a whole.
enum FeatureFlags {
    /// iCloud Drive backup (see "iCloud 备份" in ios/README.md). On since the iCloud container
    /// was registered and the entitlement wired into the build. Set to false to remove it
    /// completely: no settings row, no restore offer, no lifecycle hook, and no call into iCloud
    /// at all, since `UbiquityBackupDestination` refuses to touch the ubiquity container. Debug
    /// builds can still run the feature on a plain test folder (`-MeowverseCloudFolder <name>`).
    nonisolated static let iCloudBackup = true
    /// Multi-device iCloud sync over CloudKit (docs/ICLOUD_SYNC.md, "iCloud 同步" in ios/README.md).
    /// Off in the repository: no settings row, no lifecycle hook, no CloudKit call. A local build
    /// turns it on with the build setting `MEOWVERSE_ICLOUD_SYNC=YES` (see ios/README.md), which
    /// sets the compilation condition `MEOWVERSE_ICLOUD_SYNC` and signs the app for CloudKit's
    /// pushes. Debug builds can run it on a plain test folder (`-MeowverseSyncFolder <name>`)
    /// either way.
    #if MEOWVERSE_ICLOUD_SYNC && !MEOWVERSE_ICLOUD_SYNC_SIGNED
    // The condition alone (a plain xcodebuild without the build setting) would sync without
    // the push entitlement and background mode: changes made elsewhere would never wake it.
    #error("Build iCloud sync with MEOWVERSE_ICLOUD_SYNC=YES (see the iCloud sync section of ios/README.md), not only the compilation condition.")
    #endif
    #if MEOWVERSE_ICLOUD_SYNC
    nonisolated static let iCloudSync = true
    #else
    nonisolated static let iCloudSync = false
    #endif
    /// Making a second room or cat. Off in 1.0 (unfinished): no entry offers it and
    /// `AppModel.addRoom` and `addCat` refuse. Rooms and cats already in a library keep working.
    /// Debug and drill builds can turn it on with `-MeowverseSeveralHomes`.
    nonisolated static let severalRoomsAndCats = false
    /// Talk to Bella (docs/TALK_TO_BELLA.md): the 2D head in the room that turns one spoken
    /// sentence into one of the cat's existing actions. Not in 1.0 (unfinished): the default build
    /// compiles none of `TalkToBella/`, so there is no head, no microphone or speech permission
    /// prompt, no usage description and no Speech or Foundation Models in the binary. A local
    /// build turns it on with the build setting `MEOWVERSE_TALK_TO_BELLA=YES` (Config.xcconfig).
    #if MEOWVERSE_TALK_TO_BELLA
    nonisolated static let talkToBella = true
    #else
    nonisolated static let talkToBella = false
    #endif
}
