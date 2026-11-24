import MeowverseCore
import SwiftUI

/// About and privacy, pushed from Settings: sponsors, thanks, open source and art, privacy,
/// version. The long texts (privacy, licences, the full art credits) are one level down.
struct AboutView: View {
    var body: some View {
        List {
            AboutCreditsSections(roll: Credits.shown)
            Section {
                NavigationLink { AboutPrivacyView() } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Label { Text("你的照片与隐私", tableName: "About") } icon: { Image(systemName: "hand.raised") }
                        Text("照片存在哪里、怎么读取，识别、备份与同步", tableName: "About")
                            .font(.footnote)
                            .foregroundStyle(Color.subtle)
                    }
                }
                .accessibilityIdentifier("about-privacy")
            } header: {
                Text("隐私", tableName: "About")
            }
            Section {
                LabeledContent("版本", value: AppModel.appVersion)
            }
        }
        .navigationTitle("关于与隐私")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 赞助人, 鸣谢 and 开源与素材: the first three sections of 关于与隐私, also drawn by the DEBUG
/// gallery with sample names (`-MeowverseOverlayGallery credits`).
struct AboutCreditsSections: View {
    let roll: CreditsRoll

    var body: some View {
        // Thanks only. No amounts, links or asking: a sponsorship or tip outside In-App Purchase
        // is a review risk (App Review 3.1.1). A group with nobody in it does not show.
        let sponsors = roll.listedSponsors
        if !sponsors.isEmpty {
            Section {
                Text("赞助人支持喵空间上架 App Store，也让它一直留在那里（例如 Apple 开发者计划的年费）。谢谢你们！", tableName: "About")
                    .font(.subheadline)
                    .accessibilityIdentifier("about-sponsors-intro")
                // By place: two people without a name or a cat read the same and are still two.
                ForEach(Array(sponsors.enumerated()), id: \.offset) { _, sponsor in
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: Credits.name(of: sponsor))
                                .font(.body.weight(.semibold))
                                .accessibilityIdentifier("about-sponsor")
                            if let supported = Credits.supported(by: sponsor) {
                                Text(verbatim: supported)
                                    .font(.footnote)
                                    .foregroundStyle(Color.subtle)
                                    .accessibilityIdentifier("about-sponsor-supports")
                            }
                        }
                    } icon: {
                        Image(systemName: "heart.fill").foregroundStyle(RoomPaper.clay).accessibilityHidden(true)
                    }
                }
            } header: {
                Text("赞助人", tableName: "About")
            }
        }

        let thanks = roll.listedThanks
        if !thanks.isEmpty {
            Section {
                ForEach(thanks, id: \.role) { group in
                    LabeledContent {
                        Text(verbatim: Credits.list(group.names))
                    } label: {
                        Text(group.role.title)
                    }
                    .accessibilityIdentifier("about-thanks-\(group.role.rawValue)")
                }
            } header: {
                Text("鸣谢", tableName: "About")
            } footer: {
                Text("喵空间由个人开发。喜欢的话，欢迎在 App Store 留下评分；有想法或遇到问题，可以在“设置 › 反馈问题”里告诉我们。")
            }
        }

        Section {
            ForEach(ThirdPartyNotice.shipped) { notice in
                NavigationLink { ThirdPartyNoticeView(notice: notice) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: notice.name)
                        Text(notice.use)
                            .font(.footnote)
                            .foregroundStyle(Color.subtle)
                        Text(verbatim: notice.license)
                            .font(.caption)
                            .foregroundStyle(Color.subtle)
                    }
                }
                .accessibilityIdentifier(notice.id == .dinov2 ? "about-model-license" : "about-notice-\(notice.id.rawValue)")
            }
            NavigationLink { ArtCreditsView() } label: {
                Text("全部素材署名", tableName: "About")
            }
            .accessibilityIdentifier("about-art-credits")
        } header: {
            Text("开源与素材", tableName: "About")
        } footer: {
            Text("其余的家具和声音由喵空间制作或由开发者提供，逐项写在“全部素材署名”里。", tableName: "About")
        }
    }
}

