import MeowverseCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                RoomOpeningView()
            case .failed:
                ContentUnavailableView {
                    Label("没能打开房间", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("喵空间没有改动已保存的照片和家具。可以再试一次。")
                } actions: {
                    Button { Task { await model.bootstrap() } } label: { Text("重试").prominentInk() }
                        .buttonStyle(.borderedProminent)
                }
                .memoryPage(.home)
            case .corruptLibrary:
                CorruptLibraryRecoveryView()
            case .needsUpdate:
                ContentUnavailableView {
                    Label("需要更新喵空间", systemImage: "arrow.down.circle")
                } description: {
                    Text("这个房间是用更新的版本保存的。照片和家具都没有被改动，更新 App 后就能打开。")
                }
                .memoryPage(.home)
            case .ready:
                RoomScreen().modifier(RoomSounds())
            }
        }
        .task { await model.bootstrap() }
        .alert("照片库", isPresented: Binding(get: { model.recoveryNotice != nil }, set: { if !$0 { model.recoveryNotice = nil } })) {
            Button("好") { model.recoveryNotice = nil }
        } message: { Text(model.recoveryNotice ?? "") }
    }
}

private struct CorruptLibraryRecoveryView: View {
    @Environment(AppModel.self) private var model
    @State private var picking = false
    @State private var copiedDiagnostics = false

    var body: some View {
        ContentUnavailableView {
            Label("没能打开房间", systemImage: "exclamationmark.triangle")
        } description: {
            Text("本机的房间记录无法读取。你可以选择一份备份，预览后再确认恢复。")
        } actions: {
            if let busy = model.backup.busy {
                ProgressView(value: busy.fraction)
                if busy.operation == .reading {
                    Button("取消") { model.cancelBackupOperation() }
                }
            } else {
                if let notice = model.backup.notice { Text(notice.text) }
                Button { picking = true } label: { Text("从备份恢复…").prominentInk() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("restore-backup")
                Button("重试") { Task { await model.bootstrap() } }
                Button("拷贝诊断信息") {
                    UIPasteboard.general.string = "Meowverse \(AppModel.appVersion) · StoreError.corruptState"
                    copiedDiagnostics = true
                }
                if copiedDiagnostics { Text(verbatim: "Meowverse \(AppModel.appVersion) · StoreError.corruptState") }
            }
        }
        .memoryPage(.home)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url): model.openBackup(at: url)
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    model.backup.notice = .init(text: String(localized: "没能打开所选文件。请重新选择备份。"), isFailure: true)
                }
            }
        }
        .sheet(isPresented: Binding(get: { model.backup.pending != nil }, set: { if !$0 { model.cancelPendingRestore() } })) {
            if let prepared = model.backup.pending { RestorePreviewView(preview: prepared.preview).memoryPage(.home) }
        }
    }
}

