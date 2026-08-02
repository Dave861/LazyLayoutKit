@testable import LazyLayoutKit
import Testing

/// Each test here fails against the code as it was before the fix it guards.
@Suite("Regressions")
struct RegressionTests {
    // MARK: One bad frame must not blind the index

    /// A single infinite frame used to collapse the indexed extent to a single
    /// point, after which the bucket sweep was skipped for every query and no
    /// valid frame was ever returned. The earlier non-finite test only probed
    /// near y = 0, where the collapsed extent happened to still overlap.
    @Test("an infinite frame does not hide valid frames far down the plane")
    func infiniteFrameDoesNotBlindTheIndex() {
        let frames = [
            LayoutRect(x: 0, y: -.infinity, width: 10, height: 10),
            LayoutRect(x: 0, y: 1000, width: 400, height: 100),
        ]
        let index = VerticalVisibilityIndex(frames: frames)
        let window = LayoutRect(x: 0, y: 950, width: 400, height: 800)

        #expect(index.indices(intersecting: window, frames: frames).contains(1))
        #expect(index.indices(intersecting: window, frames: frames) == bruteForce(window, frames))
    }

    @Test("non-finite frames scattered through a valid layout still agree with brute force")
    func nonFiniteFramesAmongValidOnes() {
        var frames = (0 ..< 400).map { i in
            LayoutRect(x: 0, y: Double(i) * 120, width: 400, height: 100)
        }
        frames.insert(LayoutRect(x: 0, y: .infinity, width: 10, height: 10), at: 50)
        frames.insert(LayoutRect(x: 0, y: -.infinity, width: 10, height: 10), at: 200)
        frames.insert(LayoutRect(x: 0, y: .nan, width: 10, height: 10), at: 300)
        frames.insert(LayoutRect(x: 0, y: 500, width: 10, height: .infinity), at: 350)

        let index = VerticalVisibilityIndex(frames: frames)
        var y = -2000.0
        while y < 50000 {
            let window = LayoutRect(x: 0, y: y, width: 400, height: 800)
            #expect(index.indices(intersecting: window, frames: frames) == bruteForce(window, frames))
            y += 719
        }
    }

    // MARK: Negative coordinates must be normalised, not merely accounted for

    /// `contentHeight` used to be widened to cover a negative origin while the
    /// frames kept their negative `y`. The container positions each view at its
    /// own `y`, so the content above zero stayed clipped and an equal band of
    /// blank space appeared at the bottom instead.
    @Test("a layout emitting negative y is shifted onto a zero-based plane")
    func negativeCoordinatesAreNormalised() {
        let frames = [
            LayoutRect(x: 0, y: -300, width: 400, height: 100),
            LayoutRect(x: 0, y: -50, width: 400, height: 100),
            LayoutRect(x: 0, y: 400, width: 400, height: 100),
        ]
        let snapshot = LayoutSnapshot(
            ids: [0, 1, 2],
            result: LazyLayoutResult(frames: frames, contentHeight: 500),
            containerWidth: 400
        )

        #expect(snapshot.frames.allSatisfy { $0.minY >= 0 }, "no frame may sit above the scroll origin")
        #expect(snapshot.frames[0].minY == 0, "the topmost frame should land at zero")
        // Gaps between items must survive the shift.
        #expect(snapshot.frames[1].minY == 250)
        #expect(snapshot.frames[2].minY == 700)
        #expect(snapshot.contentHeight == 800)

        // And the first item must actually be reachable from the top of the plane.
        let topOfPlane = LayoutRect(x: 0, y: 0, width: 400, height: 200)
        #expect(snapshot.visibleItems(in: topOfPlane).contains(0))
    }

    @Test("normalisation preserves anchoring across a change of origin")
    func normalisationPreservesAnchoring() throws {
        let layout = TimelineLayout(pointsPerUnit: 2)
        let ids = Array(0 ..< 200)
        var items = (0 ..< 200).map { TimelineLayout.Interval(start: Double($0) * 30, duration: 20) }
        let before = LayoutSnapshot(
            ids: ids, result: layout.layout(items: items, containerWidth: 400), containerWidth: 400
        )

        let scrollY = 2000.0
        let viewport = LayoutRect(x: 0, y: scrollY, width: 400, height: 800)
        let anchor = try #require(before.anchor(in: viewport))
        let onScreen = try #require(before.frame(of: anchor)).minY - scrollY

        // Pull one item far into the past: the whole plane's origin moves.
        items[5] = .init(start: -4000, duration: 20)
        let after = LayoutSnapshot(
            ids: ids, result: layout.layout(items: items, containerWidth: 400), containerWidth: 400
        )

        #expect(after.frames.allSatisfy { $0.minY >= 0 })
        let adjustment = try #require(after.offsetAdjustment(keeping: anchor, alignedWith: before))
        let corrected = scrollY + adjustment
        let newOnScreen = try #require(after.frame(of: anchor)).minY - corrected
        #expect(abs(newOnScreen - onScreen) < 1e-9)
    }

    // MARK: Timeline lanes must reflect what is drawn

    /// Lanes were assigned from the semantic duration while frames were drawn
    /// with `minimumHeight`, so two short sequential events could share a lane
    /// and then overlap on screen.
    @Test("short sequential events do not share a lane and overlap")
    func shortEventsDoNotOverlapInALane() {
        let layout = TimelineLayout(pointsPerUnit: 1, laneSpacing: 4, minimumHeight: 30)
        // Each is 1 unit long but will be drawn 30 points tall.
        let items = (0 ..< 5).map { TimelineLayout.Interval(start: Double($0), duration: 1) }
        let result = layout.layout(items: items, containerWidth: 400)

        var byLane: [Double: [LayoutRect]] = [:]
        for frame in result.frames {
            byLane[frame.x, default: []].append(frame)
        }
        for (_, lane) in byLane {
            let sorted = lane.sorted { $0.minY < $1.minY }
            for (a, b) in zip(sorted, sorted.dropFirst()) {
                #expect(
                    a.maxY <= b.minY + 1e-9,
                    "items sharing a lane must not overlap once minimumHeight is applied"
                )
            }
        }
    }

    @Test("long events still share a lane when they genuinely do not overlap")
    func longSequentialEventsStillShareALane() {
        let layout = TimelineLayout(pointsPerUnit: 1, minimumHeight: 12)
        let items = (0 ..< 5).map { TimelineLayout.Interval(start: Double($0) * 100, duration: 100) }
        let result = layout.layout(items: items, containerWidth: 400)
        #expect(Set(result.frames.map(\.x)).count == 1, "minimumHeight must not fragment real lanes")
    }
}
