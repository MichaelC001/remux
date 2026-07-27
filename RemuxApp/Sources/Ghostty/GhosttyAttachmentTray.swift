import SwiftUI
import UIKit

enum GhosttyAttachmentTrayStyle {
    static let panelGlassTint = Color.primary.opacity(0.055)
    static let panelGlassStroke = Color.primary.opacity(0.14)
    static let panelGlassShadow = Color.black.opacity(0.16)
    static let fallbackPanelFill = Color(uiColor: .secondarySystemBackground).opacity(0.72)
    static let fallbackPanelStroke = Color.primary.opacity(0.08)
    static let fallbackShadow = Color.black.opacity(0.20)
    static let pendingIconStroke = Color.primary.opacity(0.08)
}
