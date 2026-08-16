@testable import LazyLayoutKit
import Testing

/// Frames grouped back into rows by their shared `y`.
///
/// The layout emits in item order and item order is row order, so a row is just
/// a run of equal tops.
private func rows(_ frames: [LayoutRect]) -> [[LayoutRect]] {
    var result: [[LayoutRect]] = []
    for frame in frames {
        if let last = result.last?.first, last.y == frame.y {
            result[result.count - 1].append(frame)
        } else {
            result.append([frame])
        }
    }
    return result
}

private func ratios(_ count: Int, seed: UInt64 = 0xCAFE) -> [ItemMetric] {
    var rng = Rng(seed: seed)
    return (0 ..< count).map { _ in .aspectRatio(rng.double(in: 0.5 ... 2.5)) }
}

@Suite("Justified layout")
struct JustifiedLayoutTests {
    static let width = 402.0

    // MARK: - The defining property

    @Test("every completed row fills the container width exactly")
    func completedRowsFillTheWidth() {
        let layout = JustifiedLayout(targetRowHeight: 160, horizontalSpacing: 6, verticalSpacing: 6)
        let result = layout.layout(items: ratios(300), containerWidth: Self.width)
        let grouped = rows(result.frames)

        #expect(grouped.count > 10, "300 items should make plenty of rows")
        for row in grouped.dropLast() {
            #expect(row[0].x == 0)
            // Exact, not within a tolerance: the last item in a justified row is
            // snapped to the container edge precisely so this can be asserted.
            #expect(row[row.count - 1].maxX == Self.width)
        }
    }

    @Test("a completed row is never taller than the target")
    func completedRowsRespectTheTarget() {
        let layout = JustifiedLayout(targetRowHeight: 160, horizontalSpacing: 6, verticalSpacing: 6)
        let result = layout.layout(items: ratios(300), containerWidth: Self.width)

        for row in rows(result.frames).dropLast() {
            #expect(row[0].height <= 160 + 1e-9)
            #expect(row[0].height > 0)
        }
    }

    @Test("aspect ratios are preserved")
    func aspectRatiosPreserved() {
        let metrics = ratios(300)
        let layout = JustifiedLayout(targetRowHeight: 160, horizontalSpacing: 6, verticalSpacing: 6)
        let result = layout.layout(items: metrics, containerWidth: Self.width)
        let grouped = rows(result.frames)

        var index = 0
        for (rowIndex, row) in grouped.enumerated() {
            for (positionInRow, frame) in row.enumerated() {
                guard case let .aspectRatio(expected) = metrics[index] else {
                    Issue.record("test data should be aspect ratios")
                    return
                }
                // The last item of a justified row absorbs the snap, so it gets a
                // sub-point tolerance where every other item is exact.
                let isSnapped = positionInRow == row.count - 1 && rowIndex < grouped.count - 1
                let tolerance = isSnapped ? 0.5 / frame.height : 1e-9
                #expect(abs(frame.width / frame.height - expected) < tolerance)
                index += 1
            }
        }
    }

    // MARK: - Spacing

    @Test("spacing is respected in both axes and rows never overlap")
    func spacing() {
        let layout = JustifiedLayout(
            targetRowHeight: 160, horizontalSpacing: 6, verticalSpacing: 14
        )
        let result = layout.layout(items: ratios(200), containerWidth: Self.width)
        let grouped = rows(result.frames)

        for row in grouped {
            for pair in zip(row, row.dropFirst()) {
                #expect(abs(pair.1.x - pair.0.maxX - 6) < 1e-9)
            }
        }
        for pair in zip(grouped, grouped.dropFirst()) {
            #expect(abs(pair.1[0].y - pair.0[0].maxY - 14) < 1e-9)
            #expect(!pair.0[0].intersectsVertically(pair.1[0]))
        }
    }

    // MARK: - Last-row policy

    @Test("a natural last row keeps the target height and ends short")
    func naturalLastRow() throws {
        // 10 squares at a 100pt target in a 402pt container: rows of 4, 4, then a
        // trailing 2 that cannot fill.
        let layout = JustifiedLayout(
            targetRowHeight: 100, horizontalSpacing: 6, verticalSpacing: 6, lastRow: .natural
        )
        let result = layout.layout(
            items: Array(repeating: .aspectRatio(1), count: 10), containerWidth: Self.width
        )
        let last = try #require(rows(result.frames).last)

        #expect(last.count == 2)
        #expect(last[0].height == 100)
        #expect(last[last.count - 1].maxX < Self.width)
    }

    @Test("a justified last row stretches to fill")
    func justifiedLastRow() throws {
        let layout = JustifiedLayout(
            targetRowHeight: 100, horizontalSpacing: 6, verticalSpacing: 6, lastRow: .justified
        )
        let result = layout.layout(
            items: Array(repeating: .aspectRatio(1), count: 10), containerWidth: Self.width
        )
        let last = try #require(rows(result.frames).last)

        #expect(last[last.count - 1].maxX == Self.width)
        #expect(last[0].height > 100, "two squares filling 402pt must be taller than the target")
    }

    @Test("a single leftover item under .justified spans the container")
    func singleItemJustifiedLastRow() {
        let layout = JustifiedLayout(
            targetRowHeight: 100, horizontalSpacing: 6, verticalSpacing: 6, lastRow: .justified
        )
        // One very tall item can never fill a row at the target height, so it is
        // the trailing row all by itself.
        let result = layout.layout(items: [.aspectRatio(0.5)], containerWidth: Self.width)

        #expect(result.frames.count == 1)
        #expect(result.frames[0].maxX == Self.width)
    }

