/// Where an item should end up in the viewport when you scroll to it.
///
/// Three of these are absolute — they describe a place in the viewport and put
/// the item there regardless of where the user currently is. ``nearest`` is not:
/// it describes an *amount of movement*, so it needs the current offset as well
/// as the item's frame.
public enum ScrollAnchor: Hashable, Sendable {
    /// The item's top edge at the viewport's top edge.
    case top
    /// The item centred vertically. An item taller than the viewport is centred
    /// on its own middle, so both its edges are off screen.
    case center
    /// The item's bottom edge at the viewport's bottom edge.
    case bottom
    /// Move as little as possible: nothing at all if the item is already fully
    /// visible, otherwise just far enough to bring the nearer edge in.
    ///
    /// An item taller than the viewport can never be fully visible, so this
    /// aligns its top and leaves the rest below the fold.
    case nearest
}

public extension LayoutSnapshot {
    /// The scroll offset that brings `id` into view at `anchor`, clamped to the
    /// scrollable range.
    ///
    /// This is the whole reason programmatic scrolling works here at all. An
    /// item that has not been materialized has no view for SwiftUI's own
    /// `ScrollPosition` to target — but the snapshot already knows exactly where
    /// it is, so the offset is arithmetic over a frame this container computed
    /// before any view existed.
    ///
    /// Returns `nil` when `id` is not in this snapshot. That is deliberately
    /// ambiguous between "deleted" and "not laid out yet": one snapshot cannot
    /// tell them apart, so the caller decides. ``LazyLayoutView`` retains a
    /// request while the snapshot is empty and drops it once a non-empty
    /// snapshot still lacks the id.
    ///
    /// When identity is not unique this targets the *first* occurrence, matching
    /// ``LayoutSnapshot/position(of:)`` and anchoring.
    ///
    /// - Parameters:
    ///   - id: The item to reveal.
    ///   - anchor: Where in the viewport it should land.
    ///   - viewportHeight: The visible height. Zero — which happens before the
    ///     scroll view has reported geometry — is tolerated and yields the right
    ///     answer for ``ScrollAnchor/top``.
    ///   - currentOffset: Where the viewport is now. Only
    ///     ``ScrollAnchor/nearest`` reads it.
    /// - Complexity: O(n), one identity scan. The same access pattern anchoring
    ///   already pays: once per request, never per frame. It must stay that way —
    ///   this is not something to call from the visibility path.
    func offset(
        toShow id: ID,
        anchor: ScrollAnchor = .top,
        viewportHeight: Double,
        currentOffset: Double = 0
    ) -> Double? {
        frame(of: id).map {
            offset(
                toShow: $0,
                anchor: anchor,
                viewportHeight: viewportHeight,
                currentOffset: currentOffset
            )
        }
    }

    /// The same calculation for a frame already in hand.
    ///
    /// Useful when you have resolved the frame yourself and do not want to pay
    /// for a second identity scan.
    func offset(
        toShow frame: LayoutRect,
        anchor: ScrollAnchor = .top,
        viewportHeight: Double,
        currentOffset: Double = 0
    ) -> Double {
        // A custom layout is allowed to emit nonsense, and the contract is to
        // clamp rather than trap — the same posture as `ItemMetric.height(forWidth:)`.
        // `LayoutSnapshot.init` has already shifted negative coordinates onto a
        // zero-based plane, so in practice these guards only catch the pathological.
        let height = viewportHeight.isFinite ? max(0, viewportHeight) : 0
        let itemHeight = frame.height.isFinite ? max(0, frame.height) : 0
        let top = frame.minY.isFinite ? frame.minY : 0
        let current = currentOffset.isFinite ? max(0, currentOffset) : 0

        let desired: Double
        switch anchor {
        case .top:
            desired = top
        case .center:
            // Negative when the item is taller than the viewport, which centres
            // on the item's own middle. That is the sensible reading, not a bug
            // to special-case.
            desired = top - (height - itemHeight) / 2
        case .bottom:
            desired = top + itemHeight - height
        case .nearest:
            let bottom = top + itemHeight
            if itemHeight >= height {
                // It cannot be made fully visible at any offset, so "reveal it"
                // has to mean something else. Aligning the top shows the item's
                // beginning; aligning the bottom would scroll *past* everything
                // the user has not seen to land at its end.
                desired = top
            } else if top >= current, bottom <= current + height {
                desired = current // already fully visible: do not move
            } else if top < current {
                desired = top // reveal upward
            } else {
                desired = bottom - height // reveal downward
            }
        }

        // The scroll view will clamp to this range whatever it is asked for.
        // Clamping here too is what lets the container adopt the offset locally
        // and build the correct window in one pass, instead of waiting for a
        // scroll-geometry round trip to tell it where it actually ended up.
        let maximum = max(0, contentHeight - height)
        return min(max(0, desired), maximum)
    }
}
