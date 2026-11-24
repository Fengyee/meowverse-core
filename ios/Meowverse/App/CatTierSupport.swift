import BackgroundAssets
import Foundation
import MeowverseCore
import OSLog
import SwiftUI
import System

// 猫的网格档 (owner, 2026-11-20): the room's cat follows 设置 › 画质. The rules (which tier,
// fallback to 中, the download states) are in Core (`CatPackTiers.swift`); this file picks the
// transport and asks for a tier when the room wants it. docs/CAT_PACK.md, "画质档" and "按需下载".

extension AppModel {
    /// The cat the room shows: the active pack on the tier 画质 asks for, or 中 while that tier
    /// is not downloaded, failed, or does not exist for this pack.
    var roomCat: CatPackVariant? {
        guard let pack = catPacks.active else { return nil }
        return pack.variant(for: CatMeshTier(quality.tier), downloaded: catTiers.downloaded(packID: pack.id),
                            unusable: catTiers.unusable(packID: pack.id))
    }

    /// The postcard's cat: the finest tier there is, whatever 画质 is (never 低).
    var postcardCat: CatPackVariant? {
        guard let pack = catPacks.active else { return nil }
        return pack.bestVariant(downloaded: catTiers.downloaded(packID: pack.id), unusable: catTiers.unusable(packID: pack.id))
    }

    /// The room could not load a tier's files: 中 until the tier is asked for again.
    func catTierUnusable(_ variant: CatPackVariant) {
        guard variant.tier != .medium else { return }
        catTiers.markUnusable(packID: variant.pack.id, tier: variant.tier)
    }

    /// When the room wants a tier a built-in pack downloads, start it (or try a failed one again:
    /// this runs only when the pack or the tier changes, or the app opens, not on every update).
    func requestWantedCatTier() {
        guard let pack = catPacks.active else { return }
        let tier = CatMeshTier(quality.tier)
        if let request = pack.downloadRequest(for: tier) {
            catTiers.retry(request)
        } else if pack.manifest.tier(tier) != nil, catTiers.state(packID: pack.id, tier: tier) == .failed(.unusable) {
            // An imported pack's tier is in its own folder: forget the earlier failure and load it again.
            catTiers.cancel(CatTierRequest(packID: pack.id, tier: tier, files: pack.manifest.files(of: tier)))
        }
    }

    static func makeCatTierTransport(_ options: LaunchOptions) -> any CatTierTransport {
        #if DEBUG || DRILLS
        switch options.catTierDrill {
        case nil: break
        case .live(let kept)?:
            if #available(iOS 26.0, *) { return LiveDrillCatTierTransport(keepsEarlierDownload: kept) }
            return UnavailableCatTierTransport()
        case let drill?:
            return DrillCatTierTransport(drill: drill, store: options.storeFolder)
        }
        #endif
        // Background Assets needs the downloader extension (MeowverseAssets) and the Info.plist
        // keys (BAHasManagedAssetPacks and friends, docs/CAT_PACK.md "按需下载"), and iOS 26.
        // A build without them, or an older system, keeps every tier on 中.
        if Bundle.main.object(forInfoDictionaryKey: "BAHasManagedAssetPacks") as? Bool == true, #available(iOS 26.0, *) {
            return BackgroundAssetsCatTierTransport()
        }
        return UnavailableCatTierTransport()
    }

    /// One quiet line for 设置 › 画质 while 画质 asks for a tier the room's cat cannot wear yet.
    /// Nil when she wears it, or when it is 中 anyway (no such tier for this cat, an imported
    /// pack that carries its own tiers).
    var catTierNote: CatTierNote? {
        guard let pack = catPacks.active else { return nil }
        let tier = CatMeshTier(quality.tier)
        guard tier != .medium, roomCat?.tier != tier, let request = pack.downloadRequest(for: tier) else { return nil }
        switch catTiers.state(of: request) {
        case .notDownloaded, .downloading: return .preparing
        case .failed(.unavailable): return .notOnThisSystem
        case .failed, .ready: return .standardForNow
        }
    }
}