/// 隐私: what happens to the photos, grouped so each point reads on its own. The words follow the
/// user's iCloud switches (`photoReach`, `cloudSyncOn`); keep them in step with the guide.
struct AboutPrivacyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                // With iCloud backup or sync on, copies go to the user's own iCloud: say how, not "never".
                Label(model.photoReach.aboutPhotosWords, systemImage: "lock.iphone")
                    .accessibilityIdentifier("about-photos")
            } header: {
                Text("照片存在哪里", tableName: "About")
            }
            Section {
                Label { Text("只读取你在相册里选中的照片。第一次添加照片时会问一次相册权限：允许后每张照片只存小预览，看大图时从相册读取，而且只读你导入过的那些照片；不允许也能照常使用，之后可以在设置里更改。", tableName: "About") } icon: { Image(systemName: "photo.badge.checkmark") }
            } header: {
                Text("读取照片", tableName: "About")
            }
            Section {
                Label("家具识别在这台设备上完成，结果由你确认。", systemImage: "iphone")
            } header: {
                Text("识别", tableName: "About")
            }
            Section {
                Label { Text("备份文件存到哪里由你决定。打开“备份到 iCloud 云盘”后，备份存在你自己的 iCloud 云盘，由系统上传。", tableName: "About") } icon: { Image(systemName: "square.and.arrow.up") }
                if model.cloudSyncOn {
                    Label { Text("你打开了 iCloud 同步，喵空间会通过 Apple 的 iCloud 和你自己的设备同步，开发者拿不到这些数据。", tableName: "About") } icon: { Image(systemName: "network") }
                        .accessibilityIdentifier("about-sync")
                }
                // Shown either way (owner, 2026-11-21): the low-tier cat models are fetched from the
                // App Store through Background Assets, so "never goes online" would not hold.
                Label { Text("喵空间没有自己的服务器。画质用到“低”档时，会请系统从 App Store 下载简化的猫咪模型，下载时不会传出你的照片和房间。", tableName: "About") } icon: { Image(systemName: "arrow.down.app") }
                    .accessibilityIdentifier("about-network")
                if model.options.cloudSyncFeature {
                    Label("打开 iCloud 同步后，你的家和喵空间保存的照片副本会通过 Apple 的 CloudKit 存进你自己的 iCloud，在登录同一个 Apple 账户的设备之间同步。开发者看不到这些内容。", systemImage: "arrow.triangle.2.circlepath.icloud")
                }
            } header: {
                Text("备份与同步", tableName: "About")
            }
            Section {
                // App Review 5.1.1(i): the policy is reachable inside the app.
                BrowserLink(url: PublicPage.privacyPolicy(chinese: AppLanguage.isChinese)) {
                    Label { Text("隐私政策", tableName: "About") } icon: { Image(systemName: "doc.text") }
                }
                .accessibilityIdentifier("about-privacy-policy")
            } footer: {
                Text("在浏览器里打开完整的隐私政策。", tableName: "About")
            }
        }
        .navigationTitle(Text("隐私", tableName: "About"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A row that opens one of the project's public pages in the system browser. The whole row is
/// the link and VoiceOver reads it as one.
///
/// In DEBUG, `-MeowverseLinkDrill` keeps the request in the app and puts the address it asked
/// for in the row's accessibility value, so a UI test loads no page.
struct BrowserLink<Content: View>: View {
    let url: URL
    @ViewBuilder let content: Content
    #if DEBUG
    @State private var asked = ""
    #endif

    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-MeowverseLinkDrill") {
            link
                .environment(\.openURL, OpenURLAction { asked = $0.absoluteString; return .handled })
                .accessibilityValue(Text(verbatim: asked))
        } else {
            link
        }
        #else
        link
        #endif
    }

    private var link: some View {
        Link(destination: url) {
            HStack(spacing: 8) {
                content
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right").font(.footnote).accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .accessibilityRemoveTraits(.isButton)
        .accessibilityAddTraits(.isLink)
    }
}

/// The first section of 设置 (owner, 2026-11-22): the project is a labour of love, and where to
/// follow it. Following or starring earns nothing.
struct LabourOfLoveSection: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Section {
            HStack(spacing: 12) {
                icon("heart.fill").foregroundStyle(RoomPaper.clay)
                Text("喵空间是一个为爱发电的项目。", tableName: "About")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-labour-of-love")
            }
            BrowserLink(url: PublicPage.sourceRepository) {
                HStack(spacing: 12) {
                    icon("star")
                    Text("喜欢的话，请去 GitHub 给我们一个关注和 star", tableName: "About")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier("settings-github")
        }
    }

    /// Decoration only. At accessibility sizes the words take the whole width, or the app's own
    /// name breaks in the middle.
    @ViewBuilder private func icon(_ symbol: String) -> some View {
        if !typeSize.isAccessibilitySize {
            Image(systemName: symbol).frame(width: 28).accessibilityHidden(true)
        }
    }
}

/// One third-party work: what it is and where it is from, then the licence text when one ships.
struct ThirdPartyNoticeView: View {
    let notice: ThirdPartyNotice

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(notice.detail)
                    .font(.subheadline)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    row(Text("作者", tableName: "About"), notice.author)
                    row(Text("许可", tableName: "About"), notice.license)
                    row(Text("来源", tableName: "About"), notice.source)
                    if notice.licenseText == nil {
                        row(Text("许可证", tableName: "About"), notice.licenseURL)
                    }
                }
                .font(.footnote)
                if let text = notice.licenseText {
                    Divider()
                    Text(verbatim: text)
                        .font(.footnote.monospaced())
                        .accessibilityIdentifier("about-license-text")
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier("about-notice-page")
        .navigationTitle(Text(verbatim: notice.name))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: Text, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            title.foregroundStyle(Color.subtle)
            Text(verbatim: value)
        }
    }
}

/// Every credit of the bundled art, sounds and fonts (`Resources/Art/ATTRIBUTION.txt`).
struct ArtCreditsView: View {
    private let text = (try? String(decoding: ArtLibrary.data("ATTRIBUTION", "txt"), as: UTF8.self)) ?? ""

    var body: some View {
        ScrollView {
            Text(Wording.credits(text))
                .font(.footnote)
                .foregroundStyle(Color.subtle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .accessibilityIdentifier("about-art-credits-text")
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(Text("全部素材署名", tableName: "About"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
