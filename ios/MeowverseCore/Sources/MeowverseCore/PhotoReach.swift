/// Where the copies Meowverse keeps of the user's photos can go, or have gone, besides this device.
///
/// Meowverse has no server of its own. The only uploads are into the user's own iCloud, and
/// only after the user turned one of two things on: "Back Up to iCloud Drive" (free, on in
/// shipped builds) puts backups with every photo into their iCloud Drive; iCloud sync sends the
/// copies through CloudKit to their other devices. A sentence that promises photos stay on the
/// device picks its wording from this, never from one switch alone: the guide and the photo
/// intro used to ask only about sync and told a user with backup on that nothing is uploaded
/// (round 12 audit, PRIVACY-4 / PRODUCT-8).
///
/// Turning a switch off stops uploads but deletes nothing in iCloud unless the user asked: backups
/// kept on "stop", and the home sync left there. With both off, those are named too (QA of task
/// E). Whether they are still there is the last fact known on this device, not a fresh look.
public enum PhotoReach: Equatable, Sendable, CaseIterable {
    /// Neither is on and nothing is known to be left in iCloud: the photos stay on this device
    /// (device backups made by the system aside).
    case thisDeviceOnly
    case iCloudDriveBackup
    case iCloudSync
    case backupAndSync
    /// Both off; backups this device made are still in iCloud Drive.
    case offWithBackupsLeft
    /// Both off; what sync stored is still in iCloud (sync was turned off, not the home deleted).
    case offWithSyncDataLeft
    case offWithBothLeft

    public init(backupOn: Bool, syncOn: Bool, backupsLeft: Bool = false, syncDataLeft: Bool = false) {
        switch (backupOn, syncOn) {
        case (true, false): self = .iCloudDriveBackup
        case (false, true): self = .iCloudSync
        case (true, true): self = .backupAndSync
        case (false, false):
            switch (backupsLeft, syncDataLeft) {
            case (false, false): self = .thisDeviceOnly
            case (true, false): self = .offWithBackupsLeft
            case (false, true): self = .offWithSyncDataLeft
            case (true, true): self = .offWithBothLeft
            }
        }
    }

    /// Whether this device's backups are still in iCloud Drive. `listedOwnBackups` is how many
    /// of them the last listing of the account they go to found, nil when there is no such
    /// listing (signed out, another account, not listed yet, the listing failed). Without one,
    /// `lastBackupKept`: this device made a backup and the app has not deleted it since.
    public static func backupsLeft(listedOwnBackups: Int?, lastBackupKept: Bool) -> Bool {
        if let listedOwnBackups { return listedOwnBackups > 0 }
        return lastBackupKept
    }

    /// Only then may a screen say Meowverse's copies are nowhere but here.
    public var staysOnThisDevice: Bool { self == .thisDeviceOnly }
    public var backsUpToICloudDrive: Bool { self == .iCloudDriveBackup || self == .backupAndSync }
    public var syncsThroughICloud: Bool { self == .iCloudSync || self == .backupAndSync }
    /// Nothing is uploaded any more, but earlier copies are still in the user's iCloud.
    public var copiesLeftInICloud: Bool {
        self == .offWithBackupsLeft || self == .offWithSyncDataLeft || self == .offWithBothLeft
    }
}
