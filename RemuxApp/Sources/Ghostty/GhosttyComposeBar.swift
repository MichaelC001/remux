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

@MainActor
final class GhosttyComposerSessionModel: ObservableObject {
    @Published var draft = ""
    @Published var attachments: [GhosttyPendingAttachment] = []

    var hasContent: Bool {
        snapshot.hasContent
    }

    var areAttachmentsReady: Bool {
        snapshot.areAttachmentsReady
    }

    var snapshot: GhosttyComposerSessionState {
        GhosttyComposerSessionState(draft: draft, attachments: attachments)
    }

    /// The retained terminal entry owns this model. Removing or replacing that
    /// entry releases the last unsent draft resources without treating ordinary
    /// pane switches or library navigation as destructive.
    isolated deinit {
        GhosttyAttachmentStagingStore.cleanup(attachments)
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
        }
    }

    var isSending: Bool {
        self == .sending
    }
}

private struct GhosttyComposerInputLayout: Layout {
    let isDictationActive: Bool
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat
    let expandedContentInset: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count == 4 else { return .zero }
        guard let width = proposal.width, width.isFinite, width > 0 else {
            let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            return CGSize(
                width: sizes.reduce(0) { $0 + $1.width } + (horizontalSpacing * 3),
                height: sizes.map(\.height).max() ?? 0
            )
        }

        let metrics = metrics(width: width, subviews: subviews)
        return CGSize(width: width, height: metrics.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 4 else { return }
        let metrics = metrics(width: bounds.width, subviews: subviews)

        if metrics.isExpanded {
            subviews[1].place(
                at: CGPoint(
                    x: bounds.minX + expandedContentInset,
                    y: bounds.minY + expandedContentInset
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(
                    width: max(0, bounds.width - (expandedContentInset * 2)),
                    height: metrics.center.height
                )
            )
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.maxY),
                anchor: .bottomLeading,
                proposal: ProposedViewSize(metrics.leading)
            )
            subviews[3].place(
                at: CGPoint(x: bounds.maxX, y: bounds.maxY),
                anchor: .bottomTrailing,
                proposal: ProposedViewSize(metrics.send)
            )
            subviews[2].place(
                at: CGPoint(
                    x: bounds.maxX - metrics.send.width - horizontalSpacing,
                    y: bounds.maxY
                ),
                anchor: .bottomTrailing,
                proposal: ProposedViewSize(metrics.dictation)
            )
            return
        }

        var x = bounds.minX
        for (index, size) in metrics.compactSizes.enumerated() {
            subviews[index].place(
                at: CGPoint(x: x, y: bounds.maxY),
                anchor: .bottomLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + horizontalSpacing
        }
    }

    private func metrics(width: CGFloat, subviews: Subviews) -> Metrics {
        let leading = subviews[0].sizeThatFits(.unspecified)
        let dictation = subviews[2].sizeThatFits(.unspecified)
        let send = subviews[3].sizeThatFits(.unspecified)
        let compactCenterWidth = max(
            0,
            width - leading.width - dictation.width - send.width - (horizontalSpacing * 3)
        )
        let compactCenter = subviews[1].sizeThatFits(
            ProposedViewSize(width: compactCenterWidth, height: nil)
        )
        let controlsHeight = max(leading.height, max(dictation.height, send.height))
        let isExpanded = !isDictationActive && compactCenter.height > controlsHeight
        let expandedCenterWidth = max(0, width - (expandedContentInset * 2))
        let center = isExpanded
            ? subviews[1].sizeThatFits(ProposedViewSize(width: expandedCenterWidth, height: nil))
            : compactCenter
        let height = isExpanded
            ? expandedContentInset + center.height + verticalSpacing + controlsHeight
            : max(controlsHeight, center.height)

        return Metrics(
            leading: leading,
            center: center,
            dictation: dictation,
            send: send,
            compactSizes: [leading, center, dictation, send],
            isExpanded: isExpanded,
            height: height
        )
    }

