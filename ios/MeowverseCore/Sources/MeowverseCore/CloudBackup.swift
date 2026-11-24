import Foundation
import os

// Automatic backup into a folder the user owns (the app's iCloud Drive folder; a plain folder
// in tests). It reuses the backup archive (`BackupArchive`) unchanged: one whole ZIP per
// backup plus a small info file beside it. This is a backup, not a sync: nothing is merged,
// and a restore goes through the same preview and all-or-nothing switch as a picked file.
//
// Rules that keep a good backup safe:
// - an archive is built and fully verified in a local work folder before it goes anywhere;
// - the info file is written last and is what makes a backup count as verified;
// - only verified backups of this device are rotated out, and never the last one;
// - other devices' files and files this code did not name are never deleted.

// MARK: - Errors and states

public enum CloudAvailability: String, Sendable, Equatable, Codable {
    case available
    /// No iCloud account, or iCloud Drive is switched off.
    case signedOut
    /// Signed in, but this app has no iCloud Drive folder (switched off for the app, or not provisioned).
    case containerUnavailable
}

/// Codes only: never a path, a file name or file content.
public enum CloudBackupError: Error, Equatable, Sendable {
    case unavailable(CloudAvailability)
    /// The archive did not pass verification, before or after it was moved. Nothing was replaced.
    case verificationFailed(String)
    /// A file of that name is already there; nothing was overwritten.
    case nameTaken
    case notFound
    /// Downloading needs a network connection.
    case offline
    /// iCloud storage is full.
    case quotaExceeded
    case io(String)
}

public enum CloudUploadState: Sendable, Equatable {
    /// A plain folder: there is no upload.
    case notApplicable
    /// In the iCloud Drive folder; the system has not said more.
    case pending
    case uploading
    case uploaded
    case failed(quotaExceeded: Bool)
}

// MARK: - File names

/// `Meowverse-backup-<device id>-<UTC time>-r<revision>.zip` and the same stem with `.json`.
/// The device id is 12 random hex digits made once per install: nothing the user typed (the
/// cat's name, the device's name) is in a file name.
public struct CloudBackupName: Sendable, Hashable {
    public let deviceID: String
    /// Whole seconds.
    public let createdAt: Date
    public let revision: Int

    static let prefix = "Meowverse-backup-"
    static let deviceIDLength = 12

    public init?(deviceID: String, createdAt: Date, revision: Int) {
        guard Self.isDeviceID(deviceID), revision >= 0 else { return nil }
        self.deviceID = deviceID
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        self.revision = revision
    }

    public init?(archiveName: String) {
        self.init(fileName: archiveName, ext: ".zip")
    }

    public init?(infoName: String) {
        self.init(fileName: infoName, ext: ".json")
    }

    private init?(fileName: String, ext: String) {
        guard fileName.hasPrefix(Self.prefix), fileName.hasSuffix(ext), fileName.utf8.count < 100 else { return nil }
        let parts = fileName.dropFirst(Self.prefix.count).dropLast(ext.count).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].hasPrefix("r"), parts[1].utf8.count == 16,
              parts[2].dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }),
              let revision = Int(parts[2].dropFirst()),
              let date = Self.formatter().date(from: String(parts[1]))
        else { return nil }
        self.init(deviceID: String(parts[0]), createdAt: date, revision: revision)
        // Only names this code would write itself: "r007" or a lenient date do not round-trip.
        guard self.stem + ext == fileName else { return nil }
    }

    private var stem: String { "\(Self.prefix)\(deviceID)-\(Self.formatter().string(from: createdAt))-r\(revision)" }
    public var archiveName: String { stem + ".zip" }
    public var infoName: String { stem + ".json" }

    public static func newDeviceID() -> String {
        String(UUID().uuidString.lowercased().filter { $0 != "-" }.prefix(deviceIDLength))
    }

    static func isDeviceID(_ value: String) -> Bool {
        value.utf8.count == deviceIDLength && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.isLenient = false
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }

    /// Newest first.
    static func newestFirst(_ a: CloudBackupName, _ b: CloudBackupName) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        if a.revision != b.revision { return a.revision > b.revision }
        return a.deviceID < b.deviceID
    }
}

// MARK: - Info file

/// Written beside an archive after it was verified and moved: what the list shows without
/// opening (or downloading) the archive. A hint only; a restore verifies the archive itself.
public struct CloudBackupInfo: Codable, Sendable, Equatable {
    public static let format = "meowverse-cloud-backup-info"
    public static let version = 1
    static let maxBytes = 64 * 1024

