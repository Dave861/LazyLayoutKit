/// How much content to build beyond what is on screen.
///
/// ## Why there are two units
///
/// 0.1 expressed this only in viewport heights, and device measurement showed
/// that is not a predictable amount of work. On an iPhone 14 Pro at 100,000
/// items, one screen height is 56 masonry cells but 108 timeline cells. Asking
/// for 80 gives 81 in both:
///
/// | layout | overscan | cells built | hitches per 100k pt |
/// |---|---|---|---|
/// | masonry | `.screens(1)` | 56 | 0.0 |
/// | masonry | `.items(80)` | **81** | 0.0 |
/// | timeline | `.screens(1)` | 108 | 34.2 |
/// | timeline | `.items(80)` | **81** | 32.3 |
/// | timeline | `.items(150)` | **151** | 37.2 |
///
/// **Bounding concurrent cells is the whole of what this buys**, and it is worth
/// having: it caps peak build cost and memory whatever the layout's density.
///
/// It is *not* a fix for dropped frames. Timeline hitches at about the same rate
/// on 81 cells as on 151, and masonry does not hitch at 81 at all — same device,
/// same count, opposite outcome. What differs is items crossing the viewport per
/// point scrolled: 67 per 1,000 pt against 26. Every item that crosses is built
/// once however large the window is, so a smaller window cannot lower the
/// construction rate.
///
/// An earlier version of this documentation cited a 2x2 measurement as showing
/// that only a large window *combined with* an expensive cell dropped frames. A
/// controlled re-run does not reproduce it, and the original runs recorded no
/// scroll distance, so they were very likely comparing unequal amounts of
/// scrolling. That claim is withdrawn.
///
/// ## Choosing
///
/// - ``screens(_:)`` when cells are uniform and cheap. Predictable distance,
///   which is what matters for a fast fling.
/// - ``items(_:)`` when cells are expensive or vary in height. Predictable work.
///
/// A bare number still means screens, so `overscan: 1` and `overscan: 0.5` keep
/// their 0.1 meaning.
public struct Overscan: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case screens(Double)
        case items(Int)
    }

    let kind: Kind

    /// Build this many multiples of the viewport height above and below.
    ///
    /// Negative and non-finite values are treated as zero.
    public static func screens(_ multiple: Double) -> Overscan {
        Overscan(kind: .screens(multiple.isFinite ? max(0, multiple) : 0))
    }

    /// Build as close to this many items in total as the content allows, centred
    /// on the viewport.
    ///
    /// Precisely: the window whose materialised count is **closest to `count`**,
    /// never fewer than are genuinely visible, and biased **downwards** on a tie.
    /// Content is discrete, so an exact hit is often impossible — with cells two
    /// per row, a budget of 81 can only resolve to 80 or 82, and this picks 80.
    ///
    /// Biasing low is deliberate. The whole reason this unit exists is that too
    /// many expensive cells drops frames, so where the budget cannot be met
    /// exactly it errs toward less work.
    ///
    /// Clamped at the ends of the content, where there is nothing to expand into,
    /// and at 20 viewport heights, so sparse content cannot run away.
    public static func items(_ count: Int) -> Overscan {
        Overscan(kind: .items(max(0, count)))
    }

    /// One viewport height above and below: 0.1's behaviour.
    public static let `default` = Overscan.screens(1)
}

extension Overscan: ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral {
    /// So `overscan: 0.5` keeps meaning half a screen.
    public init(floatLiteral value: Double) {
        self = .screens(value)
    }

    /// So `overscan: 1` keeps meaning one screen.
    public init(integerLiteral value: Int) {
        self = .screens(Double(value))
    }
}

public extension LayoutSnapshot {
    /// The region to build views for: the viewport, widened according to `overscan`.
    ///
    /// For ``Overscan/screens(_:)`` this is arithmetic. For ``Overscan/items(_:)``
    /// it has to consult the index, because how far to reach depends on how
    /// densely packed the content happens to be there — which varies down the
    /// content for a masonry or timeline layout, and varies with string length for
    /// text. The estimate comes from the density actually observed at the
    /// viewport, then converges. Queries cost about 2 µs, so spending three or
    /// four of them here is free relative to building one extra cell.
    func window(for viewport: LayoutRect, overscan: Overscan, containerWidth: Double) -> LayoutRect {
        let height = viewport.height > 0 ? viewport.height : 0
        guard height > 0 else { return viewport }

        switch overscan.kind {
        case let .screens(multiple):
            return expanded(viewport, by: height * multiple, containerWidth: containerWidth)

        case let .items(target):
            guard target > 0 else { return viewport }

            // The floor: a budget below what is on screen cannot remove cells
            // that are genuinely visible.
            let visible = visibleItems(in: viewport).count
            if visible >= target {
                return viewport
            }

            let maximumMargin = height * 20
            func count(atMargin margin: Double) -> Int {
                visibleItems(in: expanded(viewport, by: margin, containerWidth: containerWidth)).count
            }

            // Reaching as far as allowed still falls short: that is the best
            // available, so take it.
            let widest = count(atMargin: maximumMargin)
            if widest <= target {
                return expanded(viewport, by: maximumMargin, containerWidth: containerWidth)
            }

            // Count is monotonically non-decreasing in margin, so the boundary
            // can be bracketed. An earlier version estimated a margin from the
            // viewport's density and accepted the first result at or above the
            // target, which overshot by up to 1.55x on device — 124 cells for a
            // budget of 80 — because it never looked at what a smaller margin
            // would have given.
            var lower = 0.0, upper = maximumMargin
            var lowerCount = visible, upperCount = widest
            for _ in 0 ..< Self.budgetRefinements {
                let middle = (lower + upper) / 2
                let found = count(atMargin: middle)
                if found >= target {
                    upper = middle
                    upperCount = found
                } else {
                    lower = middle
                    lowerCount = found
                }
            }

            // Closest wins; a tie takes the smaller count.
            let margin = (target - lowerCount) <= (upperCount - target) ? lower : upper
            return expanded(viewport, by: margin, containerWidth: containerWidth)
        }
    }

    /// Bisection steps used to hit an item budget.
    ///
    /// Each one is a visibility query, measured at 1.8–4.3 µs on an A16, so the
    /// whole search costs roughly 25–50 µs — a fraction of a frame, and far less
    /// than building one cell that was not wanted. Ten steps resolve the margin
    /// to about a sixtieth of a viewport height, which is finer than the gap
    /// between adjacent item counts in any realistic layout.
    private static var budgetRefinements: Int {
        10
    }

    private func expanded(
        _ viewport: LayoutRect,
        by margin: Double,
        containerWidth: Double
    ) -> LayoutRect {
        let safeMargin = margin.isFinite ? max(0, margin) : 0
        return LayoutRect(
            x: 0,
            y: viewport.y - safeMargin,
            width: containerWidth,
            height: viewport.height + safeMargin * 2
        )
    }
}
