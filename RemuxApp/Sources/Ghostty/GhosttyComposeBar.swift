import SwiftUI
import UIKit

enum GhosttyComposeBarSubmissionState: Equatable {
    case composing(canSend: Bool)
    case sending
    case awaitingSubmit

    var allowsComposerInput: Bool {
        if case .composing = self { return true }
        return false
    }

    var isSendEnabled: Bool {
        switch self {
        case .composing(let canSend):
            canSend
        case .sending:
            false
        case .awaitingSubmit:
            true
        }
    }

    var isSending: Bool {
        self == .sending
    }

    var sendAccessibilityLabel: String {
        self == .awaitingSubmit ? "Submit pasted message" : "Send"
    }
}

struct GhosttyComposeBar: View {
    @Binding var text: String

    let wantsKeyboardFocus: Bool
    let keyboardActivationToken: Int
    let submissionState: GhosttyComposeBarSubmissionState
    let statusMessage: String?
    let onKeyboardFocusChange: (Bool) -> Void
    let onSend: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            utilityButton(
                systemName: "plus",
                accessibilityLabel: "Add attachment",
                accessibilityIdentifier: "terminal.composer.attachments",
                symbolSize: 22,
                symbolWeight: .regular,
                isEnabled: submissionState.allowsComposerInput,
                action: {}
            )

            VStack(alignment: .leading, spacing: 0) {
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(GhosttyPhoneChromePalette.chromeSecondaryForeground)
                        .padding(.leading, 4)
                        .accessibilityIdentifier("terminal.composer.status")
                }

                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(composerPlaceholder)
                            .foregroundStyle(GhosttyPhoneChromePalette.chromeSecondaryForeground)
                            .padding(.leading, 4)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                            .accessibilityHidden(submissionState != .awaitingSubmit)
                    }

                    GhosttyComposerTextView(
                        text: $text,
                        isEditable: submissionState.allowsComposerInput,
                        wantsFirstResponder: wantsKeyboardFocus,
                        activationToken: keyboardActivationToken,
                        onFirstResponderChange: onKeyboardFocusChange
                    )
                }
            }

            utilityButton(
                systemName: "mic",
                accessibilityLabel: "Start dictation",
                accessibilityIdentifier: "terminal.composer.mic",
                symbolSize: 20,
                symbolWeight: .regular,
                isEnabled: submissionState.allowsComposerInput,
                action: {}
            )

            sendButton(
                state: submissionState,
                action: onSend
            )
        }
        .padding(6)
        .padding(.leading, 2)
        .frame(minHeight: 54)
        .frame(maxWidth: 560)
        .ghosttyComposerSurface()
        .accessibilityElement(children: .contain)
    }

    private var composerPlaceholder: String {
        submissionState == .awaitingSubmit ? "Pasted — tap Submit" : "Compose…"
    }

    private func utilityButton(
        systemName: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        symbolSize: CGFloat,
        symbolWeight: Font.Weight,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptic.chromeControlPress()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: symbolSize, weight: symbolWeight))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(GhosttyPhoneChromePalette.chromeForeground)
                .frame(width: 42, height: 42)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.38)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func sendButton(
        state: GhosttyComposeBarSubmissionState,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptic.chromeControlPress()
            action()
        } label: {
            ZStack {
                Circle()
                    .fill(Color(uiColor: .systemBlue))

                if state.isSending {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.white)
                }
            }
                .frame(width: 34, height: 34)
                .frame(width: 42, height: 42)
        }
        .buttonStyle(.plain)
        .disabled(!state.isSendEnabled)
        .opacity(state.isSendEnabled || state.isSending ? 1 : 0.38)
        .accessibilityLabel(state.sendAccessibilityLabel)
        .accessibilityIdentifier("terminal.composer.send")
    }
}

private extension View {
    @ViewBuilder
    func ghosttyComposerSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)

        if #available(iOS 26.0, *) {
            self
                .glassEffect(
                    .regular
                        .tint(GhosttyPhoneChromePalette.toolbarGlassTint)
                        .interactive(),
                    in: shape
                )
                .overlay {
                    shape.strokeBorder(
                        GhosttyPhoneChromePalette.toolbarGlassStroke,
                        lineWidth: 0.75
                    )
                }
                .shadow(
                    color: GhosttyPhoneChromePalette.toolbarGlassShadow,
                    radius: 13,
                    y: 7
                )
        } else {
            self
                .background(GhosttyPhoneChromePalette.toolbarFallbackFill, in: shape)
                .overlay {
                    shape.strokeBorder(
                        GhosttyPhoneChromePalette.toolbarStroke,
                        lineWidth: 1
                    )
                }
                .shadow(
                    color: GhosttyPhoneChromePalette.toolbarShadow,
                    radius: 8,
                    y: 4
                )
        }
    }
}

private struct GhosttyComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let wantsFirstResponder: Bool
    let activationToken: Int
    let onFirstResponderChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.tintColor = .systemBlue
        textView.autocapitalizationType = .sentences
        textView.autocorrectionType = .yes
        textView.spellCheckingType = .yes
        textView.smartDashesType = .yes
        textView.smartQuotesType = .yes
        textView.textContainerInset = UIEdgeInsets(top: 5, left: 0, bottom: 5, right: 0)
        textView.textContainer.lineFragmentPadding = 4
        textView.isEditable = isEditable
        textView.isScrollEnabled = false
        textView.accessibilityIdentifier = "terminal.composer.field"
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        textView.isEditable = isEditable

        if textView.text != text {
            let selection = textView.selectedRange
            textView.text = text
            textView.selectedRange = NSRange(
                location: min(selection.location, textView.text.utf16.count),
                length: 0
            )
        }

        context.coordinator.reconcileFirstResponder(
            textView,
            wantsFirstResponder: wantsFirstResponder,
            activationToken: activationToken
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView textView: UITextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let measuredHeight = ceil(
            textView.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude)
            ).height
        )
        let lineHeight = textView.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
        let verticalInsets = textView.textContainerInset.top + textView.textContainerInset.bottom
        let maximumHeight = ceil((lineHeight * 5) + verticalInsets)
        let resolvedHeight = min(max(measuredHeight, 36), maximumHeight)
        textView.isScrollEnabled = measuredHeight > maximumHeight
        return CGSize(width: width, height: resolvedHeight)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: GhosttyComposerTextView
        private var appliedActivationToken = -1

        init(parent: GhosttyComposerTextView) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFirstResponderChange(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onFirstResponderChange(false)
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            textView.invalidateIntrinsicContentSize()
        }

        func reconcileFirstResponder(
            _ textView: UITextView,
            wantsFirstResponder: Bool,
            activationToken: Int
        ) {
            let activationChanged = appliedActivationToken != activationToken
            appliedActivationToken = activationToken

            if wantsFirstResponder {
                guard activationChanged || !textView.isFirstResponder else { return }
                DispatchQueue.main.async { [weak textView] in
                    guard let textView, textView.window != nil else { return }
                    textView.becomeFirstResponder()
                }
            } else if textView.isFirstResponder {
                DispatchQueue.main.async { [weak textView] in
                    textView?.resignFirstResponder()
                }
            }
        }
    }
}