struct RoomScreen: View {
    @Environment(ReminderScheduler.self) private var reminders
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppModel.self) private var model
    @State private var pickerShown = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var listShown = false
    @State private var storageShown = false
    @State private var selectedStoredID: String?
    @State private var busyDetailID: String?
    @State private var interactionsShown = false
    @State private var soundShown = false
    @State private var managerPart: HomeManagerView.Part = .rooms
    /// How far the top band reaches down over the room, so cards there start below it.
    @State private var topBandHeight: CGFloat = 0
    /// How far the bottom controls reach up, so the backdrop's ornaments sit above them.
    @State private var bottomBandHeight: CGFloat = 0
    @State private var sharingRoom = false
    @State private var newsShown = false
    @State private var roomSnapshot = RoomSnapshotSource()
    @State private var framing = RoomProjection()
    @State private var overlappingItems: [PhotoFurniture] = []
    @State private var pickedFurnitureID: String?
    @State private var invitation: CatInvitation?
    /// Talk to Bella (docs/TALK_TO_BELLA.md): the head's pipeline, and its "come here" walk.
    #if MEOWVERSE_TALK_TO_BELLA
    @State private var talk = TalkToBellaController()
    #endif
    @State private var summon: CatSummon?
    /// Where the head's top is, and how low the room reaches beside it, for the br ornament (A5).
    @State private var talkHeadTop: CGFloat?
    @State private var roomTrailingBottom: CGFloat?
    @State private var playSession = RoomPlaySession()
    @State private var aboutShown = false
    @State private var emptyHelpExpanded = false
    @State private var pickerRequested = false
    @State private var placedCount = 0
    @State private var showSlowPhotoLoad = false
    @State private var edit = RoomEditMode()
    @State private var cameraShown = false
    @State private var cameraDeniedShown = false
    /// The room on a real table (AR). While it covers the room, nothing else opens behind it.
    @State private var tabletop = RoomARPresentation()
    @State private var quickAddTask: Task<Void, Never>?
    @AppStorage(InAppCamera.savesToPhotosKey) private var savesToPhotos = true
    // The theme, or before round 7 the season it upgrades (RoomTheme.resolve).
    @AppStorage(RoomTheme.defaultsKey) private var storedTheme = ""
    @AppStorage(RoomTheme.legacySeasonKey) private var legacySeason = ""
    @AppStorage("room.appearance.plainWalls") private var plainWalls = false
    @State private var dressing = false
    @State private var draftAppearance = RoomAppearance()
    @AppStorage(RoomLightingMode.defaultsKey) private var lightingMode: RoomLightingMode = .constant
    @State private var draftLighting: RoomLightingMode = .constant
    private var savedAppearance: RoomAppearance {
        RoomAppearance(theme: RoomTheme.resolve(theme: storedTheme, legacySeason: legacySeason), plainWalls: plainWalls)
    }
    @AppStorage("bella.groundGait") private var groundGait: GroundGait = .groundWalk
    @AppStorage("bella.playItem") private var selectedPlayItem: CatPlayItem = .toyMouse
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Covers the room at launch until its furniture and cat have loaded (`LaunchCover`).
    @State private var launchCover = LaunchCover.shouldShow
    /// What lifted the cover ("ready" or "timeout"), for the cover's UI test.
    @State private var launchCoverLifted: String?

    var body: some View {
        @Bindable var model = model
        ZStack {
            roomWithInspector
                .accessibilityHidden(model.importSession != nil)
                .modifier(RoomChimeTriggers(placed: placedCount, invitation: invitation?.id, playing: playSession.isActive))
            if let session = model.importSession {
                ZStack {
                    ImportFlowView(session: session) { placedCount += 1 }
                        .id(session.id)
                        .disabled(model.isPreparingImport)
                }
                .transition(reduceMotion ? .opacity : .move(edge: .bottom))
                .zIndex(1)
            }
        }
        .overlay {
            if launchCover {
                LaunchCover()
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if LaunchCover.probes, let launchCoverLifted {
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("launch-cover-probe")
                    .accessibilityLabel(Text(verbatim: launchCoverLifted))
            }
        }
        .task {
            guard launchCover else { return }
            // A room that never reports ready (art failed to load) still uncovers.
            try? await Task.sleep(for: LaunchCover.longest)
            liftLaunchCover(by: "timeout")
        }
        // Slide the review in. On dismissal remove its navigation bar with the review,
        // including the part UIKit draws outside the safe area.
        .animation(model.importSession == nil ? nil : .snappy(duration: 0.35), value: model.importSession != nil)
        .photosPicker(isPresented: $pickerShown, selection: $picked, maxSelectionCount: 100, matching: .images, preferredItemEncoding: .current,
                      photoLibrary: .shared())
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            // One photo is reviewed right away; several are stored first and sorted afterwards.
            if items.count == 1 { model.beginImport(from: items[0]) } else { model.importBatch(items) }
        }
        .overlay {
            if model.isPreparingImport, model.importSession == nil || showSlowPhotoLoad { preparingOverlay }
        }
        .task(id: model.isPreparingImport) {
            showSlowPhotoLoad = false
            guard model.isPreparingImport, model.importSession != nil else { return }
            // Fast photo changes stay in place; a slow read still offers progress and cancellation.
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            showSlowPhotoLoad = true
        }
        .sheet(item: UIDevice.current.userInterfaceIdiom == .pad ? .constant(nil) : openedBinding) { item in
            furnitureDetail(item)
        }
        .sheet(isPresented: Binding(get: { overlappingItems.count > 1 }, set: { if !$0 { overlappingItems = [] } }), onDismiss: {
            if reminders.pendingTap == nil, let id = pickedFurnitureID, model.furniture(id) != nil { model.openedFurnitureID = id }
            pickedFurnitureID = nil
        }) {
            NavigationStack {
                List(overlappingItems) { item in
                    Button {
                        pickedFurnitureID = item.instanceId
                        overlappingItems = []
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.shownName).font(.headline)
                            Text(item.roomLocation).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("overlap-item")
                }
                .memoryPage(.workshop)
                .navigationTitle("选择家具")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { overlappingItems = [] } }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .roomEditor(item: movingBinding) { item in
            MoveFurnitureView(item: item)
        }
        .roomEditor(item: restoringBinding) { item in
            RestoreFurnitureView(item: item)
        }
        .roomEditor(isPresented: $model.addFurnitureShown) {
            AddFurnitureFlowView { placedCount += 1 }
        }
        .sheet(isPresented: UIDevice.current.userInterfaceIdiom == .pad ? .constant(false) : $interactionsShown,
               onDismiss: { tabletop.openIfAsked() }) {
            interactionPanel
        }
        .sheet(isPresented: $listShown) { FurnitureListView() }
        .sheet(isPresented: $storageShown, onDismiss: {
            if reminders.pendingTap == nil, let id = selectedStoredID { model.openedFurnitureID = id }
            selectedStoredID = nil
        }) {
            StorageChestList { selectedStoredID = $0 }
        }
        // On iPad these open as popovers from the top band instead (see `topBand`).
        .sheet(isPresented: isPad ? .constant(false) : $sharingRoom) { sharePanel }
        .modifier(PhotoPickerGate(request: $pickerRequested, pickerShown: $pickerShown))
        .sheet(isPresented: $aboutShown, onDismiss: openCatsAfterSettings) { SettingsView() }
        .sheet(isPresented: $model.photos.libraryShown) { PhotoLibraryView() }
        .sheet(isPresented: isPad ? .constant(false) : $model.home.managerShown) { HomeManagerView(part: managerPart, playing: playSession.isActive) }
        .sheet(isPresented: isPad ? .constant(false) : $soundShown) { RoomSoundPanel() }
        .modifier(RoomNewsSheet(shown: $newsShown, isPad: isPad))
        .onChange(of: model.roomFurniture.map(\.instanceId)) {
            if let id = playSession.windUpMouseID, !model.roomFurniture.contains(where: { $0.instanceId == id }) {
                playSession.end()
            }
        }
        // Another room: nothing that pointed into the old one carries over.
        .onChange(of: model.currentRoomId) {
            edit.end()
            playSession.end()
            framing = RoomProjection()
            model.openedFurnitureID = nil
            interactionsShown = false
            pickedFurnitureID = nil
            overlappingItems = []
            invitation = nil
            summon = nil
            #if MEOWVERSE_TALK_TO_BELLA
            talk.cancel()
            #endif
        }
        #if MEOWVERSE_TALK_TO_BELLA
        .modifier(TalkToBellaLifecycle(talk: talk, accepting: talkToBellaAccepting, playing: playSession.isActive))
        #endif
        .alert("没能导入", isPresented: failureBinding) {
            Button("好") {}
        } message: {
            Text(model.importFailure ?? "")
        }
        .alert("已恢复到上一次保存的房间", isPresented: $model.restoredNotice) {
            Button("好") {}
        } message: {
            Text("上次保存没有完成。之前的家具和照片都在；如果最后一次改动不见了，请再做一次。")
        }
        .alert("导入照片", isPresented: Binding(get: { model.batch.notice != nil }, set: { if !$0 { model.batch.notice = nil } })) {
            Button("好") {}
        } message: {
            Text(model.batch.notice ?? "")
        }
        .sensoryFeedback(.success, trigger: placedCount)
        .sensoryFeedback(.success, trigger: model.batch.importedCount)
        .sensoryFeedback(.impact(weight: .light), trigger: model.openedFurnitureID) { _, opened in opened != nil }
        .sensoryFeedback(.impact(weight: .medium), trigger: invitation?.id)
        .sensoryFeedback(.impact(weight: .medium), trigger: playSession.isActive) { _, active in active }
        .sensoryFeedback(.error, trigger: model.importFailure) { _, failure in failure != nil }
        .environment(\.roomAppearance, dressing ? draftAppearance : savedAppearance)
        .environment(\.roomBackdropBands, backdropBands)
        .roomLighting(mode: dressing ? draftLighting : lightingMode)
        .onChange(of: reminders.pendingTap, initial: true) { openReminderIfReady() }
        .onChange(of: canOpenReminder) { openReminderIfReady() }
        .fullScreenCover(isPresented: $cameraShown) {
            CameraScreen { shot in
                cameraShown = false
                importShot(shot)
            } onCancel: {
                cameraShown = false
            }
        }
        .modifier(RoomARCover(state: $tabletop, appearance: savedAppearance, lighting: lightingMode))
        .alert("无法打开相机", isPresented: $cameraDeniedShown) {
            if let settings = URL(string: UIApplication.openSettingsURLString) {
                Button("打开系统设置") { UIApplication.shared.open(settings) }
            }
            Button("从相册选择") { whenNothingIsPresented { pickerRequested = true } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("相机权限已关闭。请在系统设置里允许喵空间使用相机，或从相册选择照片。")
        }
        .onChange(of: QuickActionCenter.shared.pending, initial: true) { handleQuickAction() }
        .onChange(of: scenePhase) { handleQuickAction() }
        .modifier(RoomTourFacts(facts: TourRoomFacts(busy: roomBusyWith, sentCat: invitation?.id,
                                                 panelOpen: interactionsShown, playing: playSession.isActive,
                                                 editing: edit.isActive, zoomed: framing.isZoomed,
                                                 receiptShown: model.photos.storageReceipt != nil,
                                                 pickingPhotos: pickerShown || pickerRequested,
                                                 onTabletop: tabletop.covering),
                                 framing: $framing))
    }

    // MARK: Camera and Home Screen quick actions

    private func openCamera() {
        if InAppCamera.isDenied { cameraDeniedShown = true } else { cameraShown = true }
    }

    private func importShot(_ shot: InAppCamera.Shot) {
        model.beginCapturedImport(saveToPhotos: savesToPhotos ? InAppCamera.saveToPhotos : nil) {
            try InAppCamera.encode(shot)
        }
    }

    /// Work that a quick action to add photos must not throw away. Playing with the cat is not.
    private var addingPhotosWouldInterrupt: Bool {
        model.importSession != nil || model.isPreparingImport || model.batch.progress != nil || model.batch.sortingTotal != nil
            || model.photos.addTask != nil || edit.isActive || dressing || model.addFurnitureShown
            || model.movingFurnitureID != nil || model.restoringFurnitureID != nil || busyDetailID != nil
            || model.backup.busy != nil || model.backup.pending != nil || isReadingCloudBackup || model.switchingLibraries
            || model.restoredNotice || model.recoveryNotice != nil
            || QuickActionCenter.shared.hasUnsentWork
    }

    /// Getting an iCloud backup ready to restore. An automatic backup running by itself is not in the way.
    private var isReadingCloudBackup: Bool {
        if case .downloading = model.cloud.activity { return true }
        return false
    }

    /// Runs a quick action once the room is showing and the app is in front. The room exists
    /// only after the library has loaded, so a cold launch waits for that by itself.
    private func handleQuickAction() {
        guard scenePhase == .active, let request = QuickActionCenter.shared.pending else { return }
        QuickActionCenter.shared.pending = nil
        switch request.kind {
        case .companion:
            QuickActionCenter.shared.companionRequest = UUID()
        case .memory:
            // Chosen now, never shown on the Home Screen. A sorting session or an open review
            // keeps navigation until it ends, as for a reminder.
            var generator = SystemRandomNumberGenerator()
            let id = QuickActionPlan.pickMemory(from: QuickActionPlan.memoryCandidates(in: model.state), using: &generator)
            reminders.pendingTap = .init(destination: id.map(ReminderScheduler.Destination.furniture) ?? .room)
        case .camera, .library:
            quickAdd(camera: request.kind == .camera)
        }
    }

    /// Pages without unsaved work are closed to get back to the room; otherwise nothing moves
    /// and one line says why. Nothing is queued to open later.
    private func quickAdd(camera: Bool) {
        let alreadyOpen = camera ? cameraShown : pickerShown || pickerRequested
        if alreadyOpen { return }
        guard !cameraShown, !addingPhotosWouldInterrupt else {
            TransientNotice.show(String(localized: "先完成或停止正在进行的事，再添加照片。"))
            return
        }
        guard !camera || InAppCamera.isAvailable else { return }
        // `pending` is cleared before the tour looks: told here, it takes its own page away with no
        // ending, before the dismissal below would read as a swipe to skip (QA, page mode at 3.1).
        TourOutside.arrived()
        selectedStoredID = nil
        pickedFurnitureID = nil
        overlappingItems = []
        aboutShown = false
        listShown = false
        storageShown = false
        sharingRoom = false
        newsShown = false
        interactionsShown = false
        soundShown = false
        pickerShown = false
        pickerRequested = false
        model.photos.libraryShown = false
        model.openedFurnitureID = nil
        model.home.managerShown = false
        model.importFailure = nil
        model.batch.notice = nil
        invitation = nil
        playSession.end()
        whenNothingIsPresented(dismissingLeftovers: true) {
            guard !addingPhotosWouldInterrupt else { return }
            if camera { openCamera() } else { pickerRequested = true }
        }
    }

    /// Two overlapping presentations break, so wait for closing pages and alerts to slide
    /// away first. With `dismissingLeftovers`, anything still up after a second (the companion
    /// screen, which SwiftUI does not track) is dismissed directly. Only what was up when this
    /// began is a leftover: a page that came up during the wait is newer than the request, so
    /// it stays and the request is dropped (L24-06).
    private func whenNothingIsPresented(dismissingLeftovers: Bool = false, _ body: @escaping () -> Void) {
        quickAddTask?.cancel()
        quickAddTask = Task {
            weak var leftover = Self.rootController?.presentedViewController
            for attempt in 0..<30 {
                guard let root = Self.rootController, let presented = root.presentedViewController else { break }
                if presented !== leftover, !presented.isBeingDismissed { return }
                if dismissingLeftovers, attempt == 10, !presented.isBeingDismissed { root.dismiss(animated: true) }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            body()
        }
    }

    private static var rootController: UIViewController? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
    }

    /// A sorting session owns navigation even during the pause between photos.
    private var canOpenReminder: Bool {
        scenePhase == .active && !model.isPreparingImport && model.importSession == nil
            && model.batch.sortingTotal == nil
            && !pickerShown && !pickerRequested && !aboutShown && !listShown && !storageShown
            && !sharingRoom && !soundShown && !newsShown && overlappingItems.isEmpty && pickedFurnitureID == nil && selectedStoredID == nil
            && !interactionsShown && !dressing && !edit.isActive
            && !model.photos.libraryShown && !model.addFurnitureShown && !model.home.managerShown
            && model.movingFurnitureID == nil && model.restoringFurnitureID == nil
            && (busyDetailID == nil || busyDetailID != model.openedFurnitureID)
            && model.importFailure == nil && model.batch.notice == nil && !model.restoredNotice
            && !cameraShown && !cameraDeniedShown && !tabletop.covering
    }

    /// Nothing over the room and nothing in progress: the tour may begin (TECH_DESIGN §5.2, Q-09).
    /// Wider than `canOpenReminder`, which allows a piece's detail to be open (a reminder may
    /// switch to another piece) and does not look at play. On iPad the detail and 互动 are a
    /// column beside the room, not a presented page, so they are named here.
    ///
    /// nil: free. Otherwise what it is busy with, in a word for the tour's log. Only what is in
    /// progress belongs here: `invitation` is the last request, never cleared, and counting it
    /// left the room busy for the rest of the process (2026-11-21).
    private var roomBusyWith: String? {
        if playSession.isActive { return "play" }
        if edit.isActive { return "editing" }
        if dressing { return "dressing" }
        if tabletop.covering { return "tabletop" }
        if interactionsShown { return "play panel" }
        if aboutShown { return "settings" }
        if pickerShown || pickerRequested { return "photo picker" }
        if model.openedFurnitureID != nil || busyDetailID != nil { return "a piece" }
        if model.movingFurnitureID != nil { return "moving a piece" }
        if reminders.pendingTap != nil { return "a reminder tap" }
        if model.importSession != nil || model.isPreparingImport || model.batch.progress != nil
            || model.batch.sortingTotal != nil || model.photos.addTask != nil { return "photos" }
        if model.backup.busy != nil || model.backup.pending != nil || model.cloud.restoreSheetShown
            || isReadingCloudBackup || model.switchingLibraries { return "backup or restore" }
        if model.recoveryNotice != nil || model.importFailure != nil || model.batch.notice != nil
            || model.restoredNotice { return "a notice" }
        return canOpenReminder ? nil : "another page"
    }

    private func openReminderIfReady() {
        guard canOpenReminder, let tap = reminders.pendingTap else { return }
        reminders.pendingTap = nil
        interactionsShown = false
        switch tap.destination {
        case .room: model.openedFurnitureID = nil
        case .furniture(let id): model.openedFurnitureID = model.anyFurniture(id)?.instanceId
        }
    }

    @ViewBuilder
    private var roomWithInspector: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            GeometryReader { geometry in
                let width = geometry.size.width
                let isWide = RoomColumns.fits(in: width)
                let selected = model.anyFurniture(model.openedFurnitureID)
                let dockedEdit = isWide && edit.isActive
                let hasInspector = selected != nil || interactionsShown || dockedEdit
                let roomVisible = !hasInspector || isWide
                let inspectorWidth = isWide ? RoomColumns.inspectorWidth(in: width) : width
                ZStack(alignment: .trailing) {
                    roomStack
                        .frame(width: hasInspector ? width - inspectorWidth : width)
                        .clipped()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .environment(\.roomInspectorCoversScene, hasInspector && !isWide)
                        .environment(\.hasSideEditTray, dockedEdit)
                        .allowsHitTesting(roomVisible)
                        .accessibilityHidden(!roomVisible)
                    if hasInspector {
                        Group {
                            if dockedEdit {
                                ScrollView { RoomEditTray(edit: edit) }
                            } else if interactionsShown {
                                interactionPanel
                            } else if let selected {
                                furnitureDetail(selected).id(selected.instanceId)
                            }
                        }
                        .frame(width: inspectorWidth)
                        .accessibilityAddTraits(isWide ? [] : .isModal)
                        .background((dockedEdit ? RoomPaper.paper : Color(.systemBackground)).ignoresSafeArea())
                        .overlay(alignment: .leading) {
                            if isWide { Rectangle().fill(.separator).frame(width: 1).accessibilityHidden(true) }
                        }
                    }
                }
                // roomStack is clipped to its column, which also cuts its full-bleed backdrop back to
                // the safe area; this one fills the screen edges behind it.
                .background { RoomBackdrop(ornaments: false).accessibilityHidden(true) }
                .onChange(of: interactionsShown) { _, open in
                    if open { model.openedFurnitureID = nil }
                }
                .onChange(of: model.openedFurnitureID) { _, id in
                    if id != nil { interactionsShown = false }
                }
                .onChange(of: edit.isActive) { _, active in
                    if active {
                        model.openedFurnitureID = nil
                        interactionsShown = false
                    }
                }
            }
        } else {
            roomStack
        }
    }

    private func furnitureDetail(_ item: PhotoFurniture) -> some View {
        FurnitureDetailView(instanceId: item.instanceId, busyDetailID: $busyDetailID) {
            if model.openedFurnitureID == item.instanceId { model.openedFurnitureID = nil }
        }
    }

    private var interactionPanel: some View {
        InteractionPicker(invite: { item, site, action in
            if item.modelId == "mv-toy-d", action == .play {
                invitation = nil
                playSession.windUp(item)
            } else {
                playSession.end()
                invitation = CatInvitation(itemId: item.instanceId, siteId: site.id, action: action)
            }
            interactionsShown = false
        }, play: { item in
            selectedPlayItem = item
            playSession.begin(item)
            interactionsShown = false
        }, selectedPlayItem: selectedPlayItem, onClose: { interactionsShown = false }, openTabletop: {
            // On iPad 互动 is a column beside the room, not a sheet that has to go first.
            tabletop.ask(afterSheet: !isPad)
            interactionsShown = false
        })
    }

    private var roomStack: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                // The room's 3D view goes while 放到桌上看看 is open: with a non-AR view alive, the
                // AR page drew no camera picture on the owner's iPhone (iOS 27.2). It comes back
                // when the AR page has gone.
                if tabletop.covering {
                    Color.clear
                } else {
                    room
                        .allowsHitTesting(!dressing)
                        .accessibilityHidden(dressing)
                }
                VStack(spacing: 0) {
                    if typeSize.isAccessibilitySize && !edit.isActive && !dressing && model.importSession == nil {
                        roomCaption.padding(.top, 6)
                    }
                    if model.roomFurniture.isEmpty && !playSession.isActive && !dressing && model.importSession == nil {
                        emptyHint.modifier(TourHoldsRoomGuide())
                    }
                }
                .padding(.top, showsTopBand ? topBandHeight : 0)
            }
            .overlay(alignment: .top) {
                if showsTopBand {
                    topBand.transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showsTopBand)
            .overlay(alignment: .bottom) {
                if !edit.isActive && !dressing && model.importSession == nil {
                    // The head sits right above the controls; they and the play tray below keep their places.
                    VStack(alignment: .trailing, spacing: 6) {
                        #if MEOWVERSE_TALK_TO_BELLA
                        if talkToBellaShown { talkToBellaHead }
                        #endif
                        roomControls
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if dressing {
                    RoomAppearanceEditor(appearance: $draftAppearance, lighting: $draftLighting) {
                        dressing = false
                    } save: {
                        storedTheme = draftAppearance.theme.rawValue
                        if let season = draftAppearance.theme.legacySeason { legacySeason = season }
                        plainWalls = draftAppearance.plainWalls
                        lightingMode = draftLighting
                        dressing = false
                    }
                } else {
                    VStack(spacing: 0) {
                        if playSession.isActive {
                            RoomPlayTray(session: playSession, placeNext: {
                                guard let catalog = model.catalog else { return }
                                playSession.placeNext(items: model.roomFurniture, catalog: catalog)
                            }, change: { interactionsShown = true })
                        }
                        ImportQueueBar()
                    }
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                    .replacedByEditTray(edit)
                }
            }
            .background { RoomBackdrop().accessibilityHidden(true) }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    /// Editing a piece, dressing the room and reviewing an import bring their own controls.
    private var showsTopBand: Bool {
        !edit.isActive && !dressing && model.importSession == nil
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private var sharePanel: some View {
        RoomShareSheet(defaultTitle: model.roomName(model.currentRoom), source: roomSnapshot)
    }

    private var topBand: some View {
        RoomTopBar(playing: playSession.isActive, perform: openTopAction,
                   popover: { isPad ? popoverBinding($0) : nil }, panel: popoverPanel)
            .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .local).maxY }) { topBandHeight = $0 }
    }

    private func popoverBinding(_ action: RoomTopAction) -> Binding<Bool>? {
        @Bindable var model = model
        switch action {
        case .settings, .theme: return nil
        case .sound: return $soundShown
        case .share: return $sharingRoom
        case .news: return $newsShown
        case .rooms, .cats:
            let part: HomeManagerView.Part = action == .rooms ? .rooms : .cats
            return Binding(get: { model.home.managerShown && managerPart == part },
                           set: { if !$0 { model.home.managerShown = false } })
        }
    }

    private func popoverPanel(_ action: RoomTopAction) -> AnyView {
        switch action {
        case .sound: AnyView(RoomSoundPanel())
        case .share: AnyView(sharePanel)
        case .news: AnyView(RoomNewsPanel())
        case .rooms: AnyView(HomeManagerView(part: .rooms))
        case .cats: AnyView(HomeManagerView(part: .cats, playing: playSession.isActive))
        case .settings, .theme: AnyView(EmptyView())
        }
    }

    /// 设置's 「猫咪的名字和模型」 row asked for 猫咪管理. Opened once 设置 is fully gone, so the
    /// two sheets never overlap; any other way of closing 设置 leaves the flag unset.
    private func openCatsAfterSettings() {
        guard model.home.catsAfterSettings else { return }
        model.home.catsAfterSettings = false
        openTopAction(.cats)
    }

    private func openTopAction(_ action: RoomTopAction) {
        switch action {
        case .settings: aboutShown = true
        case .theme:
            draftAppearance = savedAppearance
            draftLighting = lightingMode
            dressing = true
        case .sound: soundShown = true
        case .share: sharingRoom = true
        case .news: newsShown = true
        case .rooms, .cats:
            // Both pages stay while several rooms and cats are hidden: names and the cat model
            // are changed there.
            managerPart = action == .rooms ? .rooms : .cats
            model.home.managerShown = true
        }
    }

    private func liftLaunchCover(by reason: String = "ready") {
        guard launchCover else { return }
        LaunchCover.shouldShow = false
        launchCoverLifted = reason
        withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 0.45)) { launchCover = false }
    }

    private var room: some View {
        GeometryReader { geometry in
            let projection = edit.isActive ? RoomProjection() : framing
            let ghost = edit.ghost(in: model)
            RoomSceneView(
                items: model.roomFurniture,
                ghost: ghost,
                onTapFurniture: { model.openedFurnitureID = $0 },
                onTapCell: nil,
                groundGait: groundGait,
                invitation: invitation,
                summon: summon,
                playSession: playSession,
                framing: projection,
                snapshotSource: roomSnapshot,
                onCameraChange: edit.isActive || model.importSession != nil || model.isPreparingImport ? nil : { scale, anchor, pan in
                    framing.adjust(scale: scale, anchor: anchor, pan: pan, in: geometry.size)
                },
                showsStorageChest: !edit.isActive,
                cats: model.roomCats,
                onSceneReady: { liftLaunchCover() },
                seeThrough: true
            )
            .id(model.currentRoomId)
            .accessibilityHidden(true)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { roomTrailingBottom = Self.roomTrailingBottom(in: $0) }
            .overlay {
                if let ghost, !ghost.accessCells.isEmpty {
                    PlacementAccessGuides(cells: ghost.accessCells, projection: projection)
                }
            }
            .overlay {
                FurnitureHotspots(framing: projection, edit: edit, noticeTop: showsTopBand ? topBandHeight : 0) { matches in
                    if matches.count > 1 {
                        overlappingItems = matches
                    } else if let item = matches.first {
                        model.openedFurnitureID = item.instanceId
                    }
                }
                .allowsHitTesting(!playSession.isActive)
            }
            .overlay(alignment: .topLeading) {
                if !edit.isActive {
                    storageHotspot(in: geometry.size, projection: projection)
                }
            }
            .tourSceneAnchors(projection, pieces: model.roomFurniture, catalog: model.catalog)
            .clipped()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(roomLabel)
            .accessibilityValue(Wording.phrases([model.roomCaption] + otherCatsLine
                                                + (reduceMotion ? [String(localized: "减弱动态效果已开启")] : [])))
            .accessibilityZoomAction { action in
                guard !edit.isActive else { return }
                framing.adjust(scale: action.direction == .zoomIn ? 1.5 : 1 / 1.5, anchor: action.point, in: geometry.size)
            }
            .accessibilityScrollAction { edge in
                guard !edit.isActive, framing.isZoomed else { return }
                var delta = CGSize.zero
                switch edge {
                case .leading: delta.width = geometry.size.width / 3
                case .trailing: delta.width = -geometry.size.width / 3
                case .top: delta.height = geometry.size.height / 3
                case .bottom: delta.height = -geometry.size.height / 3
                }
                framing.adjust(pan: delta, in: geometry.size)
            }
            .accessibilityIdentifier("room-world")
            .onChange(of: geometry.size) { _, size in framing.adjust(in: size) }
            .onChange(of: model.pieces.locateTick) {
                guard framing.isZoomed, let item = model.furniture(model.pieces.located) else { return }
                let size = geometry.size
                let rect = framing.screenRect(for: item, catalog: model.catalog, in: size)
                if !CGRect(origin: .zero, size: size).contains(rect) {
                    framing.adjust(pan: CGSize(width: size.width / 2 - rect.midX,
                                               height: size.height / 2 - rect.midY), in: size)
                }
            }
        }
    }

    @ViewBuilder
    private func storageHotspot(in size: CGSize, projection: RoomProjection) -> some View {
        let viewport = CGRect(origin: .zero, size: size)
        let visible = projection.storageChestRect(in: size).intersection(viewport)
        if !visible.isEmpty {
            let target = visible.insetBy(dx: min(0, (visible.width - 44) / 2),
                                         dy: min(0, (visible.height - 44) / 2)).intersection(viewport)
            Button { storageShown = true } label: {
                Color.clear
                    .frame(width: target.width, height: target.height)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("收纳箱")
            .accessibilityIdentifier("room-storage")
            .accessibilityShowsLargeContentViewer { Label("收纳箱", systemImage: "archivebox") }
            .offset(x: target.minX, y: target.minY)
        }
    }

    /// The cats in the room besides the one the caption follows, for VoiceOver.
    private var otherCatsLine: [String] {
        let others = model.roomCats.dropFirst().map(\.name)
        return others.isEmpty ? [] : [String(localized: "一起在房间里的还有\(others.formatted(.list(type: .and).locale(AppLanguage.locale)))")]
    }

    private var roomLabel: String {
        let count = model.roomFurniture.count
        guard let lead = model.leadCat else {
            return count == 0 ? String(localized: "空房间") : String(localized: "\(model.roomName(model.currentRoom))，有 \(count) 件家具")
        }
        let name = Wording.subject(lead.name)
        return count == 0 ? String(localized: "\(name)坐在空房间里") : String(localized: "\(model.roomName(model.currentRoom))，有 \(count) 件家具")
    }

    private var usesCollapsibleHint: Bool { Self.foldsEmptyHint(at: typeSize) }

    /// From this size the empty room's card is folded, its buttons inside (the tour asks, for 3.1).
    static func foldsEmptyHint(at size: DynamicTypeSize) -> Bool { size >= .xxxLarge }

    @ViewBuilder private var emptyHint: some View {
        if usesCollapsibleHint {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    Button { emptyHelpExpanded.toggle() } label: {
                        HStack {
                            Text("空房间").font(.headline)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Image(systemName: emptyHelpExpanded ? "chevron.up" : "chevron.down")
                                .font(.body.weight(.semibold)).accessibilityHidden(true)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("展开或收起房间说明")
                    .accessibilityIdentifier("empty-room-help")
                    if emptyHelpExpanded {
                        ScrollView {
                            emptyHintContent.fixedSize(horizontal: false, vertical: true)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(maxHeight: max(120, geometry.size.height - 235))
                    }
                }
                .roomPaper(corner: RoomPaper.cardCorner)
                .padding()
            }
        } else {
            emptyHintContent
                .roomPaper(corner: RoomPaper.cardCorner)
                .padding()
        }
    }

    private var emptyHintContent: some View {
        VStack(spacing: 6) {
            if !usesCollapsibleHint {
                HStack(spacing: 9) {
                    Image(systemName: "leaf.fill").scaleEffect(x: -1).accessibilityHidden(true)
                    Text("房间还是空的").font(.system(.headline, design: .rounded, weight: .semibold))
                    Image(systemName: "leaf.fill").accessibilityHidden(true)
                }
                .font(.caption2)
                .foregroundStyle(RoomPaper.ink)
                .accessibilityElement(children: .combine)
            }
            Text("选一张\(Wording.inline(model.leadCatName))的照片，照片里的家具会搬进来。")
                .font(.subheadline)
                .foregroundStyle(Color.subtle)
                .multilineTextAlignment(.center)
            // Side by side, or stacked once the text is too large for one line.
            Group {
                if usesCollapsibleHint {
                    VStack(spacing: 6) { emptyHintActions }
                } else {
                    // English at xxL does not fit side by side on the SE and was cut to "Place furniture…".
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 20) { emptyHintActions }
                        VStack(spacing: 0) { emptyHintActions }
                    }
                }
            }
            .font(.subheadline.weight(.medium))
            .padding(.top, 2)
            // Nothing unless iCloud backup is switched on and iCloud Drive holds a backup.
            ICloudRestoreOffer()
        }
        .padding()
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var emptyHintActions: some View {
        Button { model.addFurnitureShown = true } label: {
            Text("先摆家具").frame(minHeight: 44)
        }
            .tourAnchor("place-furniture-first")
            .accessibilityHint("从款式里选一件摆进房间，先不带照片")
            .accessibilityIdentifier("place-furniture-first")
        // The tour's opening from chapter 1, in place of the old three-step guide (PRODUCT_PLAN
        // §4.2, §4.3). Same words and identifier. A test library without `-MeowverseTour` has no
        // tour, and the button does nothing there.
        Button { TourReplayEntry.askOpening() } label: {
            Text("看看怎么玩").frame(minHeight: 44)
        }
            .accessibilityIdentifier("open-guide")
    }

    private var roomControls: some View {
        VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    #if DEBUG || DRILLS
                    if model.options.offerSyntheticPhoto && !playSession.isActive {
                        // The batch was in the room's old "⋯" menu.
                        HStack(spacing: 6) {
                            Button("合成照片") {
                                model.beginImport(filename: "synthetic.jpg") { SyntheticPhoto.jpeg() }
                            }
                            .accessibilityIdentifier("add-synthetic")
                            Button("合成三张照片") {
                                let batch = model.options.syntheticBatch, delay = model.options.syntheticLoadDelay
                                let hangs = model.options.syntheticLoadHangs
                                model.importBatch(loaders: (0..<batch.count).map { index in
                                    {
                                        if index >= batch.count - hangs { await SyntheticPhoto.neverArrives() }
                                        try await SyntheticPhoto.slowly(delay)
                                        return SyntheticPhoto.jpeg(variant: 20 + index, scene: index % batch.scenes)
                                    }
                                })
                            }
                            .accessibilityIdentifier("add-synthetic-batch")
                        }
                        .font(.footnote).buttonStyle(.bordered)
                    }
                    #endif
                    RoomLibraryControls(photos: { model.photos.libraryShown = true }, furniture: { listShown = true })
                }
                Spacer(minLength: 0)
                // 互动 stays open with no cat: its panel then offers keeping you company.
                RoomActionControls(hasCat: true, canAdd: model.batch.progress == nil,
                                   interact: { interactionsShown = true }, addPhoto: { pickerRequested = true },
                                   takePhoto: InAppCamera.isAvailable ? { openCamera() } : nil)
            }
            .padding(.horizontal, 12)
            if !typeSize.isAccessibilitySize { roomCaption }
        }
        .padding(.bottom, 2)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { bottomBandHeight = $0 }
    }

    private var roomCaption: some View {
        BellaCaptionView().dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    // MARK: Talk to Bella

    /// The head shows with a cat in the room, and not while a piece is edited, the room is
    /// dressed, a photo is being read or reviewed, or the room is on a table (AR).
    private var talkToBellaShown: Bool {
        FeatureFlags.talkToBella && model.leadCat != nil && !edit.isActive && !dressing
            && model.importSession == nil && !model.isPreparingImport && !tabletop.covering
    }

    /// Whether an answer may still reach the room. Opening 互动 or a piece, or leaving the
    /// room, drops a request on its way: what the person does by hand wins.
    private var talkToBellaAccepting: Bool {
        talkToBellaShown && scenePhase == .active && !interactionsShown && model.openedFurnitureID == nil
    }

    #if MEOWVERSE_TALK_TO_BELLA
    private var talkToBellaHead: some View {
        // Not over 「房间还是空的」: the "tap me" line waits until the room has something in it.
        TalkToBellaHead(talk: talk, catName: model.leadCatName, canIntroduce: !model.roomFurniture.isEmpty || playSession.isActive) {
            talk.tap(room: {
                guard talkToBellaAccepting, let catalog = model.catalog else { return nil }
                return .init(id: model.currentRoomId, items: model.roomFurniture, catalog: catalog, catName: model.leadCatName)
            }, apply: carryOut, openMenu: { interactionsShown = true })
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minY }) { talkHeadTop = $0 }
        .padding(.horizontal, 12)
    }
    #endif

    private var backdropBands: RoomBackdropBands? {
        guard topBandHeight > 0, bottomBandHeight > 0 else { return nil }
        return RoomBackdropBands(top: topBandHeight, bottom: bottomBandHeight,
                                 headTop: talkToBellaShown ? talkHeadTop : nil, roomTrailingBottom: roomTrailingBottom)
    }

    /// The lowest global y the room's floor (with its edge) and the storage chest reach in the
    /// right-hand ornament column, at the overview framing the room opens with.
    private static func roomTrailingBottom(in frame: CGRect) -> CGFloat? {
        let size = frame.size
        guard size.width > 0, size.height > 0 else { return nil }
        var projection = RoomProjection()
        projection.adjust(in: size)
        let column = size.width - RoomThemeBackdrop.ornamentSide(in: size) - 8
        let half = Float(GridRules.size) / 2
        let corners: [SIMD2<Float>] = [[-half, -half], [half, -half], [half, half], [-half, half]]
        var lowest: CGFloat?
        for (index, start) in corners.enumerated() {
            let end = corners[(index + 1) % corners.count]
            for step in 0...40 {
                let along = start + (end - start) * (Float(step) / 40)
                for height: Float in [0, -0.35] {
                    let point = projection.point([along.x, height, along.y], in: size)
                    if point.x >= column { lowest = max(lowest ?? point.y, point.y) }
                }
            }
        }
        let chest = projection.storageChestRect(in: size)
        if !chest.isNull, chest.maxX >= column { lowest = max(lowest ?? chest.maxY, chest.maxY) }
        return lowest.map { frame.minY + $0 }
    }

    /// A plan from Talk to Bella, through the same calls the Interactions menu makes.
    private func carryOut(_ plan: BellaPlan) {
        switch plan {
        case .invite(let itemId, let siteId, let action):
            if action == .play, let mouse = model.roomFurniture.first(where: { $0.instanceId == itemId }), mouse.modelId == "mv-toy-d" {
                invitation = nil
                playSession.windUp(mouse)
            } else {
                playSession.end()
                invitation = CatInvitation(itemId: itemId, siteId: siteId, action: action)
            }
        case .play(let item):
            invitation = nil
            playSession.begin(item)
            if let catalog = model.catalog { playSession.placeNext(items: model.roomFurniture, catalog: catalog) }
        case .come(let cell):
            playSession.end()
            invitation = nil
            summon = CatSummon(cell: cell)
        }
    }

    private var preparingOverlay: some View {
        VStack(spacing: 16) {
            ProgressView("正在读取照片…")
            Button("取消", role: .cancel) { model.cancelPreparingImport() }
                .buttonStyle(.bordered)
        }
        .padding(24)
        .memoryCard(.album)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.2))
        .accessibilityAddTraits(.isModal)
    }

    private var openedBinding: Binding<PhotoFurniture?> {
        // A piece in the storage box opens too: its photos stay browsable there.
        // Over the table the AR page opens pieces itself.
        Binding(get: { tabletop.covering ? nil : model.anyFurniture(model.openedFurnitureID) }, set: { model.openedFurnitureID = $0?.instanceId })
    }

    /// Not limited to stored pieces: the sheet closes itself once the piece is back in the room.
    private var restoringBinding: Binding<PhotoFurniture?> {
        // From the AR page: opens once the page has fully gone.
        Binding(get: { tabletop.covering ? nil : model.anyFurniture(model.restoringFurnitureID) }, set: { model.restoringFurnitureID = $0?.instanceId })
    }

    private var movingBinding: Binding<PhotoFurniture?> {
        Binding(get: { tabletop.covering ? nil : model.furniture(model.movingFurnitureID) }, set: { model.movingFurnitureID = $0?.instanceId })
    }

    private var failureBinding: Binding<Bool> {
        Binding(get: { model.importFailure != nil }, set: { if !$0 { model.importFailure = nil } })
    }
}

