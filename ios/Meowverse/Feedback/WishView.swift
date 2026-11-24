import MessageUI
import MeowverseCore
import SwiftUI

/// 「我想要这个」: a feature idea, written as a mail the same way as 「反馈问题」, to the same
/// address. No diagnostics and no switch for them: the mail holds what the user wrote and one
/// version line (`FeatureWish`). Meowverse never sends anything itself.
struct WishView: View {
    @Environment(\.openURL) private var openURL
    @State private var wish = ""
    @State private var context = ""
    @State private var composing = false
    @State private var outcome: MailOutcome?
    @State private var copied = false
    /// What the pasteboard holds after Copy, read back for UI tests (the test runner may not read it).
    @State private var copiedBack = ""
    @FocusState private var field: Field?

    private enum Field { case wish, context }

    private let recipient = FeedbackConfig.recipient
    private let canSendMail = MFMailComposeViewController.canSendMail()

    var body: some View {
        List {
            Section {
                Text("想要新的家具、新的玩法，或者希望哪里更顺手？写下来会变成一封发给开发者的邮件，用“邮件”App 发出。发送前你能看到并修改全部内容，喵空间自己不会发送任何东西。")
                Text("邮件里只有你写的内容和 App 的版本号，不含照片、诊断记录、猫咪的名字和家具名。")
            }
            .font(.subheadline)

            Section {
                TextField("例如：想要一个能放在窗边的猫窝", text: $wish, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($field, equals: .wish)
                    .accessibilityIdentifier("wish-what")
            } header: {
                Text("想要什么？")
            }

            Section {
                TextField("例如：猫咪每天下午都在窗边晒太阳", text: $context, axis: .vertical)
                    .lineLimit(2...6)
                    .focused($field, equals: .context)
                    .accessibilityIdentifier("wish-when")
            } header: {
                Text("会在什么时候用到？（可不填）")
            }

            sendSection
        }
        // A Home Screen quick action must not close Settings over a half-written idea.
        .unsentWork(!(wish + context).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || composing)
        .navigationTitle("我想要这个")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            // Multi-line fields have no Return to close the keyboard, which otherwise covers the buttons.
            if field != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { field = nil }
                        .accessibilityIdentifier("wish-done-typing")
                }
            }
        }
        // What was copied is no longer what is on the page.
        .onChange(of: wish) { copied = false }
        .onChange(of: context) { copied = false }
        .sheet(isPresented: $composing) {
            MailComposer(recipient: recipient, subject: subject, message: message) { result, _ in
                outcome = MailOutcome(result)
                composing = false
            }
            .ignoresSafeArea()
        }
    }

    // MARK: The mail

    private var canCompose: Bool { FeatureWish.canCompose(wish) }

    private var message: FeedbackMessage {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = FeatureWish.versionLine(appVersion: info["CFBundleShortVersionString"] as? String ?? "?",
                                              build: info["CFBundleVersion"] as? String ?? "?",
                                              osVersion: UIDevice.current.systemVersion)
        return FeatureWish.compose(wish: wish, context: context, contextHeading: String(localized: "会在什么时候用到："),
                                   versionLine: version)
    }

    private var subject: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return String(localized: "喵空间想要的功能 (\(version) build \(build))")
    }

    // MARK: Send

    private var sendSection: some View {
        Section {
            // An empty idea says nothing, unlike a bug report whose description may be left out.
            Button("写邮件", systemImage: "envelope") { compose() }
                .buttonStyle(ListCommandStyle())
                .disabled(!canCompose)
                .accessibilityIdentifier("wish-compose")
            if !canSendMail {
                Text("这台设备上的“邮件”还没有设置账户。如果没有打开别的邮件 App，可以拷贝内容，自己发到 \(recipient)。")
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("wish-address")
                Button("拷贝内容", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = message.body
                    #if DEBUG || DRILLS
                    copiedBack = UIPasteboard.general.string ?? ""
                    #endif
                    copied = true
                }
                .buttonStyle(ListCommandStyle())
                .disabled(!canCompose)
                .accessibilityIdentifier("wish-copy")
                if copied {
                    Label("已拷贝内容。", systemImage: "checkmark.circle")
                        .font(.subheadline)
                        .accessibilityValue(Text(verbatim: copiedBack))
                        .accessibilityIdentifier("wish-copied")
                }
            }
            if let outcome {
                MailOutcomeLabel(outcome: outcome, recipient: recipient)
                    .accessibilityIdentifier("wish-outcome")
            }
        }
    }

    private func compose() {
        guard canCompose else { return }
        outcome = nil
        if canSendMail {
            composing = true
            return
        }
        guard let url = MailLink.url(recipient: recipient, subject: subject, body: message.body) else {
            outcome = .mailLinkFailed
            return
        }
        openURL(url) { accepted in outcome = accepted ? .mailLinkOpened : .mailLinkFailed }
    }
}
