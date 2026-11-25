import CoreText
import Foundation
import Testing
@testable import MeowverseCore

/// The room postcard's letterhead names the app in the interface language: 喵空间 in Chinese
/// (owner: the Chinese name is used everywhere), Meowverse otherwise.
@Suite struct PostcardBrandTests {
    @Test func chineseInterfacesName喵空间() {
        for code in ["zh-Hans", "zh", "zh-Hans-CN"] {
            #expect(PostcardBrand.forInterface(languageCode: code) == .chinese)
            #expect(PostcardBrand.forInterface(languageCode: code).words == "喵空间")
        }
    }

    @Test func everyOtherInterfaceNamesMeowverse() {
        for code in ["en", "en-GB", "ja", ""] {
            #expect(PostcardBrand.forInterface(languageCode: code) == .latin)
            #expect(PostcardBrand.forInterface(languageCode: code).words == "Meowverse")
        }
    }

    /// The Chinese letterhead is drawn in the title face; the bundled ZCOOL KuaiLe has all three
    /// characters, so the card never falls back to the system face for it.
    @Test func theTitleFaceDrawsTheChineseName() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Meowverse/Resources/Fonts/ZCOOLKuaiLe-Regular.ttf")
        let descriptors = try #require(CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])
        let font = CTFontCreateWithFontDescriptor(try #require(descriptors.first), 12, nil)
        let covered = CTFontCopyCharacterSet(font) as CharacterSet
        let words = PostcardBrand.chinese.words
        #expect(RoomTitleFace.choose(for: words) { covered.contains($0) } == .cute)
    }
}