/// What 设置 › 画质 says while the cat waits on 中 (`AppModel.catTierNote`).
enum CatTierNote: Equatable {
    /// Not on the device yet, or downloading.
    case preparing
    /// The download failed or the files did not load: tried again on the next 画质 change or launch.
    case standardForNow
    /// This system (before iOS 26) or build cannot download asset packs.
    case notOnThisSystem

    var text: String {
        switch self {
        case .preparing:
            String(localized: "正在准备简化的猫咪模型，准备好之前先用标准模型。", table: "RenderQuality")
        case .standardForNow:
            String(localized: "简化的猫咪模型暂时下载不了，先用标准模型。换一次画质或下次打开 App 时会再试。", table: "RenderQuality")
        case .notOnThisSystem:
            String(localized: "这台设备的系统版本用不了简化的猫咪模型，猫咪用标准模型。", table: "RenderQuality")
        }
    }
}

/// The note under 画质, when there is one.
struct CatTierNoteText: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let note = model.catTierNote {
            Text(note.text)
                .accessibilityIdentifier("render-quality-cat-note")
        }
    }
}

/// Asks for the wanted tier once the library is ready, and again whenever the pack or 画质 changes.
struct CatTierLifecycle: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .task(id: "\(model.phase == .ready) \(model.catPacks.activeID) \(model.quality.tier.rawValue)") {
                guard model.phase == .ready else { return }
                model.requestWantedCatTier()
            }
            .onChange(of: wantedState) { _, state in
                // 未下载 → 下载中 → 已就绪 / 失败, for the log (the reason of a failure is only here).
                Self.log.notice("cat tier \(state, privacy: .public)")
            }
    }

    private static let log = Logger(subsystem: "app.meowverse", category: "cat-tier")

    private var wantedState: String {
        guard let pack = model.catPacks.active else { return "none" }
        let tier = CatMeshTier(model.quality.tier)
        let state = switch model.catTiers.state(packID: pack.id, tier: tier) {
        case .notDownloaded: "not downloaded"
        case .downloading(let fraction): "downloading \(fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "")"
        case .ready: "ready"  // not the folder: no paths in the log
        case .failed(let failure): "failed \(failure)"
        }
        return "\(pack.id) \(tier.rawValue): \(state), room \(model.roomCat?.tier.rawValue ?? "-")"
    }
}

