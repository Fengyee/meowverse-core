import Compression
import Foundation
import Testing
@testable import MeowverseCore

/// Hand-assembled ZIP bytes, so tests can lie in any header field.
struct RawZipEntry {
    var name: String
    /// The bytes as they sit in the file (already deflated when `method` is 8).
    var payload: Data
    var method: UInt16 = 0
    var flags: UInt16 = 0
    /// Defaults to the CRC-32 of `payload` (correct for stored entries).
    var crc: UInt32?
    var uncompressedSize: Int?
    var externalAttributes: UInt32 = 0
    var localName: String?
    /// Bytes inserted before this entry's local header that no entry accounts for.
    var hiddenPrefix = Data()
}

enum RawZip {
    static func deflate(_ data: Data) -> Data {
        var out = Data(count: data.count + 1024)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                                          src.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        precondition(written > 0)
        return out.prefix(written)
    }

    static func build(_ entries: [RawZipEntry], declaredCount: Int? = nil, sharedLocalOffsets: Bool = false) -> Data {
        var file = Data(), directory = Data()
        var firstOffset = 0
        for (index, entry) in entries.enumerated() {
            file.append(entry.hiddenPrefix)
            let offset = sharedLocalOffsets && index > 0 ? firstOffset : file.count
            if index == 0 { firstOffset = offset }
            let crc = entry.crc ?? ZipReader.crc32(entry.payload)
            let size = UInt32(entry.uncompressedSize ?? entry.payload.count)
            let name = Array(entry.name.utf8), localName = Array((entry.localName ?? entry.name).utf8)
            func common(_ data: inout Data, nameLength: Int) {
                data.appendLE16(20); data.appendLE16(entry.flags); data.appendLE16(entry.method)
                data.appendLE16(0); data.appendLE16(0x0021)
                data.appendLE32(crc); data.appendLE32(UInt32(entry.payload.count)); data.appendLE32(size)
                data.appendLE16(UInt16(nameLength)); data.appendLE16(0)
            }
            if !(sharedLocalOffsets && index > 0) {
                file.appendLE32(0x0403_4b50)
                common(&file, nameLength: localName.count)
                file.append(contentsOf: localName)
                file.append(entry.payload)
            }
            directory.appendLE32(0x0201_4b50)
            directory.appendLE16(20)
            common(&directory, nameLength: name.count)
            directory.appendLE16(0); directory.appendLE16(0); directory.appendLE16(0)
            directory.appendLE32(entry.externalAttributes)
            directory.appendLE32(UInt32(offset))
            directory.append(contentsOf: name)
        }
        let count = UInt16(declaredCount ?? entries.count)
        var tail = Data()
        tail.appendLE32(0x0605_4b50); tail.appendLE16(0); tail.appendLE16(0)
        tail.appendLE16(count); tail.appendLE16(count)
        tail.appendLE32(UInt32(directory.count)); tail.appendLE32(UInt32(file.count)); tail.appendLE16(0)
        return file + directory + tail
    }
}

struct ZipArchiveTests {
    let limits = ZipLimits(maxArchiveBytes: 1 << 20, maxEntries: 16, maxEntryBytes: 64 << 10, maxTotalBytes: 256 << 10)
    let hello = Data("hello, meowverse".utf8)
    let other = Data((0..<4000).map { UInt8($0 % 251) })

    private func written(_ files: [(String, Data)]) throws -> Data {
        let dir = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.zip")
        let writer = try ZipWriter(url: url)
        for (path, data) in files { try writer.add(path: path, data: data) }
        let size = try writer.finish()
        let bytes = try Data(contentsOf: url)
        #expect(bytes.count == size)
        return bytes
    }

    @Test func writerOutputReadsBackByteForByte() throws {
        let bytes = try written([("manifest.json", hello), ("originals/abc.jpeg", other)])
        let reader = try ZipReader(data: bytes, limits: limits)
        #expect(reader.entries.map(\.path) == ["manifest.json", "originals/abc.jpeg"])
        #expect(try reader.extract(#require(reader.entry("manifest.json"))) == hello)
        #expect(try reader.extract(#require(reader.entry("originals/abc.jpeg"))) == other)
        #expect(reader.entry("missing") == nil)
    }

    /// The system unzip agrees with what the writer produced (macOS test host only).
    @Test func writerOutputIsAcceptedBySystemUnzip() throws {
        #if os(macOS)
        let dir = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.zip")
        let writer = try ZipWriter(url: url)
        try writer.add(path: "state.json", data: hello)
        try writer.add(path: "originals/x.bin", data: other)
        try writer.finish()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-tq", url.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #endif
    }

