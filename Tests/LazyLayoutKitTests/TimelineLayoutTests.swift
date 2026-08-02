@testable import LazyLayoutKit
import Testing

/// These tests are as much about the *protocol* as about the layout: if the
/// machinery had quietly assumed masonry's shape, they would fail.
@Suite("Timeline layout — genericity proof")
struct TimelineLayoutTests {
    private func events(_ count: Int, seed: UInt64 = 0x71E) -> [TimelineLayout.Interval] {
        var rng = Rng(seed: seed)
        return (0 ..< count).map { _ in
            .init(start: rng.double(in: 0 ... 10000), duration: rng.double(in: 0.5 ... 40))
        }
    }

    @Test("frames are not monotonic in y — the assumption masonry would let you make")
    func framesAreNotSortedByY() {
        let layout = TimelineLayout(pointsPerUnit: 2)
        let result = layout.layout(items: events(500), containerWidth: 402)
        let ys = result.frames.map(\.minY)
        #expect(ys != ys.sorted(), "item order must not imply y order for this layout")
    }

    @Test("overlapping events get different lanes and do not collide")
    func overlappingEventsGetLanes() {
        let layout = TimelineLayout(pointsPerUnit: 1, laneSpacing: 4)
        // Three events all covering the same hour.
        let items: [TimelineLayout.Interval] = [
            .init(start: 100, duration: 60),
            .init(start: 110, duration: 60),
            .init(start: 120, duration: 60),
        ]
        let result = layout.layout(items: items, containerWidth: 300)
        let xs = Set(result.frames.map(\.x))
        #expect(xs.count == 3, "simultaneous events must occupy distinct lanes")
        // They overlap in y, which is exactly what masonry can never produce.
        #expect(result.frames[0].intersectsVertically(result.frames[1]))
    }

    @Test("sequential events reuse the same lane")
    func sequentialEventsShareLane() {
        let layout = TimelineLayout(pointsPerUnit: 1)
        let items: [TimelineLayout.Interval] = [
            .init(start: 0, duration: 60),
            .init(start: 60, duration: 60),
            .init(start: 120, duration: 60),
        ]
        let result = layout.layout(items: items, containerWidth: 300)
        #expect(Set(result.frames.map(\.x)).count == 1)
    }

    @Test("the visibility index agrees with brute force on overlapping frames")
    func indexHandlesOverlaps() {
        let layout = TimelineLayout(pointsPerUnit: 3)
        let items = events(2000)
        let result = layout.layout(items: items, containerWidth: 402)
        let snapshot = LayoutSnapshot(ids: Array(0 ..< items.count), result: result, containerWidth: 402)

        var y = -500.0
        while y < snapshot.contentHeight + 500 {
            let window = LayoutRect(x: 0, y: y, width: 402, height: 874)
            #expect(snapshot.visibleItems(in: window) == bruteForce(window, result.frames))
            y += 611
        }
    }

    @Test("an all-day event is found at every point it covers")
    func allDayEventIsAlwaysFound() {
        let layout = TimelineLayout(pointsPerUnit: 4)
        var items = events(400)
        items.append(.init(start: 0, duration: 10000)) // spans everything
        let result = layout.layout(items: items, containerWidth: 402)
        let snapshot = LayoutSnapshot(ids: Array(0 ..< items.count), result: result, containerWidth: 402)
        let allDay = items.count - 1

        var y = 0.0
        while y < snapshot.contentHeight {
            let window = LayoutRect(x: 0, y: y, width: 402, height: 400)
            #expect(snapshot.visibleItems(in: window).contains(allDay))
            y += 900
        }
    }

    @Test("anchoring works for a layout whose items overlap")
    func anchoringWithOverlaps() throws {
        let layout = TimelineLayout(pointsPerUnit: 3)
        var items = events(1000)
        let ids = Array(0 ..< items.count)
        let before = LayoutSnapshot(
            ids: ids, result: layout.layout(items: items, containerWidth: 402), containerWidth: 402
        )

        let scrollY = 6000.0
        let viewport = LayoutRect(x: 0, y: scrollY, width: 402, height: 874)
        let anchor = try #require(before.anchor(in: viewport))
        let onScreen = try #require(before.frame(of: anchor)).minY - scrollY

        // Move an early event much earlier, shifting the whole time origin.
        items[3] = .init(start: -5000, duration: 30)
        let after = LayoutSnapshot(
            ids: ids, result: layout.layout(items: items, containerWidth: 402), containerWidth: 402
        )

        let adjustment = try #require(after.offsetAdjustment(keeping: anchor, alignedWith: before))
        let corrected = scrollY + adjustment
        let newOnScreen = try #require(after.frame(of: anchor)).minY - corrected
        #expect(abs(newOnScreen - onScreen) < 1e-9)
    }

    @Test("degenerate and hostile intervals do not trap")
    func hostileIntervals() {
        let layout = TimelineLayout(pointsPerUnit: 1)
        let result = layout.layout(
            items: [
                .init(start: .nan, duration: 10),
                .init(start: 0, duration: .nan),
                .init(start: -100, duration: -50),
                .init(start: .infinity, duration: .infinity),
                .init(start: 0, duration: 0),
            ],
            containerWidth: 300
        )
        #expect(result.frames.allSatisfy { $0.y.isFinite && $0.height.isFinite && $0.height >= 0 })
        #expect(result.contentHeight.isFinite)
    }

    @Test("empty input")
    func empty() {
        let result = TimelineLayout().layout(items: [], containerWidth: 402)
        #expect(result.frames.isEmpty)
        #expect(result.contentHeight == 0)
    }
}
