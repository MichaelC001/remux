import SwiftUI
import UIKit

struct GhosttyComposerSessionState: Equatable {
    var draft = ""
    var attachments: [GhosttyPendingAttachment] = []

    var hasContent: Bool {
        !draft.isEmpty || !attachments.isEmpty
    }

    var areAttachmentsReady: Bool {
        attachments.allSatisfy { $0.transferSource != nil }
    }
}

enum GhosttyComposerMessageFormatter {
    static func message(draft: String, attachmentText: String) -> String {
        guard !draft.isEmpty else { return attachmentText }
        guard !attachmentText.isEmpty else { return draft }
        return draft + "\n" + attachmentText
    }
}

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
    static let collapsedHeight: CGFloat = 50

    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle

    @Binding var text: String
    @Binding var attachments: [GhosttyPendingAttachment]

    let wantsKeyboardFocus: Bool
    let keyboardActivationToken: Int
    let submissionState: GhosttyComposeBarSubmissionState
    let dictationPhase: GhosttyComposerDictationPhase
    let dictationAudioLevels: [CGFloat]
    let statusMessage: String?
    let attachmentUploadCount: Int
    let attachmentTransferProgress: GhosttyAttachmentTransferProgress?
    let onKeyboardFocusChange: (Bool) -> Void
    let onChoosePhotos: () -> Void
    let onChooseFiles: () -> Void
    let onOpenAttachments: () -> Void
    let onRemoveAttachment: (GhosttyPendingAttachment.ID) -> Void
    let onPasteAttachment: () -> Bool
    let onStartDictation: () -> Void
    let onCancelDictation: () -> Void
    let onFinishDictation: () -> Void
    let onSend: () -> Void

    var body: some View {
        VStack(spacing: attachments.isEmpty ? 0 : 6) {
            if !attachments.isEmpty {
                GhosttyComposerAttachmentStrip(
                    attachments: attachments,
                    isEnabled: submissionState.allowsComposerInput,
                    onOpen: onOpenAttachments,
                    onRemove: onRemoveAttachment
                )

                if submissionState.isSending, attachmentUploadCount > 0 {
                    GhosttyComposerAttachmentProgress(
                        uploadCount: attachmentUploadCount,
                        progress: attachmentTransferProgress
                    )
                }
            }

            if dictationPhase.isActive {
                dictationRow
            } else {
                composerRow
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 3)
        .frame(minHeight: Self.collapsedHeight)
        .frame(maxWidth: 560)
        .ghosttyComposerSurface()
        .accessibilityElement(children: .contain)
    }

    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: 2) {
            attachmentMenu

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
                        caretColor: UIColor(chromeStyle.accent),
                        isEditable: submissionState.allowsComposerInput,
                        wantsFirstResponder: wantsKeyboardFocus,
                        activationToken: keyboardActivationToken,
                        onFirstResponderChange: onKeyboardFocusChange,
                        onPasteAttachment: onPasteAttachment
                    )
                }
            }

            dictationButton

            sendButton(
                state: submissionState,
                action: onSend
            )
        }
    }

    private var dictationRow: some View {
        HStack(spacing: 2) {
            dictationModeButton(
                systemName: "xmark",
                accessibilityLabel: "Cancel dictation",
                accessibilityIdentifier: "terminal.composer.dictation.cancel",
                action: onCancelDictation
            )

            Group {
                switch dictationPhase {
                case .idle:
                    EmptyView()
                case .starting:
                    dictationStatus("Starting…")
                case .recording:
                    GhosttyComposerDictationMeter(levels: dictationAudioLevels)
                case .transcribing:
                    dictationStatus("Transcribing")
                }
            }
            .frame(maxWidth: .infinity)

            if dictationPhase == .recording {
                dictationModeButton(
                    systemName: "stop.fill",
                    accessibilityLabel: "Stop dictation",
                    accessibilityIdentifier: "terminal.composer.dictation.stop",
                    action: onFinishDictation
                )
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(GhosttyPhoneChromePalette.chromeForeground)
                    .frame(width: 42, height: 42)
            }

            sendButton(
                state: submissionState,
                allowsTap: dictationPhase == .recording && submissionState.isSendEnabled,
                action: onSend
            )
        }
        .frame(minHeight: 42)
    }

    private func dictationStatus(_ title: String) -> some View {
        Text(title)
            .font(.body)
            .foregroundStyle(GhosttyPhoneChromePalette.chromeSecondaryForeground)
            .lineLimit(1)
            .accessibilityIdentifier("terminal.composer.dictation.status")
    }

    private func dictationModeButton(
        systemName: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        return Button {
            Haptic.chromeControlPress()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(GhosttyPhoneChromePalette.chromeForeground)
                .frame(width: 34, height: 34)
                .background(
                    GhosttyPhoneChromePalette.toolbarButtonPressedFill,
                    in: Circle()
                )
                .frame(width: 42, height: 42)
        }
        .buttonStyle(GhosttyComposerPressButtonStyle())
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var composerPlaceholder: String {
        if submissionState == .awaitingSubmit {
            return "Pasted — tap Submit"
        }
        return attachments.isEmpty ? "Compose…" : "Describe the task…"
    }

    private var attachmentMenu: some View {
        Menu {
            Button(action: onChoosePhotos) {
                Label("Photos", systemImage: "photo")
            }

            Button(action: onChooseFiles) {
                Label("Files", systemImage: "folder")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(GhosttyPhoneChromePalette.chromeForeground)
                .frame(width: 42, height: 42)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuOrder(.fixed)
        .disabled(!submissionState.allowsComposerInput)
        .opacity(submissionState.allowsComposerInput ? 1 : 0.38)
        .accessibilityLabel("Add attachment")
        .accessibilityIdentifier("terminal.composer.attachments")
    }

    private var dictationButton: some View {
        Button {
            Haptic.chromeControlPress()
            onStartDictation()
        } label: {
            Image(systemName: "mic")
                .font(.system(size: 20, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(GhosttyPhoneChromePalette.chromeForeground)
                .frame(width: 42, height: 42)
        }
        .buttonStyle(GhosttyComposerPressButtonStyle())
        .disabled(!submissionState.allowsComposerInput)
        .opacity(submissionState.allowsComposerInput ? 1 : 0.38)
        .accessibilityLabel("Start dictation")
        .accessibilityIdentifier("terminal.composer.mic")
    }

    private func sendButton(
        state: GhosttyComposeBarSubmissionState,
        allowsTap: Bool? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let isEnabled = allowsTap ?? state.isSendEnabled

        return Button {
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
        .buttonStyle(GhosttyComposerPressButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled || state.isSending ? 1 : 0.38)
        .accessibilityLabel(state.sendAccessibilityLabel)
        .accessibilityIdentifier("terminal.composer.send")
    }
}

private struct GhosttyComposerPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                Circle()
                    .fill(
                        configuration.isPressed
                            ? GhosttyPhoneChromePalette.toolbarButtonPressedFill
                            : Color.clear
                    )
            }
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

private struct GhosttyComposerDictationMeter: View {
    let levels: [CGFloat]

    var body: some View {
        GeometryReader { geometry in
            let spacing = CGFloat(2)
            let availableWidth = max(
                geometry.size.width - (spacing * CGFloat(max(levels.count - 1, 0))),
                0
            )
            let barWidth = max(min(availableWidth / CGFloat(max(levels.count, 1)), 3), 1.5)

            HStack(spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(GhosttyPhoneChromePalette.chromeForeground.opacity(0.72))
                        .frame(
                            width: barWidth,
                            height: max(4, 6 + (level * 24))
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 32)
        .accessibilityLabel("Recording audio")
        .accessibilityIdentifier("terminal.composer.dictation.meter")
    }
}

private extension View {
    @ViewBuilder
    func ghosttyComposerSurface(cornerRadius: CGFloat = 28) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(iOS 26.0, *) {
            self
                .background {
                    Color.clear
                        .glassEffect(
                            .regular.tint(
                                GhosttyPhoneChromePalette.toolbarGlassTint.opacity(0.70)
                            ),
                            in: shape
                        )
                        .shadow(
                            color: GhosttyPhoneChromePalette.toolbarGlassShadow.opacity(0.60),
                            radius: 8,
                            y: 4
                        )
                }
        } else {
            self
                .background(GhosttyPhoneChromePalette.toolbarFallbackFill, in: shape)
                .overlay {
                    shape.strokeBorder(
                        GhosttyPhoneChromePalette.toolbarStroke,
                        lineWidth: 0.75
                    )
                }
                .shadow(
                    color: GhosttyPhoneChromePalette.toolbarShadow.opacity(0.70),
                    radius: 6,
                    y: 3
                )
        }
    }
}

private struct GhosttyComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let caretColor: UIColor
    let isEditable: Bool
    let wantsFirstResponder: Bool
    let activationToken: Int
    let onFirstResponderChange: (Bool) -> Void
    let onPasteAttachment: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> GhosttyComposerUITextView {
        let textView = GhosttyComposerUITextView()
        textView.delegate = context.coordinator
        textView.onPasteAttachment = onPasteAttachment
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.tintColor = caretColor
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .yes
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.textContainerInset = UIEdgeInsets(top: 5, left: 0, bottom: 5, right: 0)
        textView.textContainer.lineFragmentPadding = 4
        textView.isEditable = isEditable
        textView.isScrollEnabled = false
        textView.accessibilityIdentifier = "terminal.composer.field"
        return textView
    }

    func updateUIView(_ textView: GhosttyComposerUITextView, context: Context) {
        context.coordinator.parent = self
        textView.isEditable = isEditable
        textView.tintColor = caretColor
        textView.onPasteAttachment = onPasteAttachment

        if textView.text != text {
            textView.text = text
            textView.selectedRange = NSRange(
                location: textView.text.utf16.count,
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
        uiView textView: GhosttyComposerUITextView,
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

private final class GhosttyComposerUITextView: UITextView {
    var onPasteAttachment: (() -> Bool)?

    override func paste(_ sender: Any?) {
        if onPasteAttachment?() == true {
            return
        }
        super.paste(sender)
    }
}

private struct GhosttyComposerAttachmentStrip: View {
    let attachments: [GhosttyPendingAttachment]
    let isEnabled: Bool
    let onOpen: () -> Void
    let onRemove: (GhosttyPendingAttachment.ID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(attachments) { attachment in
                    attachmentChip(attachment)
                }
            }
        }
        .contentMargins(.horizontal, 2, for: .scrollContent)
        .accessibilityIdentifier("terminal.composer.attachment-strip")
    }

    private func attachmentChip(_ attachment: GhosttyPendingAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                Haptic.chromeControlPress()
                onOpen()
            } label: {
                attachmentPreview(attachment)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled || !attachment.isPreviewable)
            .accessibilityLabel("Preview \(attachment.title)")

            Button {
                Haptic.chromeControlPress()
                onRemove(attachment.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.black.opacity(0.72), in: Circle())
                    .overlay {
                        Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75)
                    }
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .accessibilityLabel("Remove \(attachment.title)")
            .accessibilityIdentifier("terminal.composer.attachment.remove")
            .offset(x: 4, y: -4)
        }
        .padding(.top, 4)
        .padding(.trailing, 4)
        .opacity(isEnabled ? 1 : 0.68)
    }

    @ViewBuilder
    private func attachmentPreview(_ attachment: GhosttyPendingAttachment) -> some View {
        if case .imageData(let data) = attachment.previewPayload,
           let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75)
                }
                .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        } else if isImageAttachment(attachment) {
            attachmentLoadingPreview(attachment)
        } else {
            filePreview(attachment)
        }
    }

    private func attachmentLoadingPreview(_ attachment: GhosttyPendingAttachment) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(0.08))

            if attachment.isPreparingTransferSource {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: attachment.systemName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(GhosttyPhoneChromePalette.chromeSecondaryForeground)
            }
        }
        .frame(width: 58, height: 58)
    }

    private func filePreview(_ attachment: GhosttyPendingAttachment) -> some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.09))

                if attachment.isPreparingTransferSource {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Text(fileTypeLabel(for: attachment))
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(GhosttyPhoneChromePalette.chromeSecondaryForeground)
                        .lineLimit(1)
                }
            }
            .frame(width: 34, height: 40)

            Text(attachment.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(GhosttyPhoneChromePalette.chromeForeground)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 9)
        .frame(width: 154, height: 58)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
        }
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func isImageAttachment(_ attachment: GhosttyPendingAttachment) -> Bool {
        switch attachment.kind {
        case .photo, .pasteboardImage:
            true
        case .video, .media, .file, .pasteboardLink, .pasteboardText:
            false
        }
    }

    private func fileTypeLabel(for attachment: GhosttyPendingAttachment) -> String {
        let fileExtension = (attachment.title as NSString).pathExtension
        return fileExtension.isEmpty ? "FILE" : String(fileExtension.prefix(5)).uppercased()
    }
}

private struct GhosttyComposerAttachmentProgress: View {
    let uploadCount: Int
    let progress: GhosttyAttachmentTransferProgress?

    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: progressFraction)
                .tint(.blue)

            Text(progressLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(GhosttyPhoneChromePalette.chromeSecondaryForeground)
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progressAccessibilityLabel)
        .accessibilityIdentifier("terminal.composer.attachment-progress")
    }

    private var progressFraction: Double {
        guard let progress else { return 0 }
        let completed = Double(progress.completedUploadCount)
        let current = progress.currentUploadFraction
        return min(1, (completed + current) / Double(max(uploadCount, 1)))
    }

    private var progressLabel: String {
        guard let progress else {
            return uploadCount > 1 ? "Uploading 1 of \(uploadCount)" : "Uploading"
        }
        let percent = Int((progress.currentUploadFraction * 100).rounded())
        if uploadCount > 1 {
            return "\(progress.currentUploadIndex) of \(uploadCount) · \(percent)%"
        }
        return "\(percent)%"
    }

    private var progressAccessibilityLabel: String {
        "Attachment upload \(Int((progressFraction * 100).rounded())) percent"
    }
}