    @Test func deflatedEntryInflatesAndIsBoundedByItsDeclaredSize() throws {
        let packed = RawZip.deflate(other)
        #expect(packed.count < other.count)
        let good = RawZip.build([RawZipEntry(name: "a.bin", payload: packed, method: 8, crc: ZipReader.crc32(other), uncompressedSize: other.count)])
        let reader = try ZipReader(data: good, limits: limits)
        #expect(try reader.extract(reader.entries[0]) == other)

        // Declares fewer bytes than the stream produces: a "bomb" must stop at the declared size.
        let bomb = RawZip.build([RawZipEntry(name: "a.bin", payload: packed, method: 8, crc: ZipReader.crc32(other), uncompressedSize: 100)])
        let bombReader = try ZipReader(data: bomb, limits: limits)
        #expect(throws: ZipError.corrupt("deflate")) { try bombReader.extract(bombReader.entries[0]) }

        // Declares more than the stream produces.
        let short = RawZip.build([RawZipEntry(name: "a.bin", payload: packed, method: 8, crc: ZipReader.crc32(other), uncompressedSize: other.count + 1)])
        let shortReader = try ZipReader(data: short, limits: limits)
        #expect(throws: ZipError.corrupt("deflate")) { try shortReader.extract(shortReader.entries[0]) }

        // A cut-off deflate stream.
        let cut = RawZip.build([RawZipEntry(name: "a.bin", payload: packed.prefix(packed.count / 2), method: 8, crc: ZipReader.crc32(other), uncompressedSize: other.count)])
        let cutReader = try ZipReader(data: cut, limits: limits)
        #expect(throws: ZipError.self) { try cutReader.extract(cutReader.entries[0]) }
    }

