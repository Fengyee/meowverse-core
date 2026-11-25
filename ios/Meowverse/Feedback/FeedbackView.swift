import MessageUI
import MeowverseCore
import SwiftUI

/// 「反馈问题」: the user describes the problem, sees every line of the diagnostics, and writes the
/// mail in the system composer. Meowverse never sends anything itself.
struct FeedbackView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var problem = ""
    @State private var includeDiagnostics = true
    @State private var showDiagnostics = false
    @State private var report: FeedbackReport?
    @State private var composing = false
    @State private var outcome: MailOutcome?
    /// What was last put on the clipboard. "Copied" shows only while it is still what the page
    /// would copy now: editing the description, the diagnostics switch or a late report ends it (R01-003).
    @State private var copiedText: String?
    @FocusState private var describing: Bool

    private let recipient = FeedbackConfig.recipient
    private let canSendMail = MFMailComposeViewController.canSendMail()

    var body: some View {
        List {
            Section {
                Text("反馈会写成一封邮件，用“邮件”App 发出。发送前你能看到并修改全部内容，喵空间自己不会发送任何东西。")
                Text("诊断信息只有：App 和 iOS 的版本、设备型号、语言与地区、文字大小、“减弱动态效果”和“旁白”是否打开、照片和家具的数量、资料库的版本号、剩余空间的大致范围、这台设备比对一张照片大约要多久，以及喵空间本次运行的最近记录。")
                Text("不包含照片、文件名、便签、猫咪的名字和你给家具起的名字。")
            }
            .font(.subheadline)

            Section {
                TextField("遇到了什么问题？怎样操作会出现？", text: $problem, axis: .vertical)
                    .lineLimit(4...10)
                    .focused($describing)
                    .accessibilityIdentifier("feedback-description")
            } header: {
                Text("问题描述（可不填）")
            }

            diagnosticsSection
            sendSection
        }
        // A Home Screen quick action must not close Settings over a half-written report.
        .unsentWork(!problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || composing)
        .navigationTitle("反馈问题")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            // A multi-line field has no Return to close the keyboard, which otherwise covers the send buttons.
            if describing {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { describing = false }
                        .accessibilityIdentifier("feedback-done-typing")
                }
            }
        }
        .task { report = await FeedbackGatherer.report(state: model.state, recognition: await model.recognitionDiagnostics()) }
        .sheet(isPresented: $composing) {
            MailComposer(recipient: recipient, subject: subject,
                         message: FeedbackMessage.compose(description: problem, report: attachedReport)) { result, _ in
                outcome = MailOutcome(result)
                composing = false
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Diagnostics

    private var attachedReport: FeedbackReport? { includeDiagnostics ? report : nil }

    private var diagnosticsSection: some View {
        Section {
            Toggle("附上诊断信息", isOn: $includeDiagnostics)
                .accessibilityIdentifier("feedback-include-diagnostics")
            if includeDiagnostics {
                DisclosureGroup(isExpanded: $showDiagnostics) {
                    if let report {
                        Text(verbatim: report.diagnosticsText)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("feedback-diagnostics-text")
                    } else {
                        ProgressView("正在读取运行记录…")
                    }
                } label: {
                    // On the label, not the group: a group's identifier would also cover the text inside.
                    Text("查看全部诊断信息")
                        .accessibilityIdentifier("feedback-show-diagnostics")
                }
            }
        } footer: {
            Text(includeDiagnostics
                 ? "诊断信息会原样放进邮件；内容较长时作为 .txt 附件。"
                 : "邮件里只有你写的描述。")
        }
    }

    // MARK: Send

    private var subject: String {
        let env = report?.environment ?? FeedbackGatherer.environment()
        return String(localized: "喵空间反馈 (\(env.appVersion) build \(env.build))")
    }

    private var sendSection: some View {
        Section {
            Button("写邮件", systemImage: "envelope") { compose() }
                .buttonStyle(ListCommandStyle())
                .disabled(includeDiagnostics && report == nil)
                .accessibilityIdentifier("feedback-compose")
            if !canSendMail {
                Text("这台设备上的“邮件”还没有设置账户。如果没有打开别的邮件 App，可以拷贝内容，自己发到 \(recipient)。")
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("feedback-address")
                // Offered with or without diagnostics: the failure message below always points here.
                if !includeDiagnostics || report != nil {
                    Button(includeDiagnostics ? "拷贝诊断信息" : "拷贝问题描述", systemImage: "doc.on.doc") {
                        let text = copyText
                        UIPasteboard.general.string = text
                        copiedText = text
                    }
                    .buttonStyle(ListCommandStyle())
                    .accessibilityIdentifier("feedback-copy")
                    if copiedText == copyText {
                        Label(includeDiagnostics ? "已拷贝问题描述和诊断信息。" : "已拷贝问题描述。", systemImage: "checkmark.circle")
                            .font(.subheadline)
                            .accessibilityIdentifier("feedback-copied")
                    }
                }
            }
            if let outcome {
                MailOutcomeLabel(outcome: outcome, recipient: recipient)
                    .accessibilityIdentifier("feedback-outcome")
            }
        }
        // No TestFlight hint here: App Review installs carry the same sandbox receipt, and a
        // reviewer reading "TestFlight" may treat the build as a beta (guideline 2.2).
    }

    private var copyText: String { FeedbackMessage.plainText(description: problem, report: attachedReport) }

    private func compose() {
        outcome = nil
        if canSendMail {
            composing = true
            return
        }
        let body = FeedbackMessage.mailLinkBody(description: problem, report: attachedReport)
        guard let url = MailLink.url(recipient: recipient, subject: subject, body: body) else { outcome = .mailLinkFailed; return }
        openURL(url) { accepted in outcome = accepted ? .mailLinkOpened : .mailLinkFailed }
    }
}