/// Small decoded thumbnail from the app's own store. Decoding stays off the main thread.
struct ThumbnailView: View {
    @Environment(AppModel.self) private var model
    let photoId: String?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .accessibilityHidden(true)
        .task(id: photoId) {
            image = nil
            guard let photoId, let url = await model.thumbnailURL(photoId: photoId) else { return }
            let cgImage = await Task.detached { PhotoIngest.downsampledImage(at: url, maxPixel: 256) }.value
            guard !Task.isCancelled else { return }
            image = cgImage.map { UIImage(cgImage: $0) }
        }
    }
}

/// Each piece has an accessible target where it appears in the 3D view. Taps in
/// overlapping targets offer all the pieces there; VoiceOver activates the focused piece.
/// A long press lifts the piece for editing; the same touch can go straight on to drag it.
struct FurnitureHotspots: View {
    let framing: RoomProjection
    let edit: RoomEditMode
    /// Room notices start below the top band.
    var noticeTop: CGFloat = 0
    let pick: ([PhotoFurniture]) -> Void
    @Environment(AppModel.self) private var model

    private struct Target: Identifiable {
        let item: PhotoFurniture
        let rect: CGRect
        var id: String { item.instanceId }
    }

    private func hitTargets(in size: CGSize) -> [Target] {
        func depth(_ item: PhotoFurniture) -> Int { item.wall == nil ? item.x + item.z : -1 }
        let items = model.roomFurniture.sorted { depth($0) < depth($1) }
        let viewport = CGRect(origin: .zero, size: size)
        return items.compactMap { item in
            let rect = framing.screenRect(for: item, catalog: model.catalog, in: size)
            let target = rect.insetBy(dx: min(0, (rect.width - 44) / 2), dy: min(0, (rect.height - 44) / 2))
            let visible = target.intersection(viewport)
            return visible.isEmpty ? nil : Target(item: item, rect: visible)
        }
    }

