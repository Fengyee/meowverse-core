import Foundation
import MeowverseCore
import OSLog

/// Which cat the room shows: the built-in packs from the app bundle and the packs the user
/// imported (docs/CAT_PACK.md). The choice is a device setting, not part of the library backup.
@Observable
final class CatPackLibrary {
    /// Built-in packs. To add one, put `<id>-cat.json` and its `<id>-<file>` files in
    /// Resources/Art and add the id here. The first id is the fallback.
    static let builtInIDs = ["bella", "airou", "zhumi", "siamese", "ragdoll", "black", "white", "sphynx", "zhaocai"]
    static var fallbackID: String { builtInIDs[0] }
    static let defaultsKey = "cat.activePack"

    struct Notice: Equatable {
        var text: String
        var isFailure: Bool
    }

    private(set) var builtIn: [CatPack] = []
    private(set) var imported: [CatPack] = []
    private(set) var activeID: String
    /// Reading, checking or writing a `.meowcat` file.
    private(set) var busy = false
    /// A checked pack with the id of one already installed; waits for the user's confirmation.
    private(set) var pendingReplacement: StagedCatPack?
    var notice: Notice?

    let store: CatPackStore
    private let defaults: UserDefaults
    private let defaultsKey: String
    private var generation = 0
    private let log = Logger(subsystem: "app.meowverse", category: "cat-pack")

    init(options: LaunchOptions, defaults: UserDefaults = .standard) {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        // Test stores (`-MeowverseStore`) get their own packs and choice, reset with the store.
        let isTest = options.storeFolder != "Library"
        let root = base.appending(path: isTest ? "CatPacks-\(options.storeFolder)" : "CatPacks", directoryHint: .isDirectory)
        defaultsKey = isTest ? "\(Self.defaultsKey).\(options.storeFolder)" : Self.defaultsKey
        if isTest, options.resetStore {
            try? fm.removeItem(at: root)
            defaults.removeObject(forKey: defaultsKey)
        }
        self.defaults = defaults
        store = CatPackStore(root: root, reservedIDs: Set(Self.builtInIDs))
        activeID = defaults.string(forKey: defaultsKey) ?? Self.fallbackID
        store.removeLeftovers()
        reload()
    }

    var all: [CatPack] { builtIn + imported }

    /// The pack the room shows. Nil only when the app bundle itself is broken.
    var active: CatPack? {
        all.first { $0.id == activeID } ?? builtIn.first
    }

    func pack(id: String) -> CatPack? { all.first { $0.id == id } }

    /// Rereads the bundle and the imported folder. A chosen pack that is gone falls back to the first built-in one.
    func reload() {
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        builtIn = Self.builtInIDs.compactMap { id in
            do {
                return try CatPack.builtIn(id: id, resourceDirectory: resources)
            } catch {
                log.error("built-in cat pack \(id, privacy: .public) unreadable: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        imported = store.installed().map(CatPack.init(installed:))
        if pack(id: activeID) == nil { select(Self.fallbackID) }
    }

    func select(_ id: String) {
        guard activeID != id || defaults.string(forKey: defaultsKey) != id else { return }
        activeID = id
        defaults.set(id, forKey: defaultsKey)
    }

    // MARK: Import and delete

    /// Checks a picked `.meowcat` file off the main thread. A pack with a new id is installed and
    /// chosen at once; one that would replace an installed pack waits for `confirmReplacement`.
    func importPack(at url: URL) {
        guard !busy else { return }
        cancelReplacement()
        notice = nil
        busy = true
        generation += 1
        let generation = self.generation, store = self.store
        Task {
            // A file picked in Files is only readable between these two calls.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let staged = try await AppModel.offMain { try store.stage(archiveAt: url) }
                guard generation == self.generation else {
                    store.discard(staged)
                    return
                }
                if staged.replacesExisting {
                    pendingReplacement = staged
                    busy = false
                } else {
                    await install(staged)
                }
            } catch {
                log.error("cat pack refused: \(String(describing: error), privacy: .public)")
                notice = Notice(text: Wording.catPackFailure(error), isFailure: true)
                busy = false
            }
        }
    }

    /// The installed pack that a pending import would replace.
    var replacementTarget: CatPack? { pendingReplacement.flatMap { pack(id: $0.manifest.id) } }

    func confirmReplacement() {
        guard let staged = pendingReplacement, !busy else { return }
        pendingReplacement = nil
        busy = true
        Task { await install(staged) }
    }

    func cancelReplacement() {
        if let staged = pendingReplacement { store.discard(staged) }
        pendingReplacement = nil
    }

    private func install(_ staged: StagedCatPack) async {
        let store = self.store
        do {
            try await AppModel.offMain { try store.commit(staged) }
            reload()
            select(staged.manifest.id)
            notice = Notice(text: String(localized: "已导入「\(staged.manifest.name)」，房间里的猫咪换成了它。"), isFailure: false)
        } catch {
            reload()
            notice = Notice(text: Wording.catPackFailure(error), isFailure: true)
        }
        busy = false
    }

    func delete(id: String) {
        guard !busy, imported.contains(where: { $0.id == id }) else { return }
        let name = pack(id: id)?.manifest.name ?? id
        do {
            try store.delete(id: id)
            if activeID == id { select(Self.fallbackID) }
            notice = Notice(text: String(localized: "已删除「\(name)」。"), isFailure: false)
        } catch {
            notice = Notice(text: String(localized: "没能删除「\(name)」。房间里的猫咪没有变化，可以再试一次。"), isFailure: true)
        }
        reload()
    }
}
