import os
import SwiftUI

/// Internal measurement events consumed by the benchmark/demo harness.
/// The SPI keeps diagnostics out of the supported 0.1 API surface.
@_spi(Instrumentation)
public enum LazyLayoutInstrumentationEvent: Sendable {
    case solve(layout: Duration, snapshot: Duration, total: Duration)
    case visibility(duration: Duration, count: Int, first: Int?, last: Int?)
    case viewport(offsetY: Double)
}

/// A scrolling container that places items with an arbitrary
/// ``LazyLayoutAlgorithm`` and builds views only for what's on screen.
///
/// ```swift
/// LazyLayoutView(photos, layout: MasonryLayout(columns: 3)) { photo in
///     .aspectRatio(photo.width / photo.height)
/// } content: { photo in
///     PhotoCell(photo)
/// }
/// ```
///
/// ## What it does not do in 0.1
///
/// - Scrolls **vertically** only. A layout may place items anywhere across the
///   container's width; the scroll axis and the visibility index are y.
/// - Item sizes must be known before a view exists. There is no measurement pass.
/// - Collection changes are applied **correctly but without animation**. Scroll
///   position is preserved by anchoring on a stable id; insertion and removal do
///   not animate.
///
/// ## Cost note
///
/// `init` maps the collection once to extract ids and layout inputs, so creating
/// this view is O(n) in the number of items. That happens when the *parent*
/// re-renders, not while scrolling — scrolling only re-runs `body`, which
/// iterates the on-screen window.
public struct LazyLayoutView<Element, ID: Hashable & Sendable, Layout: LazyLayoutAlgorithm, Cell: View>: View {
    private let elements: [Element]
    private let ids: [ID]
    private let items: [Layout.Item]
    private let layout: Layout
    private let overscan: Double
    private let content: (Element) -> Cell
    private let onInstrumentation: ((LazyLayoutInstrumentationEvent) -> Void)?

    @State private var snapshot: LayoutSnapshot<ID>?
    @State private var containerWidth: Double = 0
    @State private var viewport = LayoutRect(x: 0, y: 0, width: 0, height: 0)
    @State private var placed: [Placed] = []
    @State private var scrollPosition = ScrollPosition(idType: ID.self)
    @State private var hasWarnedAboutDuplicates = false

    /// Everything a re-solve depends on, so one mutation triggers one solve.
    private struct ResolutionInput: Equatable {
        let ids: [ID]
        let items: [Layout.Item]
        let layout: Layout
    }

    private struct Placed: Identifiable {
        let id: ID
        let position: Int
        let frame: LayoutRect
        /// The element as of the last solve. Used only as a fallback for the one
        /// frame between a collection mutation and the re-solve, when positions
        /// no longer address the new collection.
        let element: Element
    }

    /// - Parameters:
    ///   - data: The items to lay out.
    ///   - id: Key path to a stable identity. Identity must be unique and must
    ///     not change as the collection mutates — it is what preserves scroll
    ///     position across an edit.
    ///   - layout: The placement algorithm.
    ///   - overscan: How much extra content, in multiples of the viewport
    ///     height, to build above and below the visible area. Higher values
    ///     trade memory and build cost for fewer empty cells during a fast
    ///     fling.
    ///   - item: The layout input for an element. Must be cheap: it is called
    ///     once per element whenever the view is created.
    ///   - content: The view for an element. Called only for on-screen items.
    public init<Data: RandomAccessCollection>(
        _ data: Data,
        id: KeyPath<Element, ID>,
        layout: Layout,
        overscan: Double = 1,
        item: (Element) -> Layout.Item,
        @ViewBuilder content: @escaping (Element) -> Cell
    ) where Data.Element == Element {
        let elements = Array(data)
        self.elements = elements
        ids = elements.map { $0[keyPath: id] }
        items = elements.map(item)
        self.layout = layout
        self.overscan = max(0, overscan)
        self.content = content
        onInstrumentation = nil
    }

    /// Instrumented initializer used by this package's demo. It is SPI rather
    /// than public API so applications do not acquire a diagnostics contract.
    @_spi(Instrumentation)
    public init<Data: RandomAccessCollection>(
        _ data: Data,
        id: KeyPath<Element, ID>,
        layout: Layout,
        overscan: Double = 1,
        item: (Element) -> Layout.Item,
        onInstrumentation: @escaping (LazyLayoutInstrumentationEvent) -> Void,
        @ViewBuilder content: @escaping (Element) -> Cell
    ) where Data.Element == Element {
        let elements = Array(data)
        self.elements = elements
        ids = elements.map { $0[keyPath: id] }
        items = elements.map(item)
        self.layout = layout
        self.overscan = max(0, overscan)
        self.content = content
        self.onInstrumentation = onInstrumentation
    }

    public var body: some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                // Establishes the scrollable extent without materializing anything.
                Color.clear
                    .frame(width: 1, height: snapshot?.contentHeight ?? 0)

