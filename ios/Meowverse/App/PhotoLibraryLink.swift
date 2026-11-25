import MeowverseCore
import OSLog
import Photos
import PhotosUI
import SwiftUI
import UIKit

/// The optional link to the user's photo library (owner, 2026-11-13).
///
/// Off by default: the app then reads only what the system picker hands it and keeps a copy
/// up to `PhotoIngest.storedMaxPixel` on its longest side. Turned on (which needs full access
/// to the library), a newly imported photo keeps only a small preview
/// (`PhotoIngest.linkedMaxPixel`), and the full-size picture is read from the library when a
/// photo is opened. The preview stays viewable if the library copy is deleted, access is taken
/// away, or the library is on another device.
///
/// The app only ever asks the library for assets whose identifier it recorded at import.
@MainActor
@Observable
final class PhotoLibraryLink {
    private static let wantedKey = "photoLibraryLinkWanted"
    private nonisolated static let log = Logger(subsystem: "app.meowverse", category: "photo-library")
    @ObservationIgnored private let defaults: UserDefaults
    private static let introKey = "photoLibraryLinkIntroAnswered"
    /// What the user chose. The link works only while access is also granted.
    private(set) var wanted: Bool
    /// False until the user has answered the explanation shown before their first photos.
    private(set) var introAnswered: Bool

    init(options: LaunchOptions = .current, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        wanted = defaults.bool(forKey: Self.wantedKey)
        // A UI-test store never meets the explanation unless the test asks for it.
        let isTest = options.storeFolder != "Library"
        introAnswered = isTest ? !options.libraryIntro : defaults.bool(forKey: Self.introKey)
    }

    /// The link is explained before the first photos come in, rather than left for the user to
    /// find in Settings (owner, 2026-11-13). The explanation leads to the system alert, where
    /// the user decides (round 12: a pre-alert screen neither recommends nor skips the alert).
    /// Read live: once access has been answered anywhere (the Settings switch, iOS Settings), no
    /// system alert can follow, so the screen is not shown (round 12 QA).
    var needsIntro: Bool { !introAnswered && !isOn && Self.canAsk }

