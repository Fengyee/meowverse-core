import MeowverseCore
import os
import SwiftUI

@main
struct MeowverseApp: App {
    /// Only for the Home Screen quick actions, which reach the app through its scene delegate.
    @UIApplicationDelegateAdaptor private var appDelegate: QuickActionAppDelegate
    @State private var model = AppModel(options: .current)
    @State private var reminders = ReminderScheduler(options: .current)
    @State private var tour = TourCoordinator(options: .current)
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Before the tour counts this open: whether this is the library's first open decides
        // when the first icon change may come (AppIconTourHold).
        AppIconTourHold.noteLaunch()
    }

    private var app: some View {
        RootView()
            .tourHost(tour)
            .modifier(PocketCatReturn(catName: model.leadCatName))
            .modifier(AppIconFollowsCalendar())
            .modifier(ICloudBackupLifecycle())
            .modifier(ICloudSyncLifecycle())
            .modifier(RenderQualityLifecycle())
            .modifier(CatTierLifecycle())
            .modifier(PendingCaptureOffer())
            .reminderScheduling(model: model, scheduler: reminders)
            .quickActionItems(model: model)
            #if DEBUG || DRILLS
            .modifier(AddHomesDrill())
            #endif
            .environment(model)
            .environment(reminders)
            .environment(tour)
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            // Screenshots of the round-6 overlay components before they are wired (OverlayGallery).
            if let page = OverlayGallery.page {
                OverlayGallery(page: page)
            } else {
                app
            }
            #else
            app
            #endif
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            Task {
                for activity in PocketCatActivity.activities where activity.isOngoing {
                    let now = Date()
                    let state = activity.content.state
                    if state.rotation == nil { await activity.show(state.mood, at: now) }
                }
            }
        }
    }
}

/// Launch switches used by UI tests and on-device fault drills. Compiled out of Release builds
/// unless built with the DRILLS condition for profiling.
struct LaunchOptions: Sendable {
    var storeFolder = "Library"
    var resetStore = false
    var skipReminderSetup = false
    /// UI tests skip the first-run photo library explanation unless they ask for it.
    var libraryIntro = false
    var failNextSave = false
    var offerSyntheticPhoto = false
    /// Settings shows a button that feeds the backup just exported back into restore,
    /// so a UI test can do a full round trip without the system file picker.
    var backupDrill = false
    /// Settings shows a button that opens this backup file as if it had been picked.
    var backupFile: String?
    /// Settings shows a button that imports this `.meowcat` file as if it had been picked.
    var catPackFile: String?
    /// Test switch for iCloud backup: turns the feature on with a plain folder of this name
    /// (inside the app's own container) in place of iCloud Drive.
    var cloudFolder: String?
    /// Test switch: a test library (`-MeowverseStore`) uses the real iCloud Drive as well. Without
    /// it a test library leaves iCloud alone, so UI tests on a phone signed in to iCloud never
    /// see, or are offered, the real backups.
    var realICloud = false
    /// Test switch for iCloud sync: a plain folder of this name (inside the app's own container)
    /// stands in for CloudKit. Two test libraries with the same name sync with each other.
    var syncFolder: String?
    /// With `syncFolder`: the account the stand-in cloud says is signed in.
    var syncAccount = "ui"
    /// With `syncFolder`: the stand-in cloud fails like this (see `FolderSyncCloud.Fault`).
    var syncFault: String?
    /// Test switch: a test library uses real CloudKit sync too (only where `FeatureFlags.iCloudSync`
    /// is on). Without it a test library never touches CloudKit.
    var realICloudSync = false
    /// The look-alike suggestion uses `ColorGridEmbedder` instead of Vision, whose networks do
    /// not run on the simulator.
    var colorGridSimilarity = false
    /// UI tests on the colour grid: the batch rule's distance cut and the review order's radius
    /// on that stand-in's scale (`-MeowverseSuggestionDistances <cut> <radius>`). The shipped
    /// numbers are for DINOv2 prints and stay as they are.
    var suggestionDistances: (cut: Float, radius: Float)?
    /// UI tests: fewer representatives than 10, so a test can reach the end of the round.
    var representativeRound: Int?
    /// The synthetic batch button's photo count and how many different scenes they show.
    var syntheticBatch = (count: 3, scenes: 1)
    var pocketCatInterval = PocketCatRotation.standardInterval
    /// 设置 › 画质 test switches (`RenderQualityModel`): store this choice at launch, pretend
    /// the device has this many GiB of memory, pretend this thermal state.
    var qualityChoice: RenderQualityChoice?
    var qualityMemoryGiB: Double?
    var qualityThermal: ProcessInfo.ThermalState?
    /// With `qualityThermal`: it arrives this many seconds after the library is ready, as a
    /// change the system announces would, instead of at launch.
    var qualityThermalAfter: Double?
    #if DEBUG || DRILLS
    /// `-MeowverseCatTiers <ready|hang|fail|after:<秒>|live|live-kept>`: how the built-in cats'
    /// 低 downloads behave (`CatTierDrill`).
    var catTierDrill: CatTierDrill?
    #endif
    /// Test switch `-MeowverseSeveralHomes`: several rooms and cats, which 1.0 hides
    /// (`FeatureFlags.severalRoomsAndCats`). A release build never reads it.
    var severalHomes = false
    #if DEBUG || DRILLS
    /// `-MeowverseAddHomesDrill`: see `AddHomesDrill`.
    var addHomesDrill = false
    #endif
    /// Entries only test and drill builds have (owner, 2026-11-20): 「导入猫咪模型…」, which App
    /// Review reads as unfinished. `-MeowverseReleaseEntries` asks for the release look.
    var debugEntries = false
    /// "拍照" offers a stand-in camera that hands over a drawn photo with camera metadata.
    var fakeCamera = false
    /// The stand-in camera behaves as if camera access had been turned off.
    var fakeCameraDenied = false
    /// A Home Screen quick action delivered as if the app had been launched from it.
    var quickAction: String?
    /// Delivers `quickAction` this many seconds after launch instead, as if the app had been
    /// brought back from the background by it.
    var quickActionDelay: Double = 0
    /// DEBUG: seconds each synthetic batch photo takes to arrive, as a photo coming from iCloud would.
    var syntheticLoadDelay: Double = 0
    /// DEBUG: seconds every feature print takes, as on a device loading the model for the first time.
    var slowPrints: Double = 0
    /// DEBUG: the last this many synthetic photos never arrive, as a stalled iCloud request.
    var syntheticLoadHangs = 0
    /// DEBUG: this many seconds after an import starts, act as if the system ended its background
    /// task (the user stopped it from the system's progress).
    var importExpiryDrill: Double?
    /// Time limits of each photo request (`-MeowverseLoadLimits <first> <retry>` in seconds).
    var loadWatch = LoadWatch.photos