    public var format: String
    public var version: Int
    public var archiveName: String
    public var deviceID: String
    /// "iPhone", "iPad": the kind of device, not its name.
    public var deviceKind: String
    public var createdAt: Date
    public var revision: Int
    public var photoCount: Int
    public var furnitureCount: Int
    public var byteSize: Int
    public var sha256: String
    public var appVersion: String

    static func decode(_ data: Data, for name: CloudBackupName) -> CloudBackupInfo? {
        guard data.count <= maxBytes else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let info = try? decoder.decode(CloudBackupInfo.self, from: data),
              info.format == format, info.version >= 1, info.version <= version,
              info.archiveName == name.archiveName, info.deviceID == name.deviceID, info.revision == name.revision,
              info.photoCount >= 0, info.furnitureCount >= 0, info.byteSize > 0, BackupArchive.isHash(info.sha256)
        else { return nil }
        return info
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

// MARK: - Destination

/// One file as the destination reports it.
public struct CloudBackupFile: Sendable, Equatable {
    public var name: String
    /// nil when the destination cannot tell (a placeholder for a file that is not downloaded).
    public var byteSize: Int?
    public var isDownloaded: Bool
    public var upload: CloudUploadState

    public init(name: String, byteSize: Int?, isDownloaded: Bool, upload: CloudUploadState) {
        self.name = name
        self.byteSize = byteSize
        self.isDownloaded = isDownloaded
        self.upload = upload
    }
}

/// Where backups are kept: one flat folder. All calls may block; call them off the main actor.
public protocol BackupDestination: Sendable {
    func availability() -> CloudAvailability
    /// Which account the folder belongs to, as an opaque fingerprint (`CloudBackupAccount`);
    /// nil when there is none or it cannot be told. Fast: no file access. Backups are written
    /// only while this is the account the user agreed for.
    func accountFingerprint() -> String?
    func list() throws -> [CloudBackupFile]
    /// A small file that is already local. Throws when it is missing or not downloaded.
    func readSmallFile(_ name: String) throws -> Data
    /// Moves a finished local file in under `name`. Never replaces an existing file.
    func place(_ local: URL, as name: String) throws
    func writeSmallFile(_ data: Data, as name: String) throws
    func remove(_ name: String) throws
    /// The file itself when its content is on this device, else nil.
    func localURL(for name: String) -> URL?
    /// Makes the file local (downloading it if needed) and returns where it can be read.
    /// `progress` gets 0...1, or nil while the amount is not known.
    func download(_ name: String, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL
}

/// A plain folder. Used by tests and by the app's test switch; also the reference behaviour
/// for the iCloud Drive destination.
public struct FolderBackupDestination: BackupDestination {
    /// The account a plain folder reports unless it is told another one.
    public static let defaultAccount = "folder"

    public let folder: URL
    private let fixedAvailability: CloudAvailability
    private let account: String?

    public init(folder: URL, availability: CloudAvailability = .available, account: String? = Self.defaultAccount) {
        self.folder = folder
        fixedAvailability = availability
        self.account = account
    }

    public func availability() -> CloudAvailability { fixedAvailability }
    public func accountFingerprint() -> String? { account }

    private func url(_ name: String) throws -> URL {
        guard Self.isPlainName(name) else { throw CloudBackupError.io("name") }
        return folder.appendingPathComponent(name, isDirectory: false)
    }

    /// One path component, not hidden.
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\0") && name.utf8.count <= 200
    }

    public func list() throws -> [CloudBackupFile] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return [] }
        let names: [String]
        do { names = try fm.contentsOfDirectory(atPath: folder.path) } catch { throw CloudBackupError.io("list") }
        return names.filter(Self.isPlainName).sorted().compactMap { name in
            let path = folder.appendingPathComponent(name).path
            guard let attributes = try? fm.attributesOfItem(atPath: path), attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber else { return nil }
            return CloudBackupFile(name: name, byteSize: size.intValue, isDownloaded: true, upload: .notApplicable)
        }
    }

    public func readSmallFile(_ name: String) throws -> Data {
        let url = try url(name)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else { throw CloudBackupError.notFound }
        guard size.intValue <= CloudBackupInfo.maxBytes, let data = try? Data(contentsOf: url) else { throw CloudBackupError.io("read") }
        return data
    }

