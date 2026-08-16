@testable import LazyLayoutKit
import Testing

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

/// A single column of 100pt items with no spacing: item `i` occupies
/// `[i * 100, i * 100 + 100)`, so every expected offset can be written by hand.
private func ruler(count: Int = 100) -> LayoutSnapshot<Int> {
    snapshot(
        ids: Array(0 ..< count),
        metrics: Array(repeating: .fixedHeight(100), count: count),
        layout: MasonryLayout(columns: 1, spacing: 0)
    )
}

@Suite("Scrolling to an item")
struct ScrollTargetTests {
    // MARK: - The three absolute anchors

    @Test("top puts the item's top edge at the viewport's top edge")
    func topAnchor() throws {
        let snapshot = ruler()
        let offset = try #require(
            snapshot.offset(toShow: 40, anchor: .top, viewportHeight: 800)
        )
        #expect(offset == 4000)
    }

    @Test("center leaves equal space above and below")
    func centerAnchor() throws {
        let snapshot = ruler()
        let frame = try #require(snapshot.frame(of: 40))
        let offset = try #require(
            snapshot.offset(toShow: 40, anchor: .center, viewportHeight: 800)
        )
        #expect(abs((frame.minY - offset) - (800 - frame.height) / 2) < 1e-9)
    }

    @Test("bottom puts the item's bottom edge at the viewport's bottom edge")
    func bottomAnchor() throws {
        let snapshot = ruler()
        let frame = try #require(snapshot.frame(of: 40))
        let offset = try #require(
            snapshot.offset(toShow: 40, anchor: .bottom, viewportHeight: 800)
        )
        #expect(abs((frame.maxY - offset) - 800) < 1e-9)
    }

    // MARK: - Clamping

    @Test("centering the first item clamps to the top rather than going negative")
    func centerOnFirstItemClamps() throws {
        let snapshot = ruler()
        let offset = try #require(
            snapshot.offset(toShow: 0, anchor: .center, viewportHeight: 800)
        )
        #expect(offset == 0)
    }

    @Test("the last item clamps to the end of the scrollable range")
    func lastItemClamps() throws {
        let snapshot = ruler()
        let offset = try #require(
            snapshot.offset(toShow: 99, anchor: .top, viewportHeight: 800)
        )
        #expect(offset == snapshot.contentHeight - 800)
    }

    @Test(
        "content shorter than the viewport never scrolls",
        arguments: [ScrollAnchor.top, .center, .bottom, .nearest]
    )
    func shortContentDoesNotScroll(anchor: ScrollAnchor) throws {
        let snapshot = ruler(count: 3) // 300pt of content
        let offset = try #require(
            snapshot.offset(toShow: 2, anchor: anchor, viewportHeight: 800)
        )
        #expect(offset == 0)
    }

    // MARK: - nearest

    @Test("nearest does not move an item that is already fully visible")
    func nearestLeavesVisibleItemAlone() throws {
        let snapshot = ruler()
        // Viewport [4000, 4800) fully contains item 42 at [4200, 4300).
        let offset = try #require(
            snapshot.offset(toShow: 42, anchor: .nearest, viewportHeight: 800, currentOffset: 4000)
        )
        #expect(offset == 4000)
    }

    @Test("nearest reveals an item above by aligning its top")
    func nearestRevealsUpward() throws {
        let snapshot = ruler()
        let offset = try #require(
            snapshot.offset(toShow: 10, anchor: .nearest, viewportHeight: 800, currentOffset: 4000)
        )
        #expect(offset == 1000)
    }

    @Test("nearest reveals an item below by aligning its bottom")
    func nearestRevealsDownward() throws {
        let snapshot = ruler()
        // Item 60 is [6000, 6100); showing its bottom in an 800pt viewport
        // means an offset of 5300.
        let offset = try #require(
            snapshot.offset(toShow: 60, anchor: .nearest, viewportHeight: 800, currentOffset: 4000)
        )
        #expect(offset == 5300)
    }

    @Test("nearest pulls in an item straddling the top edge")
    func nearestStraddlingTop() throws {
        let snapshot = ruler()
        // Viewport starts at 4050, so item 40 at [4000, 4100) is half cut off.
        let offset = try #require(
            snapshot.offset(toShow: 40, anchor: .nearest, viewportHeight: 800, currentOffset: 4050)
        )
        #expect(offset == 4000)
    }

    @Test("nearest pulls in an item straddling the bottom edge")
    func nearestStraddlingBottom() throws {
        let snapshot = ruler()
        // Viewport [4000, 4800); item 47 is [4700, 4800) — flush, so visible.
        // Item 48 at [4800, 4900) is entirely below and needs an offset of 4100.
        let offset = try #require(
            snapshot.offset(toShow: 48, anchor: .nearest, viewportHeight: 800, currentOffset: 4000)
        )
        #expect(offset == 4100)
    }

    // MARK: - Items larger than the viewport

    @Test("an item taller than the viewport stays finite and in range")
    func oversizedItem() throws {
        var metrics = [ItemMetric](repeating: .fixedHeight(100), count: 50)
        metrics[20] = .fixedHeight(3000)
        let snapshot = snapshot(
            ids: Array(0 ..< 50),
            metrics: metrics,
            layout: MasonryLayout(columns: 1, spacing: 0)
        )
        let maximum = snapshot.contentHeight - 800

        for anchor in [ScrollAnchor.top, .center, .bottom, .nearest] {
            let offset = try #require(
                snapshot.offset(toShow: 20, anchor: anchor, viewportHeight: 800, currentOffset: 0)
            )
            #expect(offset.isFinite)
            #expect(offset >= 0 && offset <= maximum)
        }

        // Top still means top, however tall the item is.
        let top = try #require(snapshot.offset(toShow: 20, anchor: .top, viewportHeight: 800))
        #expect(top == 2000)

        // It can never be fully visible, so nearest aligns its top too.
        let nearest = try #require(
            snapshot.offset(toShow: 20, anchor: .nearest, viewportHeight: 800, currentOffset: 0)
        )
        #expect(nearest == 2000)
    }

    // MARK: - Degenerate input

    @Test(
        "a degenerate viewport height yields a finite in-range offset",
        arguments: [0.0, -100, .nan, .infinity, -.infinity]
    )
    func degenerateViewportHeight(height: Double) throws {
        let snapshot = ruler()
        for anchor in [ScrollAnchor.top, .center, .bottom, .nearest] {
            let offset = try #require(
                snapshot.offset(toShow: 40, anchor: anchor, viewportHeight: height)
            )
            #expect(offset.isFinite)
            #expect(offset >= 0 && offset <= snapshot.contentHeight)
        }
    }

    @Test(
        "a degenerate current offset yields a finite in-range offset",
        arguments: [-5.0, .nan, .infinity, -.infinity]
    )
    func degenerateCurrentOffset(current: Double) throws {
        let snapshot = ruler()
        let offset = try #require(
            snapshot.offset(
                toShow: 40, anchor: .nearest, viewportHeight: 800, currentOffset: current
            )
        )
        #expect(offset.isFinite)
        #expect(offset >= 0 && offset <= snapshot.contentHeight - 800)
    }

    @Test("an absent id has no offset")
    func absentID() {
        #expect(ruler().offset(toShow: 5000, anchor: .top, viewportHeight: 800) == nil)
    }

    @Test("an empty snapshot has no offset")
    func emptySnapshot() {
        let empty = snapshot(ids: [], metrics: [])
        #expect(empty.offset(toShow: 0, anchor: .top, viewportHeight: 800) == nil)
    }

    // MARK: - Interaction with the rest of the package

    @Test("a layout with a negative origin still produces non-negative offsets")
    func negativeOriginLayout() throws {
        // TimelineLayout's origin is the earliest start, and the snapshot shifts
        // the whole plane onto zero. Offsets have to come from the shifted plane,
        // not the layout's own coordinates.
        let layout = TimelineLayout(pointsPerUnit: 3, laneSpacing: 8, minimumHeight: 44)
        let intervals = (0 ..< 200).map {
            TimelineLayout.Interval(start: Double($0) * 10 - 1000, duration: 8)
        }
        let snapshot = LayoutSnapshot(
            ids: Array(0 ..< 200),
            result: layout.layout(items: intervals, containerWidth: 402),
            containerWidth: 402
        )

        for anchor in [ScrollAnchor.top, .center, .bottom, .nearest] {
            let offset = try #require(
                snapshot.offset(toShow: 0, anchor: anchor, viewportHeight: 800)
            )
            #expect(offset >= 0)
            #expect(offset.isFinite)
        }
    }

    @Test("duplicate ids target the first occurrence, like anchoring")
    func duplicateIDs() throws {
        let ids = [0, 1, 2, 1, 4, 5, 6, 7, 8, 9]
        let snapshot = snapshot(
            ids: ids,
            metrics: Array(repeating: .fixedHeight(100), count: ids.count),
            layout: MasonryLayout(columns: 1, spacing: 0)
        )
        let offset = try #require(
            snapshot.offset(toShow: 1, anchor: .top, viewportHeight: 400)
        )
        #expect(offset == 100, "position 1, not position 3")
    }

    @Test("the frame overload agrees with the id overload")
    func frameOverloadAgrees() throws {
        let snapshot = ruler()
        let frame = try #require(snapshot.frame(of: 40))
        for anchor in [ScrollAnchor.top, .center, .bottom, .nearest] {
            let byID = try #require(
                snapshot.offset(toShow: 40, anchor: anchor, viewportHeight: 800, currentOffset: 100)
            )
            let byFrame = snapshot.offset(
                toShow: frame, anchor: anchor, viewportHeight: 800, currentOffset: 100
            )
            #expect(byID == byFrame)
        }
    }
}
