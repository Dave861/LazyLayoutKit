@testable import LazyLayoutKit
import Testing

/// Windowing behaviour for both overscan units.
///
/// The item-budget unit exists because device measurement showed screen-heights
/// mean very different amounts of work per layout — 54 masonry cells against 128
/// timeline cells for the same one screen. These check the budget is actually
/// honoured, and more importantly that the ways it can go wrong are bounded:
/// it must never build fewer than is visible, never expand without limit through
/// sparse content, and never spend an unbounded number of queries converging.
@Suite("Overscan")
struct OverscanTests {
    /// Uniform stack of `count` items, each `height` tall.
    private static func stack(count: Int, height: Double, width: Double = 400) -> LayoutSnapshot<Int> {
        let frames = (0 ..< count).map {
            LayoutRect(x: 0, y: Double($0) * height, width: width, height: height)
        }
        return LayoutSnapshot(
            ids: Array(0 ..< count),
            result: LazyLayoutResult(frames: frames, contentHeight: Double(count) * height),
            containerWidth: width
        )
    }

    private static let viewport = LayoutRect(x: 0, y: 5000, width: 400, height: 800)

    // MARK: - Literal compatibility

    /// 0.1 spelled this as a `Double`. Those call sites have to keep compiling and
    /// keep meaning the same thing.
    @Test("Numeric literals still mean screen-heights")
    func literalsMeanScreens() {
        #expect((1 as Overscan) == .screens(1))
        #expect((0.5 as Overscan) == .screens(0.5))
        #expect((0 as Overscan) == .screens(0))
        #expect(Overscan.default == .screens(1))
    }

    @Test("Degenerate configurations are clamped rather than rejected")
    func degenerateConfigurationsAreClamped() {
        #expect(Overscan.screens(-3) == .screens(0))
        #expect(Overscan.screens(.nan) == .screens(0))
        #expect(Overscan.screens(.infinity) == .screens(0))
        #expect(Overscan.items(-10) == .items(0))
    }

    // MARK: - Screens

    @Test("A screen budget widens by that many viewport heights", arguments: [0.0, 0.25, 1.0, 2.0])
    func screenBudgetWidensProportionally(multiple: Double) {
        let snapshot = Self.stack(count: 2000, height: 100)
        let window = snapshot.window(
            for: Self.viewport,
            overscan: .screens(multiple),
            containerWidth: 400
        )
        let margin = 800 * multiple
        #expect(window.y == Self.viewport.y - margin)
        #expect(window.height == Self.viewport.height + margin * 2)
    }

    // MARK: - Items

    @Test("An item budget builds approximately that many items", arguments: [20, 40, 80, 200])
    func itemBudgetIsApproximatelyHonoured(target: Int) {
        // 100pt items in an 800pt viewport: 8-9 visible, so every target here
        // requires real expansion.
        let snapshot = Self.stack(count: 5000, height: 100)
        let window = snapshot.window(for: Self.viewport, overscan: .items(target), containerWidth: 400)
        let count = snapshot.visibleItems(in: window).count
        #expect(count >= target, "built \(count), wanted at least \(target)")
        // Approximately, not exactly — but not wildly over either, or the budget
        // would not be controlling anything.
        #expect(count <= target * 2, "built \(count) for a budget of \(target)")
    }

    /// The budget is a target for *extra* work, not a cap on what is on screen.
    /// Asking for fewer items than are visible must not hide any of them.
    @Test("A budget smaller than the visible count never hides visible items")
    func budgetSmallerThanVisibleStillShowsEverythingVisible() {
        let snapshot = Self.stack(count: 5000, height: 20) // 40 visible in 800pt
        let visible = snapshot.visibleItems(in: Self.viewport).count
        #expect(visible > 5)
        for target in [0, 1, 5] {
            let window = snapshot.window(for: Self.viewport, overscan: .items(target), containerWidth: 400)
            let built = snapshot.visibleItems(in: window)
            #expect(built.count >= visible, "budget \(target) built \(built.count) of \(visible) visible")
        }
    }

    /// Sparse content is the case that could make a density estimate run away:
    /// few items per point means a large reach to hit the budget.
    @Test("Sparse content does not expand the window without bound")
    func sparseContentIsBounded() {
        // Items far taller than the viewport, so very few are ever visible.
        let snapshot = Self.stack(count: 500, height: 4000)
        let window = snapshot.window(for: Self.viewport, overscan: .items(500), containerWidth: 400)
        // 20 viewport heights either side is the documented ceiling.
        let maximumHeight = Self.viewport.height + 800 * 20 * 2
        #expect(window.height <= maximumHeight)
        #expect(window.height.isFinite)
    }

    @Test("A budget larger than the whole collection clamps to the content")
    func budgetLargerThanContentIsSafe() {
        let snapshot = Self.stack(count: 30, height: 100)
        let viewport = LayoutRect(x: 0, y: 0, width: 400, height: 800)
        let window = snapshot.window(for: viewport, overscan: .items(10000), containerWidth: 400)
        let built = snapshot.visibleItems(in: window)
        #expect(built.count == 30)
        #expect(window.height.isFinite)
    }

