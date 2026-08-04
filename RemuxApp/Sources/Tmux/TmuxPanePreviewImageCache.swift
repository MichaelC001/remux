import CoreGraphics
import Foundation

/// Byte-bounded last-captured pane thumbnails for selector-sheet previews.
/// The cache is a Remux presentation concern; canonical terminal and renderer
/// state remain owned by the tmux session.
struct TmuxPanePreviewImageCache {
    struct Key: Hashable {
        let paneID: TmuxPaneID
        let framing: GhosttyPanePreviewSession.PreviewFraming
    }

    struct Entry {
        let preview: GhosttyPanePreviewSession.RenderedPreview
        let byteCost: Int
        var lastAccess: UInt64
    }

    let byteLimit: Int
    private(set) var entries: [Key: Entry] = [:]
    private(set) var totalByteCost = 0
    private var accessSequence: UInt64 = 0

    init(byteLimit: Int) {
        precondition(byteLimit > 0)
        self.byteLimit = byteLimit
    }

    mutating func preview(
        for paneID: TmuxPaneID,
        framing: GhosttyPanePreviewSession.PreviewFraming
    ) -> GhosttyPanePreviewSession.RenderedPreview? {
        let key = Key(paneID: paneID, framing: framing)
        guard var entry = entries[key] else { return nil }
        accessSequence &+= 1
        entry.lastAccess = accessSequence
        entries[key] = entry
        return entry.preview
    }

    @discardableResult
    mutating func store(
        _ preview: GhosttyPanePreviewSession.RenderedPreview,
        for paneID: TmuxPaneID,
        framing: GhosttyPanePreviewSession.PreviewFraming
    ) -> [Key] {
        let image = preview.image
        let (byteCost, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard !overflow, byteCost > 0, byteCost <= byteLimit else { return [] }

        let key = Key(paneID: paneID, framing: framing)
        if let replaced = entries.removeValue(forKey: key) {
            totalByteCost -= replaced.byteCost
        }
        accessSequence &+= 1
        entries[key] = Entry(
            preview: preview,
            byteCost: byteCost,
            lastAccess: accessSequence
        )
        totalByteCost += byteCost

        var evictedKeys: [Key] = []
        while totalByteCost > byteLimit,
              let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
            entries.removeValue(forKey: oldest.key)
            totalByteCost -= oldest.value.byteCost
            evictedKeys.append(oldest.key)
        }
        return evictedKeys
    }

    @discardableResult
    mutating func retainOnly(_ paneIDs: Set<TmuxPaneID>) -> [Key] {
        let removedKeys = entries.keys.filter { !paneIDs.contains($0.paneID) }
        for key in removedKeys {
            if let removed = entries.removeValue(forKey: key) {
                totalByteCost -= removed.byteCost
            }
        }
        return removedKeys
    }

    mutating func remove(
        _ paneID: TmuxPaneID,
        framing: GhosttyPanePreviewSession.PreviewFraming
    ) {
        let key = Key(paneID: paneID, framing: framing)
        guard let removed = entries.removeValue(forKey: key) else { return }
        totalByteCost -= removed.byteCost
    }

    mutating func removeAll() {
        entries.removeAll()
        totalByteCost = 0
        accessSequence = 0
    }
}