/// Apple-hosted Background Assets (iOS 26 and later): one asset pack per cat and tier,
/// `cat-<id>-<tier>`, with its files under `cats/<id>/<tier>/` of the shared asset root.
/// Not verified on a device or through TestFlight: that needs the downloader extension, the
/// App Group and the asset packs uploaded to App Store Connect (docs/CAT_PACK.md, "按需下载").
@available(iOS 26.0, *)
nonisolated struct BackgroundAssetsCatTierTransport: CatTierTransport {
    func installed(_ request: CatTierRequest) async -> URL? {
        if #available(iOS 26.4, *) {
            guard AssetPackManager.shared.assetPackIsAvailableLocally(withID: request.assetPackID) else { return nil }
        }
        return Self.folder(request)
    }

    func download(_ request: CatTierRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let manager = AssetPackManager.shared
        let pack: AssetPack
        if #available(iOS 27.0, *) {
            guard let listed = try await manager.manifest.assetPack(withID: request.assetPackID) else {
                throw ManagedBackgroundAssetsError.assetPackNotFound(withID: request.assetPackID)
            }
            pack = listed
        } else {
            pack = try await manager.assetPack(withID: request.assetPackID)
        }
        let updates = Task {
            for await update in manager.statusUpdates(forAssetPackWithID: request.assetPackID) {
                if case .downloading(_, let fraction) = update { progress(fraction.fractionCompleted) }
            }
        }
        defer { updates.cancel() }
        do {
            if #available(iOS 26.4, *) {
                try await manager.ensureLocalAvailability(of: pack, requireLatestVersion: false)
            } else {
                try await manager.ensureLocalAvailability(of: pack)
            }
        } catch {
            Self.log.notice("\(request.assetPackID, privacy: .public) did not download: \(String(describing: error), privacy: .public)")
            throw error
        }
        guard let folder = Self.folder(request) else {
            throw ManagedBackgroundAssetsError.fileNotFound(at: FilePath(request.folder))
        }
        Self.log.notice("\(request.assetPackID, privacy: .public) is on the device")
        return folder
    }

    /// The tier's files as one folder. Every file is asked for on its own: `url(for:)` stages
    /// just the file it is asked about (into `Staging/Unlocalized/<path>` of the system's
    /// container), so the folder of one file holds none of the others (seen on the iOS 27.2
    /// simulator, 2026-11-20: the first file only, the rest "incomplete"). When they all land in
    /// one folder that is the answer; otherwise a folder of links in the app's caches.
    private static func folder(_ request: CatTierRequest) -> URL? {
        guard !request.files.isEmpty else { return nil }
        var urls: [String: URL] = [:]
        for file in request.files {
            do {
                urls[file] = try AssetPackManager.shared.url(for: FilePath("\(request.folder)/\(file)"))
            } catch {
                log.notice("\(request.assetPackID, privacy: .public): no \(file, privacy: .public): \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        let folders = Set(urls.values.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        if folders.count == 1, let only = folders.first { return URL(filePath: only, directoryHint: .isDirectory) }
        do { return try links(urls, for: request) } catch {
            log.notice("\(request.assetPackID, privacy: .public): links not made: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func links(_ urls: [String: URL], for request: CatTierRequest) throws -> URL {
        let fm = FileManager.default
        let folder = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "CatTierLinks/\(request.assetPackID)", directoryHint: .isDirectory)
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // The names are bare file names (CatPackManifest checks them).
        for (file, url) in urls { try fm.createSymbolicLink(at: folder.appending(path: file), withDestinationURL: url) }
        return folder
    }

    private static let log = Logger(subsystem: "app.meowverse", category: "cat-tier")
}

#if DEBUG || DRILLS
/// `-MeowverseCatTiers <ready|hang|fail|after:<秒>|live|live-kept>`: how the built-in cats' 低
/// downloads behave. Every built-in cat declares a real 低 in its bundled `cat.json`; the
/// manifests are not touched.
/// - `live` asks Background Assets for the real asset pack (`cat-<id>-low`) after removing any
///   earlier download of it, so every launch starts 未下载; `live-kept` keeps an earlier
///   download. With a local `ba-serve` serving the packs from `ios/ba-local.sh stage` it
///   downloads the real 低 cat (ios/README.md "画质"); without one it fails.
/// - The others download nothing: a stand-in writes the cat's own 中 files under the tier's names
///   (`DrillCatTierTransport`). `ready` is already on the device, `hang` never finishes, `fail`
///   fails after half a second, `after:<秒>` finishes after that many seconds. They test the
///   choosing, the fallback and the note, not what the 低 cat looks like.
nonisolated enum CatTierDrill: Sendable, Equatable {
    case ready, hang, fail
    case after(Double)
    case live(kept: Bool)

    init?(_ text: String) {
        switch text {
        case "ready": self = .ready
        case "hang": self = .hang
        case "fail": self = .fail
        case "live": self = .live(kept: false)
        case "live-kept": self = .live(kept: true)
        default:
            guard text.hasPrefix("after:"), let seconds = Double(text.dropFirst(6)), seconds >= 0 else { return nil }
            self = .after(seconds)
        }
    }
}

/// `live` and `live-kept`: the app's own Background Assets transport. `live` first removes the
/// asset pack from this device, once per launch, so a run never starts with last run's download.
@available(iOS 26.0, *)
nonisolated struct LiveDrillCatTierTransport: CatTierTransport {
    let keepsEarlierDownload: Bool
    private let base = BackgroundAssetsCatTierTransport()
    private static let removals = Removals()

    private actor Removals {
        private var done: Set<String> = []

        func removeOnce(_ id: String) async {
            guard done.insert(id).inserted else { return }
            do { try await AssetPackManager.shared.remove(assetPackWithID: id) } catch {
                Logger(subsystem: "app.meowverse", category: "cat-tier").notice("drill: \(id, privacy: .public) not removed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func installed(_ request: CatTierRequest) async -> URL? {
        if !keepsEarlierDownload { await Self.removals.removeOnce(request.assetPackID) }
        return await base.installed(request)
    }

    func download(_ request: CatTierRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await base.download(request, progress: progress)
    }
}

/// Writes a stand-in for the tier's files into the app's caches, as a download would.
nonisolated struct DrillCatTierTransport: CatTierTransport {
    let drill: CatTierDrill
    let store: String

    private var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "CatTierDrill-\(store)", directoryHint: .isDirectory)
    }

    func installed(_ request: CatTierRequest) async -> URL? {
        guard drill == .ready else {
            // Every other drill starts 未下载, even after an earlier run wrote the files.
            try? FileManager.default.removeItem(at: root)
            return nil
        }
        return try? await AppModel.offMain { [self] in try write(request) }
    }

    func download(_ request: CatTierRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        switch drill {
        case .ready:
            return try await AppModel.offMain { [self] in try write(request) }
        case .hang:
            try await Task.sleep(for: .seconds(86_400))
            throw CancellationError()
        case .fail:
            try await Task.sleep(for: .seconds(0.5))
            throw CocoaError(.fileReadUnknown)
        case .live:
            // `live` goes through Background Assets (`LiveDrillCatTierTransport`), never here.
            throw CatTierTransportError.unavailable
        case .after(let seconds):
            progress(0.1)
            try await Task.sleep(for: .seconds(seconds))
            progress(1)
            return try await AppModel.offMain { [self] in try write(request) }
        }
    }

    /// The cat's own 中 files under the names its tier gives them (its bundled `cat.json`): each
    /// pose for that pose, each texture for that role's 中 texture (awake or asleep), and for the
    /// skin the rig's own mesh and joint names. 中 meshes wear 中 textures, so the stand-in is
    /// drawn right although it borrows nothing (`textureGap`).
    private func write(_ request: CatTierRequest) throws -> URL {
        let folder = root.appending(path: request.folder, directoryHint: .isDirectory)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let bundle = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        func source(_ name: String) -> URL { bundle.appending(path: "\(request.packID)-\(name)") }
        let manifest = try CatPackManifest.decode(Data(contentsOf: source("cat.json")))
        guard let tier = manifest.tier(request.tier) else { throw CatTierTransportError.unavailable }
        var copies: [(from: String, to: String)] = CatPackPose.allCases.compactMap { pose in
            tier.poseFile(pose).map { (manifest.file(for: pose), $0) }
        }
        for (role, own) in tier.materials ?? [:] {
            guard let mid = manifest.materials[role] else { continue }
            if let name = own.baseColor { copies.append((mid.baseColor, name)) }
            if let name = own.sleepBaseColor { copies.append((mid.baseColor(sleeping: true), name)) }
        }
        for (from, to) in copies {
            let target = folder.appending(path: to)
            if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: source(from), to: target) }
        }
        if let name = tier.skin {
            let skin = folder.appending(path: name)
            if !fm.fileExists(atPath: skin.path) {
                let rig = try JSONSerialization.jsonObject(with: Data(contentsOf: source(manifest.groundGaits))) as? [String: Any] ?? [:]
                var json: [String: Any] = ["format": CatSkin.formatName,
                                           "jointNames": (rig["joints"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String },
                                           "parts": rig["parts"] ?? []]
                if let skeleton = rig["skeleton"] { json["skeleton"] = skeleton }
                try JSONSerialization.data(withJSONObject: json).write(to: skin, options: .atomic)
            }
        }
        return folder
    }
}
#endif