    @Test func everyTruncationIsRefused() throws {
        let bytes = try written([("manifest.json", hello), ("b.bin", Data(repeating: 7, count: 300))])
        for length in 0..<bytes.count {
            #expect(throws: ZipError.self, "prefix of \(length) bytes") {
                _ = try ZipReader(data: bytes.prefix(length), limits: limits)
            }
        }
        // Extra bytes after the end record are refused too.
        #expect(throws: ZipError.self) { _ = try ZipReader(data: bytes + Data([0]), limits: limits) }
        #expect(throws: ZipError.notZip) { _ = try ZipReader(data: Data("not a zip at all, just some text".utf8), limits: limits) }
    }

    @Test func pathTraversalAndOddNamesAreRefused() {
        for name in ["../evil", "/abs/path", "a/../b", "a//b", "dir/", "a\\b", ".hidden", "a/./b", "名字.jpg", "a b", "C:evil", String(repeating: "a", count: 161)] {
            let bytes = RawZip.build([RawZipEntry(name: name, payload: hello)])
            #expect(throws: ZipError.unsafePath, "name \(name)") { _ = try ZipReader(data: bytes, limits: limits) }
        }
        let symlink = RawZip.build([RawZipEntry(name: "link", payload: hello, externalAttributes: UInt32(0o120777) << 16)])
        #expect(throws: ZipError.unsafePath) { _ = try ZipReader(data: symlink, limits: limits) }
        #expect(ZipReader.isSafePath("originals/0a1b.jpeg") && ZipReader.isSafePath("media/000001/original.bin"))
    }

    @Test func oversizeAndAbsurdCountsAreRefused() {
        let big = RawZip.build([RawZipEntry(name: "a", payload: hello, uncompressedSize: (64 << 10) + 1)])
        #expect(throws: ZipError.tooLarge) { _ = try ZipReader(data: big, limits: limits) }

        let many = RawZip.build((0..<17).map { RawZipEntry(name: "f\($0)", payload: hello) })
        #expect(throws: ZipError.tooLarge) { _ = try ZipReader(data: many, limits: limits) }

        // Each entry is within its own limit but the declared total is not.
        let packed = RawZip.deflate(Data(repeating: 0, count: 60 << 10))
        let total = RawZip.build((0..<5).map { RawZipEntry(name: "f\($0)", payload: packed, method: 8, uncompressedSize: 60 << 10) })
        #expect(throws: ZipError.tooLarge) { _ = try ZipReader(data: total, limits: limits) }

        let small = ZipLimits(maxArchiveBytes: 64, maxEntries: 16, maxEntryBytes: 64, maxTotalBytes: 64)
        #expect(throws: ZipError.tooLarge) { _ = try ZipReader(data: RawZip.build([RawZipEntry(name: "a", payload: hello)]), limits: small) }

        // A directory that claims more entries than it holds.
        let lying = RawZip.build([RawZipEntry(name: "a", payload: hello)], declaredCount: 3)
        #expect(throws: ZipError.self) { _ = try ZipReader(data: lying, limits: limits) }
        let empty = RawZip.build([RawZipEntry(name: "a", payload: Data())])
        #expect(throws: ZipError.corrupt("emptyEntry")) { _ = try ZipReader(data: empty, limits: limits) }
    }

    @Test func badChecksumIsCaughtOnExtract() throws {
        var bytes = try written([("a.bin", other)])
        // Flip one byte of the stored data (after the 30-byte header and the 5-byte name).
        bytes[30 + 5 + 100] ^= 0x01
        let reader = try ZipReader(data: bytes, limits: limits)
        #expect(throws: ZipError.checksum) { try reader.extract(reader.entries[0]) }

        let wrong = RawZip.build([RawZipEntry(name: "a.bin", payload: hello, crc: 0xDEAD_BEEF)])
        let wrongReader = try ZipReader(data: wrong, limits: limits)
        #expect(throws: ZipError.checksum) { try wrongReader.extract(wrongReader.entries[0]) }
    }

    @Test func duplicateHiddenOverlappingAndExoticArchivesAreRefused() {
        let duplicate = RawZip.build([RawZipEntry(name: "a", payload: hello), RawZipEntry(name: "a", payload: other)])
        #expect(throws: ZipError.duplicateEntry) { _ = try ZipReader(data: duplicate, limits: limits) }

        let hidden = RawZip.build([RawZipEntry(name: "a", payload: hello), RawZipEntry(name: "b", payload: hello, hiddenPrefix: Data("secret".utf8))])
        #expect(throws: ZipError.corrupt("layout")) { _ = try ZipReader(data: hidden, limits: limits) }

        // Two directory records that share one local record.
        let shared = RawZip.build([RawZipEntry(name: "a", payload: hello), RawZipEntry(name: "b", payload: hello)], sharedLocalOffsets: true)
        #expect(throws: ZipError.self) { _ = try ZipReader(data: shared, limits: limits) }

        let mismatch = RawZip.build([RawZipEntry(name: "a", payload: hello, localName: "b")])
        #expect(throws: ZipError.corrupt("localMismatch")) { _ = try ZipReader(data: mismatch, limits: limits) }

        let encrypted = RawZip.build([RawZipEntry(name: "a", payload: hello, flags: 1)])
        #expect(throws: ZipError.unsupported) { _ = try ZipReader(data: encrypted, limits: limits) }
        let method = RawZip.build([RawZipEntry(name: "a", payload: hello, method: 12)])
        #expect(throws: ZipError.unsupported) { _ = try ZipReader(data: method, limits: limits) }
        let stored = RawZip.build([RawZipEntry(name: "a", payload: hello, uncompressedSize: 99)])
        #expect(throws: ZipError.corrupt("storedSize")) { _ = try ZipReader(data: stored, limits: limits) }
    }

    /// Random damage anywhere in a valid archive: the reader either refuses it or returns the
    /// original bytes; it never crashes and never returns altered data as valid.
    @Test func randomDamageNeverYieldsAlteredData() throws {
        let packed = RawZip.deflate(other)
        let bytes = RawZip.build([
            RawZipEntry(name: "manifest.json", payload: hello),
            RawZipEntry(name: "media/000000/original.bin", payload: packed, method: 8, crc: ZipReader.crc32(other), uncompressedSize: other.count),
        ])
        let originals = ["manifest.json": hello, "media/000000/original.bin": other]
        var generator = SystemRandomNumberGenerator()
        var refused = 0
        for _ in 0..<600 {
            var damaged = bytes
            for _ in 0..<Int.random(in: 1...3, using: &generator) {
                damaged[Int.random(in: 0..<damaged.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            guard let reader = try? ZipReader(data: damaged, limits: limits) else {
                refused += 1
                continue
            }
            for entry in reader.entries {
                if let data = try? reader.extract(entry) {
                    #expect(data == originals[entry.path], "entry \(entry.path) extracted altered bytes")
                }
            }
        }
        #expect(refused > 0)
    }
}