    @Test("An empty snapshot produces a finite window")
    func emptySnapshotIsSafe() {
        let snapshot = LayoutSnapshot<Int>(
            ids: [],
            result: LazyLayoutResult(frames: [], contentHeight: 0),
            containerWidth: 400
        )
        let window = snapshot.window(for: Self.viewport, overscan: .items(50), containerWidth: 400)
        #expect(window.height.isFinite)
        #expect(snapshot.visibleItems(in: window).isEmpty)
    }

    @Test("An unmeasured viewport does not produce a degenerate window")
    func zeroHeightViewportIsSafe() {
        let snapshot = Self.stack(count: 1000, height: 100)
        let empty = LayoutRect(x: 0, y: 0, width: 400, height: 0)
        for overscan in [Overscan.screens(1), .items(50)] {
            let window = snapshot.window(for: empty, overscan: overscan, containerWidth: 400)
            #expect(window.height.isFinite)
            #expect(window.height >= 0)
        }
    }

    /// The whole point of the item unit: two layouts with very different cell
    /// densities should build comparable numbers of cells, where screen-heights
    /// would build wildly different ones.
    @Test("The item budget equalises work across densities where screens do not")
    func itemBudgetEqualisesAcrossDensities() {
        let sparse = Self.stack(count: 5000, height: 200) // ~4 per screen
        let dense = Self.stack(count: 20000, height: 25) // ~32 per screen

        let sparseScreens = sparse.visibleItems(
            in: sparse.window(for: Self.viewport, overscan: .screens(1), containerWidth: 400)
        ).count
        let denseScreens = dense.visibleItems(
            in: dense.window(for: Self.viewport, overscan: .screens(1), containerWidth: 400)
        ).count
        // The problem, restated as a test: same setting, very different work.
        #expect(denseScreens > sparseScreens * 4)

        let sparseItems = sparse.visibleItems(
            in: sparse.window(for: Self.viewport, overscan: .items(60), containerWidth: 400)
        ).count
        let denseItems = dense.visibleItems(
            in: dense.window(for: Self.viewport, overscan: .items(60), containerWidth: 400)
        ).count
        // The fix: same setting, comparable work.
        #expect(sparseItems >= 60)
        #expect(denseItems >= 60)
        #expect(Double(max(sparseItems, denseItems)) / Double(min(sparseItems, denseItems)) < 2)
    }

    // MARK: - Realistic snapshots

