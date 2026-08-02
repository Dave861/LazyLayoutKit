@testable import LazyLayoutKit
import Testing

private func metrics(_ count: Int, seed: UInt64 = 0xF00D) -> [ItemMetric] {
    var rng = Rng(seed: seed)
    return (0 ..< count).map { _ in .aspectRatio(rng.double(in: 0.5 ... 2.0)) }
}

private func snapshot(
    ids: [Int],
    metrics: [ItemMetric],
    layout: MasonryLayout = MasonryLayout(columns: 3, spacing: 8),
    width: Double = 402
) -> LayoutSnapshot<Int> {
    LayoutSnapshot(
        ids: ids,
        result: layout.layout(items: metrics, containerWidth: width),
        containerWidth: width
    )
}

@Suite("Anchoring by stable identity")
struct AnchoringTests {
    @Test("an upstream resize moves the anchor, and the adjustment cancels it")
    func resizeAboveViewport() throws {
        let ids = Array(0 ..< 1000)
        var items = metrics(1000)
        let before = snapshot(ids: ids, metrics: items)

        let scrollY = 5000.0
        let viewport = LayoutRect(x: 0, y: scrollY, width: 402, height: 874)
        let anchor = try #require(before.anchor(in: viewport))
        let onScreenOffset = try #require(before.frame(of: anchor)).minY - scrollY

        items[10] = .fixedHeight(1200)
        let after = snapshot(ids: ids, metrics: items)

        let adjustment = try #require(after.offsetAdjustment(keeping: anchor, alignedWith: before))
        #expect(abs(adjustment) > 100, "an upstream resize should genuinely move the anchor")

        let corrected = scrollY + adjustment
        let newOnScreenOffset = try #require(after.frame(of: anchor)).minY - corrected
        #expect(abs(newOnScreenOffset - onScreenOffset) < 1e-9)
    }

    /// The reason identity is caller-supplied. With index identity this test is
    /// not merely inaccurate — it silently anchors to a different item.
    @Test("inserting at the front does not move the anchored item")
    func insertAtFrontKeepsAnchor() throws {
        let ids = Array(0 ..< 1000)
        var items = metrics(1000)
        let before = snapshot(ids: ids, metrics: items)

        let scrollY = 5000.0
        let viewport = LayoutRect(x: 0, y: scrollY, width: 402, height: 874)
        let anchor = try #require(before.anchor(in: viewport))
        let onScreenOffset = try #require(before.frame(of: anchor)).minY - scrollY

        // Five new items at the front: every index shifts by five.
        let newIDs = [-5, -4, -3, -2, -1] + ids
        items.insert(contentsOf: metrics(5, seed: 0xAAAA), at: 0)
        let after = snapshot(ids: newIDs, metrics: items)

        // The anchor's *index* changed by five; its identity did not.
        let oldPosition = try #require(before.position(of: anchor))
        let newPosition = try #require(after.position(of: anchor))
        #expect(newPosition == oldPosition + 5)

        let adjustment = try #require(after.offsetAdjustment(keeping: anchor, alignedWith: before))
        let corrected = scrollY + adjustment
        let newOnScreenOffset = try #require(after.frame(of: anchor)).minY - corrected
        #expect(abs(newOnScreenOffset - onScreenOffset) < 1e-9)
    }

    @Test("removing items above the viewport keeps the anchor put")
    func removeAboveKeepsAnchor() throws {
        var ids = Array(0 ..< 1000)
        var items = metrics(1000)
        let before = snapshot(ids: ids, metrics: items)

        let scrollY = 8000.0
        let viewport = LayoutRect(x: 0, y: scrollY, width: 402, height: 874)
        let anchor = try #require(before.anchor(in: viewport))
        let onScreenOffset = try #require(before.frame(of: anchor)).minY - scrollY

        ids.removeSubrange(3 ..< 20)
        items.removeSubrange(3 ..< 20)
        let after = snapshot(ids: ids, metrics: items)

        let adjustment = try #require(after.offsetAdjustment(keeping: anchor, alignedWith: before))
        let corrected = scrollY + adjustment
        let newOnScreenOffset = try #require(after.frame(of: anchor)).minY - corrected
        #expect(abs(newOnScreenOffset - onScreenOffset) < 1e-9)
    }

