#if os(macOS)
    import AppKit
    @testable import LazyLayoutKit
    import SwiftUI
    import XCTest

    /// macOS runtime validation.
    ///
    /// The spike that justified this package ran only on iOS. `ScrollView` on macOS
    /// is `NSScrollView`-backed, so none of the container's assumptions transfer for
    /// free: whether `onScrollGeometryChange` reports a usable viewport at all,
    /// whether materialization stays bounded, and whether the scrollable extent is
    /// sized from `contentHeight` rather than from the materialized subset.
    ///
    /// These are XCTest rather than Swift Testing because they need to host real
    /// SwiftUI in a window and pump the main run loop.
    final class MacRuntimeTests: XCTestCase {
        private struct Photo: Identifiable, Equatable {
            let id: Int
            let ratio: Double
        }

        private func makePhotos(_ count: Int) -> [Photo] {
            var rng = Rng(seed: 0x9A05)
            return (0 ..< count).map { Photo(id: $0, ratio: rng.double(in: 0.5 ... 2.0)) }
        }

        /// Hosts a view in a real window and pumps the main run loop until
        /// `condition` holds or the deadline passes. The window is passed in so
        /// conditions can inspect the resulting AppKit hierarchy.
        @MainActor
        private func host(
            _ view: some View,
            size: NSSize = NSSize(width: 400, height: 800),
            timeout: TimeInterval = 5,
            until condition: (NSWindow) -> Bool
        ) -> (window: NSWindow, satisfied: Bool) {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            // Programmatically created NSWindows default to releasing themselves
            // on close, so `close()` plus ARC's own release is an over-release.
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(origin: .zero, size: size)
            window.contentView = hosting
            window.orderFront(nil)
            window.layoutIfNeeded()

            let deadline = Date().addingTimeInterval(timeout)
            while !condition(window), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return (window, condition(window))
        }

        @MainActor
        private static func findScrollView(in window: NSWindow) -> NSScrollView? {
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

        /// The load-bearing question: does the container receive a usable viewport
        /// and build a bounded window of cells on macOS at all?
        @MainActor
        func testContainerMaterializesABoundedWindowOnMacOS() {
            let built = Box<Set<Int>>([])
            let photos = makePhotos(20000)

            let view = LazyLayoutView(photos, layout: MasonryLayout(columns: 3, spacing: 8)) {
                .aspectRatio($0.ratio)
            } content: { photo in
                Color.gray
                    .onAppear { built.value.insert(photo.id) }
            }

            let (window, satisfied) = host(view) { _ in !built.value.isEmpty }
            defer { window.close() }

            XCTAssertTrue(
                satisfied,
                "no cells were built — the geometry callbacks did not deliver a usable viewport on macOS"
            )
            XCTAssertLessThan(
                built.value.count, 600,
                "materialization is unbounded on macOS; built \(built.value.count) of 20,000"
            )
            XCTAssertTrue(built.value.contains(0), "the first item should be in the initial window")
            XCTAssertFalse(
                built.value.contains(19999),
                "the last item must not be materialized at rest"
            )
        }

        /// Does the scrollable extent come from `contentHeight`? If macOS sized the
        /// content to the materialized subset instead, scrolling past the first
        /// window would be impossible and the container would be useless there.
        @MainActor
        func testContentPlaneIsSizedFromContentHeight() {
            let photos = makePhotos(5000)
            let expected = MasonryLayout(columns: 3, spacing: 8)
                .layout(items: photos.map { .aspectRatio($0.ratio) }, containerWidth: 400)
                .contentHeight
            XCTAssertGreaterThan(expected, 100_000, "sanity: the test data should be very tall")

            let view = LazyLayoutView(photos, layout: MasonryLayout(columns: 3, spacing: 8)) {
                .aspectRatio($0.ratio)
            } content: { _ in Color.gray }

            let (window, satisfied) = host(view) { window in
                (Self.findScrollView(in: window)?.documentView?.frame.height ?? 0) > expected * 0.5
            }
            defer { window.close() }

            let height = Self.findScrollView(in: window)?.documentView?.frame.height ?? 0
            XCTAssertTrue(
                satisfied,
                "scrollable extent was \(height); expected roughly contentHeight (\(expected))"
            )
        }
    }

    /// Reference box so cell closures can record into shared state.
    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) {
            self.value = value
        }
    }
#endif
