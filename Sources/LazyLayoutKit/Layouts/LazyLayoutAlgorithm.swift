/// A layout that can place every item without building a single view.
///
/// This is the whole contract. Given each item's layout input and the width
/// available, return a frame per item. No view is constructed, measured, or
/// consulted — which is exactly what makes virtualization possible: frames for
/// a hundred thousand items are arithmetic, and only the ones on screen ever
/// become views.
///
/// ``Item`` is an associated type rather than a fixed "height or aspect ratio"
/// enum on purpose. A masonry grid wants an aspect ratio; a timeline wants a
/// start and an end; a calendar wants a date range. Fixing the input to a
/// height would quietly make this a masonry protocol wearing a general name.
///
/// ## Requirements
///
/// - `layout` must be **pure**: the same items and width must produce the same
///   frames. The container caches results and re-solves on width changes, so a
///   layout that consults external mutable state will appear to glitch.
/// - Frames may overlap, may be in any order, and may use negative coordinates.
///   Nothing downstream assumes the output is sorted or monotonic.
/// - `contentHeight` should cover every frame. Returning less clips scrolling.
public protocol LazyLayoutAlgorithm: Equatable, Sendable {
    /// Per-item layout input. Whatever this layout needs in order to place an
    /// item without seeing it.
    ///
    /// `Equatable` because the container has to know when the inputs changed in
    /// order to re-solve. Without it, an item resizing would not be noticed.
    associatedtype Item: Equatable & Sendable

    func layout(items: [Item], containerWidth: Double) -> LazyLayoutResult
}

/// The frames a ``LazyLayoutAlgorithm`` produced, plus the total scrollable height.
public struct LazyLayoutResult: Equatable, Sendable {
    /// One frame per item, in item order.
    public var frames: [LayoutRect]
    /// Total height of the content plane. Should span every frame.
    public var contentHeight: Double

    public init(frames: [LayoutRect], contentHeight: Double) {
        self.frames = frames
        self.contentHeight = contentHeight
    }
}

/// Layout input for algorithms that place items by height alone.
///
/// There is deliberately no `.estimated` or `.measured` case. Those names imply
/// a measure-and-correct lifecycle — build a view, observe what it wanted, then
/// correct the layout and the scroll offset — which this package does not
/// implement and is not planning to.
///
/// Self-sizing text does not change that. `TextMeasurer` computes a height from
/// the string, the font and the width before any view exists, so the caller still
/// passes a `.fixedHeight`; the number was simply computed rather than known in
/// advance. From here the distinction is invisible, which is the point.
///
/// What remains unsupported is content whose height is genuinely only knowable
/// after it has been built.
public enum ItemMetric: Hashable, Sendable {
    /// width ÷ height. Height is derived from whatever column width the layout
    /// assigns.
    case aspectRatio(Double)
    /// A height that does not depend on the width available.
    case fixedHeight(Double)

    /// Resolved height, guarding against inputs that would produce a degenerate
    /// or non-finite frame.
    public func height(forWidth width: Double) -> Double {
        switch self {
        case let .aspectRatio(ratio):
            guard ratio > 0, ratio.isFinite, width > 0 else { return max(0, width) }
            return width / ratio
        case let .fixedHeight(height):
            guard height.isFinite else { return 0 }
            return max(0, height)
        }
    }
}