    @Test("a deleted anchor yields no adjustment rather than a wrong one")
    func deletedAnchorReturnsNil() {
        let ids = Array(0 ..< 200)
        let items = metrics(200)
        let before = snapshot(ids: ids, metrics: items)

        var trimmedIDs = ids
        var trimmedItems = items
        trimmedIDs.removeSubrange(100 ..< 200)
        trimmedItems.removeSubrange(100 ..< 200)
        let after = snapshot(ids: trimmedIDs, metrics: trimmedItems)

        #expect(after.offsetAdjustment(keeping: 150, alignedWith: before) == nil)
    }

    @Test("no anchor when nothing is visible")
    func noAnchorWhenEmpty() {
        let snap = snapshot(ids: Array(0 ..< 50), metrics: metrics(50))
        let farBelow = LayoutRect(x: 0, y: snap.contentHeight + 5000, width: 402, height: 874)
        #expect(snap.anchor(in: farBelow) == nil)
    }

    @Test("duplicate ids are reported, not fatal")
    func duplicateIDsAreReported() {
        let ids = [1, 2, 3, 2, 5]
        let snap = snapshot(ids: ids, metrics: metrics(5))
        #expect(snap.duplicateIDCount == 1)
        // First occurrence wins, so the anchor can never jump backwards.
        #expect(snap.position(of: 2) == 1)
    }

    @Test("content height covers every frame even if the layout under-reports")
    func contentHeightCoversFrames() {
        let frames = [
            LayoutRect(x: 0, y: 0, width: 100, height: 100),
            LayoutRect(x: 0, y: 900, width: 100, height: 200),
        ]
        let snap = LayoutSnapshot(
            ids: [0, 1],
            result: LazyLayoutResult(frames: frames, contentHeight: 10),
            containerWidth: 402
        )
        #expect(snap.contentHeight >= 1100)
    }
}

@Suite("Masonry layout")
struct MasonryLayoutTests {
    @Test("items within a column never overlap")
    func noOverlapWithinColumn() {
        let layout = MasonryLayout(columns: 3, spacing: 8)
        let result = layout.layout(items: metrics(500), containerWidth: 402)

        var byColumn: [Double: [LayoutRect]] = [:]
        for frame in result.frames {
            byColumn[frame.x, default: []].append(frame)
        }
        for (_, column) in byColumn {
            let sorted = column.sorted { $0.minY < $1.minY }
            for (a, b) in zip(sorted, sorted.dropFirst()) {
                #expect(a.maxY <= b.minY + 1e-9)
            }
        }
    }

    @Test("content height matches the tallest frame")
    func contentHeight() {
        let layout = MasonryLayout(columns: 4, spacing: 10)
        let result = layout.layout(items: metrics(200), containerWidth: 1000)
        let tallest = result.frames.map(\.maxY).max() ?? 0
        #expect(abs(result.contentHeight - tallest) < 1e-9)
    }

    @Test("degenerate configuration does not trap", arguments: [0, 1, 2])
    func degenerate(count: Int) {
        let layout = MasonryLayout(columns: 1, spacing: 0)
        let result = layout.layout(items: metrics(count), containerWidth: 0)
        #expect(result.frames.count == count)
        #expect(result.contentHeight >= 0)
    }

    @Test("hostile metrics never produce a non-finite frame")
    func hostileMetrics() {
        let layout = MasonryLayout(columns: 2, spacing: 4)
        let result = layout.layout(
            items: [
                .aspectRatio(.nan), .aspectRatio(0), .aspectRatio(-1),
                .aspectRatio(.infinity), .fixedHeight(.nan), .fixedHeight(-50),
            ],
            containerWidth: 300
        )
        #expect(result.frames.allSatisfy { $0.height.isFinite && $0.y.isFinite && $0.height >= 0 })
        #expect(result.contentHeight.isFinite)
    }

    @Test("columns stay balanced")
    func balanced() {
        let layout = MasonryLayout(columns: 3, spacing: 8)
        let result = layout.layout(items: metrics(2000), containerWidth: 402)
        var bottoms: [Double: Double] = [:]
        for frame in result.frames {
            bottoms[frame.x] = max(bottoms[frame.x] ?? 0, frame.maxY)
        }
        let spread = (bottoms.values.max() ?? 0) - (bottoms.values.min() ?? 0)
        #expect(spread < 900, "no column should run away from the others")
    }
}
