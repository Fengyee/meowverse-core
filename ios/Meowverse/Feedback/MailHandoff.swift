import MessageUI
import SwiftUI

/// What happened to a mail the user wrote, said plainly. "Sent" only means handed to Mail.
/// Shared by 「反馈问题」 and 「我想要这个」.
enum MailOutcome: Equatable {
    case handedToMail, savedDraft, cancelled, failed, mailLinkOpened, mailLinkFailed

    init(_ result: MFMailComposeResult) {
        self = switch result {
        case .sent: .handedToMail
        case .saved: .savedDraft
        case .cancelled: .cancelled
        default: .failed
        }
    }

    var isProblem: Bool { self == .failed || self == .mailLinkFailed }

    func text(recipient: String) -> String {
        switch self {
        case .handedToMail: String(localized: "已交给“邮件”发送。是否送达请在“邮件”里查看。")
        case .savedDraft: String(localized: "已存为“邮件”里的草稿，还没有发出。")
        case .cancelled: String(localized: "没有发送。")
        case .failed: String(localized: "“邮件”没能处理这封邮件，没有发出。可以再试一次。")
        case .mailLinkOpened: String(localized: "已打开邮件 App。请在那里检查内容后发送。")
        case .mailLinkFailed: String(localized: "没能打开邮件 App，没有发出。请拷贝内容，自己发到 \(recipient)。")
        }
    }
}

/// Without a Mail account: a `mailto:` link for whatever mail app is installed.
enum MailLink {
    static func url(recipient: String, subject: String, body: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = recipient
        parts.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        return parts.url
    }
}

/// The outcome line under the send buttons.
struct MailOutcomeLabel: View {
    let outcome: MailOutcome
    let recipient: String

    var body: some View {
        Label(outcome.text(recipient: recipient),
              systemImage: outcome.isProblem ? "exclamationmark.triangle" : "info.circle")
            .font(.subheadline)
            .foregroundStyle(outcome.isProblem ? Color.caution : Color.primary)
    }
}