    // MARK: - Structure and content height

    @Test("one frame per item, in item order")
    func frameCount() {
        let layout = JustifiedLayout()
        for count in [0, 1, 2, 7, 99, 1000] {
            let result = layout.layout(items: ratios(count), containerWidth: Self.width)
            #expect(result.frames.count == count)
        }
    }

    @Test("content height spans every frame without trailing spacing")
    func contentHeight() throws {
        let layout = JustifiedLayout(targetRowHeight: 160, horizontalSpacing: 6, verticalSpacing: 6)
        let result = layout.layout(items: ratios(300), containerWidth: Self.width)
        let bottom = try #require(result.frames.map(\.maxY).max())

        #expect(abs(result.contentHeight - bottom) < 1e-9)
    }

    @Test("uniform ratios produce a predictable row size")
    func uniformRatios() {
        // Squares at a 100pt target in 402pt with 6pt gutters: 4 per row needs
        // 4·100 + 3·6 = 418 > 402, so the fourth tips it over and stays, giving
        // rows of 4 at a height just under the target.
        let layout = JustifiedLayout(targetRowHeight: 100, horizontalSpacing: 6, verticalSpacing: 6)
        let result = layout.layout(
            items: Array(repeating: .aspectRatio(1), count: 40), containerWidth: Self.width
        )
        let grouped = rows(result.frames)

        #expect(grouped.count == 10)
        for row in grouped {
            #expect(row.count == 4)
        }
    }

    // MARK: - Sanitization

    @Test("one absurd ratio cannot collapse the rest of its row")
    func absurdRatioIsClamped() {
        // Without the maximum-ratio clamp this row's height goes to about zero,
        // and a zero-height frame intersects no viewport — so every other item in
        // the row would silently never be built.
        var metrics = [ItemMetric](repeating: .aspectRatio(1), count: 10)
        metrics[3] = .aspectRatio(1e9)
        let result = JustifiedLayout(targetRowHeight: 160)
            .layout(items: metrics, containerWidth: Self.width)

        for frame in result.frames {
            #expect(frame.height > 0)
            #expect(frame.width > 0)
        }
    }

    @Test("a fixed height has no ratio to preserve and is laid out square")
    func fixedHeightIsSquare() {
        let result = JustifiedLayout(targetRowHeight: 100, horizontalSpacing: 0, verticalSpacing: 0)
            .layout(items: [.fixedHeight(725), .aspectRatio(1)], containerWidth: 200)

        // Two squares in 200pt: one row of 2 at 100pt each.
        #expect(result.frames[0].width == result.frames[0].height)
        #expect(result.frames[1].width == result.frames[1].height)
    }

    @Test(
        "degenerate ratios still produce finite, non-negative frames",
        arguments: [Double.nan, 0, -1, .infinity, -.infinity, 1e12, 1e-12]
    )
    func degenerateRatios(ratio: Double) {
        var metrics = [ItemMetric](repeating: .aspectRatio(1.5), count: 20)
        metrics[7] = .aspectRatio(ratio)
        let result = JustifiedLayout().layout(items: metrics, containerWidth: Self.width)

        #expect(result.frames.count == 20)
        for frame in result.frames {
            #expect(frame.x.isFinite && frame.y.isFinite)
            #expect(frame.width.isFinite && frame.width >= 0)
            #expect(frame.height.isFinite && frame.height >= 0)
        }
        #expect(result.contentHeight.isFinite)
        #expect(result.contentHeight >= (result.frames.map(\.maxY).max() ?? 0) - 1e-9)
    }

    @Test(
        "a degenerate container width terminates without trapping",
        arguments: [0.0, -10, .nan, .infinity]
    )
    func degenerateContainerWidth(width: Double) {
        let result = JustifiedLayout().layout(items: ratios(50), containerWidth: width)

        #expect(result.frames.count == 50)
        for frame in result.frames {
            #expect(frame.width.isFinite && frame.width >= 0)
            #expect(frame.height.isFinite && frame.height >= 0)
        }
        #expect(result.contentHeight.isFinite)
    }

    @Test("degenerate configuration is clamped at initialization")
    func degenerateConfiguration() {
        let layout = JustifiedLayout(
            targetRowHeight: .nan, horizontalSpacing: -5, verticalSpacing: .infinity
        )
        #expect(layout.targetRowHeight == 240)
        #expect(layout.horizontalSpacing == 0)
        #expect(layout.verticalSpacing == 0)

        #expect(JustifiedLayout(targetRowHeight: -100).targetRowHeight == 1)
    }

    @Test("an empty collection lays out to nothing")
    func empty() {
        let result = JustifiedLayout().layout(items: [], containerWidth: Self.width)
        #expect(result.frames.isEmpty)
        #expect(result.contentHeight == 0)
    }

    // MARK: - Scale

    @Test("100,000 items stay finite and monotone")
    func scale() {
        let result = JustifiedLayout(targetRowHeight: 200)
            .layout(items: ratios(100_000), containerWidth: Self.width)

        #expect(result.frames.count == 100_000)
        #expect(result.contentHeight.isFinite)
        // Row tops never go backwards, so the visibility index sees a sane plane.
        for pair in zip(result.frames, result.frames.dropFirst()) {
            #expect(pair.1.y >= pair.0.y)
        }
    }
}