    public func place(_ local: URL, as name: String) throws {
        let fm = FileManager.default
        let target = try url(name)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            guard !fm.fileExists(atPath: target.path) else { throw CloudBackupError.nameTaken }
            // Copied under a hidden name first when the folder is on another volume, so the
            // visible name only ever appears complete.
            let partial = folder.appendingPathComponent(".partial-\(UUID().uuidString)", isDirectory: false)
            defer { try? fm.removeItem(at: partial) }
            try fm.moveItem(at: local, to: partial)
            LibraryStore.fsyncDirectory(folder)
            guard link(partial.path, target.path) == 0 else { throw errno == EEXIST ? CloudBackupError.nameTaken : CloudBackupError.io("link") }
            LibraryStore.fsyncDirectory(folder)
        } catch let error as CloudBackupError {
            throw error
        } catch {
            throw CloudBackupError.io("place")
        }
    }

    public func writeSmallFile(_ data: Data, as name: String) throws {
        let target = try url(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        } catch {
            throw CloudBackupError.io("write")
        }
    }

    public func remove(_ name: String) throws {
        let target = try url(name)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        do { try FileManager.default.removeItem(at: target) } catch { throw CloudBackupError.io("remove") }
    }

    public func localURL(for name: String) -> URL? {
        guard let target = try? url(name), FileManager.default.fileExists(atPath: target.path) else { return nil }
        return target
    }

    public func download(_ name: String, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        guard let url = localURL(for: name) else { throw CloudBackupError.notFound }
        progress(1)
        return url
    }
}

// MARK: - Listing

/// One backup in the destination.
public struct CloudBackupEntry: Sendable, Equatable, Identifiable {
    public enum Condition: Sendable, Equatable {
        /// Has its info file and the archive's size matches it.
        case verified
        /// Its info file is there but not on this device yet (iCloud has not downloaded it).
        /// Probably fine; never pruned, and a restore verifies it in full.
        case pending
        /// An archive without a usable info file (interrupted, or the info was removed).
        /// It may be perfectly good; a restore verifies it in full.
        case unverified
        /// The size does not match the info, or a restore found it broken.
        case damaged
    }

    public var name: CloudBackupName
    public var info: CloudBackupInfo?
    public var byteSize: Int?
    public var isDownloaded: Bool
    public var upload: CloudUploadState
    public var condition: Condition
    public var isFromThisDevice: Bool

    public var id: String { name.archiveName }

    public init(name: CloudBackupName, info: CloudBackupInfo?, byteSize: Int?, isDownloaded: Bool, upload: CloudUploadState,
                condition: Condition, isFromThisDevice: Bool) {
        self.name = name
        self.info = info
        self.byteSize = byteSize
        self.isDownloaded = isDownloaded
        self.upload = upload
        self.condition = condition
        self.isFromThisDevice = isFromThisDevice
    }
}

public struct CloudBackupListing: Sendable, Equatable {
    /// Newest first.
    public var entries: [CloudBackupEntry]
    /// Info files of this device whose archive is gone or which are not usable.
    public var orphanInfoNames: [String]

    public init(entries: [CloudBackupEntry] = [], orphanInfoNames: [String] = []) {
        self.entries = entries
        self.orphanInfoNames = orphanInfoNames
    }
}

public enum CloudBackupCatalog {
    /// What the destination holds. Files with other names are not ours and are left out.
    public static func load(from destination: any BackupDestination, deviceID: String,
                            knownDamaged: Set<String> = []) throws -> CloudBackupListing {
        let files = try destination.list()
        var infos: [CloudBackupName: CloudBackupInfo] = [:]
        var infoFiles: [CloudBackupName: String] = [:]
        // Read, but not a valid info for that name: safe to delete. An info that could not be
        // read (not downloaded yet) is not held against its archive.
        var invalidInfos = Set<CloudBackupName>()
        var unreadInfos = Set<CloudBackupName>()
        for file in files {
            guard let name = CloudBackupName(infoName: file.name) else { continue }
            infoFiles[name] = file.name
            if let data = try? destination.readSmallFile(file.name) {
                if let info = CloudBackupInfo.decode(data, for: name) { infos[name] = info } else { invalidInfos.insert(name) }
            } else {
                unreadInfos.insert(name)
            }
        }
        var entries: [CloudBackupEntry] = []
        var seen = Set<CloudBackupName>()
        for file in files {
            guard let name = CloudBackupName(archiveName: file.name), seen.insert(name).inserted else { continue }
            let info = infos[name]
            let condition: CloudBackupEntry.Condition
            if knownDamaged.contains(file.name) {
                condition = .damaged
            } else if let info {
                // A size the destination cannot report yet (not downloaded) is not held against it.
                condition = file.byteSize.map { $0 == info.byteSize } ?? true ? .verified : .damaged
            } else if unreadInfos.contains(name) {
                condition = .pending
            } else {
                condition = .unverified
            }
            entries.append(CloudBackupEntry(name: name, info: info, byteSize: file.byteSize ?? info?.byteSize, isDownloaded: file.isDownloaded,
                                            upload: file.upload, condition: condition, isFromThisDevice: name.deviceID == deviceID))
        }
        entries.sort { CloudBackupName.newestFirst($0.name, $1.name) }
        let orphans = infoFiles.filter { $0.key.deviceID == deviceID && (!seen.contains($0.key) || invalidInfos.contains($0.key)) }.values.sorted()
        return CloudBackupListing(entries: entries, orphanInfoNames: orphans)
    }
}

