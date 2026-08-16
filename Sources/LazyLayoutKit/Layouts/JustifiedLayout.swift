/// A justified gallery: images keep their aspect ratios, and every completed row
/// fills the container's width exactly.
///
/// This is the Photos and Flickr arrangement. It is also the clearest example of
/// something `LazyVGrid` cannot express: a grid has to know its columns before it
/// sees the content, but here the number of items in a row is a *result* of the
/// content — how many landscape shots happen to sit next to each other decides
/// where the row breaks.
///
/// ```swift
/// LazyLayoutView(photos, layout: JustifiedLayout(targetRowHeight: 200)) { photo in
///     .aspectRatio(photo.width / photo.height)
/// } content: { photo in
///     PhotoCell(photo)
/// }
/// ```
///
/// Placement is one pass of arithmetic over the items — the same complexity as
/// ``MasonryLayout``, and it builds no view to do it. That is a statement about
/// the algorithm, not a measurement: the device figures this project publishes
/// were all taken with ``MasonryLayout`` and have not been re-run here.
///
/// ## A property worth knowing before you use it
///
/// Rows are closed greedily: items are added until the row is full enough to be
/// no taller than ``targetRowHeight``, and the item that tipped it over stays in
/// that row. So **every completed row is at or below the target height**, never
/// above it. The cost is that one very wide panorama can pull its row well below
/// the target on its own.
///
/// The usual refinement is a one-item look-back — close the row without that item
/// if doing so lands closer to the target — and it is deliberately not done here.
/// It reopens the following row for a second decision and introduces a "can this
/// row end up empty" case, which is real complexity for a purely aesthetic gain.
///
/// ## Sizes down the content
///
/// Row tops accumulate by addition, so at a million items the last row's `y` is
/// the sum of roughly three hundred thousand terms. At `Double`'s precision that
/// is a relative error around 1e-16 over a plane of about 10^7 points — well
/// under a micron, and far below anything a scroll offset can express. No
/// compensated summation is warranted.
public struct JustifiedLayout: LazyLayoutAlgorithm {
    public typealias Item = ItemMetric

    /// What to do with the trailing row, which by definition never filled up.
    public enum LastRowPolicy: Hashable, Sendable {
        /// Keep ``targetRowHeight``, so the items are the size they would have
        /// been and the row simply ends short of the right edge.
        ///
        /// The default, and what every photo grid you have seen does.
        case natural
        /// Stretch it to fill like any other row, so a single leftover image
        /// spans the entire container.
        case justified
    }

    /// The height rows aim for. Actual heights vary — that is the point of
    /// justification — but a completed row is never taller than this.
    public var targetRowHeight: Double
    /// The gutter between items within a row.
    public var horizontalSpacing: Double
    /// The gutter between rows.
    public var verticalSpacing: Double
    public var lastRow: LastRowPolicy

    public init(
        targetRowHeight: Double = 240,
        horizontalSpacing: Double = 8,
        verticalSpacing: Double = 8,
        lastRow: LastRowPolicy = .natural
    ) {
        self.targetRowHeight = targetRowHeight.isFinite ? max(1, targetRowHeight) : 240
        self.horizontalSpacing = max(0, horizontalSpacing.isFinite ? horizontalSpacing : 0)
        self.verticalSpacing = max(0, verticalSpacing.isFinite ? verticalSpacing : 0)
        self.lastRow = lastRow
    }

    /// What an item with no usable ratio is treated as: a square.
    ///
    /// ``ItemMetric/fixedHeight(_:)`` lands here. A fixed height is a height
    /// without a width, so there is no ratio in it to preserve, and this layout
    /// places entirely by ratio. Pass ``ItemMetric/aspectRatio(_:)``.
    private static let fallbackAspectRatio = 1.0
    /// A 1:20 tower.
    private static let minimumAspectRatio = 0.05
    /// A 20:1 panorama.
    private static let maximumAspectRatio = 20.0