                ForEach(placed) { item in
                    // `placed` is @State and survives the parent handing this view
                    // a new collection, but `elements` is replaced immediately
                    // and `body` runs before the onChange handler re-solves.
                    // A stale position would read out of bounds after a deletion
                    // and pair an id with the wrong element after an insertion.
                    //
                    // Skipping the cell is safe but blanks the entire window for
                    // one frame, because a single insertion invalidates *every*
                    // position at once. Falling back to the element captured at
                    // solve time keeps the right content on screen for that frame
                    // instead — same identity, just one frame stale.
                    let current = item.position < elements.count && ids[item.position] == item.id
                        ? elements[item.position]
                        : item.element
                    content(current)
                        .frame(width: item.frame.width, height: item.frame.height)
                        .offset(x: item.frame.x, y: item.frame.y)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: LayoutRect.self) { geometry in
            LayoutRect(
                x: 0,
                y: geometry.contentOffset.y + geometry.contentInsets.top,
                width: geometry.containerSize.width,
                height: geometry.containerSize.height
            )
        } action: { _, new in
            viewport = new
            onInstrumentation?(.viewport(offsetY: new.y))
            updateWindow()
        }
        .onGeometryChange(for: Double.self) { proxy in
            proxy.size.width
        } action: { width in
            guard width > 0, width != containerWidth else { return }
            containerWidth = width
            resolve(anchored: false)
        }
        // One trigger, not three: ids, metrics and layout configuration very
        // often change together, and three separate handlers would run two or
        // three full solves for a single mutation.
        .onChange(of: ResolutionInput(ids: ids, items: items, layout: layout)) { _, _ in
            resolve(anchored: true)
        }
    }

    /// Build a fresh exact snapshot, optionally shifting the scroll offset so the
    /// item the user is looking at does not move.
    private func resolve(anchored: Bool) {
        guard containerWidth > 0 else { return }
        let previous = snapshot
        let anchor = anchored ? previous?.anchor(in: viewport) : nil

        let state = Signposts.signposter.beginInterval(Signposts.solve)
        var result: LazyLayoutResult!
        let layoutDuration = ContinuousClock().measure {
            result = layout.layout(items: items, containerWidth: containerWidth)
        }
        var next: LayoutSnapshot<ID>!
        let snapshotDuration = ContinuousClock().measure {
            next = LayoutSnapshot(ids: ids, result: result, containerWidth: containerWidth)
        }
        Signposts.signposter.endInterval(Signposts.solve, state)
        onInstrumentation?(
            .solve(
                layout: layoutDuration,
                snapshot: snapshotDuration,
                total: layoutDuration + snapshotDuration
            )
        )
        snapshot = next

        // Duplicate detection is an O(n) diagnostic, so keep it out of the
        // release solve path.
        #if DEBUG
            if next.duplicateIDCount > 0, !hasWarnedAboutDuplicates {
                hasWarnedAboutDuplicates = true
                // Same failure mode as a duplicate ForEach id: view identity and
                // scroll anchoring both stop being reliable. Report once.
                Logger(subsystem: Signposts.subsystem, category: "diagnostics").fault(
                    """
                    LazyLayoutView: \(next.duplicateIDCount, privacy: .public) duplicate ids. \
                    Scroll anchoring and cell identity will be unreliable.
                    """
                )
            }
        #endif

        if let anchor, let previous,
           let adjustment = next.offsetAdjustment(keeping: anchor, alignedWith: previous),
           abs(adjustment) > 0.5
        {
            // The whole point is that nothing appears to move, so this must not
            // animate.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scrollPosition.scrollTo(y: viewport.y + adjustment)
            }
            // Adopt the requested offset locally before resolving the window.
            // `scrollTo` does not update scroll geometry synchronously, so the
            // immediately following `updateWindow()` would otherwise materialise
            // the *new* snapshot at the *old* offset — a visibly wrong window for
            // one frame, and the adjustment is largest exactly when it is most
            // noticeable (a front insertion). The real geometry callback still
            // arrives afterwards and reconciles any clamping at a content edge.
            viewport = LayoutRect(
                x: viewport.x,
                y: viewport.y + adjustment,
                width: viewport.width,
                height: viewport.height
            )
        }
        updateWindow()
    }

    private func updateWindow() {
        guard let snapshot else { return }
        let height = viewport.height > 0 ? viewport.height : 900
        let margin = height * overscan
        let window = LayoutRect(
            x: 0,
            y: viewport.y - margin,
            width: containerWidth,
            height: height + margin * 2
        )

        let state = Signposts.signposter.beginInterval(Signposts.visibility)
        var positions: [Int] = []
        let duration = ContinuousClock().measure {
            positions = snapshot.visibleItems(in: window)
        }
        Signposts.signposter.endInterval(Signposts.visibility, state)
        onInstrumentation?(
            .visibility(
                duration: duration,
                count: positions.count,
                first: positions.first,
                last: positions.last
            )
        )

        placed = positions.map {
            Placed(
                id: snapshot.ids[$0],
                position: $0,
                frame: snapshot.frames[$0],
                element: elements[$0]
            )
        }
    }
}

public extension LazyLayoutView where Element: Identifiable, ID == Element.ID {
    /// Convenience for `Identifiable` elements.
    init<Data: RandomAccessCollection>(
        _ data: Data,
        layout: Layout,
        overscan: Double = 1,
        item: (Element) -> Layout.Item,
        @ViewBuilder content: @escaping (Element) -> Cell
    ) where Data.Element == Element {
        self.init(data, id: \.id, layout: layout, overscan: overscan, item: item, content: content)
    }
}
