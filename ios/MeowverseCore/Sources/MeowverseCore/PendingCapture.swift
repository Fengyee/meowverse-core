import Foundation

/// A photo taken with the in-app camera that is in neither the photo library nor the app's
/// library yet (JOURNEY-NEW-4, owner 2026-11-22). Until the user confirms it, the bytes are
/// held in one private file in the library folder, so quitting the app does not lose them:
/// the next launch asks whether to go on. Confirming or discarding deletes the file.
///
/// The file is not part of the library. Exports and iCloud backups list the library's own
/// files only, sync sends records, the file is excluded from device backups, and restore and
/// clear-all switch in a new library folder, which takes the file away with the old one.
public struct PendingCapture: Sendable, Equatable {
    /// What Photos did with the capture: the review says the same thing again on reopening.
    public enum Save: String, Codable, Sendable { case notWanted, refused, failed }

    public let data: Data
    public let save: Save

    public init(data: Data, save: Save) {
        self.data = data
        self.save = save
    }

    public var sha256: String { PhotoIngest.sha256Hex(data) }

    /// One capture at a time: a newer one replaces the file.
    public static let fileName = "pending-capture"
    static let tempFileName = "pending-capture.tmp"
    static let magic = Data("MVPENDING1\n".utf8)

    struct Header: Codable, Equatable {
        /// The library folder's name: a file found in another library's folder is not offered.
        var library: String
        var save: Save
        var sha256: String
        var byteSize: Int
    }

    /// The magic line, the header's length as one line, the JSON header, then the photo's bytes.
    static func encode(_ capture: PendingCapture, library: String) throws -> Data {
        let header = try JSONEncoder().encode(Header(library: library, save: capture.save,
                                                     sha256: capture.sha256, byteSize: capture.data.count))
        return magic + Data("\(header.count)\n".utf8) + header + capture.data
    }

    /// nil for anything that is not a whole, intact capture of `library`.
    static func decode(_ file: Data, library: String) -> PendingCapture? {
        guard file.starts(with: magic) else { return nil }
        let rest = file.dropFirst(magic.count)
        guard let newline = rest.firstIndex(of: UInt8(ascii: "\n")),
              let length = Int(String(decoding: rest[rest.startIndex..<newline], as: UTF8.self)),
              length > 0, length <= 4096, rest.distance(from: newline, to: rest.endIndex) > length else { return nil }
        let headerStart = rest.index(after: newline)
        let headerEnd = rest.index(headerStart, offsetBy: length)
        guard let header = try? JSONDecoder().decode(Header.self, from: Data(rest[headerStart..<headerEnd])),
              header.library == library else { return nil }
        let data = Data(rest[headerEnd...])
        guard !data.isEmpty, data.count == header.byteSize, PhotoIngest.sha256Hex(data) == header.sha256 else { return nil }
        return PendingCapture(data: data, save: header.save)
    }
}

public extension PendingCapture.Save {
    /// Only a capture Photos did not take is held: a saved one is safe in Photos already.
    init?(_ save: CameraCapture.LibrarySave) {
        switch save {
        case .notWanted: self = .notWanted
        case .refused: self = .refused
        case .failed: self = .failed
        case .saved: return nil
        }
    }

    var librarySave: CameraCapture.LibrarySave {
        switch self {
        case .notWanted: .notWanted
        case .refused: .refused
        case .failed: .failed
        }
    }
}
