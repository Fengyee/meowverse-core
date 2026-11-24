import CoreText
import Foundation
import Testing
@testable import MeowverseCore

/// The room title's face (art/ui/OVERLAY_SPEC.md §4): ZCOOL KuaiLe draws the Han characters unless
/// one of them is missing from it, in which case the whole title uses the system face.
@Suite struct RoomTitleFaceTests {
    /// A stand-in for KuaiLe's character set: everything except 間.
    private func choose(_ title: String) -> RoomTitleFace {
        RoomTitleFace.choose(for: title) { $0 != "間" }
    }

    @Test func titlesWhoseHanTheFaceCoversAreCute() {
        #expect(choose("Bella 的房间") == .cute)
        #expect(choose("小橘子和大黄的阳光房") == .cute)
    }

    @Test func oneMissingHanCharacterSetsTheWholeTitleInTheSystemFace() {
        #expect(choose("Momo 的房間") == .system)
        #expect(choose("間") == .system)
    }

    /// Latin, digits, kana, emoji and punctuation are not Han: the system draws them in either face.
    @Test func nonHanCharactersNeverForceTheFallback() {
        #expect(RoomTitleFace.choose(for: "Bella’s room 2") { _ in false } == .cute)
        #expect(RoomTitleFace.choose(for: "ねこ 🐱「」、。") { _ in false } == .cute)
        #expect(RoomTitleFace.choose(for: "") { _ in false } == .cute)
    }

    @Test func hanDetection() {
        for han: Unicode.Scalar in ["的", "間", "㐀", "\u{20000}", "〇"] { #expect(RoomTitleFace.isHan(han)) }
        for other: Unicode.Scalar in ["a", "1", "’", "ね", "ネ", "한", "「", "。", "🐱", "，"] { #expect(!RoomTitleFace.isHan(other)) }
    }

    /// The real bundled font: GB2312 Han is in (琮 too), traditional 間 and name characters outside
    /// GB2312 such as 玥 are not.
    @Test func theBundledFontsCoverage() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Meowverse/Resources/Fonts/ZCOOLKuaiLe-Regular.ttf")
        let descriptors = try #require(CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])
        let font = CTFontCreateWithFontDescriptor(try #require(descriptors.first), 12, nil)
        #expect(CTFontCopyPostScriptName(font) as String == "ZCOOLKuaiLe-Regular")
        let covered = CTFontCopyCharacterSet(font) as CharacterSet
        let has = { (scalar: Unicode.Scalar) in covered.contains(scalar) }
        #expect(RoomTitleFace.choose(for: "Bella 的房间", cuteFaceHas: has) == .cute)
        #expect(RoomTitleFace.choose(for: "小橘子和大黄的阳光房", cuteFaceHas: has) == .cute)
        #expect(RoomTitleFace.choose(for: "Momo 的房間", cuteFaceHas: has) == .system)
        #expect(RoomTitleFace.choose(for: "琮琮的小屋", cuteFaceHas: has) == .cute)
        #expect(RoomTitleFace.choose(for: "玥玥的小屋", cuteFaceHas: has) == .system)
    }
}