    /// Whether any iCloud backup UI or code runs at all.
    /// A shipped build only ever has the user's own library, so there this is the flag alone.
    var cloudBackupFeature: Bool {
        if cloudFolder != nil { return true }
        return FeatureFlags.iCloudBackup && (storeFolder == "Library" || realICloud)
    }

    /// Whether any iCloud sync UI or code runs at all. Off with `FeatureFlags.iCloudSync` off:
    /// no settings row, no lifecycle hook, no CloudKit. A test library needs a test switch.
    var cloudSyncFeature: Bool {
        if syncFolder != nil { return true }
        return FeatureFlags.iCloudSync && (storeFolder == "Library" || realICloudSync)
    }

    static var current: LaunchOptions {
        var options = LaunchOptions()
        #if DEBUG || DRILLS
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-MeowverseStore"), args.indices.contains(index + 1) {
            let name = args[index + 1].filter { $0.isLetter || $0.isNumber || $0 == "-" }
            if !name.isEmpty { options.storeFolder = "Test-" + name }
        }
        options.skipReminderSetup = args.contains("-MeowverseSkipReminderSetup")
        options.resetStore = args.contains("-MeowverseResetStore") && options.storeFolder != "Library"
        options.failNextSave = args.contains("-MeowverseFailNextSave")
        options.libraryIntro = args.contains("-MeowverseLibraryIntro")
        options.offerSyntheticPhoto = args.contains("-MeowverseSyntheticPhoto")
        if args.contains("-MeowverseLargeSyntheticPhoto") { SyntheticPhoto.pixelScale = 3 }
        options.backupDrill = args.contains("-MeowverseBackupDrill")
        options.severalHomes = args.contains("-MeowverseSeveralHomes")
        options.addHomesDrill = args.contains("-MeowverseAddHomesDrill")
        options.debugEntries = !args.contains("-MeowverseReleaseEntries")
        options.colorGridSimilarity = args.contains("-MeowverseColorGridSimilarity")
        if let index = args.firstIndex(of: "-MeowverseSuggestionDistances"), args.indices.contains(index + 2),
           let cut = Float(args[index + 1]), let radius = Float(args[index + 2]), cut > 0, radius > 0 {
            options.suggestionDistances = (cut, radius)
        }
        if let index = args.firstIndex(of: "-MeowverseRepresentativeRound"), args.indices.contains(index + 1),
           let round = Int(args[index + 1]), round > 0 {
            options.representativeRound = round
        }
        if let index = args.firstIndex(of: "-MeowverseSyntheticBatch"), args.indices.contains(index + 2),
           let count = Int(args[index + 1]), let scenes = Int(args[index + 2]), (1...30).contains(count), (1...3).contains(scenes) {
            options.syntheticBatch = (count, scenes)
        }
        if args.contains("-MeowverseFastPocketCat") { options.pocketCatInterval = 5 }
        options.fakeCamera = args.contains("-MeowverseFakeCamera") || args.contains("-MeowverseFakeCameraDenied")
        options.fakeCameraDenied = args.contains("-MeowverseFakeCameraDenied")
        if let index = args.firstIndex(of: "-MeowverseQuickAction"), args.indices.contains(index + 1) {
            options.quickAction = args[index + 1]
        }
        if let index = args.firstIndex(of: "-MeowverseSyntheticLoadDelay"), args.indices.contains(index + 1) {
            options.syntheticLoadDelay = Double(args[index + 1]) ?? 0
        }
        if let index = args.firstIndex(of: "-MeowverseSlowPrints"), args.indices.contains(index + 1) {
            options.slowPrints = max(0, Double(args[index + 1]) ?? 0)
        }
        if let index = args.firstIndex(of: "-MeowverseSyntheticLoadHangs"), args.indices.contains(index + 1) {
            options.syntheticLoadHangs = max(0, Int(args[index + 1]) ?? 0)
        }
        if let index = args.firstIndex(of: "-MeowverseImportExpiryDrill"), args.indices.contains(index + 1),
           let delay = Double(args[index + 1]), delay >= 0 {
            options.importExpiryDrill = delay
        }
        if let index = args.firstIndex(of: "-MeowverseLoadLimits"), args.indices.contains(index + 2),
           let first = Double(args[index + 1]), let retry = Double(args[index + 2]), first > 0, retry > 0 {
            options.loadWatch = LoadWatch(limits: [.seconds(first), .seconds(retry)])
        }
        if let index = args.firstIndex(of: "-MeowverseQuickActionDelay"), args.indices.contains(index + 1) {
            options.quickActionDelay = Double(args[index + 1]) ?? 0
        }
        if let index = args.firstIndex(of: "-MeowverseBackupFile"), args.indices.contains(index + 1) {
            options.backupFile = args[index + 1]
        }
        if let index = args.firstIndex(of: "-MeowverseCatPackFile"), args.indices.contains(index + 1) {
            options.catPackFile = args[index + 1]
        }
        if let index = args.firstIndex(of: "-MeowverseCloudFolder"), args.indices.contains(index + 1) {
            let name = args[index + 1].filter { $0.isLetter || $0.isNumber || $0 == "-" }
            if !name.isEmpty { options.cloudFolder = name }
        }
        options.realICloud = args.contains("-MeowverseRealICloud")
        if let index = args.firstIndex(of: "-MeowverseSyncFolder"), args.indices.contains(index + 1) {
            let name = args[index + 1].filter { $0.isLetter || $0.isNumber || $0 == "-" }
            if !name.isEmpty { options.syncFolder = name }
        }
        if let index = args.firstIndex(of: "-MeowverseSyncAccount"), args.indices.contains(index + 1) {
            let name = args[index + 1].filter { $0.isLetter || $0.isNumber || $0 == "-" }
            if !name.isEmpty { options.syncAccount = name }
        }
        if let index = args.firstIndex(of: "-MeowverseSyncFault"), args.indices.contains(index + 1) {
            options.syncFault = args[index + 1]
        }
        options.realICloudSync = args.contains("-MeowverseRealICloudSync")
        if let index = args.firstIndex(of: "-MeowverseQuality"), args.indices.contains(index + 1) {
            options.qualityChoice = RenderQualityChoice(rawValue: args[index + 1])
        }
        if let index = args.firstIndex(of: "-MeowverseQualityMemory"), args.indices.contains(index + 1),
           let gib = Double(args[index + 1]), gib > 0 {
            options.qualityMemoryGiB = gib
        }
        if let index = args.firstIndex(of: "-MeowverseQualityThermal"), args.indices.contains(index + 1) {
            let states: [String: ProcessInfo.ThermalState] = ["nominal": .nominal, "fair": .fair, "serious": .serious, "critical": .critical]
            options.qualityThermal = states[args[index + 1]]
        }
        if let index = args.firstIndex(of: "-MeowverseQualityThermalAfter"), args.indices.contains(index + 1),
           let delay = Double(args[index + 1]), delay >= 0 {
            options.qualityThermalAfter = delay
        }
        if let index = args.firstIndex(of: "-MeowverseCatTiers"), args.indices.contains(index + 1) {
            options.catTierDrill = CatTierDrill(args[index + 1])
        }
        #endif
        return options
    }
}