    private func pick(at point: CGPoint, from targets: [Target]) {
        guard !edit.isActive else { return }
        // The nearest visible piece comes first in the overlapping-target chooser.
        let hits = targets.reversed().filter { $0.rect.contains(point) }
        pick(hits.map(\.item))
    }

    private func lift(_ item: PhotoFurniture, at point: CGPoint, in size: CGSize) {
        if !edit.isActive {
            guard !item.isLocked else { model.sayLocked(item); return }
            edit.begin(item)
        }
        edit.drag(to: framing.touch(at: point, in: size))
    }

    private func gestures(for target: Target, in size: CGSize, targets: [Target]) -> some View {
        Color.clear
            .frame(width: target.rect.width, height: target.rect.height)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .named(RoomEditMode.space)) { point in
                pick(at: point, from: targets)
            }
            .gesture(LiftFurnitureGesture(moved: { point in
                lift(target.item, at: point, in: size)
            }, ended: edit.endDrag))
    }

    private func hotspot(_ target: Target, in size: CGSize, targets: [Target]) -> some View {
        let item = target.item
        // Photos on another device that have not arrived are not "no photos yet".
        let label: LocalizedStringKey = !item.sources.isEmpty ? "\(item.shownName)，查看照片"
            : (model.sync.pendingLinksByPiece[item.instanceId] ?? 0) > 0 ? "\(item.shownName)，照片还在同步" : "\(item.shownName)，还没有照片"
        return gestures(for: target, in: size, targets: targets)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(label))
            .accessibilityIdentifier(item.sources.isEmpty ? "room-piece-without-photos" : "room-piece-with-photos")
            .accessibilityValue(item.roomLocation)
            .accessibilityAction { model.openedFurnitureID = item.instanceId }
            .accessibilityAction(named: Text("编辑摆放")) {
                if item.isLocked { model.sayLocked(item) } else { edit.begin(item) }
            }
            .accessibilityHidden(edit.isActive)
            .overlay {
                if model.pieces.located == item.instanceId {
                    LocatedOutline().id(model.pieces.locateTick)
                }
            }
            .offset(x: target.rect.minX, y: target.rect.minY)
    }

    @ViewBuilder private func layer(in size: CGSize) -> some View {
        let targets = hitTargets(in: size)
        ForEach(targets) { target in
            hotspot(target, in: size, targets: targets)
        }
        if edit.isActive {
            RoomEditSurface(edit: edit, framing: framing, size: size)
                .allowsHitTesting(!edit.saving)
        }
    }

    var body: some View {
        GeometryReader { layer(in: $0.size) }
        .overlay(alignment: .top) {
            if let notice = model.pieces.roomNotice {
                Text(notice)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .memoryCard(.home)
                    .padding(.horizontal)
                    .padding(.top, 8 + noticeTop)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("room-notice")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.pieces.roomNotice)
        // The outline and the notice go away by themselves.
        .task(id: model.pieces.locateTick) {
            guard model.pieces.located != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { model.pieces.located = nil }
        }
        .task(id: model.pieces.noticeTick) {
            guard model.pieces.roomNotice != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { model.pieces.roomNotice = nil }
        }
        .coordinateSpace(.named(RoomEditMode.space))
        // The tray is taller than the bar it replaces, so the room shifts under a finger that is
        // still down: grab again from where the piece now is, instead of letting it jump.
        .onGeometryChange(for: CGSize.self, of: \.size) { _ in edit.endDrag() }
        .sensoryFeedback(.impact(weight: .medium), trigger: edit.instanceId) { _, id in id != nil }
        .sensoryFeedback(.selection, trigger: edit.draft) { old, new in old != nil && new != nil }
        // The piece can go away under the edit (removed, or the room restored from a backup).
        .onChange(of: model.furniture(edit.instanceId) == nil) { _, gone in
            if gone { edit.end() }
        }
    }
}

