import Foundation

/// Remux records each zoom it makes on the zoomed window, as the tmux user
/// option `@remux-zoom-owner`, so a reconnect or an app restart can tell its
/// own zooms from anyone else's and still release them. The owner is the saved
/// server's id: stable on this install, different on every other device.
///
/// The native client pairs exactly one reply block with each command, so these
/// are plain command sequences (never `if-shell`, whose nested commands add
/// blocks). The conditional part is a `set-option -F` format that tmux
/// evaluates right after the zoom change, in the same sequence.
struct TmuxZoomOwner: Equatable, Sendable {
    static let optionName = "@remux-zoom-owner"

    let id: String

    init(serverID: UUID) {
        id = serverID.uuidString
    }

    /// Follows a zoom command: marks the window as this owner's only if the
    /// window ended up zoomed.
    func markIfZoomedCommand(windowID: TmuxWindowID) -> String {
        let option = Self.optionName
        return "set-option -F -w -t @\(windowID.rawValue) \(option) '#{?window_zoomed_flag,\(id),#{\(option)}}'"
    }

    /// Clears the window's mark only if it is this owner's.
    func clearMarkCommand(windowID: TmuxWindowID) -> String {
        let option = Self.optionName
        return "set-option -F -w -t @\(windowID.rawValue) \(option) '#{?#{==:#{\(option)},\(id)},,#{\(option)}}'"
    }

    static let marksQuery = "list-windows -F '#{window_id} #{window_zoomed_flag} #{\(optionName)}'"

    /// Parses a `marksQuery` reply. Lines that are not `@id flag [owner]` are
    /// skipped.
    func marks(fromQueryReply reply: String) -> [TmuxZoomMark] {
        reply.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 2,
                  fields[0].first == "@",
                  let rawWindowID = UInt64(fields[0].dropFirst()),
                  fields[1] == "0" || fields[1] == "1"
            else { return nil }
            let owner = fields.count == 3 ? String(fields[2]) : ""
            return TmuxZoomMark(
                windowID: TmuxWindowID(rawWindowID),
                zoomed: fields[1] == "1",
                isOwn: owner == id
            )
        }
    }
}

struct TmuxZoomMark: Equatable, Sendable {
    let windowID: TmuxWindowID
    let zoomed: Bool
    /// The window carries this owner's mark.
    let isOwn: Bool
}

/// What a new attachment does with the marks it finds: it takes back the zooms
/// this owner made that are still in place, and forgets marks whose zoom is
/// gone (tmux unzooms on its own, for example after a split).
struct TmuxZoomMarkAdoption: Equatable {
    let adoptedWindowIDs: [TmuxWindowID]
    let forgottenWindowIDs: [TmuxWindowID]

    /// - Parameters:
    ///   - zoomedWindowIDs: zoomed windows in the attachment's current
    ///     topology, which may be newer than the marks reply.
    ///   - zoomingWindowIDs: windows this attachment is zooming itself; their
    ///     fresh marks may arrive before the topology shows the zoom.
    init(
        marks: [TmuxZoomMark],
        zoomedWindowIDs: Set<TmuxWindowID>,
        zoomingWindowIDs: Set<TmuxWindowID>
    ) {
        let ownMarks = marks.filter(\.isOwn)
        adoptedWindowIDs = ownMarks
            .filter { $0.zoomed && zoomedWindowIDs.contains($0.windowID) }
            .map(\.windowID)
        forgottenWindowIDs = ownMarks
            .filter { mark in
                !zoomingWindowIDs.contains(mark.windowID)
                    && !(mark.zoomed && zoomedWindowIDs.contains(mark.windowID))
            }
            .map(\.windowID)
    }
}
