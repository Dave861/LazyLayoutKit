/// A solved layout: every frame, plus what's needed to answer visibility and
/// anchoring questions about it.
///
/// Snapshots are exact and computed eagerly — there is no estimation and no
/// chunking in 0.1. When the collection or the width changes, the container
/// builds a new snapshot rather than mutating this one.
///
/// ## Why identity is caller-supplied
///
/// Positions are keyed by a stable `ID`, not by index. Index identity is correct
/// only for a collection that never mutates: insert one item at the front and
/// every index shifts, so anchoring "keep item 37 where it is" silently starts
/// holding a different item still. Anchoring across a mutation is precisely the
/// case that has to work.
public struct LayoutSnapshot<ID: Hashable & Sendable>: Sendable {
    /// Item identity, in item order.
    public let ids: [ID]
    /// Item frames, in item order. Parallel to ``ids``.
    public let frames: [LayoutRect]
    public let contentHeight: Double
    public let containerWidth: Double

    let index: VerticalVisibilityIndex

    /// Number of ids that collided. Non-zero means the caller's identity is not
    /// unique, so anchoring and view identity are both unreliable.
    ///
    /// Computing this is O(n), so it is a diagnostic to check deliberately — not
    /// something to touch on the solve path.
    public var duplicateIDCount: Int {
        var seen = Set<ID>(minimumCapacity: ids.count)
        var duplicates = 0
        for id in ids where !seen.insert(id).inserted {
            duplicates += 1
        }
        return duplicates
    }

    public init(
        ids: [ID],
        result: LazyLayoutResult,
        containerWidth: Double
    ) {
        precondition(
            ids.count == result.frames.count,
            "a layout must return exactly one frame per item"
        )
        self.ids = ids
        self.containerWidth = containerWidth

        // A layout is allowed to emit negative coordinates — a timeline whose
        // origin is "now" naturally does. The scroll plane cannot be negative,
        // though, so the snapshot shifts everything onto a zero-based plane
        // here. Widening `contentHeight` alone would not do: the container
        // positions each view at its own `y`, so a frame above zero would stay
        // clipped while an equal band of blank space appeared at the bottom.
        var lowestTop = Double.infinity
        var highestBottom = -Double.infinity
        for frame in result.frames where frame.height > 0 && frame.minY.isFinite && frame.maxY.isFinite {
            lowestTop = min(lowestTop, frame.minY)
            highestBottom = max(highestBottom, frame.maxY)
        }
        let shift = lowestTop.isFinite ? max(0, -lowestTop) : 0

        if shift > 0 {
            frames = result.frames.map {
                LayoutRect(x: $0.x, y: $0.y + shift, width: $0.width, height: $0.height)
            }
        } else {
            frames = result.frames
        }

        let bottom = highestBottom.isFinite ? highestBottom + shift : 0
        // Trust the algorithm's content height, but never let it clip frames it
        // actually produced.
        contentHeight = max(0, max(result.contentHeight, bottom))

        index = VerticalVisibilityIndex(frames: frames)
    }

    public var count: Int {
        frames.count
    }

    /// Contiguous index payload for benchmark and demo instrumentation.
    @_spi(Instrumentation)
    public var visibilityIndexStorageByteCount: Int {
        index.storageByteCount
    }

    /// Item positions whose frames intersect `viewport`, in source order.
    public func visibleItems(in viewport: LayoutRect) -> [Int] {
        index.indices(intersecting: viewport, frames: frames)
    }

    /// Buffer-reusing variant for the per-frame path.
    public func appendVisibleItems(in viewport: LayoutRect, to result: inout [Int]) {
        index.appendIndices(intersecting: viewport, frames: frames, to: &result)
    }

    /// - Complexity: O(n). Anchoring performs one lookup per snapshot; a
    ///   contiguous scan is substantially cheaper for that access pattern than
    ///   constructing a hash table over the entire collection.
    public func position(of id: ID) -> Int? {
        ids.firstIndex(of: id)
    }

    public func frame(of id: ID) -> LayoutRect? {
        position(of: id).map { frames[$0] }
    }

    /// The item to hold still when the layout changes.
    ///
    /// Prefers the topmost item at or below the viewport's top edge; falls back
    /// to whatever straddles that edge. Returns `nil` only when nothing is
    /// visible, in which case there is no anchor to preserve.
    public func anchor(in viewport: LayoutRect) -> ID? {
        var bestBelow: Int?
        var bestBelowY = Double.infinity
        var bestStraddling: Int?
        var bestStraddlingY = -Double.infinity

        for position in visibleItems(in: viewport) {
            let top = frames[position].minY
            if top >= viewport.minY {
                if top < bestBelowY {
                    bestBelowY = top
                    bestBelow = position
                }
            } else if top > bestStraddlingY {
                bestStraddlingY = top
                bestStraddling = position
            }
        }
        return (bestBelow ?? bestStraddling).map { ids[$0] }
    }

    /// How far to move the scroll offset so `anchor` stays where the user sees it.
    ///
    /// Returns `nil` when the anchor is absent from either snapshot — it was
    /// deleted, or has not been laid out yet — in which case the caller should
    /// leave the offset alone rather than guess.
    public func offsetAdjustment(
        keeping anchor: ID,
        alignedWith previous: LayoutSnapshot<ID>
    ) -> Double? {
        guard
            let now = frame(of: anchor)?.minY,
            let before = previous.frame(of: anchor)?.minY
        else { return nil }
        return now - before
    }
}
