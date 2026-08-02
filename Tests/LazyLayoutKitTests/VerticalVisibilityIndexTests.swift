@testable import LazyLayoutKit
import Testing

/// Deterministic pseudo-random so any failure is reproducible from the seed.
struct Rng {
    var state: UInt64
    init(seed: UInt64 = 0xF00D) {
        state = seed
    }

    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 100_000) / 100_000
    }

    mutating func double(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + next() * (range.upperBound - range.lowerBound)
    }
}

/// The oracle every test compares against: a linear scan.
func bruteForce(_ range: LayoutRect, _ frames: [LayoutRect]) -> [Int] {
    frames.indices.filter { frames[$0].intersectsVertically(range) }
}

func viewport(_ y: Double, height: Double = 800) -> LayoutRect {
    LayoutRect(x: 0, y: y, width: 400, height: height)
}

@Suite("Vertical visibility index")
struct VerticalVisibilityIndexTests {
    @Test("matches a brute-force scan over a stacked layout")
    func matchesBruteForceStacked() {
        var rng = Rng()
        var frames: [LayoutRect] = []
        var y = 0.0
        for _ in 0 ..< 2000 {
            let height = rng.double(in: 20 ... 300)
            frames.append(LayoutRect(x: 0, y: y, width: 400, height: height))
            y += height + 8
        }
        let index = VerticalVisibilityIndex(frames: frames)

        var probe = -1000.0
        while probe < y + 1000 {
            let range = viewport(probe)
            #expect(index.indices(intersecting: range, frames: frames) == bruteForce(range, frames))
            probe += 373
        }
    }

    @Test("matches brute force when frames overlap arbitrarily")
    func matchesBruteForceOverlapping() {
        var rng = Rng(seed: 0xBEEF)
        // Deliberately unordered and overlapping — nothing a monotonic
        // per-column search could handle.
        let frames = (0 ..< 1500).map { _ in
            LayoutRect(
                x: rng.double(in: 0 ... 300),
                y: rng.double(in: -5000 ... 50000),
                width: 100,
                height: rng.double(in: 1 ... 400)
            )
        }
        let index = VerticalVisibilityIndex(frames: frames)

        var probe = -6000.0
        while probe < 52000 {
            let range = viewport(probe, height: rng.double(in: 100 ... 1200))
            #expect(index.indices(intersecting: range, frames: frames) == bruteForce(range, frames))
            probe += 517
        }
    }

    @Test("results are ascending and free of duplicates")
    func noDuplicates() {
        var rng = Rng(seed: 0xC0FFEE)
        // Heights well beyond one bucket, so most items land in several.
        let frames = (0 ..< 800).map { i in
            LayoutRect(
                x: 0, y: Double(i) * 40,
                width: 400, height: rng.double(in: 200 ... 2000)
            )
        }
        let index = VerticalVisibilityIndex(frames: frames)

        for step in 0 ..< 60 {
            let found = index.indices(intersecting: viewport(Double(step) * 500), frames: frames)
            #expect(found == found.sorted(), "results must be in source order")
            #expect(Set(found).count == found.count, "an item spanning buckets must appear once")
        }
    }

    @Test("a very tall item is found from anywhere it covers")
    func oversizedItemsAreAlwaysFound() {
        var frames = (0 ..< 500).map { i in
            LayoutRect(x: 0, y: Double(i) * 100, width: 400, height: 90)
        }
        // Spans the entire content — the case that would otherwise be
        // duplicated into every bucket.
        frames.append(LayoutRect(x: 0, y: 0, width: 400, height: 50000))
        let index = VerticalVisibilityIndex(frames: frames)

        #expect(!index.oversized.isEmpty, "the tall item should take the oversized path")

        for step in 0 ..< 50 {
            let range = viewport(Double(step) * 900)
            let found = index.indices(intersecting: range, frames: frames)
            #expect(found == bruteForce(range, frames))
        }
    }

    @Test("handles negative coordinates")
    func negativeCoordinates() {
        let frames = (0 ..< 300).map { i in
            LayoutRect(x: 0, y: -20000 + Double(i) * 60, width: 400, height: 55)
        }
        let index = VerticalVisibilityIndex(frames: frames)
        for step in 0 ..< 40 {
            let range = viewport(-21000 + Double(step) * 500)
            #expect(index.indices(intersecting: range, frames: frames) == bruteForce(range, frames))
        }
    }

    @Test("handles sparse content with huge empty gaps")
    func sparseContent() {
        // Ten items spread over two million points: almost every bucket empty.
        let frames = (0 ..< 10).map { i in
            LayoutRect(x: 0, y: Double(i) * 200_000, width: 400, height: 100)
        }
        let index = VerticalVisibilityIndex(frames: frames)
        for step in 0 ..< 40 {
            let range = viewport(Double(step) * 50000)
            #expect(index.indices(intersecting: range, frames: frames) == bruteForce(range, frames))
        }
    }

    @Test("degenerate inputs do not trap", arguments: [0, 1, 2, 13])
    func degenerate(count: Int) {
        let frames = (0 ..< count).map { _ in
            LayoutRect(x: 0, y: 0, width: 0, height: 0)
        }
        let index = VerticalVisibilityIndex(frames: frames)
        let range = viewport(0)
        #expect(index.indices(intersecting: range, frames: frames) == bruteForce(range, frames))
    }

    @Test("all frames stacked at the same y")
    func allAtSameY() {
        let frames = (0 ..< 1000).map { _ in
            LayoutRect(x: 0, y: 500, width: 400, height: 100)
        }
        let index = VerticalVisibilityIndex(frames: frames)
        #expect(index.indices(intersecting: viewport(400), frames: frames).count == 1000)
        #expect(index.indices(intersecting: viewport(2000), frames: frames).isEmpty)
    }

    @Test("non-finite coordinates do not trap")
    func nonFinite() {
        let frames = [
            LayoutRect(x: 0, y: 0, width: 10, height: 10),
            LayoutRect(x: 0, y: .nan, width: 10, height: 10),
            LayoutRect(x: 0, y: .infinity, width: 10, height: 10),
            LayoutRect(x: 0, y: 100, width: 10, height: .nan),
        ]
        let index = VerticalVisibilityIndex(frames: frames)
        // The contract is only that this terminates without trapping and agrees
        // with the same comparisons a linear scan makes.
        let range = viewport(0)
        #expect(index.indices(intersecting: range, frames: frames) == bruteForce(range, frames))
    }

    @Test("a range beyond the content returns nothing")
    func beyondContent() {
        let frames = (0 ..< 100).map { i in
            LayoutRect(x: 0, y: Double(i) * 100, width: 400, height: 90)
        }
        let index = VerticalVisibilityIndex(frames: frames)
        #expect(index.indices(intersecting: viewport(100_000), frames: frames).isEmpty)
        #expect(index.indices(intersecting: viewport(-100_000), frames: frames).isEmpty)
    }

    @Test("zero-height frames are never visible")
    func zeroHeightIsInvisible() {
        let frames = [LayoutRect(x: 0, y: 100, width: 400, height: 0)]
        let index = VerticalVisibilityIndex(frames: frames)
        #expect(index.indices(intersecting: viewport(0), frames: frames).isEmpty)
    }
}