#if DEBUG || DRILLS
/// `-MeowverseAddHomesDrill`: once the library is open, asks for a room and a cat as a quick
/// action, an intent or a link would, then says what came back. The pages hide their rows, so
/// this is how a UI test reaches the refusal in `addRoom` and `addCat` themselves.
private struct AddHomesDrill: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.task(id: model.phase == .ready) {
            guard model.options.addHomesDrill, model.phase == .ready else { return }
            let room = await model.addRoom(name: "Drill"), cat = await model.addCat(name: "Drill")
            model.recoveryNotice = [room?.message ?? "room added", cat?.message ?? "cat added"].joined(separator: " ")
        }
    }
}
#endif

/// Signposts for Instruments (Points of Interest). Values are sizes and counts only.
enum Perf {
    nonisolated static let signposter = OSSignposter(subsystem: "app.meowverse", category: .pointsOfInterest)

    /// Marks a moment and records the app's current and peak memory footprint.
    nonisolated static func mark(_ name: StaticString) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let now = Double(info.phys_footprint) / 1_048_576, peak = Double(info.ledger_phys_footprint_peak) / 1_048_576
        signposter.emitEvent(name, "footprint \(now, format: .fixed(precision: 1)) MB, peak \(peak, format: .fixed(precision: 1)) MB")
    }
}
