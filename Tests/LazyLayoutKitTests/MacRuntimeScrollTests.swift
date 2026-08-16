#if os(macOS)
    import AppKit
    @testable import LazyLayoutKit
    import SwiftUI
    import XCTest

    /// Hosted tests for programmatic scrolling.
    ///
    /// The offset arithmetic itself is covered without rendering in
    /// `ScrollTargetTests`. What needs a real window is everything around it: that
    /// a request made before the first layout survives to be applied, that a jump
    /// actually moves the materialised window, that a repeat of the same request
    /// fires, and that an explicit target beats the anchoring path.
    final class MacRuntimeScrollTests: XCTestCase {
        private struct Item: Identifiable, Equatable {
            let id: Int
            let ratio: Double
        }

        private final class Recorder: @unchecked Sendable {
            var active: [Int: CGRect] = [:]
            var everBuilt: Set<Int> = []
        }

        private final class Model: ObservableObject {
            @Published var items: [Item]
            @Published var position: LazyLayoutPosition<Int>
            /// Drives container re-creation, as a `.id()` change would.
            @Published var containerIdentity = 0
            /// Whether the container is handed a position binding at all.
            @Published var attached = true

            init(_ items: [Item], position: LazyLayoutPosition<Int> = .init()) {
                self.items = items
                self.position = position
            }
        }

        private static let space = "lazylayout-scroll"

        private struct Harness: View {
            @ObservedObject var model: Model
            let recorder: Recorder
            var topInset: Double = 0

            /// `nil` once detached, which is the case the container has to notice.
            private var positionBinding: Binding<LazyLayoutPosition<Int>>? {
                model.attached ? $model.position : nil
            }

            var body: some View {
                LazyLayoutView(
                    model.items,
                    layout: MasonryLayout(columns: 3, spacing: 8),
                    position: positionBinding
                ) {
                    .aspectRatio($0.ratio)
                } content: { item in
                    Color.gray
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .named(MacRuntimeScrollTests.space))
                        } action: { rect in
                            recorder.active[item.id] = rect
                        }
                        .onAppear { recorder.everBuilt.insert(item.id) }
                        .onDisappear { recorder.active[item.id] = nil }
                }
                .id(model.containerIdentity)
                .safeAreaInset(edge: .top) {
                    // Zero-height by default, so the inset test is the only one
                    // that pays for it.
                    Color.clear.frame(height: topInset)
                }
                .coordinateSpace(.named(MacRuntimeScrollTests.space))
            }
        }

        private func makeItems(_ ids: Range<Int>) -> [Item] {
            var rng = Rng(seed: 0x5EED)
            return ids.map { Item(id: $0, ratio: rng.double(in: 0.5 ... 2.0)) }
        }

        @MainActor
        private func pump(_ seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }

        @MainActor
        private func host(
            _ model: Model,
            _ recorder: Recorder,
            topInset: Double = 0,
            size: NSSize = NSSize(width: 400, height: 800),
            settle: TimeInterval = 0.6
        ) -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            // Programmatically created windows release themselves on close, so
            // `close()` plus ARC's release is an over-release that SIGSEGVs the
            // next test in the suite.
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(
                rootView: Harness(model: model, recorder: recorder, topInset: topInset)
            )
            hosting.frame = NSRect(origin: .zero, size: size)
            window.contentView = hosting
            window.orderFront(nil)
            window.layoutIfNeeded()
            pump(settle)
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

        // MARK: - 1. Initial positioning

        /// A request that predates the first snapshot. There is nothing laid out
        /// when the binding is first read, so this only works because the request
        /// is held and applied by the first solve.
        @MainActor
        func testInitialPositioningOpensAtTheTarget() throws {
            let model = Model(
                makeItems(0 ..< 20000),
                position: LazyLayoutPosition(initiallyScrolledTo: 5000)
            )
            let recorder = Recorder()
            let window = host(model, recorder)
            defer { window.close() }

            let active = Set(recorder.active.keys)
            XCTAssertFalse(active.isEmpty, "nothing was built")
            XCTAssertFalse(active.contains(0), "the container opened at the top instead of the target")
            XCTAssertTrue(active.contains(5000), "the target itself was never built")
            XCTAssertGreaterThan(active.min() ?? 0, 4000, "active ids are not near the target")

            // And the scroll view really is there, not just the window.
            let scroll = try XCTUnwrap(scrollView(in: window))
            let snapshot = LayoutSnapshot(
                ids: model.items.map(\.id),
                result: MasonryLayout(columns: 3, spacing: 8)
                    .layout(items: model.items.map { .aspectRatio($0.ratio) }, containerWidth: 400),
                containerWidth: 400
            )
            let expected = try XCTUnwrap(
                snapshot.offset(toShow: 5000, anchor: .top, viewportHeight: 800)
            )
            XCTAssertEqual(scroll.contentView.bounds.origin.y, expected, accuracy: 40)
        }

        /// The retain half of the absent-target policy: an empty collection is
        /// "not laid out yet", so the request waits for the data.
        @MainActor
        func testRequestMadeBeforeDataArrivesIsHonoured() {
            let model = Model([])
            let recorder = Recorder()
            let window = host(model, recorder, settle: 0.3)
            defer { window.close() }

            model.position.scrollTo(id: 9000)
            pump(0.3)
            XCTAssertTrue(recorder.active.isEmpty, "there is nothing to show yet")

            model.items = makeItems(0 ..< 20000)
            pump(0.8)

            let active = Set(recorder.active.keys)
            XCTAssertFalse(active.isEmpty)
            XCTAssertTrue(active.contains(9000), "the held request was dropped when the data arrived")
        }

        // MARK: - 2. Deep jumps

        @MainActor
        func testDeepJumpMovesTheMaterializedWindow() {
            let model = Model(makeItems(0 ..< 20000))
            let recorder = Recorder()
            let window = host(model, recorder)
            defer { window.close() }

            let before = Set(recorder.active.keys)
            XCTAssertFalse(before.isEmpty)

            model.position.scrollTo(id: 15000)
            pump(0.8)

            let after = Set(recorder.active.keys)
            XCTAssertFalse(after.isEmpty, "the container went blank after the jump")
            XCTAssertTrue(
                after.isDisjoint(with: before),
                "the window did not move; \(after.intersection(before).count) cells were kept"
            )
            XCTAssertTrue(after.contains(15000))
            XCTAssertLessThan(after.count, 600, "materialization is unbounded after a jump")
        }

        /// The one-pass claim. The container adopts the destination offset locally
        /// rather than waiting for scroll geometry to report it, so the target's
        /// neighbourhood is built on the same pass — not one round trip later.
        @MainActor
        func testDeepJumpBuildsTheTargetImmediately() {
            let model = Model(makeItems(0 ..< 20000))
            let recorder = Recorder()
            let window = host(model, recorder)
            defer { window.close() }

            recorder.everBuilt.removeAll()
            model.position.scrollTo(id: 15000)
            // Two short slices only: enough for SwiftUI to run the update, far too
            // little for a settled scroll-geometry callback to have redrawn twice.
            pump(0.04)

            XCTAssertTrue(
                recorder.everBuilt.contains(15000),
                "the target was not built promptly; built \(recorder.everBuilt.count) other cells"
            )
        }

        // MARK: - 3. Repeated requests

        /// **This test fails without the generation counter.** The second request
        /// is equal to the first by value, so a container comparing only the target
        /// would ignore it — which is exactly the case where the user has scrolled
        /// away and taps the same button again to come back.
        @MainActor
        func testRepeatingTheSameRequestScrollsAgain() throws {
            let model = Model(makeItems(0 ..< 20000))
            let recorder = Recorder()
            let window = host(model, recorder)
            defer { window.close() }

            model.position.scrollTo(id: 9000)
            pump(0.8)
            XCTAssertTrue(recorder.active.keys.contains(9000))

            // Drive the scroll view away by hand, as a user would.
            let scroll = try XCTUnwrap(scrollView(in: window))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            pump(0.8)
            XCTAssertFalse(
                recorder.active.keys.contains(9000),
                "the test needs the target genuinely off screen before repeating"
            )

            model.position.scrollTo(id: 9000)
            pump(0.8)
            XCTAssertTrue(
                recorder.active.keys.contains(9000),
                "a repeated request for the same id did nothing"
            )
        }

        /// Replacing the position with a brand new instance must still scroll.
        ///
        /// **This test fails against a per-instance request counter.** A fresh
        /// `LazyLayoutPosition` restarts its count low, so if the container
        /// compared per-instance numbers it would see a value it had already
        /// serviced and ignore the request — silently, and only for callers who
        /// reset their scroll state, which is a natural thing to do when moving to
        /// a new context. Request tokens are drawn from a process-wide counter for
        /// exactly this reason.
        @MainActor
        func testReplacingThePositionInstanceStillScrolls() {
            let model = Model(makeItems(0 ..< 20000))
            let recorder = Recorder()
            let window = host(model, recorder)
            defer { window.close() }

            model.position.scrollTo(id: 2000)
            pump(0.9)
            XCTAssertTrue(recorder.active.keys.contains(2000))

            model.position = LazyLayoutPosition(initiallyScrolledTo: 12000)
            pump(0.9)
            XCTAssertTrue(
                recorder.active.keys.contains(12000),
                "a fresh position instance was ignored — its request collided with one already serviced"
            )
        }

        /// `cancelScroll()` has to withdraw a request that is still *held* because
        /// nothing had been laid out when it was made.
        @MainActor
        func testCancelWithdrawsAHeldRequest() {
            let model = Model([])
            let recorder = Recorder()
            let window = host(model, recorder, settle: 0.3)
            defer { window.close() }

            model.position.scrollTo(id: 3000)
            pump(0.3)
            model.position.cancelScroll()
            pump(0.3)
            model.items = makeItems(0 ..< 5000)
            pump(0.8)

            XCTAssertFalse(recorder.active.isEmpty)
            XCTAssertFalse(
                recorder.active.keys.contains(3000),
                "a cancelled request still fired once the data arrived"
            )
        }

        /// Two requests inside one update: the last one is the caller's intent.
        @MainActor
        func testLastRequestWinsWithinOneUpdate() {
            let model = Model(makeItems(0 ..< 20000))
            let recorder = Recorder()
            let window = host(model, recorder)
            defer { window.close() }

            model.position.scrollTo(id: 3000)
            model.position.scrollTo(id: 12000)
            pump(0.9)

            XCTAssertTrue(recorder.active.keys.contains(12000))
            XCTAssertFalse(recorder.active.keys.contains(3000))
        }

        /// A container created after a request was already serviced must not act
        /// on it.
        ///
        /// This is the defect that documentation cannot paper over. Nothing is
        /// ever read back, so the target a position holds is the last thing the
        /// caller *asked for* — not where the user is. Once the user has scrolled
        /// on, re-applying it on a tab switch or `.id()` change jumps somewhere
        /// arbitrary. It is not restoration, and `ScrollPosition` is no precedent
        /// for it: that type tracks the user via `viewID`, which this deliberately
        /// does not.
        @MainActor
        func testRebuiltContainerIgnoresAlreadyServicedRequest() throws {
            let model = Model(makeItems(0 ..< 20000))
            let recorder = Recorder()
            let window = host(model, recorder)
            defer { window.close() }

            model.position.scrollTo(id: 2000)
            pump(0.9)
            XCTAssertTrue(recorder.active.keys.contains(2000), "the jump itself failed")

            // The user reads on. The position still says 2000; nothing told it.
            let scroll = try XCTUnwrap(scrollView(in: window))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            pump(0.8)

            // `active` is keyed by id and both containers are briefly alive, so the
            // old one's `onDisappear` can clobber the new one's entry for a shared
            // id. `everBuilt` only ever inserts, so it cannot be raced that way.
            recorder.everBuilt.removeAll()
            model.containerIdentity += 1
            pump(0.9)

            XCTAssertFalse(
                recorder.everBuilt.contains(2000),
                "a rebuilt container re-applied a request serviced before it existed"
            )
            XCTAssertTrue(
                recorder.everBuilt.contains(0),
                "a rebuilt container should start at the top, not at a stale target"
            )
        }

        /// The deliberate exception: `initiallyScrolledTo` exists precisely to be
        /// honoured by a container that did not exist when it was made.
        @MainActor
        func testRebuiltContainerHonoursAnExplicitInitialTarget() {
            let model = Model(makeItems(0 ..< 20000))
            let recorder = Recorder()
            let window = host(model, recorder)
            defer { window.close() }

            recorder.everBuilt.removeAll()
            model.position = LazyLayoutPosition(initiallyScrolledTo: 8000)
            model.containerIdentity += 1
            pump(0.9)

            XCTAssertTrue(
                recorder.everBuilt.contains(8000),
                "an explicit initial target was ignored by a fresh container"
            )
        }

        /// Detaching the binding withdraws a request that is still deferred.
        ///
        /// The request is captured while the collection is empty, so it sits in the
        /// container waiting for data. If the caller then takes the binding away,
        /// that request is no longer anyone's intent — it belongs to a handle they
        /// have removed — and firing it when the data lands would scroll on behalf
        /// of a caller who is no longer asking.
        @MainActor
        func testDetachingTheBindingWithdrawsADeferredRequest() {
            let model = Model([])
            let recorder = Recorder()
            let window = host(model, recorder, settle: 0.3)
            defer { window.close() }

            model.position.scrollTo(id: 3000)
            pump(0.3)
            XCTAssertTrue(recorder.active.isEmpty, "nothing should be built yet")

            model.attached = false
            pump(0.3)

            model.items = makeItems(0 ..< 5000)
            pump(0.8)

            XCTAssertFalse(recorder.active.isEmpty, "the container should still show the new data")
            XCTAssertFalse(
                recorder.active.keys.contains(3000),
                "a request deferred before the binding was detached still scrolled"
            )
        }

        /// The birth-token exemption for an initial request is used up once.
        ///
        /// Otherwise `initiallyScrolledTo` would be permanently exempt: the
        /// position keeps its target forever, so every later container would
        /// re-open at the deep link, however far the user had read past it — which
        /// is the exact behaviour the stale-request rule exists to prevent.
        @MainActor
        func testConsumedInitialRequestIsNotReappliedAfterRebuild() throws {
            let model = Model(
                makeItems(0 ..< 20000),
                position: LazyLayoutPosition(initiallyScrolledTo: 8000)
            )
            let recorder = Recorder()
            let window = host(model, recorder)
            defer { window.close() }

            XCTAssertTrue(recorder.active.keys.contains(8000), "initial positioning failed")

            // The user reads on. Nothing tells the position.
            let scroll = try XCTUnwrap(scrollView(in: window))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            pump(0.8)

            recorder.everBuilt.removeAll()
            model.containerIdentity += 1
            pump(0.9)

            XCTAssertFalse(
                recorder.everBuilt.contains(8000),
                "a spent initial request was honoured again by a rebuilt container"
            )
            XCTAssertTrue(
                recorder.everBuilt.contains(0),
                "the rebuilt container should start at the top"
            )
        }

        // MARK: - 4. Absent and deleted targets

        /// The drop half of the policy: a non-empty snapshot that lacks the id
        /// means the id is not in this collection, so the request must not lurk
        /// and fire later when something unrelated introduces it.
        @MainActor
        func testAbsentTargetIsDroppedRatherThanHeld() throws {
            let model = Model(makeItems(0 ..< 1000))
            let recorder = Recorder()
            let window = host(model, recorder)
            defer { window.close() }

            let scroll = try XCTUnwrap(scrollView(in: window))
            let before = scroll.contentView.bounds.origin.y

            model.position.scrollTo(id: 999_999)
            pump(0.6)
            XCTAssertEqual(
                scroll.contentView.bounds.origin.y, before, accuracy: 1,
                "a request for an id that does not exist moved the scroll view"
            )

            // Now introduce that id. The dropped request must not resurface.
            model.items = makeItems(0 ..< 1000) + [Item(id: 999_999, ratio: 1)]
            pump(0.8)
            XCTAssertFalse(
                recorder.active.keys.contains(999_999),
                "a dropped request fired later when its id happened to appear"
            )
        }

        // MARK: - 5. Interaction with mutations and anchoring

        @MainActor
        func testJumpedOffsetSurvivesAFrontInsertion() throws {
            let model = Model(makeItems(0 ..< 5000))
            let recorder = Recorder()
            let window = host(model, recorder)
            defer { window.close() }

            model.position.scrollTo(id: 900, anchor: .top)
            pump(0.8)
            let before = try XCTUnwrap(recorder.active[900], "the target was never built")

            model.items = makeItems(-25 ..< 0) + model.items
            pump(0.8)

            let after = try XCTUnwrap(
                recorder.active[900], "the target fell out of the window after the insertion"
            )
            XCTAssertEqual(
                after.minY, before.minY, accuracy: 2,
                "anchoring did not hold the jumped-to item still across the insertion"
            )
        }

        /// When a mutation and an explicit request land together, the request wins.
        /// Applying both would add an anchoring adjustment to an absolute offset.
        @MainActor
        func testExplicitRequestBeatsAnchoringInTheSameUpdate() {
            let model = Model(makeItems(0 ..< 5000))
            let recorder = Recorder()
            let window = host(model, recorder)
            defer { window.close() }

            model.position.scrollTo(id: 900)
            pump(0.8)
            XCTAssertTrue(recorder.active.keys.contains(900))

            // Both in one update: a front insertion (which anchoring would want to
            // compensate for) and a new destination.
            model.items = makeItems(-500 ..< 0) + model.items
            model.position.scrollTo(id: 3000)
            pump(0.8)

            let active = Set(recorder.active.keys)
            XCTAssertTrue(active.contains(3000), "the explicit target lost to anchoring")
            XCTAssertFalse(active.contains(900))
        }

        // MARK: - 6. Content insets

        /// Anchoring only ever applies a *delta*, so a constant content inset
        /// cancels out and has never been observable. An absolute jump does not
        /// cancel, which makes this the one place an inset could put the target a
        /// whole inset height off.
        ///
        /// Asserting on the container's own viewport would not catch that — the
        /// assertion has to be about where the cell actually rendered.
        ///
        /// The named coordinate space wraps the inset, so "at the top of the
        /// visible region" means the cell's `minY` equals the inset height.
        /// Running at two insets is what makes this a real test rather than a
        /// number copied from the output: if the offset were written in the wrong
        /// space, both cases could not land at their own inset. Subtracting the
        /// inset before `scrollTo(y:)` was tried, and moves the 120pt case a
        /// further 120pt down.
        @MainActor
        func testTargetLandsAtTheTopOfTheVisibleRegionUnderATopInset() throws {
            for inset in [0.0, 120.0] {
                let model = Model(makeItems(0 ..< 20000))
                let recorder = Recorder()
                let window = host(model, recorder, topInset: inset)
                defer { window.close() }

                model.position.scrollTo(id: 6000, anchor: .top)
                pump(0.8)

                let frame = try XCTUnwrap(
                    recorder.active[6000], "the target was never built at inset \(inset)"
                )
                XCTAssertEqual(
                    frame.minY, inset, accuracy: 12,
                    "at inset \(inset) the target rendered at \(frame.minY), "
                        + "which is \(frame.minY - inset)pt off the top of the visible region"
                )
            }
        }
    }
#endif
