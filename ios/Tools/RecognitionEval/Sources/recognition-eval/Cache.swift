import Foundation
import MeowverseCore

/// What is kept for one photo between runs: its Vision prints by id (the two whole-picture ones
/// under the masking names, the cat crops under `CatCrop.Variant.id`) and the cat boxes Vision
/// found (normalised x, y, width, height, lower-left origin).
struct CachedPhoto: Codable {
    var prints: [String: FeaturePrint] = [:]
    var cats: [[Double]]?
}

/// Feature prints kept between runs, so a second run over the same folder skips Vision.
///
/// Lives in the system temporary folder (per user, never in the repo), one small JSON file per
/// photo named by the SHA-256 of the photo's bytes. A file holds only prints and cat boxes: no
/// file name, path, time or place. The folder name includes everything that changes how a print
/// is made (Vision revision, the app's pixel pipeline and thumbnail size, the macOS build, this
/// file's format), so a change starts a fresh folder instead of mixing prints. Delete the folder
/// to clear it.
final class PrintCache {
    let directory: URL

    init() {
        let recipe = "prints-2 rev\(VisionPhotoEmbedder.revision) pipeline\(FeaturePrintCache.pipeline) "
            + "px\(VisionPhotoEmbedder.maxPixel) cover\(CatCrop.coverMargin) \(ProcessInfo.processInfo.operatingSystemVersionString)"
        let tag = String(PhotoIngest.sha256Hex(Data(recipe.utf8)).prefix(16))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meowverse-recognition-eval", isDirectory: true)
            .appendingPathComponent(tag, isDirectory: true)
    }

    private func file(_ key: String) -> URL { directory.appendingPathComponent(key + ".json") }

    func entry(for key: String) -> CachedPhoto? {
        guard let data = try? Data(contentsOf: file(key)) else { return nil }
        return try? JSONDecoder().decode(CachedPhoto.self, from: data)
    }

    func store(_ entry: CachedPhoto, for key: String) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(entry).write(to: file(key), options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(key).path)
        } catch {
            FileHandle.standardError.write(Data("print cache not written: \(error.localizedDescription)\n".utf8))
        }
    }
}