// MARK: - Settings

/// The last backup that fully succeeded.
public struct CloudBackupRecord: Codable, Sendable, Equatable {
    public var archiveName: String
    /// SHA-256 of the library state inside that archive.
    public var fingerprint: String
    public var revision: Int
    public var date: Date
    public var photoCount: Int
    public var furnitureCount: Int
    public var byteSize: Int

    public init(archiveName: String, fingerprint: String, revision: Int, date: Date, photoCount: Int, furnitureCount: Int, byteSize: Int) {
        self.archiveName = archiveName
        self.fingerprint = fingerprint
        self.revision = revision
        self.date = date
        self.photoCount = photoCount
        self.furnitureCount = furnitureCount
        self.byteSize = byteSize
    }
}

/// What the app remembers about cloud backup for one library. Off until the user turns it on.
public struct CloudBackupSettings: Codable, Sendable, Equatable {
    public struct Failure: Codable, Sendable, Equatable {
        public var date: Date
        /// An error code, never a path or a name.
        public var code: String

        public init(date: Date, code: String) {
            self.date = date
            self.code = code
        }
    }

    public static let maxDamagedNames = 20

    public var enabled = false
    public var lastSuccess: CloudBackupRecord?
    /// The most recent attempt that failed after the last success; cleared by a success.
    public var lastFailure: Failure?
    /// Archives a restore found broken, so they are not offered first again.
    public var damagedNames: [String] = []
    /// The user closed the "restore from iCloud" offer on the empty room.
    public var restoreOfferDismissed = false
    /// The account backups go to (`CloudBackupAccount.fingerprint`): the one signed in when the
    /// user turned backup on, or later chose to keep backing up to. nil from builds before it
    /// was remembered. Never an account name or the token itself.
    public var account: String?

    public init() {}

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        lastSuccess = try values.decodeIfPresent(CloudBackupRecord.self, forKey: .lastSuccess)
        lastFailure = try values.decodeIfPresent(Failure.self, forKey: .lastFailure)
        damagedNames = try values.decodeIfPresent([String].self, forKey: .damagedNames) ?? []
        restoreOfferDismissed = try values.decodeIfPresent(Bool.self, forKey: .restoreOfferDismissed) ?? false
        account = try values.decodeIfPresent(String.self, forKey: .account)
    }

    public mutating func rememberDamaged(_ archiveName: String) {
        damagedNames.removeAll { $0 == archiveName }
        damagedNames.append(archiveName)
        if damagedNames.count > Self.maxDamagedNames { damagedNames.removeFirst(damagedNames.count - Self.maxDamagedNames) }
    }
}

// MARK: - Account

/// Which Apple Account an iCloud Drive folder belongs to, without naming it: the system's
/// identity token is hashed with a tag of this app, and only a short prefix is kept. Enough to
/// tell two accounts apart on one device; nothing that identifies the person or matches the
/// token elsewhere.
public enum CloudBackupAccount {
    static let tag = Data("meowverse.icloud-drive-backup.account.v1:".utf8)

    /// `ud-` and 20 hex digits.
    public static func fingerprint(token: Data) -> String {
        "ud-" + PhotoIngest.sha256Hex(tag + token).prefix(20)
    }
}

// MARK: - Policy

