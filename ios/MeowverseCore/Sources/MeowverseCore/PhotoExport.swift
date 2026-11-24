import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A failed lookup leaves the imported photo and its links intact. A missing identifier on a
/// different device is not proof the user deleted the asset.
public enum PhotoSourceIssue: Error, Sendable, Equatable, Hashable {
    case unlinked, permission, missing, iCloud, unavailable, changed
}

public struct PhotoExport: Sendable {
    public struct CopyCaptureDay: Equatable, Sendable {
        public let day: String
        public let source: CaptureDateSource

        init?(_ photo: PhotoRecord) {
            guard photo.captureDateSource != .unknown, let day = photo.captureDate,
                  PhotoLibrary.isValidDay(day) else { return nil }
            self.day = day
            source = photo.captureDateSource
        }
    }

    public let url: URL
    public let copyReason: PhotoSourceIssue?
    public let copyCaptureDay: CopyCaptureDay?

    init(url: URL, copyReason: PhotoSourceIssue?, copyCaptureDay: CopyCaptureDay? = nil) {
        self.url = url
        self.copyReason = copyReason
        self.copyCaptureDay = copyCaptureDay
    }

    /// The date Photos is given for this file on a device in one zone. The confirmation reads
    /// it and the delivery sets it, so what the page says is what happens (fifth review, R5-07).
    public enum CopyDate: Sendable, Equatable {
        /// Not a copy: Photos reads the date in the file itself.
        case fromFile
        /// 12:00 local time on the recorded day.
        case localNoon(Date)
        /// The zone skipped 12:00 that day; the first moment after it, still the same day.
        case laterThatDay(Date)
        /// The zone skipped the whole day: no date is set, Photos chooses one.
        case dayMissingHere
        /// The day is not known: no date is set, Photos chooses one.
        case unknownDay

        public var creationDate: Date? {
            switch self {
            case .localNoon(let date), .laterThatDay(let date): date
            case .fromFile, .dayMissingHere, .unknownDay: nil
            }
        }
    }

    public func copyDate(in timeZone: TimeZone) -> CopyDate {
        guard copyReason != nil else { return .fromFile }
        guard let day = copyCaptureDay?.day else { return .unknownDay }
        guard let date = PhotoLibrary.creationDate(on: day, in: timeZone) else { return .dayMissingHere }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let local = calendar.dateComponents([.hour, .minute, .second], from: date)
        return local.hour == 12 && local.minute == 0 && local.second == 0 ? .localNoon(date) : .laterThatDay(date)
    }

    /// How many copies of `files` fall in each case, for the confirmation's date note.
    public struct CopyDateCounts: Sendable, Equatable {
        public var localNoon = 0, laterThatDay = 0, dayMissingHere = 0, unknownDay = 0
        public init(localNoon: Int = 0, laterThatDay: Int = 0, dayMissingHere: Int = 0, unknownDay: Int = 0) {
            self.localNoon = localNoon
            self.laterThatDay = laterThatDay
            self.dayMissingHere = dayMissingHere
            self.unknownDay = unknownDay
        }
    }

    public static func copyDateCounts(_ files: [PhotoExport], in timeZone: TimeZone) -> CopyDateCounts {
        var counts = CopyDateCounts()
        for file in files {
            switch file.copyDate(in: timeZone) {
            case .fromFile: break
            case .localNoon: counts.localNoon += 1
            case .laterThatDay: counts.laterThatDay += 1
            case .dayMissingHere: counts.dayMissingHere += 1
            case .unknownDay: counts.unknownDay += 1
            }
        }
        return counts
    }

    /// Stage immutable bytes for the share extension or Photos transaction. Only an exact
    /// match of the picked file's hash is described as the original.
    public static func prepare(photo: PhotoRecord, stored: URL?, in directory: URL,
                               libraryData: @Sendable () async throws -> Data) async throws -> Self {
        if photo.reducedFrom == nil, let stored, LibraryStore.hashFile(stored) == photo.sha256 {
            return try stageStored(stored, hash: photo.sha256, in: directory, reason: nil)
        }

        let issue: PhotoSourceIssue
        do {
            let data = try await libraryData()
            try Task.checkCancellation()
            guard PhotoIngest.sha256Hex(data) == (photo.reducedFrom?.sha256 ?? photo.sha256) else {
                throw PhotoSourceIssue.changed
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let uti = CGImageSourceGetType(source) as String?,
                  let ext = UTType(uti)?.preferredFilenameExtension else { throw PhotoSourceIssue.unavailable }
            let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            try data.write(to: url, options: .atomic)
            return Self(url: url, copyReason: nil)
        } catch let reason as PhotoSourceIssue {
            issue = reason
        }
        try Task.checkCancellation()
        guard photo.reducedFrom != nil, let stored else { throw issue }
        return try stageStored(stored, hash: photo.sha256, in: directory, reason: issue,
                               copyCaptureDay: CopyCaptureDay(photo))
    }

    /// Produce one upright, full-resolution still for receivers that only accept standard images.
    /// A separate staged file keeps the verified source available for exact file sharing and Photos.
    public func compatibleJPEG() async throws -> URL {
        try Task.checkCancellation()
        return try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard let index = PhotoIngest.primaryIndex(of: source),
                  let pixels = PhotoIngest.uprightImage(source: source, index: index) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let output = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".jpg")
            guard let writer = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let encoding: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95,
                                             kCGImageDestinationBackgroundColor: CGColor(gray: 1, alpha: 1)]
            CGImageDestinationAddImage(writer, pixels, encoding as CFDictionary)
            guard CGImageDestinationFinalize(writer) else {
                try? FileManager.default.removeItem(at: output)
                throw CocoaError(.fileWriteUnknown)
            }
            return output
        }
    }

    private static func stageStored(_ source: URL, hash: String, in directory: URL,
                                    reason: PhotoSourceIssue?, copyCaptureDay: CopyCaptureDay? = nil) throws -> Self {
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(source.pathExtension)
        try FileManager.default.copyItem(at: source, to: url)
        guard LibraryStore.hashFile(url) == hash else {
            try FileManager.default.removeItem(at: url)
            throw CocoaError(.fileReadCorruptFile)
        }
        return Self(url: url, copyReason: reason, copyCaptureDay: copyCaptureDay)
    }
}
