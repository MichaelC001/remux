import Foundation

enum GhosttyTerminalActionMissingTarget: Equatable, Sendable {
    case host
    case pane(UUID)
    case focusedPane
    case topLevel(UUID)
    case topLevelPane(UUID)
    case selectedTopLevel
    case adjacentTopLevel
}