private extension PhotoFurniture {
    var roomLocation: String {
        switch wall {
        case .left: String(localized: "挂在左墙，从第 \(x + 1) 格起占 \(width) 格")
        case .back: String(localized: "挂在后墙，从第 \(x + 1) 格起占 \(width) 格")
        case nil: String(localized: "第 \(x + 1) 列，第 \(z + 1) 行，转了 \(turn) 次")
        }
    }
}

/// Drawn around a piece the furniture library pointed out. It pulses a few times, or just
/// stands still when motion is reduced.
private struct LocatedOutline: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var wide = false

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.accentColor, lineWidth: 4)
            .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 12))
            .scaleEffect(wide ? 1.08 : 1)
            .opacity(wide ? 0.55 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.5).repeatCount(5, autoreverses: true)) { wide = true }
            }
    }
}

/// Tells the tour what the room page knows about itself.
/// Chapter 1 of the tour keeps the empty-room card away, and lets it fade back in after (VISUAL
/// §11.1). Gone at once, so it never shows for a moment before the chapter's card.
private struct TourHoldsRoomGuide: ViewModifier {
    @Environment(TourCoordinator.self) private var tour: TourCoordinator?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let held = tour?.holdsRoomGuide == true
        content
            .opacity(held ? 0 : 1)
            .allowsHitTesting(!held)
            .accessibilityHidden(held)
            .animation(held ? nil : .easeIn(duration: 0.2), value: held)
    }
}

