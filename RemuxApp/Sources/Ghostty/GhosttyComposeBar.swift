import SwiftUI
import UIKit

struct GhosttyComposeBar: View {
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle
    @Binding var text: String

    let wantsKeyboardFocus: Bool
    let keyboardActivationToken: Int
    let onKeyboardFocusChange: (Bool) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            composeButton(
                systemName: "plus",
                accessibilityLabel: "Add attachment",
                accessibilityIdentifier: "terminal.composer.attachments",
                isEnabled: false,
                action: {}
            )

            HStack(alignment: .bottom, spacing: 4) {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Compose…")
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }

                    GhosttyComposerTextView(
                        text: $text,
                        wantsFirstResponder: wantsKeyboardFocus,
                        activationToken: keyboardActivationToken,
                        onFirstResponderChange: onKeyboardFocusChange
                    )
                }

                composeButton(
                    systemName: "mic.fill",
                    accessibilityLabel: "Start dictation",
                    accessibilityIdentifier: "terminal.composer.mic",
                    isEnabled: false,
                    size: 36,
                    action: {}
                )
            }
            .padding(.leading, 16)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .frame(minHeight: 44)
            .background(.regularMaterial, in: composeFieldShape)
            .overlay {
                composeFieldShape
                    .strokeBorder(Color.primary.opacity(0.11), lineWidth: 0.75)
            }

            composeButton(
                systemName: "arrow.up",
                accessibilityLabel: "Send",
                accessibilityIdentifier: "terminal.composer.send",
                isEnabled: false,
                usesAccentFill: true,
                action: {}
            )
        }
        .frame(maxWidth: 560)
        .accessibilityElement(children: .contain)
    }

    private var composeFieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
    }

    private func composeButton(
        systemName: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        isEnabled: Bool,
        size: CGFloat = 44,
        usesAccentFill: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptic.chromeControlPress()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(
                    usesAccentFill
                        ? chromeStyle.accentForeground
                        : GhosttyPhoneChromePalette.chromeForeground
                )
                .frame(width: size, height: size)
                .background(
                    usesAccentFill
                        ? chromeStyle.accent
                        : Color(uiColor: .secondarySystemBackground).opacity(0.88),
                    in: Circle()
                )
                .overlay {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75)
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.38)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct GhosttyComposerTextView: UIViewRepresentable {
    @Binding var text: String
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
        textView.isScrollEnabled = false
        textView.accessibilityIdentifier = "terminal.composer.field"
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self

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