public enum CloudBackupPolicy {
    /// Verified backups of this device that are kept. One (owner, 2026-11-13): every backup
    /// holds all the photos, so three of them tripled the iCloud storage the app used. The
    /// previous backup still stays until the new one is verified, and the newest one known
    /// to have reached iCloud is never pruned, so there is always one good backup.
    public static let keepCount = 1
    /// Automatic backups are at most this often.
    public static let minimumInterval: TimeInterval = 24 * 60 * 60
    /// After a failed attempt, an automatic one waits this long.
    public static let retryInterval: TimeInterval = 60 * 60

    public enum Trigger: Sendable, Equatable {
        /// App launch or going to the background.
        case automatic
        /// The user tapped "back up now".
        case manual
    }

    public enum Skip: Sendable, Equatable {
        case disabled
        /// Signed in to another account than the one backups belong to, or the account changed
        /// while this backup ran. Waits for the user's answer.
        case otherAccount
        /// No account was ever remembered (turned on while signed out, or by an older build) and
        /// nothing shows this one is it. Not called another account; waits for the user to confirm.
        case accountUnconfirmed
        /// iCloud Drive is there but which account it belongs to cannot be told.
        case accountUnknown
        /// An empty room is never backed up: it would only rotate real backups out.
        case emptyLibrary
        case unchanged
        case tooSoon(until: Date)
    }

    public enum Decision: Sendable, Equatable {
        case backUp
        case skip(Skip)
    }

    public enum AccountCheck: Sendable, Equatable {
        /// Signed in to the account backups belong to.
        case matches
        /// Settings from before the account was remembered, and this device's last backup is in
        /// this account's folder: the account is this one, and is remembered from now on.
        case adopt(String)
        /// Another account than the remembered one.
        case differs
        /// No account remembered, and nothing shows this is the one the user agreed for. Nothing
        /// shows it is another either: the user is asked to confirm, in neutral words.
        case unconfirmed
        /// No account to compare, or the folder could not be read to find out.
        case unknown
    }

    /// Whose iCloud Drive this is, compared with the account backups belong to. A remembered
    /// account is never replaced here: only the user's answer does that. `listing` counts as
    /// proof only if it was read while signed in to `current` (callers read the account before
    /// and after listing, and pass nil when the two differ).
    public static func checkAccount(remembered: String?, current: String?, lastSuccess: CloudBackupRecord?,
                                    listing: CloudBackupListing?) -> AccountCheck {
        guard let current else { return .unknown }
        if let remembered { return remembered == current ? .matches : .differs }
        guard let listing else { return .unknown }
        guard let lastSuccess,
              listing.entries.contains(where: { $0.name.archiveName == lastSuccess.archiveName && $0.condition != .damaged })
        else { return .unconfirmed }
        return .adopt(current)
    }

    public static func decide(enabled: Bool, trigger: Trigger, libraryIsEmpty: Bool, fingerprint: String,
                              lastSuccess: CloudBackupRecord?, lastSuccessStillPresent: Bool, lastFailure: Date?, now: Date) -> Decision {
        guard enabled else { return .skip(.disabled) }
        guard !libraryIsEmpty else { return .skip(.emptyLibrary) }
        // A backup the user removed from the folder no longer counts.
        let last = lastSuccessStillPresent ? lastSuccess : nil
        if let last, last.fingerprint == fingerprint { return .skip(.unchanged) }
        guard trigger == .automatic else { return .backUp }
        if let lastFailure, (0..<retryInterval).contains(now.timeIntervalSince(lastFailure)) {
            return .skip(.tooSoon(until: lastFailure + retryInterval))
        }
        if let last, (0..<minimumInterval).contains(now.timeIntervalSince(last.date)) {
            return .skip(.tooSoon(until: last.date + minimumInterval))
        }
        return .backUp
    }

    /// The backup to offer first: the newest verified one; without any, the newest one whose
    /// info is still on its way, then the newest without info. Never one known to be damaged.
    /// The user can still pick any other that is not damaged from the list.
    public static func recommended(_ entries: [CloudBackupEntry]) -> CloudBackupEntry? {
        let sorted = entries.sorted { CloudBackupName.newestFirst($0.name, $1.name) }
        return sorted.first { $0.condition == .verified } ?? sorted.first { $0.condition == .pending }
            ?? sorted.first { $0.condition == .unverified }
    }

