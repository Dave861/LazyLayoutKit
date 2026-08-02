#if os(macOS)
    import AppKit
    @testable import LazyLayoutKit
    import SwiftUI
    import XCTest

    /// Hosted tests for the two things snapshot tests cannot reach: what happens to
    /// the container when the collection is mutated underneath it, and whether it
    /// still behaves after scrolling to depth.
    ///
    /// The mutation case matters because `placed` is `@State` and survives the
    /// parent handing the view a new collection, while `elements` is replaced
    /// immediately — so `body` can run with new data and stale positions.
    final class MacRuntimeMutationTests: XCTestCase {
        private struct Item: Identifiable, Equatable {
            let id: Int
            let ratio: Double
            /// Carried so a cell can report which element it was actually given.
            let tag: String
        }

        /// Live record of what is on screen right now — cells insert on appear and
        /// remove on disappear, so this is active cells, not everything ever built.
        private final class Recorder: @unchecked Sendable {
            var active: [Int: String] = [:]
            var everBuilt: Set<Int> = []
            var mismatches: [String] = []
        }

        private final class Data: ObservableObject {
            @Published var items: [Item]
            init(_ items: [Item]) {
                self.items = items
            }
        }

        private struct Harness: View {
            @ObservedObject var data: Data
            let recorder: Recorder

            var body: some View {
                LazyLayoutView(data.items, layout: MasonryLayout(columns: 3, spacing: 8)) {
                    .aspectRatio($0.ratio)
                } content: { item in
                    Color.gray
                        .onAppear {
                            recorder.active[item.id] = item.tag
                            recorder.everBuilt.insert(item.id)
                            // The pairing that breaks if a stale position is used
                            // to index a freshly replaced collection.
                            if item.tag != "tag-\(item.id)" {
                                recorder.mismatches.append("id \(item.id) got \(item.tag)")
                            }
                        }
                        .onDisappear { recorder.active[item.id] = nil }
                }
            }
        }

        private func makeItems(_ ids: Range<Int>) -> [Item] {
            var rng = Rng(seed: 0x5EED)
            return ids.map { Item(id: $0, ratio: rng.double(in: 0.5 ... 2.0), tag: "tag-\($0)") }
        }

        @MainActor
        private func pump(_ seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }

        @MainActor
        private func hostHarness(
            _ data: Data,
            _ recorder: Recorder,
            size: NSSize = NSSize(width: 400, height: 800)
        ) -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            // Programmatically created NSWindows default to releasing themselves on
            // close, so `close()` plus ARC's own release is an over-release. That
            // crashed the second test in the suite with SIGSEGV.
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: Harness(data: data, recorder: recorder))
            hosting.frame = NSRect(origin: .zero, size: size)
            window.contentView = hosting
            window.orderFront(nil)
            window.layoutIfNeeded()
            pump(0.6)
            return window
        }

        @MainActor
        private func scrollView(in window: NSWindow) -> NSScrollView? {
            guard let root = window.contentView else { return nil }
            var queue: [NSView] = [root]
            while let view = queue.first {
                queue.removeFirst()
                if let scroll = view as? NSScrollView {
                    return scroll
                }
                queue.append(contentsOf: view.subviews)
            }
            return nil
        }

        /// Deleting from the front is the case that could index out of bounds.
        @MainActor
        func testDeletingManyItemsDoesNotCrashOrMispair() {
            let data = Data(makeItems(0 ..< 5000))
            let recorder = Recorder()
            let window = hostHarness(data, recorder)
            defer { window.close() }

            XCTAssertFalse(recorder.active.isEmpty, "nothing was built before the mutation")

            // Remove almost everything, including every id currently on screen.
            data.items = makeItems(4900 ..< 5000)
            pump(0.8)

            XCTAssertTrue(
                recorder.mismatches.isEmpty,
                "cells were paired with the wrong element: \(recorder.mismatches.prefix(5))"
            )
            XCTAssertFalse(recorder.active.isEmpty, "the container went permanently blank after deletion")
            for id in recorder.active.keys {
                XCTAssertTrue(
                    (4900 ..< 5000).contains(id),
                    "id \(id) is still on screen but no longer exists in the data"
                )
            }
        }

        /// The out-of-bounds path specifically: scroll deep so the live positions are
        /// large, then shrink the collection below them. Without the identity guard
        /// in `body`, the next render indexes `elements` past its end.
        @MainActor
        func testShrinkingBelowADeepScrollPositionDoesNotCrash() throws {
            let data = Data(makeItems(0 ..< 20000))
            let recorder = Recorder()
            let window = hostHarness(data, recorder)
            defer { window.close() }

            let scroll = try XCTUnwrap(scrollView(in: window))
            let deepOffset = (scroll.documentView?.frame.height ?? 0) * 0.5
            scroll.contentView.scroll(to: NSPoint(x: 0, y: deepOffset))
            scroll.reflectScrolledClipView(scroll.contentView)
            pump(0.8)

            let deepPositions = Set(recorder.active.keys)
            XCTAssertGreaterThan(
                deepPositions.min() ?? 0, 200,
                "the test needs live positions well beyond the size we are about to shrink to"
            )

            // Every live position is now past the end of the collection.
            data.items = makeItems(0 ..< 50)
            pump(0.8)

            XCTAssertTrue(recorder.mismatches.isEmpty, "\(recorder.mismatches.prefix(5))")
            for id in recorder.active.keys {
                XCTAssertTrue((0 ..< 50).contains(id), "id \(id) survived a shrink that removed it")
            }
        }

        /// Inserting at the front shifts every index, which is what pairs an id with
        /// the wrong element if positions are trusted blindly.
        @MainActor
        func testInsertingAtFrontDoesNotMispair() {
            let data = Data(makeItems(1000 ..< 2000))
            let recorder = Recorder()
            let window = hostHarness(data, recorder)
            defer { window.close() }

            XCTAssertFalse(recorder.active.isEmpty)
            data.items = makeItems(0 ..< 1000) + data.items
            pump(0.8)

            XCTAssertTrue(
                recorder.mismatches.isEmpty,
                "cells were paired with the wrong element: \(recorder.mismatches.prefix(5))"
            )
            XCTAssertFalse(recorder.active.isEmpty)
        }

        /// Repeated churn, to catch anything that only breaks on the second pass.
        @MainActor
        func testRepeatedMutationsStayConsistent() {
            let data = Data(makeItems(0 ..< 2000))
            let recorder = Recorder()
            let window = hostHarness(data, recorder)
            defer { window.close() }

            for step in 1 ... 5 {
                data.items = makeItems((step * 100) ..< (2000 + step * 100))
                pump(0.35)
                XCTAssertTrue(
                    recorder.mismatches.isEmpty,
                    "mispaired at step \(step): \(recorder.mismatches.prefix(5))"
                )
            }
            XCTAssertFalse(recorder.active.isEmpty)
        }

        /// The macOS tests so far only proved the *initial* window. This scrolls to
        /// depth and checks that the active set moves with it and stays bounded.
        @MainActor
        func testScrollingToDepthMovesTheActiveWindow() throws {
            let data = Data(makeItems(0 ..< 20000))
            let recorder = Recorder()
            let window = hostHarness(data, recorder)
            defer { window.close() }

            let initialActive = Set(recorder.active.keys)
            XCTAssertFalse(initialActive.isEmpty)
            let scroll = try XCTUnwrap(scrollView(in: window), "no NSScrollView was found")

            let deepOffset = (scroll.documentView?.frame.height ?? 0) * 0.5
            XCTAssertGreaterThan(deepOffset, 10000, "sanity: the content should be very tall")

            scroll.contentView.scroll(to: NSPoint(x: 0, y: deepOffset))
            scroll.reflectScrolledClipView(scroll.contentView)
            pump(1.0)

            let deepActive = Set(recorder.active.keys)
            XCTAssertFalse(deepActive.isEmpty, "nothing is active after scrolling to depth")
            XCTAssertTrue(
                deepActive.isDisjoint(with: initialActive),
                "the active window did not move; still showing \(deepActive.intersection(initialActive).count) of the original cells"
            )
            XCTAssertGreaterThan(
                deepActive.min() ?? 0, 100,
                "active ids should be deep in the collection, got \(deepActive.min() ?? -1)"
            )
            XCTAssertLessThan(
                deepActive.count, 600,
                "active materialization is unbounded at depth: \(deepActive.count)"
            )
        }
    }
#endif
