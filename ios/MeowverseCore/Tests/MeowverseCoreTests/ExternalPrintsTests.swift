import Foundation
import Testing
@testable import MeowverseCore

@Suite struct ExternalPrintsTests {
    private let a = String(repeating: "a", count: 64)
    private let b = String(repeating: "b", count: 64)
    private let c = String(repeating: "c", count: 64)
    private let d = String(repeating: "d", count: 64)

    private func load(_ json: String) throws -> ExternalPrints {
        try ExternalPrints.load(Data(json.utf8))
    }

    @Test func vectorsAreScaledToUnitLengthAndKeyedByLowercaseHash() throws {
        let prints = try load(#"{"model": " clip-test ", "vectors": {"\#(a.uppercased())": [3, 4], "\#(b)": [0, 2]}}"#)
        #expect(prints.model == "clip-test")
        #expect(prints.dimension == 2)
        #expect(prints.vectors[a] == [0.6, 0.8])
        #expect(prints.vectors[b] == [0, 1])
        #expect(prints.skipped.total == 0)
    }

    @Test func badFilesAreRefusedWithAReason() {
        #expect(throws: ExternalPrints.LoadError.notJSON) { try load("not json") }
        #expect(throws: ExternalPrints.LoadError.notJSON) { try load("[1, 2]") }
        #expect(throws: ExternalPrints.LoadError.missingModel) { try load(#"{"vectors": {}}"#) }
        #expect(throws: ExternalPrints.LoadError.missingModel) { try load(#"{"model": "  ", "vectors": {}}"#) }
        #expect(throws: ExternalPrints.LoadError.missingVectors) { try load(#"{"model": "m", "vectors": [1]}"#) }
        #expect(throws: ExternalPrints.LoadError.badDimension) { try load(#"{"model": "m", "dimension": 1.5, "vectors": {}}"#) }
        #expect(throws: ExternalPrints.LoadError.badDimension) { try load(#"{"model": "m", "dimension": true, "vectors": {}}"#) }
        #expect(throws: ExternalPrints.LoadError.noUsableVectors) { try load(#"{"model": "m", "vectors": {}}"#) }
        #expect(throws: ExternalPrints.LoadError.noUsableVectors) { try load(#"{"model": "m", "vectors": {"\#(a)": [0, 0]}}"#) }
    }

    @Test func unusableEntriesAreSkippedAndCounted() throws {
        let json = #"""
        {"model": "m", "dimension": 3, "vectors": {
          "\#(a)": [1, 0, 0],
          "\#(b)": [1, 0],
          "\#(c)": [0, 0, 0],
          "\#(d)": [1, "x", 0],
          "IMG_0001.HEIC": [1, 0, 0],
          "\#(String(repeating: "e", count: 64))": [true, false, true],
          "\#(String(repeating: "f", count: 64))": 7
        }}
        """#
        let prints = try load(json)
        #expect(prints.vectors.keys.sorted() == [a])
        #expect(prints.skipped.wrongDimension == 1)
        #expect(prints.skipped.zero == 1)
        #expect(prints.skipped.notNumbers == 3)
        #expect(prints.skipped.badKey == 1)
        #expect(prints.skipped.total == 6)
    }

    @Test func withoutADeclaredDimensionTheCommonestLengthWins() throws {
        let prints = try load(#"{"model": "m", "vectors": {"\#(a)": [1, 0], "\#(b)": [0, 1], "\#(c)": [1, 1, 1]}}"#)
        #expect(prints.dimension == 2)
        #expect(prints.skipped.wrongDimension == 1)
    }

    @Test func photosMissingFromTheFileAreCounted() throws {
        let prints = try load(#"{"model": "m", "vectors": {"\#(a)": [1, 0]}}"#)
        let (vectors, missing) = prints.lookup([a.uppercased(), b, c])
        #expect(vectors.map { $0 != nil } == [true, false, false])
        #expect(missing == 2)
    }
}