    /// The backup an empty room offers: of those it may offer (`offersRestore`), the one
    /// `recommended` would pick. Filtered first (QA_T2 R3-1): a newer empty backup from a third
    /// device must not hide an older one with photos in it.
    public static func restoreOffer(_ entries: [CloudBackupEntry]) -> CloudBackupEntry? {
        recommended(entries.filter(offersRestore(of:)))
    }

    /// Whether an empty room offers this backup (QA_T2 R2-1). Not this device's own: it holds what
    /// this library had, and a library whose only change was a name was offered its own backup
    /// back. Not one whose info says it holds no photos and no furniture: there is nothing to bring
    /// back. One whose info is not here yet is offered; unknown is not empty. Settings › iCloud
    /// backup still lists them all.
    public static func offersRestore(of entry: CloudBackupEntry) -> Bool {
        guard !entry.isFromThisDevice else { return false }
        if let info = entry.info, info.photoCount == 0, info.furnitureCount == 0 { return false }
        return true
    }

    /// Whether the backup is known to be stored safely: uploaded to iCloud, or in a plain folder.
    static func isStored(_ entry: CloudBackupEntry) -> Bool {
        entry.upload == .uploaded || entry.upload == .notApplicable
    }

    /// File names to delete after a successful backup. Only this device's files: verified
    /// backups beyond the newest `keep` (at least one always stays), and leftovers (no info, or
    /// damaged) older than the newest verified one. Without a verified backup nothing is deleted.
    /// Never deleted: a backup whose info has not reached this device yet, and the newest
    /// verified backup that is known to be uploaded (so a full iCloud that stops uploads can
    /// never rotate the last uploaded backup out in favour of ones that only exist locally).
    public static func prune(_ entries: [CloudBackupEntry], keep: Int = keepCount) -> [String] {
        let mine = entries.filter(\.isFromThisDevice).sorted { CloudBackupName.newestFirst($0.name, $1.name) }
        let verified = mine.filter { $0.condition == .verified }
        let kept = verified.prefix(max(1, keep))
        guard let newestKept = kept.first else { return [] }
        var keptNames = Set(kept.map(\.name))
        if let newestStored = verified.first(where: isStored) { keptNames.insert(newestStored.name) }
        var doomed: [CloudBackupEntry] = []
        for entry in mine where !keptNames.contains(entry.name) {
            switch entry.condition {
            case .verified: doomed.append(entry)
            case .pending: break
            case .unverified, .damaged:
                if CloudBackupName.newestFirst(newestKept.name, entry.name) { doomed.append(entry) }
            }
        }
        return doomed.flatMap { [$0.name.archiveName, $0.name.infoName] }
    }
}

// MARK: - Engine

extension LibraryStore {
    /// SHA-256 of the state as it is stored: equal exactly when nothing in the library changed.
    public func backupFingerprint() throws -> String {
        PhotoIngest.sha256Hex(try Self.encodeState(snapshot()))
    }
}

public enum CloudBackupEngine {
    public struct Context: Sendable {
        public var deviceID: String
        public var deviceKind: String
        public var appVersion: String
        /// An empty local folder for the archive while it is built and verified. Removed afterwards.
        public var workDirectory: URL
        public var catalog: FurnitureCatalog
        public var keepCount: Int
        /// Free bytes on the volume of `workDirectory`; nil measures it. Set by tests.
        public var availableSpace: Int?

        public init(deviceID: String, deviceKind: String, appVersion: String, workDirectory: URL, catalog: FurnitureCatalog,
                    keepCount: Int = CloudBackupPolicy.keepCount, availableSpace: Int? = nil) {
            self.deviceID = deviceID
            self.deviceKind = deviceKind
            self.appVersion = appVersion
            self.workDirectory = workDirectory
            self.catalog = catalog
            self.keepCount = keepCount
            self.availableSpace = availableSpace
        }
    }

    /// Room kept free beside the work files, so a backup never fills the phone.
    static let spareBytes = 200 * 1024 * 1024

    /// Bytes a backup of `state` needs locally while it is built: the archive plus the
    /// verification copy that `BackupArchive.prepare` writes, each about the size of the originals.
    public static func localSpaceNeeded(for state: AppState) -> Int {
        2 * state.photos.reduce(0) { $0 + $1.byteSize } + spareBytes
    }

    /// Free bytes for important use on the volume holding `directory` (or its nearest existing parent).
    public static func freeSpace(at directory: URL) -> Int? {
        var probe = directory
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        guard let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return Int(free)
    }

