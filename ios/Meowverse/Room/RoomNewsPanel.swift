import MeowverseCore
import SwiftUI

/// 公告, opened from the room's top band: what is new, what is planned, and the thanks. The names
/// are the ones 关于与隐私 shows (`Credits.shown`), with the same rule: thanks only, no links.
struct RoomNewsPanel: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        RoomFolio(title: String(localized: "公告", table: "News"), image: "TopNews", detents: [.large],
                  close: RoomFolioClose(label: Text("关闭"), id: "close-room-news") { dismiss() }) {
            Text(verbatim: News.versionLine)
                .font(.footnote)
                .foregroundStyle(RoomPaper.note)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32)
                .accessibilityIdentifier("news-version")
            heading(Text("新功能", tableName: "News"), id: "news-features")
            items(News.features)
            if !News.plans.isEmpty {
                heading(Text("正在计划", tableName: "News"), id: "news-plans")
                items(News.plans)
            }
            if !Credits.shown.isEmpty {
                heading(Text("鸣谢", tableName: "News"), id: "news-thanks")
                thanks(Credits.shown)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("room-news-panel")
    }

    private func heading(_ title: Text, id: String) -> some View {
        title
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(RoomPaper.note)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(id)
    }

    private func items(_ items: [News.Item]) -> some View {
        RoomFolioCard {
            ForEach(items) { item in
                RoomFolioRow(title: Text(item.title), note: Text(item.note)) { EmptyView() }
                    .accessibilityElement(children: .combine)
            }
        }
    }

    /// The same rule as 关于与隐私: a group with nobody in it has no row.
    private func thanks(_ roll: CreditsRoll) -> some View {
        RoomFolioCard {
            let sponsors = roll.listedSponsors
            if !sponsors.isEmpty {
                RoomFolioRow(title: Text("赞助人", tableName: "News"), note: Text(verbatim: Credits.list(sponsors.map(Credits.name(of:))))) { EmptyView() }
                    .accessibilityElement(children: .combine)
            }
            ForEach(roll.listedThanks, id: \.role) { group in
                RoomFolioRow(title: Text(group.role.title), note: Text(verbatim: Credits.list(group.names))) { EmptyView() }
                    .accessibilityElement(children: .combine)
            }
        }
    }
}

/// 公告 as a sheet on iPhone; on iPad it is a popover from its token (`RoomTopBar`). A modifier of
/// its own because `RoomScreen.body` is at the type checker's limit.
struct RoomNewsSheet: ViewModifier {
    @Binding var shown: Bool
    let isPad: Bool

    func body(content: Content) -> some View {
        content.sheet(isPresented: isPad ? .constant(false) : $shown) { RoomNewsPanel() }
    }
}
