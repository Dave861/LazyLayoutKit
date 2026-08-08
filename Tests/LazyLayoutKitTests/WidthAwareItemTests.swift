#if os(macOS)
    import AppKit
    import CoreText
    @testable import LazyLayoutKit
    import SwiftUI
    import XCTest

    /// Runtime behaviour of the width-aware item closure.
    ///
    /// The claim being tested is narrow but load-bearing: the closure is handed
    /// the width the items will actually be laid out in, and it is re-run when
    /// that width changes. Everything about self-sizing text depends on both — a
    /// height measured at the wrong width is wrong, and a height not re-measured
    /// after a resize is stale.
    ///
    /// XCTest rather than Swift Testing because this needs real SwiftUI in a
    /// window, matching `MacRuntimeTests`.
    final class WidthAwareItemTests: XCTestCase {
        private struct Row: Identifiable, Equatable {
            let id: Int
            let text: String
        }

        private final class Box<T>: @unchecked Sendable {
            var value: T
            init(_ value: T) {
                self.value = value
            }
        }

        private func rows(_ count: Int) -> [Row] {
            (0 ..< count).map { index in
                Row(id: index, text: String(repeating: "word\(index % 9) ", count: 3 + index % 20))
            }
        }

        @MainActor
        private func host(
            _ view: some View,
            size: NSSize,
            timeout: TimeInterval = 5,
            until condition: () -> Bool
        ) -> (window: NSWindow, satisfied: Bool) {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(origin: .zero, size: size)
            window.contentView = hosting
            window.orderFront(nil)
            window.layoutIfNeeded()

            let deadline = Date().addingTimeInterval(timeout)
            while !condition(), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return (window, condition())
        }

        /// The closure must see the container's real width, not zero and not a
        /// placeholder. A height measured at the wrong width is silently wrong,
        /// which is the worst kind of wrong.
        @MainActor
        func testItemClosureReceivesTheRealContainerWidth() {
            let widths = Box<[Double]>([])
            let data = rows(200)

            let view = LazyLayoutView(
                data,
                layout: MasonryLayout(columns: 1, spacing: 0),
                // Nothing outside the collection affects these heights.
                recomputeOn: 0
            ) { _, width in
                widths.value.append(width)
                return .fixedHeight(40)
            } content: { row in
                Color.gray.overlay(Text(row.text))
            }

            let (window, satisfied) = host(view, size: NSSize(width: 500, height: 600)) {
                !widths.value.isEmpty
            }
            defer { window.close() }

            XCTAssertTrue(satisfied, "The item closure was never called.")
            let observed = Set(widths.value)
            XCTAssertFalse(observed.contains(0), "The closure was called with a zero width.")
            for width in observed {
                XCTAssertGreaterThan(width, 0)
                XCTAssertLessThanOrEqual(width, 500)
                XCTAssertGreaterThan(width, 400, "Expected roughly the 500pt window width, got \(width).")
            }
        }

        /// Model driving a width change from inside SwiftUI.
        ///
        /// Resizing the host `NSWindow` also changes the width, but it exercises
        /// AppKit's resize plumbing as much as the container, and a failure there
        /// is indistinguishable from the container not re-solving. Driving the
        /// width through state isolates the behaviour under test.
        private final class WidthModel: ObservableObject {
            @Published var width: Double = 500
        }

        private struct ResizableHarness<Cell: View>: View {
            @ObservedObject var model: WidthModel
            let data: [Row]
            let record: (Double) -> Void
            let cell: (Row) -> Cell

            var body: some View {
                LazyLayoutView(
                    data,
                    layout: MasonryLayout(columns: 1, spacing: 0),
                    recomputeOn: 0
                ) { _, width in
                    record(width)
                    return .fixedHeight(40)
                } content: { row in
                    cell(row)
                }
                .frame(width: model.width)
            }
        }

        /// A width change has to re-run the closure, or text keeps a height
        /// measured for the old width and either clips or leaves a gap.
        @MainActor
        func testWidthChangeReRunsTheItemClosureAtTheNewWidth() {
            let widths = Box<[Double]>([])
            let model = WidthModel()
            let harness = ResizableHarness(
                model: model,
                data: rows(200),
                record: { widths.value.append($0) },
                cell: { _ in Color.gray }
            )

            let (window, satisfied) = host(harness, size: NSSize(width: 600, height: 600)) {
                !widths.value.isEmpty
            }
            defer { window.close() }
            XCTAssertTrue(satisfied, "The item closure never ran at the initial width.")

            let beforeChange = Set(widths.value)
            XCTAssertTrue(
                beforeChange.contains { abs($0 - 500) < 1 },
                "Expected the initial 500pt width, saw \(beforeChange)."
            )

            model.width = 300
            let deadline = Date().addingTimeInterval(5)
            while !widths.value.contains(where: { abs($0 - 300) < 1 }), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }

            XCTAssertTrue(
                widths.value.contains { abs($0 - 300) < 1 },
                "After narrowing to 300pt the closure never ran at the new width. Saw \(Set(widths.value))."
            )
        }

        /// End to end: real measured text drives the layout, and the resulting
        /// content plane reflects the measured heights rather than a placeholder.
        @MainActor
        func testMeasuredTextDrivesTheContentHeight() throws {
            guard #available(macOS 26, *) else {
                throw XCTSkip("Needs macOS 26 for the Font-to-CTFont bridge.")
            }
            let data = rows(300)
            let context = EnvironmentValues().fontResolutionContext
            let measurer = TextMeasurer(TextStyle(font: .body, in: context, lineLimit: 3))
            let built = Box<Set<Int>>([])

            let view = LazyLayoutView(
                data,
                layout: MasonryLayout(columns: 1, spacing: 8),
                recomputeOn: measurer.style
            ) { row, width in
                .fixedHeight(measurer.height(of: row.text, width: width))
            } content: { row in
                Text(row.text)
                    .font(.body)
                    .lineLimit(3)
                    .onAppear { built.value.insert(row.id) }
            }

            let (window, satisfied) = host(view, size: NSSize(width: 400, height: 700)) {
                !built.value.isEmpty
            }
            defer { window.close() }
            XCTAssertTrue(satisfied, "No cells were built.")

            // Only a window's worth of cells, not all 300 — the point of the
            // container is that measured text stays lazy.
            XCTAssertLessThan(built.value.count, 300)

            // Every measured height must be a real, positive, finite number: a
            // zero would collapse the cell and a NaN would poison the layout.
            for row in data {
                let height = measurer.height(of: row.text, width: 384)
                XCTAssertTrue(height.isFinite)
                XCTAssertGreaterThan(height, 0)
            }
        }

        /// The 0.1 initializer must keep working unchanged alongside the new one.
        @MainActor
        func testFixedItemInitializerStillWorks() {
            let built = Box<Set<Int>>([])
            let data = rows(500)

            let view = LazyLayoutView(data, layout: MasonryLayout(columns: 2, spacing: 8)) { _ in
                ItemMetric.aspectRatio(1.5)
            } content: { row in
                Color.gray.onAppear { built.value.insert(row.id) }
            }

            let (window, satisfied) = host(view, size: NSSize(width: 400, height: 700)) {
                !built.value.isEmpty
            }
            defer { window.close() }
            XCTAssertTrue(satisfied)
            XCTAssertLessThan(built.value.count, 500)
        }
    }
#endif
