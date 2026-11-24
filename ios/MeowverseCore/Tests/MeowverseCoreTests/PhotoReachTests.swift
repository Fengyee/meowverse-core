import Testing
@testable import MeowverseCore

/// Which privacy promise a screen may make about the photos (round 12 audit PRIVACY-4,
/// PRODUCT-8, and QA of task E): "never uploaded" only while neither iCloud backup nor iCloud
/// sync is on and nothing is known to be left in iCloud; each switch that is on is named, and
/// with both off, whatever an earlier switch left in iCloud is named.
struct PhotoReachTests {
    @Test(arguments: [false, true], [false, true])
    func eachSwitchIsNamedAndNoUploadIsPromisedOnlyWithBothOff(backupOn: Bool, syncOn: Bool) {
        let reach = PhotoReach(backupOn: backupOn, syncOn: syncOn)
        #expect(reach.backsUpToICloudDrive == backupOn)
        #expect(reach.syncsThroughICloud == syncOn)
        #expect(reach.staysOnThisDevice == (!backupOn && !syncOn))
        #expect(!reach.copiesLeftInICloud)
    }

    @Test func theSwitchStates() {
        #expect(PhotoReach(backupOn: false, syncOn: false) == .thisDeviceOnly)
        #expect(PhotoReach(backupOn: true, syncOn: false) == .iCloudDriveBackup)
        #expect(PhotoReach(backupOn: false, syncOn: true) == .iCloudSync)
        #expect(PhotoReach(backupOn: true, syncOn: true) == .backupAndSync)
        #expect(Set(PhotoReach.allCases).count == 7)
    }

    /// Both switches off, but copies went up before: stopping backup with "keep", turning sync
    /// off (by hand, by clearing this device only, or after a replace while not syncing).
    @Test(arguments: [false, true], [false, true])
    func bothOffNamesWhatIsLeftInICloud(backupsLeft: Bool, syncDataLeft: Bool) {
        let reach = PhotoReach(backupOn: false, syncOn: false, backupsLeft: backupsLeft, syncDataLeft: syncDataLeft)
        switch (backupsLeft, syncDataLeft) {
        case (false, false): #expect(reach == .thisDeviceOnly)
        case (true, false): #expect(reach == .offWithBackupsLeft)
        case (false, true): #expect(reach == .offWithSyncDataLeft)
        case (true, true): #expect(reach == .offWithBothLeft)
        }
        #expect(reach.staysOnThisDevice == (!backupsLeft && !syncDataLeft))
        #expect(reach.copiesLeftInICloud == (backupsLeft || syncDataLeft))
        #expect(!reach.backsUpToICloudDrive && !reach.syncsThroughICloud, "nothing is uploaded any more")
    }

    /// A switch that is on already says copies go to iCloud; what the other left is not a "never".
    @Test(arguments: [false, true], [false, true])
    func aSwitchThatIsOnWins(backupsLeft: Bool, syncDataLeft: Bool) {
        #expect(PhotoReach(backupOn: true, syncOn: false, backupsLeft: backupsLeft, syncDataLeft: syncDataLeft) == .iCloudDriveBackup)
        #expect(PhotoReach(backupOn: false, syncOn: true, backupsLeft: backupsLeft, syncDataLeft: syncDataLeft) == .iCloudSync)
        #expect(PhotoReach(backupOn: true, syncOn: true, backupsLeft: backupsLeft, syncDataLeft: syncDataLeft) == .backupAndSync)
    }

    /// What the backup side knows without asking iCloud: a listing of the account backups go to
    /// is the truth; without one, the last backup this device made and the app has not deleted.
    @Test func backupsLeftTrustsAUsableListingOverTheRememberedLastBackup() {
        #expect(PhotoReach.backupsLeft(listedOwnBackups: 2, lastBackupKept: false))
        #expect(!PhotoReach.backupsLeft(listedOwnBackups: 0, lastBackupKept: true), "deleted in the Files app since")
        #expect(PhotoReach.backupsLeft(listedOwnBackups: nil, lastBackupKept: true))
        #expect(!PhotoReach.backupsLeft(listedOwnBackups: nil, lastBackupKept: false))
    }
}
