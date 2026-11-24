import MessageUI
import MeowverseCore
import SwiftUI

/// The system mail composer, pre-filled. The user edits and sends from it; the app sends nothing.
struct MailComposer: UIViewControllerRepresentable {
    let recipient: String
    let subject: String
    let message: FeedbackMessage
    let onFinish: (MFMailComposeResult, (any Error)?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = context.coordinator
        composer.setToRecipients([recipient])
        composer.setSubject(subject)
        composer.setMessageBody(message.body, isHTML: false)
        if let attachment = message.attachment {
            composer.addAttachmentData(Data(attachment.utf8), mimeType: "text/plain", fileName: "diagnostics.txt")
        }
        return composer
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: (MFMailComposeResult, (any Error)?) -> Void

        init(onFinish: @escaping (MFMailComposeResult, (any Error)?) -> Void) { self.onFinish = onFinish }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult, error: (any Error)?) {
            onFinish(result, error)
        }
    }
}