    /// The system alert can still come: access has not been answered yet.
    nonisolated static var canAsk: Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined
    }

    /// The user answered the system alert, either way. Settings can still change it later.
    func answerIntro() {
        introAnswered = true
        defaults.set(true, forKey: Self.introKey)
    }

    /// Read live, so access taken away in the Settings app is noticed without a restart.
    var isOn: Bool { wanted && Self.hasFullAccess }

    nonisolated static var hasFullAccess: Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
    }

    /// Asks for access if the user has not answered yet. Returns false, leaving the link off,
    /// unless the answer is full access: with "limited" access the system picker's choice does
    /// not make a photo readable, so the link could not find what was just imported.
    func turnOn() async -> Bool {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard status == .authorized else { return false }
        setWanted(true)
        answerIntro()
        return true
    }

    func turnOff() { setWanted(false) }

    private func setWanted(_ value: Bool) {
        wanted = value
        defaults.set(value, forKey: Self.wantedKey)
    }

    // MARK: Import

    struct ImportPlan: Sendable {
        var maxPixel = PhotoIngest.storedMaxPixel
        var cloudIdentifier: String?
    }

    /// How to keep a picked photo. The small preview is chosen only when the library shows
    /// the asset right now; anything else keeps the normal copy. Call off the main actor.
    nonisolated static func importPlan(assetIdentifier: String?, linked: Bool) -> ImportPlan {
        guard linked, let assetIdentifier, hasFullAccess,
              PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil).count > 0
        else { return ImportPlan() }
        let cloud = try? PHPhotoLibrary.shared()
            .cloudIdentifierMappings(forLocalIdentifiers: [assetIdentifier])[assetIdentifier]?.get()
        return ImportPlan(maxPixel: PhotoIngest.linkedMaxPixel, cloudIdentifier: cloud?.stringValue)
    }

    nonisolated static func load(_ item: PhotosPickerItem) async throws -> Data {
        try await PhotoRequest.value { reply in
            let progress = item.loadTransferable(type: Data.self) { result in
                reply(result.flatMap { $0.map(Result.success) ?? .failure(IngestError.notAnImage) })
            }
            return { progress.cancel() }
        }
    }

    /// `fullSizeCopy` is `.onlyHere` when `data` is the only full-size file (a camera photo
    /// Photos did not take): it is then kept whole, whatever the plan's size.
    nonisolated static func makeDraft(data: Data, filename: String?, assetIdentifier: String?, fullSizeCopy: FullSizeCopy,
                                      linked: Bool, store: LibraryStore?) async throws -> ImportDraft {
        var draft = try await AppModel.offMain {
            try Task.checkCancellation()
            let plan = importPlan(assetIdentifier: assetIdentifier, linked: linked)
            var draft = try PhotoIngest.makeDraft(data: data, filename: filename, fullSizeCopy: fullSizeCopy, maxPixel: plan.maxPixel)
            draft.assetIdentifier = assetIdentifier
            draft.cloudIdentifier = plan.cloudIdentifier
            return draft
        }
        guard linked, let local = assetIdentifier,
              let existing = await store?.existingPhoto(matching: draft), existing.assetIdentifier != local
        else { return draft }
        draft.missingLibraryBinding = try await AppModel.offMain {
            MissingLibraryBinding.confirmed(photo: existing, selected: local, hasFullAccess: { hasFullAccess },
                                            localExists: { PHAsset.fetchAssets(withLocalIdentifiers: [$0], options: nil).count > 0 },
                                            cloudIsMissing: cloudIsMissing)
        }
        return draft
    }

    /// The photos whose original Photos shows right now, by the asset recorded at import. Asks
    /// for nothing: without full access none is confirmed, so a delete warns (DATA-1). An asset
    /// known only under its cloud identifier is not confirmed either.
    nonisolated static func originalsInPhotos(_ photos: [PhotoRecord]) async -> Set<String> {
        let local = photos.compactMap(\.assetIdentifier)
        guard !local.isEmpty, hasFullAccess else { return [] }
        let found: Set<String> = (try? await AppModel.offMain { () -> Set<String> in
            var identifiers = Set<String>()
            PHAsset.fetchAssets(withLocalIdentifiers: local, options: nil).enumerateObjects { asset, _, _ in
                identifiers.insert(asset.localIdentifier)
            }
            return identifiers
        }) ?? []
        return Set(photos.filter { $0.assetIdentifier.map(found.contains) == true }.map(\.photoId))
    }

    private nonisolated static func cloudIsMissing(_ cloud: String) -> Bool {
        let identifier = PHCloudIdentifier(stringValue: cloud)
        guard let mapping = PHPhotoLibrary.shared().localIdentifierMappings(for: [identifier])[identifier] else { return false }
        // A network or temporary mapping failure gives no evidence that the old binding has gone.
        if case .failure(let error) = mapping {
            let error = error as NSError
            return error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.Code.identifierNotFound.rawValue
        }
        return false
    }

    // MARK: Reading the full-size picture

    enum FullImage: Sendable {
        case image(UIImage)
        case failure(PhotoSourceIssue)
    }

    func fullImage(for photo: PhotoRecord, maxPixel: Int) async -> FullImage? {
        guard photo.reducedFrom != nil, !Task.isCancelled else { return nil }
        let linked = wanted
        do {
            let asset = try await Self.asset(for: photo, linked: linked)
            try Task.checkCancellation()
            let result = await Self.request(asset, maxPixel: maxPixel)
            if case .image(let image) = result {
                let width = Int(image.size.width * image.scale), height = Int(image.size.height * image.scale)
                Self.log.info("library image: \(width, privacy: .public)x\(height, privacy: .public) photo=\(photo.photoId, privacy: .public)")
            }
            return result
        } catch let issue as PhotoSourceIssue {
            return .failure(issue)
        } catch {
            return nil
        }
    }

    nonisolated static func asset(for photo: PhotoRecord, linked: Bool) async throws -> PHAsset {
        guard photo.assetIdentifier != nil || photo.cloudIdentifier != nil else { throw PhotoSourceIssue.unlinked }
        guard linked else { throw PhotoSourceIssue.unlinked }
        guard hasFullAccess else { throw PhotoSourceIssue.permission }
        return try await Task.detached(priority: .userInitiated) {
            if let local = photo.assetIdentifier,
               let asset = PHAsset.fetchAssets(withLocalIdentifiers: [local], options: nil).firstObject { return asset }
            if let cloud = photo.cloudIdentifier {
                let id = PHCloudIdentifier(stringValue: cloud)
                guard let mapping = PHPhotoLibrary.shared().localIdentifierMappings(for: [id])[id] else {
                    throw PhotoSourceIssue.unavailable
                }
                do {
                    let local = try mapping.get()
                    if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [local], options: nil).firstObject { return asset }
                } catch {
                    throw sourceIssue(error: error, inCloud: false)
                }
            }
            throw hasFullAccess ? PhotoSourceIssue.missing : .permission
        }.value
    }

    nonisolated static func sourceIssue(error: Error?, inCloud: Bool) -> PhotoSourceIssue {
        guard hasFullAccess else { return .permission }
        if let error = error as NSError?, error.domain == PHPhotosErrorDomain {
            switch PHPhotosError.Code(rawValue: error.code) {
            case .identifierNotFound: return .missing
            case .networkAccessRequired, .networkError: return .iCloud
            case .accessUserDenied, .accessRestricted: return .permission
            default: break
            }
        }
        return inCloud || (error as NSError?)?.domain == NSURLErrorDomain ? .iCloud : .unavailable
    }

    nonisolated static func originalData(for photo: PhotoRecord, linked: Bool) async throws -> Data {
        let asset = try await asset(for: photo, linked: linked)
        let expected = photo.reducedFrom?.sha256 ?? photo.sha256
        // The picker used .current. If the asset has since been edited, its original may still match;
        // and if the current version cannot be read, the original is still tried (audit A24-09).
        return try await PhotoOriginalVersions.read([PHImageRequestOptionsVersion.current, .original], expected: expected) { version in
            let options = PHImageRequestOptions()
            options.version = version
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            return try await PhotoRequest.value { reply in
                let id = PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                    if let data { reply(.success(data)) }
                    else { reply(.failure(sourceIssue(error: info?[PHImageErrorKey] as? Error,
                                                      inCloud: info?[PHImageResultIsInCloudKey] as? Bool == true))) }
                }
                return { PHImageManager.default().cancelImageRequest(id) }
            }
        }
    }

    private nonisolated static func request(_ asset: PHAsset, maxPixel: Int) async -> FullImage {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        let side = CGFloat(maxPixel)
        return (try? await PhotoRequest.value { reply in
            let id = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                                           contentMode: .aspectFit, options: options) { image, info in
                if (info?[PHImageCancelledKey] as? Bool) == true || info?[PHImageErrorKey] != nil {
                    reply(.success(.failure(sourceIssue(error: info?[PHImageErrorKey] as? Error, inCloud: info?[PHImageResultIsInCloudKey] as? Bool == true))))
                } else if (info?[PHImageResultIsDegradedKey] as? Bool) != true {
                    reply(.success(image.map(FullImage.image) ?? .failure(sourceIssue(error: nil, inCloud: info?[PHImageResultIsInCloudKey] as? Bool == true))))
                }
            }
            return { PHImageManager.default().cancelImageRequest(id) }
        }) ?? .failure(.unavailable)
    }

    static func note(for result: FullImage?) -> String? {
        switch result {
        case .failure(let issue): issue.guidance
        case .image, nil: nil
        }
    }
}

