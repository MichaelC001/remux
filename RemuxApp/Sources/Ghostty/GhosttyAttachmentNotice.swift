import SwiftUI

struct GhosttyAttachmentNotice: Identifiable, Equatable {
    let id: UUID
    let message: String

    init(message: String, id: UUID = UUID()) {
        self.id = id
        self.message = message
    }
}

struct GhosttyAttachmentNoticeBanner: View {
    let notice: GhosttyAttachmentNotice

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .semibold))
                .imageScale(.medium)
                .accessibilityHidden(true)

            Text(notice.message)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(GhosttyPhoneChromePalette.chromeForeground)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 360, alignment: .leading)
        .ghosttyAttachmentNoticeSurface()
        .accessibilityIdentifier("terminal.attachments.notice")
    }
}

private extension View {
    @ViewBuilder
    func ghosttyAttachmentNoticeSurface() -> some View {
        let shape = Capsule()

        if #available(iOS 26.0, *) {
            self
                .glassEffect(
                    .regular
                        .tint(GhosttyAttachmentSurfaceStyle.panelGlassTint),
                    in: shape
                )
                .overlay {
                    shape.strokeBorder(GhosttyAttachmentSurfaceStyle.panelGlassStroke, lineWidth: 0.75)
                }
                .shadow(color: GhosttyAttachmentSurfaceStyle.panelGlassShadow, radius: 12, y: 7)
                .contentShape(shape)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .background {
                    shape.fill(GhosttyAttachmentSurfaceStyle.fallbackPanelFill)
                }
                .overlay {
                    shape.strokeBorder(GhosttyAttachmentSurfaceStyle.fallbackPanelStroke, lineWidth: 1)
                }
                .shadow(color: GhosttyAttachmentSurfaceStyle.fallbackShadow, radius: 12, y: 7)
        }
    }
}