private struct RoomTourFacts: ViewModifier {
    @Environment(TourCoordinator.self) private var tour: TourCoordinator?
    let facts: TourRoomFacts
    /// Set back when the tour asks (chapters 6 and 7 start from the room as it opens).
    @Binding var framing: RoomProjection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var resetting: Task<Void, Never>?
    /// The room eases back over 0.35 s; with Reduce Motion it is simply back.
    private static let spring = Spring(duration: 0.35, bounce: 0)

    func body(content: Content) -> some View {
        content
            .onChange(of: facts, initial: true) { _, facts in tour?.room = facts }
            .onChange(of: tour?.zoomResets) { reset() }
    }

    private func reset() {
        resetting?.cancel()
        let from = framing, to = RoomProjection()
        guard from != to else { return }
        guard !reduceMotion else { framing = to; return }
        resetting = Task { @MainActor in
            let start = Date.now
            var written = from
            while !Task.isCancelled {
                // The user's own pinch or drag wins: stop where they took over.
                guard framing == written else { return }
                let time = Date.now.timeIntervalSince(start)
                let progress = Self.spring.value(target: 1.0, time: time)
                // Done within half a percent (about 0.4 s): the tour's next window waits on it,
                // and waits at most 0.6 s (`TourNoteMotion.measureWait`).
                guard progress < 0.995, time < Self.spring.settlingDuration else { framing = to; return }
                written = from.blended(toward: to, Float(progress))
                framing = written
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }
}