    private struct Metrics {
        let leading: CGSize
        let center: CGSize
        let dictation: CGSize
        let send: CGSize
        let compactSizes: [CGSize]
        let isExpanded: Bool
        let height: CGFloat
    }
}

struct GhosttyComposeBar: View {
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle

    @Binding var text: String
    @Binding var attachments: [GhosttyPendingAttachment]

    let wantsKeyboardFocus: Bool
    let keyboardActivationToken: Int
    let keyboardResponderHandoff: GhosttyKeyboardResponderHandoff
    let submissionState: GhosttyComposeBarSubmissionState
    let dictationPhase: GhosttyComposerDictationPhase
    let dictationAudioLevelModel: GhosttyComposerAudioLevelModel
    let statusMessage: String?
    let attachmentUploadCount: Int
    let attachmentTransferProgress: GhosttyAttachmentTransferProgress?
    let onKeyboardFocusRequest: () -> Void
    let onKeyboardResponderAttached: () -> Void
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

            composerRow
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 3)
        .frame(minHeight: GhosttyKeyboardChromeSizing.baselineHeight)
        .frame(maxWidth: .infinity)
        .ghosttyComposerSurface()
        .overlay {
            Color.clear
                .accessibilityElement()
                .accessibilityIdentifier("terminal.composer.bounds")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.composer")
    }

    private var composerRow: some View {
        GhosttyComposerInputLayout(
            isDictationActive: dictationPhase.isActive,
            horizontalSpacing: 2,
            verticalSpacing: 2,
            expandedContentInset: 8
        ) {
            leadingControl

            composerTextRegion

            dictationControl

            sendButton(
                state: submissionState,
                allowsTap: !dictationPhase.isActive
                    || (dictationPhase == .recording && submissionState.isSendEnabled),
                action: onSend
            )
        }
    }

    private var composerTextRegion: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !dictationPhase.isActive, let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(GhosttyPhoneChromePalette.chromeSecondaryForeground)
                    .padding(.leading, 4)
                    .accessibilityIdentifier("terminal.composer.status")
            }

            ZStack(alignment: .topLeading) {
                GhosttyComposerTextView(
                    text: $text,
                    caretColor: UIColor(chromeStyle.accent),
                    allowsUserEdits: submissionState.allowsComposerInput
                        && !dictationPhase.isActive,
                    wantsFirstResponder: wantsKeyboardFocus,
                    activationToken: keyboardActivationToken,
                    responderHandoff: keyboardResponderHandoff,
                    onFocusRequest: onKeyboardFocusRequest,
                    onResponderAttached: onKeyboardResponderAttached,
                    onPasteAttachment: onPasteAttachment
                )
                .frame(height: dictationPhase.isActive ? 32 : nil)
                .opacity(dictationPhase.isActive ? 0 : 1)
                .allowsHitTesting(!dictationPhase.isActive)
                .accessibilityHidden(dictationPhase.isActive)
                .overlay(alignment: .topLeading) {
                    composerCenterPresentation
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var composerCenterPresentation: some View {
        if dictationPhase.isActive {
            dictationCenterContent
                .frame(maxWidth: .infinity)
                .frame(height: 32)
        } else if text.isEmpty {
            Text(composerPlaceholder)
                .foregroundStyle(GhosttyPhoneChromePalette.chromeSecondaryForeground)
                .padding(.leading, 4)
                .padding(.top, 8)
                .allowsHitTesting(false)
                .accessibilityIdentifier("terminal.composer.placeholder")
        }
    }

    @ViewBuilder
    private var leadingControl: some View {
        if dictationPhase.isActive {
            dictationModeButton(
                systemName: "xmark",
                accessibilityLabel: "Cancel dictation",
                accessibilityIdentifier: "terminal.composer.dictation.cancel",
                action: onCancelDictation
            )
        } else {
            attachmentMenu
        }
    }

    @ViewBuilder
    private var dictationCenterContent: some View {
        switch dictationPhase {
        case .idle:
            EmptyView()
        case .preparing:
            dictationStatus("Preparing dictation…")
        case .starting:
            dictationStatus("Starting…")
        case .recording:
            GhosttyComposerDictationMeter(model: dictationAudioLevelModel)
        case .transcribing:
            dictationStatus("Transcribing")
        }
    }

    @ViewBuilder
    private var dictationControl: some View {
        switch dictationPhase {
        case .idle:
            dictationButton
        case .recording:
            dictationModeButton(
                systemName: "stop.fill",
                accessibilityLabel: "Stop dictation",
                accessibilityIdentifier: "terminal.composer.dictation.stop",
                action: onFinishDictation
            )
        case .preparing, .starting, .transcribing:
            ProgressView()
                .controlSize(.small)
                .tint(GhosttyPhoneChromePalette.chromeForeground)
                .frame(width: 42, height: 42)
        }
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
        allowsTap: Bool,
        action: @escaping () -> Void
    ) -> some View {
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
        .disabled(!allowsTap)
        .opacity(allowsTap || state.isSending ? 1 : 0.38)
        .accessibilityLabel("Send")
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
    @ObservedObject var model: GhosttyComposerAudioLevelModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(model.levels.indices, id: \.self) { index in
                Capsule()
                    .fill(GhosttyPhoneChromePalette.chromeForeground.opacity(0.72))
                    .frame(
                        width: 2.5,
                        height: max(4, 6 + (model.levels[index] * 24))
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 32)
        .clipped()
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
    let allowsUserEdits: Bool
    let wantsFirstResponder: Bool
    let activationToken: Int
    let responderHandoff: GhosttyKeyboardResponderHandoff
    let onFocusRequest: () -> Void
    let onResponderAttached: () -> Void
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
        // Keep the keyboard's assistance geometry identical when ownership
        // moves between the terminal and composer responders.
        textView.spellCheckingType = .no
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.textContainerInset = UIEdgeInsets(top: 5, left: 0, bottom: 5, right: 0)
        textView.textContainer.lineFragmentPadding = 4
        textView.isScrollEnabled = false
        textView.accessibilityIdentifier = "terminal.composer.field"
        textView.onAttachedToWindow = onResponderAttached
        responderHandoff.register(textView, as: .composer)
        return textView
    }

    func updateUIView(_ textView: GhosttyComposerUITextView, context: Context) {
        context.coordinator.parent = self
        textView.tintColor = caretColor
        textView.onPasteAttachment = onPasteAttachment
        textView.onAttachedToWindow = onResponderAttached
        responderHandoff.register(textView, as: .composer)

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
        private var reconciliationGeneration: UInt64 = 0

        init(parent: GhosttyComposerTextView) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocusRequest()
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            textView.invalidateIntrinsicContentSize()
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            parent.allowsUserEdits
        }

        func reconcileFirstResponder(
            _ textView: UITextView,
            wantsFirstResponder: Bool,
            activationToken: Int
        ) {
            let activationChanged = appliedActivationToken != activationToken
            appliedActivationToken = activationToken
            reconciliationGeneration &+= 1
            let requestedGeneration = reconciliationGeneration

            if wantsFirstResponder {
                guard !textView.isFirstResponder else { return }
                guard activationChanged || textView.window != nil else { return }
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self,
                          self.reconciliationGeneration == requestedGeneration,
                          self.parent.wantsFirstResponder,
                          let textView,
                          textView.window != nil,
                          !textView.isFirstResponder else {
                        return
                    }
                    _ = textView.becomeFirstResponder()
                }
            } else if textView.isFirstResponder {
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self,
                          self.reconciliationGeneration == requestedGeneration,
                          !self.parent.wantsFirstResponder,
                          let textView,
                          textView.isFirstResponder else {
                        return
                    }
                    _ = textView.resignFirstResponder()
                }
            }
        }
    }
}

private final class GhosttyComposerUITextView: UITextView {
    var onPasteAttachment: (() -> Bool)?
    var onAttachedToWindow: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        onAttachedToWindow?()
    }

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