/// The switch in Settings › 存储.
struct PhotoLibraryLinkRow: View {
    @Environment(AppModel.self) private var model
    @State private var refused = false
    @State private var asking = false

    var body: some View {
        Toggle(isOn: Binding(get: { model.photoLibrary.isOn }, set: set)) {
            VStack(alignment: .leading, spacing: 4) {
                Text("从相册读取大图")
                Text("打开后，新导入的照片在喵空间里只存一张小预览，更省空间；看大图时从相册读取。需要允许访问所有照片，喵空间只会读取你导入过的那些。相册里的照片删掉后，这里仍留着小预览。")
                    .font(.footnote)
                    .foregroundStyle(Color.subtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(asking)
        .accessibilityIdentifier("library-link-toggle")
        .alert("没有拿到相册权限", isPresented: $refused) {
            Button("打开系统设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("好", role: .cancel) {}
        } message: {
            Text("要在系统设置里把喵空间的“照片”改成“完整访问”，这个开关才能打开。现在照片照旧保存，什么都没有变。")
        }
    }

    private func set(_ on: Bool) {
        guard on else { return model.photoLibrary.turnOff() }
        asking = true
        Task {
            refused = !(await model.photoLibrary.turnOn())
            asking = false
        }
    }
}

/// Shown once, before the first photos are picked: why the app would like to read the photo
/// library, what it will and will not do with it, and what happens without it.
struct PhotoLibraryIntro: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var asking = false
    @State private var refused = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    MemoryEmblem(.album)
                        .frame(width: 104, height: 78)
                        .frame(maxWidth: .infinity)
                    Text("让照片少占空间")
                        .font(.system(.title2, design: .serif, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                    point("internaldrive", String(localized: "如果喵空间能读取相册，每张照片在喵空间里只存一张小预览，设备空间和 iCloud 空间都占得更少；看大图时直接从你的相册读取。这要用到对所有照片的访问。"))
                    // With iCloud backup or sync on, the copies Meowverse keeps do go to the user's iCloud.
                    point("lock.shield", model.photoReach.libraryIntroWords)
                        .accessibilityIdentifier("library-intro-privacy")
                    point("arrow.uturn.backward", String(localized: "不允许也能照常使用：喵空间会给每张照片存一份较大的副本。之后可以随时在设置里更改。"))
                    if refused {
                        Text("这次没有拿到完整访问，照片会按较大的副本保存。以后可以在设置里打开“从相册读取大图”。")
                            .font(.footnote)
                            .foregroundStyle(Color.caution)
                            .accessibilityIdentifier("library-intro-refused")
                    } else if PhotoLibraryLink.canAsk {
                        Text("轻点“继续”后，系统会询问是否允许喵空间访问照片。")
                            .font(.footnote)
                            .foregroundStyle(Color.subtle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                // A pre-alert screen has one button, and it opens the system alert (HIG, Privacy ›
                // Pre-alert screens): no way past the alert here, and no "Allow" in its title, so
                // the choice is made in the system's own alert (round 12 audit, PRIVACY-2).
                if refused {
                    primaryButton(String(localized: "继续"), enabled: true) { dismiss() }
                        .accessibilityIdentifier("library-intro-done")
                } else {
                    primaryButton(String(localized: "继续"), enabled: !asking) {
                        asking = true
                        Task {
                            let on = await model.photoLibrary.turnOn()
                            model.photoLibrary.answerIntro()
                            asking = false
                            if on { dismiss() } else { refused = true }
                        }
                    }
                    .accessibilityHint("打开系统的照片访问询问")
                    .accessibilityIdentifier("library-intro-continue")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("library-intro")
            .memoryPage(.album)
            .navigationTitle("相册权限")
            .navigationBarTitleDisplayMode(.inline)
        }
        // The answer is given in the system alert, which the button opens.
        .interactiveDismissDisabled()
    }

    private func point(_ symbol: String, _ words: String) -> some View {
        Label {
            Text(words).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
        }
    }
}

/// Opens the system photo picker, after the explanation the first time. Set `request` to ask.
struct PhotoPickerGate: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var request: Bool
    @Binding var pickerShown: Bool
    @State private var introShown = false

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, asked in
                guard asked else { return }
                if model.photoLibrary.needsIntro {
                    introShown = true
                } else {
                    pickerShown = true
                    request = false
                }
            }
            // The picker opens only after the explanation has fully gone.
            .sheet(isPresented: $introShown, onDismiss: {
                pickerShown = true
                request = false
            }) { PhotoLibraryIntro() }
    }
}
