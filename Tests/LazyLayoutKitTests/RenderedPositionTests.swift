#if os(macOS)
    import AppKit
    @testable import LazyLayoutKit
    import SwiftUI
    import XCTest

    /// Do cells actually land where the layout put them?
    ///
    /// Every other test in this package checks the numbers a layout produces.
    /// None of them checked that those numbers survive being rendered — and a
    /// change to how the cell layer is composed did exactly that, drawing masonry
    /// cells on top of each other while the layout output stayed perfect and the
    /// whole suite stayed green. It was only visible by looking at the screen.
    ///
    /// So this measures the rendered cells instead of the frames: each one reports
    /// its own geometry, and the assertions are about what a person would notice.
    final class RenderedPositionTests: XCTestCase {
        private struct Tile: Identifiable, Equatable {
            let id: Int
            let ratio: Double
        }

        private final class Box<T>: @unchecked Sendable {
            var value: T
            init(_ value: T) {
                self.value = value
            }
        }

        private static let space = "lazylayout-content"

        @MainActor
        private func renderedFrames(
            columns: Int,
            width: Double,
            height: Double = 900
        ) -> [Int: CGRect] {
            var rng = SystemRandomNumberGenerator()
            _ = rng
            // Deterministic ratios spanning short and tall cells, so columns end
            // at genuinely different heights and placement is non-trivial.
            let tiles = (0 ..< 60).map { index in
                Tile(id: index, ratio: 0.6 + Double((index * 37) % 13) * 0.12)
            }
            let frames = Box<[Int: CGRect]>([:])

            let view = LazyLayoutView(tiles, layout: MasonryLayout(columns: columns, spacing: 10)) { tile in
                ItemMetric.aspectRatio(tile.ratio)
            } content: { tile in
                Color.gray.onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(Self.space))
                } action: { rect in
                    frames.value[tile.id] = rect
                }
            }
            .coordinateSpace(.named(Self.space))
            .frame(width: width, height: height)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
            window.contentView = hosting
            window.orderFront(nil)
            window.layoutIfNeeded()

            let deadline = Date().addingTimeInterval(5)
            while frames.value.count < 6, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            window.close()
            return frames.value
        }

        /// The regression: cells drawn on top of one another.
        @MainActor
        func testRenderedCellsDoNotOverlap() {
            let frames = renderedFrames(columns: 3, width: 400)
            XCTAssertGreaterThan(frames.count, 5, "Too few cells rendered to judge.")

            var overlaps: [String] = []
            let sorted = frames.sorted { $0.key < $1.key }
            for (index, a) in sorted.enumerated() {
                for b in sorted.dropFirst(index + 1) {
                    let intersection = a.value.intersection(b.value)
                    // Rounding can leave a hairline; anything a person could see
                    // is more than a point in both directions.
                    if intersection.width > 1, intersection.height > 1 {
                        overlaps.append(
                            "\(a.key) \(a.value.integral) overlaps \(b.key) \(b.value.integral)"
                        )
                    }
                }
            }
            XCTAssertTrue(
                overlaps.isEmpty,
                "Rendered cells overlap, so the layout's frames are not reaching the screen:\n"
                    + overlaps.prefix(10).joined(separator: "\n")
            )
        }

        /// Cells must land in as many distinct columns as the layout asked for.
        /// A composition that collapses positioning tends to pile them up.
        @MainActor
        func testRenderedCellsOccupyEveryColumn() {
            for columns in [2, 3] {
                let frames = renderedFrames(columns: columns, width: 400)
                let xs = Set(frames.values.map { ($0.minX * 2).rounded() / 2 })
                XCTAssertEqual(
                    xs.count,
                    columns,
                    "Expected \(columns) distinct column positions, saw \(xs.sorted())"
                )
            }
        }

        /// Rendered heights must match what the layout computed, or the cells are
        /// being squeezed by whatever is composing them.
        @MainActor
        func testRenderedHeightsMatchTheLayout() {
            let width = 400.0
            let frames = renderedFrames(columns: 3, width: width)

            let tiles = (0 ..< 60).map { index in
                ItemMetric.aspectRatio(0.6 + Double((index * 37) % 13) * 0.12)
            }
            let expected = MasonryLayout(columns: 3, spacing: 10)
                .layout(items: tiles, containerWidth: width)

            for (id, rect) in frames {
                let want = expected.frames[id]
                XCTAssertEqual(
                    Double(rect.height), want.height, accuracy: 1,
                    "Cell \(id) rendered \(rect.height)pt tall, layout said \(want.height)pt"
                )
                XCTAssertEqual(
                    Double(rect.width), want.width, accuracy: 1,
                    "Cell \(id) rendered \(rect.width)pt wide, layout said \(want.width)pt"
                )
            }
        }

        /// Relative vertical placement must survive rendering: the gap between two
        /// cells in a column is the layout's gap, not something compressed.
        @MainActor
        func testVerticalGapsMatchTheLayout() {
            let width = 400.0
            let frames = renderedFrames(columns: 3, width: width)
            let tiles = (0 ..< 60).map { index in
                ItemMetric.aspectRatio(0.6 + Double((index * 37) % 13) * 0.12)
            }
            let expected = MasonryLayout(columns: 3, spacing: 10)
                .layout(items: tiles, containerWidth: width)

            // Compare each rendered cell against the first rendered one, so the
            // scroll view's own inset cancels out.
            guard let anchor = frames.keys.sorted().first, let anchorRect = frames[anchor] else {
                return XCTFail("Nothing rendered.")
            }
            for (id, rect) in frames where id != anchor {
                let renderedDelta = Double(rect.minY - anchorRect.minY)
                let expectedDelta = expected.frames[id].y - expected.frames[anchor].y
                XCTAssertEqual(
                    renderedDelta, expectedDelta, accuracy: 1.5,
                    "Cell \(id) rendered \(renderedDelta)pt below cell \(anchor), layout said \(expectedDelta)pt"
                )
            }
        }
    }
#endif
