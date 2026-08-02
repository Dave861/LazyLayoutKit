/// A masonry ("waterfall") layout: fixed columns, each item placed in whichever
/// column is currently shortest.
///
/// The reference implementation of ``LazyLayoutAlgorithm``. It exists to be
/// useful, and to demonstrate that the protocol asks for very little.
///
/// ## A property worth knowing before you use it
///
/// Placement is a fold over the items, so changing one item's height can change
/// which *column* every later item lands in. Scroll position is preserved across
/// such a change — the container anchors on a stable id — but the content will
/// visibly reflow. If your items resize after they are on screen, that reflow is
/// inherent to masonry, not a bug in the container. A fixed-height grid does not
/// have this property.
public struct MasonryLayout: LazyLayoutAlgorithm {
    public typealias Item = ItemMetric

    public var columns: Int
    public var spacing: Double

    public init(columns: Int, spacing: Double = 8) {
        self.columns = max(1, columns)
        self.spacing = max(0, spacing.isFinite ? spacing : 0)
    }

    public func columnWidth(forContainerWidth containerWidth: Double) -> Double {
        let gaps = spacing * Double(columns - 1)
        return max(0, (containerWidth - gaps) / Double(columns))
    }

    public func layout(items: [ItemMetric], containerWidth: Double) -> LazyLayoutResult {
        guard !items.isEmpty else { return LazyLayoutResult(frames: [], contentHeight: 0) }

        let width = columnWidth(forContainerWidth: containerWidth)
        var frames = [LayoutRect]()
        frames.reserveCapacity(items.count)
        var columnBottoms = [Double](repeating: 0, count: columns)

        for item in items {
            var shortest = 0
            for column in 1 ..< columns where columnBottoms[column] < columnBottoms[shortest] {
                shortest = column
            }
            let y = columnBottoms[shortest]
            let height = item.height(forWidth: width)
            frames.append(
                LayoutRect(
                    x: Double(shortest) * (width + spacing),
                    y: y,
                    width: width,
                    height: height
                )
            )
            columnBottoms[shortest] = y + height + spacing
        }

        // The trailing spacing below the last item in the tallest column is not
        // content.
        let tallest = columnBottoms.max() ?? 0
        return LazyLayoutResult(frames: frames, contentHeight: max(0, tallest - spacing))
    }
}