    /// Seeded aspect ratios through the real masonry layout: variable heights,
    /// three columns, density that changes as you scroll.
    private static func masonry(count: Int, width: Double = 400) -> LayoutSnapshot<Int> {
        var state: UInt64 = 0xA11CE
        func unit() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state % 10000) / 10000
        }
        let metrics = (0 ..< count).map { _ in ItemMetric.aspectRatio(0.55 + unit() * 1.35) }
        let result = MasonryLayout(columns: 3, spacing: 10).layout(items: metrics, containerWidth: width)
        return LayoutSnapshot(ids: Array(0 ..< count), result: result, containerWidth: width)
    }

    /// Seeded intervals through the real timeline layout: frames that overlap
    /// vertically and are not monotonic in y in item order — the shape that
    /// breaks anything assuming a simple stack.
    private static func timeline(count: Int, width: Double = 400) -> LayoutSnapshot<Int> {
        var state: UInt64 = 0xB0BA
        func unit() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state % 10000) / 10000
        }
        var cursor = 0.0
        var intervals: [TimelineLayout.Interval] = []
        for _ in 0 ..< count {
            intervals.append(.init(start: cursor, duration: 3 + unit() * 9))
            cursor += 2.5 + unit() * 5
        }
        let layout = TimelineLayout(pointsPerUnit: 3, laneSpacing: 8, minimumHeight: 44)
        let result = layout.layout(items: intervals, containerWidth: width)
        return LayoutSnapshot(ids: Array(0 ..< count), result: result, containerWidth: width)
    }

    /// What the ideal answer is, found by scanning margins finely: the count
    /// closest to the target, ties taking the smaller count.
    private static func bestReachableCount(
        _ snapshot: LayoutSnapshot<Int>,
        viewport: LayoutRect,
        target: Int,
        containerWidth: Double = 400
    ) -> Int {
        let maximumMargin = viewport.height * 20
        var best = snapshot.visibleItems(in: viewport).count
        var bestDistance = abs(best - target)
        var margin = 0.0
        let step = maximumMargin / 4000
        while margin <= maximumMargin {
            let window = LayoutRect(
                x: 0,
                y: viewport.y - margin,
                width: containerWidth,
                height: viewport.height + margin * 2
            )
            let count = snapshot.visibleItems(in: window).count
            let distance = abs(count - target)
            // Ties take the smaller count, matching the documented rule.
            if distance < bestDistance || (distance == bestDistance && count < best) {
                best = count
                bestDistance = distance
            }
            margin += step
        }
        return best
    }

    // MARK: - Closest reachable

    /// The property the device run falsified: `.items(80)` produced 124 cells.
    @Test(
        "A masonry budget lands on the closest reachable count",
        arguments: [20, 40, 60, 80, 120, 200]
    )
    func masonryBudgetIsClosestReachable(target: Int) {
        let snapshot = Self.masonry(count: 6000)
        for offset in [3000.0, 12000.0, 40000.0] {
            let viewport = LayoutRect(x: 0, y: offset, width: 400, height: 800)
            let window = snapshot.window(for: viewport, overscan: .items(target), containerWidth: 400)
            let actual = snapshot.visibleItems(in: window).count
            let ideal = Self.bestReachableCount(snapshot, viewport: viewport, target: target)
            #expect(
                abs(actual - target) <= abs(ideal - target) + 1,
                "budget \(target) at y=\(offset): got \(actual), best reachable was \(ideal)"
            )
        }
    }

    /// Timeline is the density that broke the old estimate worst: its cells are
    /// small and tightly packed, so a margin guessed from the viewport overshoots.
    @Test(
        "A timeline budget lands on the closest reachable count",
        arguments: [40, 80, 150]
    )
    func timelineBudgetIsClosestReachable(target: Int) {
        let snapshot = Self.timeline(count: 8000)
        for offset in [5000.0, 20000.0, 60000.0] {
            let viewport = LayoutRect(x: 0, y: offset, width: 400, height: 800)
            let window = snapshot.window(for: viewport, overscan: .items(target), containerWidth: 400)
            let actual = snapshot.visibleItems(in: window).count
            let ideal = Self.bestReachableCount(snapshot, viewport: viewport, target: target)
            #expect(
                abs(actual - target) <= abs(ideal - target) + 1,
                "budget \(target) at y=\(offset): got \(actual), best reachable was \(ideal)"
            )
        }
    }

    /// The specific device failure, as a regression test: 80 must not become 124.
    @Test("A budget never overshoots the way the density estimate did")
    func budgetDoesNotOvershoot() {
        for snapshot in [Self.masonry(count: 6000), Self.timeline(count: 8000)] {
            for target in [40, 80, 150] {
                let viewport = LayoutRect(x: 0, y: 20000, width: 400, height: 800)
                let window = snapshot.window(for: viewport, overscan: .items(target), containerWidth: 400)
                let actual = snapshot.visibleItems(in: window).count
                let visible = snapshot.visibleItems(in: viewport).count
                guard visible < target else { continue }
                #expect(
                    Double(actual) <= Double(target) * 1.15,
                    "budget \(target) built \(actual) — more than 15% over"
                )
            }
        }
    }

    /// Ties go to the smaller count, because the point of the unit is less work.
    @Test("A tie between two reachable counts takes the smaller one")
    func tiesTakeTheSmallerCount() {
        // Uniform rows two-up: counts step in twos, so an odd target ties.
        var frames: [LayoutRect] = []
        for index in 0 ..< 4000 {
            let row = Double(index / 2)
            frames.append(LayoutRect(x: Double(index % 2) * 200, y: row * 100, width: 190, height: 90))
        }
        let snapshot = LayoutSnapshot(
            ids: Array(0 ..< frames.count),
            result: LazyLayoutResult(frames: frames, contentHeight: 200_000),
            containerWidth: 400
        )
        let viewport = LayoutRect(x: 0, y: 50000, width: 400, height: 800)
        let visible = snapshot.visibleItems(in: viewport).count
        for target in [visible + 5, visible + 11, visible + 21] {
            let window = snapshot.window(for: viewport, overscan: .items(target), containerWidth: 400)
            let actual = snapshot.visibleItems(in: window).count
            #expect(
                actual <= target,
                "odd budget \(target) resolved to \(actual); a tie should round down"
            )
        }
    }

    /// Non-uniform content is the realistic case for text, where a density
    /// measured at the viewport does not predict density elsewhere.
    @Test("A budget is met even when density varies down the content")
    func varyingDensityStillMeetsBudget() {
        // Alternating bands: tall items near the viewport, short ones beyond.
        var frames: [LayoutRect] = []
        var y = 0.0
        for index in 0 ..< 4000 {
            let height = index < 60 ? 300.0 : 15.0
            frames.append(LayoutRect(x: 0, y: y, width: 400, height: height))
            y += height
        }
        let snapshot = LayoutSnapshot(
            ids: Array(0 ..< frames.count),
            result: LazyLayoutResult(frames: frames, contentHeight: y),
            containerWidth: 400
        )
        let viewport = LayoutRect(x: 0, y: 3000, width: 400, height: 800)
        let window = snapshot.window(for: viewport, overscan: .items(100), containerWidth: 400)
        #expect(snapshot.visibleItems(in: window).count >= 100)
    }
}
