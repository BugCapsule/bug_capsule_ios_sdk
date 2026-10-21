import Foundation

extension BugCapsule {
    /// What the feedback forms send: the feedback, linked to the last
    /// event, plus a capsule when `captureCapsuleWithFeedback` applies
    /// (default: in `qa` mode) and the session is recording.
    @discardableResult
    public static func submitFeedback(message: String, name: String? = nil, email: String? = nil) async -> String? {
        guard let s = BugCapsuleSession.current, let m = s.monitoring else { return nil }
        let withCapsule = m.options.captureCapsuleWithFeedback ?? (s.mode == .qa)
        var capsuleId: String?
        if withCapsule && s.isRecording {
            capsuleId = await capture(note: "feedback")?.capsuleId
        }
        return captureFeedback(
            message: message, name: name, email: email, associatedEventId: m.lastEventId, capsuleId: capsuleId)
    }
}

#if canImport(UIKit)
    import UIKit

    /// Ready-made feedback form (name, email, message). Present it in a
    /// navigation controller, or call `BugCapsule.showFeedbackForm()`.
    open class BugCapsuleFeedbackViewController: UIViewController, UITextViewDelegate {
        public var formTitle = "Report a problem"
        public var messagePlaceholder = "What happened?"
        public var submitTitle = "Send"
        /// Called after sending with the feedback id (nil if not sent).
        public var onSubmit: (@MainActor (String?) -> Void)?

        public let nameField = UITextField()
        public let emailField = UITextField()
        public let messageView = UITextView()
        private let placeholder = UILabel()

        open override func viewDidLoad() {
            super.viewDidLoad()
            title = formTitle
            view.backgroundColor = .systemBackground
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: submitTitle, style: .done, target: self, action: #selector(sendTapped))
            navigationItem.rightBarButtonItem?.isEnabled = false

            nameField.placeholder = "Name (optional)"
            nameField.textContentType = .name
            emailField.placeholder = "Email (optional)"
            emailField.keyboardType = .emailAddress
            emailField.textContentType = .emailAddress
            emailField.autocapitalizationType = .none
            for f in [nameField, emailField] {
                f.borderStyle = .roundedRect
                f.accessibilityIdentifier = f === nameField ? "bugcapsule.feedback.name" : "bugcapsule.feedback.email"
            }
            messageView.font = .preferredFont(forTextStyle: .body)
            messageView.layer.borderColor = UIColor.separator.cgColor
            messageView.layer.borderWidth = 1
            messageView.layer.cornerRadius = 6
            messageView.delegate = self
            messageView.accessibilityIdentifier = "bugcapsule.feedback.message"
            placeholder.text = messagePlaceholder
            placeholder.textColor = .placeholderText
            placeholder.font = messageView.font
            placeholder.translatesAutoresizingMaskIntoConstraints = false
            messageView.addSubview(placeholder)

            let stack = UIStackView(arrangedSubviews: [nameField, emailField, messageView])
            stack.axis = .vertical
            stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(stack)
            let guide = view.layoutMarginsGuide
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
                stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
                messageView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
                placeholder.topAnchor.constraint(equalTo: messageView.topAnchor, constant: 8),
                placeholder.leadingAnchor.constraint(equalTo: messageView.leadingAnchor, constant: 5),
            ])
            if let user = BugCapsule.scope?.user {
                nameField.text = user.username
                emailField.text = user.email
            }
        }

        public func textViewDidChange(_ textView: UITextView) {
            let empty = textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            placeholder.isHidden = !textView.text.isEmpty
            navigationItem.rightBarButtonItem?.isEnabled = !empty
        }

        @objc private func cancelTapped() { dismiss(animated: true) }

        @objc private func sendTapped() {
            navigationItem.rightBarButtonItem?.isEnabled = false
            let message = messageView.text ?? ""
            let name = nameField.text?.isEmpty == false ? nameField.text : nil
            let email = emailField.text?.isEmpty == false ? emailField.text : nil
            Task { @MainActor in
                let id = await BugCapsule.submitFeedback(message: message, name: name, email: email)
                self.onSubmit?(id)
                self.dismiss(animated: true)
            }
        }
    }

    extension BugCapsule {
        /// Presents `BugCapsuleFeedbackViewController` over the top-most
        /// view controller of the key window.
        @MainActor
        public static func showFeedbackForm(from presenter: UIViewController? = nil) {
            guard let base = presenter ?? topViewController() else { return }
            if base is BugCapsuleFeedbackViewController || (base as? UINavigationController)?.topViewController is BugCapsuleFeedbackViewController {
                return
            }
            let nav = UINavigationController(rootViewController: BugCapsuleFeedbackViewController())
            base.present(nav, animated: true)
        }

        /// Shake-to-report: opens the feedback form when
        /// `enableShakeToReport` is set. `BugCapsuleWindow` calls it; apps
        /// with their own window call it from `motionEnded(_:with:)`.
        @MainActor
        public static func handleShake() {
            guard let m = BugCapsuleSession.current?.monitoring, m.options.enableShakeToReport, m.isActive else { return }
            showFeedbackForm()
        }

        @MainActor
        static func topViewController() -> UIViewController? {
            let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first { $0.isKeyWindow }
            var top = window?.rootViewController
            while let presented = top?.presentedViewController { top = presented }
            return top
        }
    }

    extension BugCapsuleWindow {
        open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            if motion == .motionShake { BugCapsule.handleShake() }
            super.motionEnded(motion, with: event)
        }
    }
#endif

#if canImport(SwiftUI) && canImport(UIKit)
    import SwiftUI

    /// SwiftUI feedback form; `.bugCapsuleFeedbackSheet(isPresented:)`
    /// presents it as a sheet.
    public struct BugCapsuleFeedbackForm: View {
        @Environment(\.dismiss) private var dismiss
        @State private var name = ""
        @State private var email = ""
        @State private var message = ""
        @State private var sending = false
        private let title: String
        private let onSubmit: ((String?) -> Void)?

        public init(title: String = "Report a problem", onSubmit: ((String?) -> Void)? = nil) {
            self.title = title
            self.onSubmit = onSubmit
        }

        public var body: some View {
            NavigationView {
                Form {
                    Section {
                        TextField("Name (optional)", text: $name).textContentType(.name)
                        TextField("Email (optional)", text: $email)
                            .textContentType(.emailAddress).keyboardType(.emailAddress).autocapitalization(.none)
                    }
                    Section(header: Text("What happened?")) {
                        TextEditor(text: $message).frame(minHeight: 140)
                            .accessibilityIdentifier("bugcapsule.feedback.message")
                    }
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send") {
                            sending = true
                            let (m, n, e) = (message, name, email)
                            Task { @MainActor in
                                let id = await BugCapsule.submitFeedback(
                                    message: m, name: n.isEmpty ? nil : n, email: e.isEmpty ? nil : e)
                                onSubmit?(id)
                                dismiss()
                            }
                        }
                        .disabled(sending || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .onAppear {
                if let user = BugCapsule.scope?.user {
                    name = user.username ?? ""
                    email = user.email ?? ""
                }
            }
        }
    }

    extension View {
        /// Presents `BugCapsuleFeedbackForm` as a sheet.
        public func bugCapsuleFeedbackSheet(isPresented: Binding<Bool>, onSubmit: ((String?) -> Void)? = nil) -> some View {
            sheet(isPresented: isPresented) { BugCapsuleFeedbackForm(onSubmit: onSubmit) }
        }
    }
#endif