    public enum Outcome: Sendable, Equatable {
        case skipped(CloudBackupPolicy.Skip)
        case completed(CloudBackupRecord)
    }

    private static let log = Logger(subsystem: "app.meowverse", category: "cloudBackup")

    /// Decides whether a backup is due and, if so, writes one. Nothing is written to the
    /// destination unless `settings.enabled` is true. Throws when a backup was due and failed;
    /// in that case every backup that was in the destination before is still there, unchanged.
    public static func backUpIfNeeded(store: LibraryStore, destination: any BackupDestination, settings: CloudBackupSettings,
                                      trigger: CloudBackupPolicy.Trigger, context: Context, now: Date = Date(),
                                      progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Outcome {
        defer { try? FileManager.default.removeItem(at: context.workDirectory) }
        guard settings.enabled else { return .skipped(.disabled) }
        let state = await store.snapshot()
        let isEmpty = state.isEmptyForBackup
        guard !isEmpty else { return .skipped(.emptyLibrary) }
        let availability = destination.availability()
        guard availability == .available else { throw CloudBackupError.unavailable(availability) }

        let fingerprint = try await store.backupFingerprint()
        // Only into the account the user agreed for: never into another person's iCloud Drive.
        // Asked before and after the listing, so the listing is known to be of that account.
        let listedUnder = destination.accountFingerprint()
        let before = try CloudBackupCatalog.load(from: destination, deviceID: context.deviceID, knownDamaged: Set(settings.damagedNames))
        let account = destination.accountFingerprint()
        guard listedUnder == account else {
            log.notice("cloud backup stopped: the iCloud account changed")
            return .skipped(.otherAccount)
        }
        switch CloudBackupPolicy.checkAccount(remembered: settings.account, current: account, lastSuccess: settings.lastSuccess, listing: before) {
        case .matches, .adopt: break
        case .differs: return .skipped(.otherAccount)
        case .unconfirmed: return .skipped(.accountUnconfirmed)
        case .unknown: return .skipped(.accountUnknown)
        }
        // Still there and not found broken. Its info merely not being local (evicted) does not
        // make the library "changed": that would write a duplicate every day.
        let lastPresent = settings.lastSuccess.map { last in
            before.entries.contains { $0.name.archiveName == last.archiveName && $0.condition != .damaged }
        } ?? false
        let decision = CloudBackupPolicy.decide(
            enabled: settings.enabled, trigger: trigger, libraryIsEmpty: isEmpty, fingerprint: fingerprint,
            lastSuccess: settings.lastSuccess, lastSuccessStillPresent: lastPresent, lastFailure: settings.lastFailure?.date, now: now)
        if case .skip(let reason) = decision { return .skipped(reason) }

        // Refuse cheaply, before reading or writing anything, what cannot succeed: a library
        // over the single-file limit (no ZIP64), or a phone without room for the work files.
        let originals = state.photos.reduce(0) { $0 + $1.byteSize }
        guard originals < ZipLimits.backup.maxArchiveBytes - spareBytes else { throw BackupError.tooLarge }
        if let free = context.availableSpace ?? freeSpace(at: context.workDirectory), free < localSpaceNeeded(for: state) {
            throw CloudBackupError.io("space")
        }

        let record: CloudBackupRecord
        do {
            record = try await write(store: store, destination: destination, account: account, context: context, now: now, progress: progress)
        } catch AccountSwitched.during {
            log.notice("cloud backup stopped: the iCloud account changed")
            return .skipped(.otherAccount)
        }
        // Pruning lists and deletes in whatever account is signed in now: only in the one written to.
        if destination.accountFingerprint() == account {
            prune(destination: destination, context: context, knownDamaged: Set(settings.damagedNames))
        } else {
            log.notice("cloud backup not pruned: the iCloud account changed")
        }
        return .completed(record)
    }

    private enum AccountSwitched: Error { case during }

    /// Build locally → verify → move in → read back → info file. The info file is the last
    /// step: until it exists the new archive does not count, and nothing else was touched.
    /// The account is asked again before each step that writes, since every call reaches the
    /// iCloud Drive of whoever is signed in at that moment.
    private static func write(store: LibraryStore, destination: any BackupDestination, account: String?, context: Context, now: Date,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> CloudBackupRecord {
        let fm = FileManager.default
        let work = context.workDirectory
        do { try fm.createDirectory(at: work, withIntermediateDirectories: true) } catch { throw CloudBackupError.io("workDirectory") }
        let local = work.appendingPathComponent("archive.zip", isDirectory: false)

        // 1. The same export as "export backup": every original is re-hashed first.
        let summary = try await store.exportBackup(to: local, appVersion: context.appVersion) { progress($0.fraction * 0.45) }
        try Task.checkCancellation()

        // 2. The same verification a restore runs, on the finished file.
        let staging = work.appendingPathComponent("verify", isDirectory: true)
        let prepared: PreparedLibrary
        do {
            prepared = try BackupArchive.prepare(file: local, stagingURL: staging, catalog: context.catalog) { progress(0.45 + $0.fraction * 0.4) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CloudBackupError.verificationFailed("archive")
        }
        prepared.discard()
        let state = prepared.state
        let furnitureCount = state.items.count + state.storage.count
        guard prepared.preview.kind == .iosBackup, state.photos.count == summary.photoCount, furnitureCount == summary.furnitureCount,
              let sha256 = LibraryStore.hashFile(local),
              let size = (try? fm.attributesOfItem(atPath: local.path))?[.size] as? NSNumber, size.intValue == summary.byteSize,
              let name = CloudBackupName(deviceID: context.deviceID, createdAt: now, revision: state.revision)
        else { throw CloudBackupError.verificationFailed("summary") }
        let fingerprint = PhotoIngest.sha256Hex(try LibraryStore.encodeState(state))
        progress(0.88)
        try Task.checkCancellation()

        // 3. Move it in under a new name. An existing file is never replaced. Not at all if
        // another account was signed in while it was built.
        guard destination.accountFingerprint() == account else { throw AccountSwitched.during }
        try destination.place(local, as: name.archiveName)

        // 4. Read it back where it now is. If that fails the new file is taken out again.
        guard let placed = destination.localURL(for: name.archiveName), LibraryStore.hashFile(placed) == sha256 else {
            try? destination.remove(name.archiveName)
            throw CloudBackupError.verificationFailed("placed")
        }
        progress(0.97)

        // 5. The info file makes it count; not in an account switched to since the move. The
        // archive without it is an unverified leftover in the first account, pruned later there.
        guard destination.accountFingerprint() == account else { throw AccountSwitched.during }
        let info = CloudBackupInfo(
            format: CloudBackupInfo.format, version: CloudBackupInfo.version, archiveName: name.archiveName, deviceID: context.deviceID,
            deviceKind: String(context.deviceKind.prefix(40)), createdAt: name.createdAt, revision: state.revision,
            photoCount: summary.photoCount, furnitureCount: summary.furnitureCount, byteSize: summary.byteSize, sha256: sha256,
            appVersion: String(context.appVersion.prefix(40)))
        try destination.writeSmallFile(try info.encoded(), as: name.infoName)
        progress(1)
        log.info("cloud backup written: photos=\(summary.photoCount, privacy: .public) bytes=\(summary.byteSize, privacy: .public)")
        return CloudBackupRecord(archiveName: name.archiveName, fingerprint: fingerprint, revision: state.revision, date: name.createdAt,
                                 photoCount: summary.photoCount, furnitureCount: summary.furnitureCount, byteSize: summary.byteSize)
    }

    /// After a success only. A failure here costs storage, never a backup, so it is not an error.
    private static func prune(destination: any BackupDestination, context: Context, knownDamaged: Set<String>) {
        guard let listing = try? CloudBackupCatalog.load(from: destination, deviceID: context.deviceID, knownDamaged: knownDamaged) else { return }
        let doomed = CloudBackupPolicy.prune(listing.entries, keep: context.keepCount) + listing.orphanInfoNames
        for name in doomed { try? destination.remove(name) }
        if !doomed.isEmpty { log.info("cloud backup pruned files=\(doomed.count, privacy: .public)") }
    }

    /// Deletes exactly the backups the user was shown and confirmed (archive and info file of
    /// each), and only ones this device wrote. Anything else in the folder, including a backup
    /// that appeared after the user was asked, stays. Returns how many archives were deleted.
    @discardableResult
    public static func deleteBackups(_ names: [CloudBackupName], deviceID: String, in destination: any BackupDestination) throws -> Int {
        var deleted = 0
        for name in names where name.deviceID == deviceID {
            // The info first: a half-finished delete leaves an "unverified" archive, never a verified ghost.
            try destination.remove(name.infoName)
            try destination.remove(name.archiveName)
            deleted += 1
        }
        return deleted
    }
}