    /// Sanitized width ÷ height for an item.
    ///
    /// The clamp is load-bearing, not cosmetic. A row's height is
    /// `available / Σratios`, so a single ratio of 1e9 drives the entire row to
    /// roughly zero points — and a zero-height frame intersects no viewport
    /// (see ``LayoutRect/intersectsVertically(_:)``), so one bad ratio would
    /// silently delete every other item beside it. Clamping letterboxes the
    /// offender instead, which is visible and recoverable.
    private func ratio(of item: ItemMetric) -> Double {
        guard case let .aspectRatio(ratio) = item, ratio.isFinite, ratio > 0 else {
            return Self.fallbackAspectRatio
        }
        return min(Self.maximumAspectRatio, max(Self.minimumAspectRatio, ratio))
    }

    public func layout(items: [ItemMetric], containerWidth: Double) -> LazyLayoutResult {
        guard !items.isEmpty else { return LazyLayoutResult(frames: [], contentHeight: 0) }

        let width = containerWidth.isFinite ? max(0, containerWidth) : 0
        let ratios = items.map(ratio)

        var frames = [LayoutRect](
            repeating: LayoutRect(x: 0, y: 0, width: 0, height: 0),
            count: items.count
        )
        var rowStart = 0
        var ratioSum = 0.0
        var y = 0.0

        for index in items.indices {
            ratioSum += ratios[index]
            let count = index - rowStart + 1
            // Every ratio is at least `minimumAspectRatio`, so the sum is
            // strictly positive and this cannot divide by zero.
            let height = available(forItemCount: count, in: width) / ratioSum

            // Adding an item only ever lowers the height, so this is monotone and
            // the row closes the moment it is short enough.
            if height <= targetRowHeight {
                emit(
                    rowStart ... index,
                    ratios: ratios,
                    height: height,
                    width: width,
                    justified: true,
                    into: &frames,
                    y: &y
                )
                rowStart = index + 1
                ratioSum = 0
            }
        }

        if rowStart < items.count {
            let range = rowStart ... (items.count - 1)
            switch lastRow {
            case .natural:
                emit(
                    range,
                    ratios: ratios,
                    height: targetRowHeight,
                    width: width,
                    justified: false,
                    into: &frames,
                    y: &y
                )
            case .justified:
                let count = range.count
                let sum = ratios[range].reduce(0, +)
                emit(
                    range,
                    ratios: ratios,
                    height: available(forItemCount: count, in: width) / sum,
                    width: width,
                    justified: true,
                    into: &frames,
                    y: &y
                )
            }
        }

        // The trailing spacing below the last row is not content — same reasoning
        // as `MasonryLayout`.
        return LazyLayoutResult(frames: frames, contentHeight: max(0, y - verticalSpacing))
    }

    /// Width left for the photos themselves once the gutters are taken out.
    private func available(forItemCount count: Int, in width: Double) -> Double {
        max(0, width - horizontalSpacing * Double(count - 1))
    }

    private func emit(
        _ range: ClosedRange<Int>,
        ratios: [Double],
        height: Double,
        width: Double,
        justified: Bool,
        into frames: inout [LayoutRect],
        y: inout Double
    ) {
        let rowHeight = height.isFinite ? max(0, height) : 0
        var x = 0.0
        for index in range {
            var itemWidth = rowHeight * ratios[index]
            if justified, index == range.upperBound {
                // Σ(h · rᵢ) equals the available width in exact arithmetic but
                // not in `Double`, so the row's right edge can miss the container
                // by a few ulps — or, once heights are large, by a visible
                // fraction of a point. Snapping the last item makes a completed
                // row fill the width *exactly*, which is the property callers see
                // and the one the tests assert without a tolerance.
                //
                // The guard means a row whose sums genuinely went wrong keeps its
                // computed width rather than being handed a nonsense one.
                let remainder = width - x
                if abs(remainder - itemWidth) <= 0.5 {
                    itemWidth = remainder
                }
            }
            frames[index] = LayoutRect(
                x: x,
                y: y,
                width: max(0, itemWidth),
                height: rowHeight
            )
            x += itemWidth + horizontalSpacing
        }
        y += rowHeight + verticalSpacing
    }
}
