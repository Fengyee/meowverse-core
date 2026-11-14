import Compression
import Foundation
import zlib

/// Why a ZIP file was refused. Codes only; never a path or file content.
public enum ZipError: Error, Equatable, Sendable {
    /// Archive, one entry or the declared total is over the limits, or there are too many entries.
    case tooLarge
    /// No usable end-of-central-directory record: not a (complete) ZIP file.
    case notZip
    /// Multi-volume, ZIP64, encrypted, or a compression method other than stored/deflate.
    case unsupported
    /// Structurally inconsistent; the code names the check that failed.
    case corrupt(String)
    case unsafePath
    case duplicateEntry
    /// The data of an entry does not match its CRC-32.
    case checksum
}

public struct ZipLimits: Sendable, Equatable {
    public var maxArchiveBytes: Int
    public var maxEntries: Int
    public var maxEntryBytes: Int
    /// Sum of the declared uncompressed sizes.
    public var maxTotalBytes: Int

    public init(maxArchiveBytes: Int, maxEntries: Int, maxEntryBytes: Int, maxTotalBytes: Int) {
        self.maxArchiveBytes = maxArchiveBytes
        self.maxEntries = maxEntries
        self.maxEntryBytes = maxEntryBytes
        self.maxTotalBytes = maxTotalBytes
    }

    /// What a Meowverse backup may be: below the 4 GiB a ZIP without ZIP64 can describe,
    /// and no single file larger than the largest photo the app imports.
    public static let backup = ZipLimits(maxArchiveBytes: Int(UInt32.max) - 1, maxEntries: 20_000,
                                         maxEntryBytes: PhotoIngest.maxBytes, maxTotalBytes: Int(UInt32.max) - 1)
}

public struct ZipEntry: Sendable, Equatable {
    public let path: String
    /// 0 = stored, 8 = deflate.
    public let method: Int
    public let crc: UInt32
    public let compressedSize: Int
    public let uncompressedSize: Int
    let dataOffset: Int
}

/// A strict reader for untrusted ZIP files (same checks as the web `inspectZip`): every offset
/// and size is bounds-checked, names must be plain relative paths, entries may not repeat,
/// overlap or hide data between them, and nothing is ever written to disk by the reader.
public struct ZipReader: Sendable {
    public let entries: [ZipEntry]
    private let data: Data
    private let byPath: [String: Int]

    /// Maps the file instead of reading it into memory.
    public init(fileURL: URL, limits: ZipLimits) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue
        guard let size else { throw ZipError.notZip }
        guard size <= limits.maxArchiveBytes else { throw ZipError.tooLarge }
        guard let data = try? Data(contentsOf: fileURL, options: [.alwaysMapped]) else { throw ZipError.notZip }
        try self.init(data: data, limits: limits)
    }

    public init(data source: Data, limits: ZipLimits) throws {
        let data = source.startIndex == 0 ? source : Data(source)
        let count = data.count
        guard count <= limits.maxArchiveBytes else { throw ZipError.tooLarge }
        guard count >= 22 else { throw ZipError.notZip }

        // End of central directory: the last record, its comment must end exactly at the file end.
        var end = -1
        var offset = count - 22
        let lowest = max(0, count - 65_557)
        while offset >= lowest {
            if try Self.u32(data, offset) == 0x0605_4b50, offset + 22 + (try Self.u16(data, offset + 20)) == count {
                end = offset
                break
            }
            offset -= 1
        }
        guard end >= 0 else { throw ZipError.notZip }
        if end >= 20, try Self.u32(data, end - 20) == 0x0706_4b50 { throw ZipError.unsupported }
        let entryCount = try Self.u16(data, end + 10)
        guard try Self.u16(data, end + 4) == 0, try Self.u16(data, end + 6) == 0,
              try Self.u16(data, end + 8) == entryCount else { throw ZipError.unsupported }
        guard entryCount != 0xFFFF else { throw ZipError.unsupported }
        guard entryCount > 0 else { throw ZipError.corrupt("empty") }
        guard entryCount <= limits.maxEntries else { throw ZipError.tooLarge }
        let centralSize = try Self.u32(data, end + 12), centralOffset = try Self.u32(data, end + 16)
        guard centralSize != 0xFFFF_FFFF, centralOffset != 0xFFFF_FFFF else { throw ZipError.unsupported }
        guard centralOffset + centralSize == end, centralOffset < count, centralSize >= entryCount * 46 else {
            throw ZipError.corrupt("directoryOffset")
        }

        var cursor = centralOffset, total = 0
        var entries: [ZipEntry] = [], segments: [(start: Int, end: Int)] = []
        var byPath: [String: Int] = [:]
        entries.reserveCapacity(entryCount)
        for _ in 0..<entryCount {
            guard cursor + 46 <= end, try Self.u32(data, cursor) == 0x0201_4b50 else { throw ZipError.corrupt("directory") }
            let flags = try Self.u16(data, cursor + 8), method = try Self.u16(data, cursor + 10)
            let crc = UInt32(try Self.u32(data, cursor + 16))
            let compressedSize = try Self.u32(data, cursor + 20), uncompressedSize = try Self.u32(data, cursor + 24)
            let nameLength = try Self.u16(data, cursor + 28), extraLength = try Self.u16(data, cursor + 30)
            let commentLength = try Self.u16(data, cursor + 32)
            let localOffset = try Self.u32(data, cursor + 42)
            guard cursor + 46 + nameLength + extraLength + commentLength <= end else { throw ZipError.corrupt("directoryLength") }
            // Only "UTF-8 names" and "data descriptor" flags; no encryption, no other volumes.
            guard flags & ~(0x800 | 8) == 0, method == 0 || method == 8, try Self.u16(data, cursor + 34) == 0 else {
                throw ZipError.unsupported
            }
            guard compressedSize != 0xFFFF_FFFF, uncompressedSize != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF else {
                throw ZipError.unsupported
            }
            // Unix mode in the high half of the external attributes: no symbolic links.
            if (try Self.u32(data, cursor + 38) >> 16) & 0o170000 == 0o120000 { throw ZipError.unsafePath }
            guard let path = String(data: data.subdata(in: cursor + 46..<cursor + 46 + nameLength), encoding: .utf8),
                  Self.isSafePath(path) else { throw ZipError.unsafePath }
            guard byPath[path] == nil else { throw ZipError.duplicateEntry }
            total += uncompressedSize
            guard total <= limits.maxTotalBytes, compressedSize <= limits.maxArchiveBytes,
                  uncompressedSize <= limits.maxEntryBytes else { throw ZipError.tooLarge }
            guard uncompressedSize > 0 else { throw ZipError.corrupt("emptyEntry") }

            guard localOffset + 30 <= centralOffset, try Self.u32(data, localOffset) == 0x0403_4b50 else {
                throw ZipError.corrupt("localHeader")
            }
            let localNameLength = try Self.u16(data, localOffset + 26), localExtraLength = try Self.u16(data, localOffset + 28)
            let dataOffset = localOffset + 30 + localNameLength + localExtraLength
            guard dataOffset + compressedSize <= centralOffset,
                  localNameLength == nameLength,
                  data.subdata(in: localOffset + 30..<localOffset + 30 + localNameLength) == data.subdata(in: cursor + 46..<cursor + 46 + nameLength),
                  try Self.u16(data, localOffset + 6) == flags, try Self.u16(data, localOffset + 8) == method
            else { throw ZipError.corrupt("localMismatch") }
            if flags & 8 == 0 {
                guard try Self.u32(data, localOffset + 14) == Int(crc), try Self.u32(data, localOffset + 18) == compressedSize,
                      try Self.u32(data, localOffset + 22) == uncompressedSize else { throw ZipError.corrupt("localSizes") }
            }
            var segmentEnd = dataOffset + compressedSize
            if flags & 8 != 0 {
                guard segmentEnd + 12 <= centralOffset else { throw ZipError.corrupt("descriptor") }
                let signature = try Self.u32(data, segmentEnd) == 0x0807_4b50 ? 4 : 0
                guard segmentEnd + signature + 12 <= centralOffset,
                      try Self.u32(data, segmentEnd + signature) == Int(crc),
                      try Self.u32(data, segmentEnd + signature + 4) == compressedSize,
                      try Self.u32(data, segmentEnd + signature + 8) == uncompressedSize
                else { throw ZipError.corrupt("descriptor") }
                segmentEnd += signature + 12
            }
            if method == 0, compressedSize != uncompressedSize { throw ZipError.corrupt("storedSize") }
            segments.append((localOffset, segmentEnd))
            byPath[path] = entries.count
            entries.append(ZipEntry(path: path, method: method, crc: crc, compressedSize: compressedSize,
                                    uncompressedSize: uncompressedSize, dataOffset: dataOffset))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        guard cursor == end else { throw ZipError.corrupt("directoryTail") }
        // Local records must tile [0, centralOffset): nothing hidden, overlapping or shared.
        segments.sort { $0.start < $1.start }
        var next = 0
        for segment in segments {
            guard segment.start == next, segment.end > segment.start else { throw ZipError.corrupt("layout") }
            next = segment.end
        }
        guard next == centralOffset else { throw ZipError.corrupt("layout") }

        self.entries = entries
        self.data = data
        self.byPath = byPath
    }

    public func entry(_ path: String) -> ZipEntry? {
        byPath[path].map { entries[$0] }
    }

    /// The entry's bytes, never more than its declared size, verified against its CRC-32.
    public func extract(_ entry: ZipEntry) throws -> Data {
        guard entry.dataOffset >= 0, entry.compressedSize >= 0,
              entry.dataOffset + entry.compressedSize <= data.count else { throw ZipError.corrupt("range") }
        let compressed = data.subdata(in: entry.dataOffset..<entry.dataOffset + entry.compressedSize)
        let output: Data
        switch entry.method {
        case 0:
            guard compressed.count == entry.uncompressedSize else { throw ZipError.corrupt("storedSize") }
            output = compressed
        case 8:
            output = try Self.inflate(compressed, expected: entry.uncompressedSize)
        default:
            throw ZipError.unsupported
        }
        guard Self.crc32(output) == entry.crc else { throw ZipError.checksum }
        return output
    }

    // MARK: - Helpers

    /// `[A-Za-z0-9][A-Za-z0-9._/-]*`, at most 160 bytes, no empty, `.` or `..` component.
    public static func isSafePath(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= 160, bytes.last != UInt8(ascii: "/") else { return false }
        func alphanumeric(_ b: UInt8) -> Bool {
            (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122)
        }
        guard alphanumeric(bytes[0]) else { return false }
        for b in bytes where !(alphanumeric(b) || b == UInt8(ascii: ".") || b == UInt8(ascii: "_")
                               || b == UInt8(ascii: "/") || b == UInt8(ascii: "-")) {
            return false
        }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    public static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { raw -> UInt32 in
            var crc = zlib.crc32(0, nil, 0)
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return UInt32(crc) }
            var offset = 0
            while offset < raw.count {
                let chunk = min(raw.count - offset, 1 << 30)
                crc = zlib.crc32(crc, base + offset, uInt(chunk))
                offset += chunk
            }
            return UInt32(crc)
        }
    }

    /// Raw deflate. Fails unless the stream ends cleanly, uses all its input and produces
    /// exactly `expected` bytes; the output buffer is never larger than `expected`.
    static func inflate(_ source: Data, expected: Int) throws -> Data {
        guard !source.isEmpty, expected > 0 else { throw ZipError.corrupt("deflate") }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZipError.corrupt("deflate")
        }
        defer { compression_stream_destroy(stream) }
        var output = Data(count: expected)
        var spill: UInt8 = 0
        let finalize = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
        let ok: Bool = source.withUnsafeBytes { src -> Bool in
            output.withUnsafeMutableBytes { dst -> Bool in
                guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress,
                      let dstBase = dst.bindMemory(to: UInt8.self).baseAddress else { return false }
                stream.pointee.src_ptr = srcBase
                stream.pointee.src_size = src.count
                stream.pointee.dst_ptr = dstBase
                stream.pointee.dst_size = expected
                var status = compression_stream_process(stream, finalize)
                if status == COMPRESSION_STATUS_OK, stream.pointee.dst_size == 0 {
                    // Output is full but the stream has not ended: one spare byte tells an
                    // exact fit (ends without writing) from an oversized stream.
                    status = withUnsafeMutablePointer(to: &spill) { spare -> compression_status in
                        stream.pointee.dst_ptr = spare
                        stream.pointee.dst_size = 1
                        let result = compression_stream_process(stream, finalize)
                        return stream.pointee.dst_size == 1 ? result : COMPRESSION_STATUS_ERROR
                    }
                    return status == COMPRESSION_STATUS_END && stream.pointee.src_size == 0
                }
                return status == COMPRESSION_STATUS_END && stream.pointee.dst_size == 0 && stream.pointee.src_size == 0
            }
        }
        guard ok else { throw ZipError.corrupt("deflate") }
        return output
    }

    private static func u16(_ data: Data, _ offset: Int) throws -> Int {
        guard offset >= 0, offset + 2 <= data.count else { throw ZipError.corrupt("range") }
        return Int(data[offset]) | Int(data[offset + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) throws -> Int {
        guard offset >= 0, offset + 4 <= data.count else { throw ZipError.corrupt("range") }
        return Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
    }
}

/// Writes a plain ZIP (stored entries, no ZIP64) straight to a file, one entry at a time.
/// Photos are already compressed, so storing them costs nothing and keeps export fast.
public final class ZipWriter {
    private struct Record {
        let name: [UInt8]
        let crc: UInt32
        let size: Int
        let offset: Int
    }

    private let handle: FileHandle
    private var records: [Record] = []
    private var offset = 0
    private var finished = false

    /// Creates (or truncates) the file at `url`.
    public init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
    }

    deinit { try? handle.close() }

    public func add(path: String, data: Data) throws {
        guard !finished, ZipReader.isSafePath(path), !data.isEmpty else { throw ZipError.unsafePath }
        guard !records.contains(where: { $0.name == Array(path.utf8) }) else { throw ZipError.duplicateEntry }
        let name = Array(path.utf8)
        let limit = Int(UInt32.max) - 1
        guard records.count < 65_534, data.count <= limit, offset + 30 + name.count + data.count <= limit else {
            throw ZipError.tooLarge
        }
        let crc = ZipReader.crc32(data)
        var header = Data()
        header.appendLE32(0x0403_4b50)
        Self.appendCommon(&header, crc: crc, size: data.count, nameLength: name.count)
        header.append(contentsOf: name)
        try handle.write(contentsOf: header)
        try handle.write(contentsOf: data)
        records.append(Record(name: name, crc: crc, size: data.count, offset: offset))
        offset += header.count + data.count
    }

    /// Writes the directory and flushes the file to disk. Returns the archive size in bytes.
    @discardableResult
    public func finish() throws -> Int {
        guard !finished, !records.isEmpty else { throw ZipError.corrupt("empty") }
        var directory = Data()
        for record in records {
            directory.appendLE32(0x0201_4b50)
            directory.appendLE16(20)                // made by: 2.0, MS-DOS attributes
            Self.appendCommon(&directory, crc: record.crc, size: record.size, nameLength: record.name.count)
            directory.appendLE16(0)                 // comment length
            directory.appendLE16(0)                 // disk number
            directory.appendLE16(0)                 // internal attributes
            directory.appendLE32(0)                 // external attributes
            directory.appendLE32(UInt32(record.offset))
            directory.append(contentsOf: record.name)
        }
        guard offset + directory.count + 22 <= Int(UInt32.max) - 1 else { throw ZipError.tooLarge }
        var tail = Data()
        tail.appendLE32(0x0605_4b50)
        tail.appendLE16(0)
        tail.appendLE16(0)
        tail.appendLE16(UInt16(records.count))
        tail.appendLE16(UInt16(records.count))
        tail.appendLE32(UInt32(directory.count))
        tail.appendLE32(UInt32(offset))
        tail.appendLE16(0)
        try handle.write(contentsOf: directory)
        try handle.write(contentsOf: tail)
        try handle.synchronize()
        try handle.close()
        finished = true
        return offset + directory.count + tail.count
    }

    /// The fields shared by a local header and a directory record, from "version needed" to
    /// "extra length": stored, UTF-8 names, fixed 1980-01-01 timestamp (no clock data leaks).
    private static func appendCommon(_ data: inout Data, crc: UInt32, size: Int, nameLength: Int) {
        data.appendLE16(20)
        data.appendLE16(0x0800)
        data.appendLE16(0)
        data.appendLE16(0)
        data.appendLE16(0x0021)
        data.appendLE32(crc)
        data.appendLE32(UInt32(size))
        data.appendLE32(UInt32(size))
        data.appendLE16(UInt16(nameLength))
        data.appendLE16(0)
    }
}

extension Data {
    mutating func appendLE16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendLE32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { append(UInt8((value >> UInt32(shift)) & 0xFF)) }
    }
}
