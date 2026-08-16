import os
import SwiftUI

/// Internal measurement events consumed by the benchmark/demo harness.
/// The SPI keeps diagnostics out of the supported 0.1 API surface.
@_spi(Instrumentation)
public enum LazyLayoutInstrumentationEvent: Sendable {
    case solve(items: Duration, layout: Duration, snapshot: Duration, total: Duration)
    /// Time to decide what to build: resolving the overscan window *and* querying
    /// it. The two are reported together because an `Overscan/items(_:)` budget
    /// resolves its window by bisection — about a dozen visibility queries — and
    /// timing only the final lookup would report a fraction of the real cost.
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
/// Sizes are still known before any view exists — that is what makes
/// virtualization possible. For content whose size depends on the width, such as
/// text, use the width-aware initializer, which defers the item mapping to solve
/// time and pairs with ``TextMeasurer``:
///
/// ```swift
/// @State private var measurers = TextMeasurerStore()
/// // ...
/// let style = TextStyle(font: .body, in: fontContext, lineLimit: 3)
/// let measurer = measurers.measurer(for: style)
///
/// LazyLayoutView(posts, layout: MasonryLayout(columns: 1), recomputeOn: style) { post, width in
///     .fixedHeight(measurer.height(of: post.body, width: width))
/// } content: { post in
///     Text(post.body).lineLimit(3)
/// }
/// ```
///
/// ## What it still does not do
///
/// - Scrolls **vertically** only. A layout may place items anywhere across the
///   container's width; the scroll axis and the visibility index are y.
/// - There is no measure-and-correct pass. Sizes are computed before layout, not
///   observed from rendered views and reconciled afterwards.
/// - Collection changes are applied **correctly but without animation**. Scroll
///   position is preserved by anchoring on a stable id; insertion and removal do
///   not animate.
///
/// ## Cost note
///
/// `init` maps the collection once to extract ids, so creating this view is O(n)
/// in the number of items. That happens when the *parent* re-renders, not while
/// scrolling — scrolling only re-runs `body`, which iterates the on-screen window.
/// The width-aware initializer additionally runs its item closure for every
/// element on each width change; see its documentation for what that costs with
/// measured text.
public struct LazyLayoutView<Element, ID: Hashable & Sendable, Layout: LazyLayoutAlgorithm, Cell: View>: View {
    private let elements: [Element]
    private let ids: [ID]
    private let items: ItemSource
    private let changeToken: ChangeToken
    private let layout: Layout
    private let overscan: Overscan
    /// The caller's scroll handle, if they asked for one.
    ///
    /// Read but never written. Writing would invalidate the caller's state and
    /// re-run this view's initializer, which is O(n); see ``LazyLayoutPosition``.
    private let position: Binding<LazyLayoutPosition<ID>>?
    private let content: (Element) -> Cell
    private let onInstrumentation: ((LazyLayoutInstrumentationEvent) -> Void)?

    /// Where each item's layout input comes from.
    ///
    /// Most layout inputs — an aspect ratio, a date range — are properties of the
    /// element and can be extracted once. Text is not: its height depends on the
    /// width it will be laid out in, which does not exist until the container has
    /// been measured. So the width-aware case defers the mapping to solve time,
    /// when the width is known.
    private enum ItemSource {
        case fixed([Layout.Item])
        case widthAware((Element, Double) -> Layout.Item)

        func resolve(for elements: [Element], containerWidth: Double) -> [Layout.Item] {
            switch self {
            case let .fixed(items): items
            case let .widthAware(make): elements.map { make($0, containerWidth) }
            }
        }
    }

    /// What the container watches to know a re-solve is needed.
    ///
    /// The fixed path can watch the mapped items directly. The width-aware path
    /// cannot — the items do not exist at `body` time, and computing them there to
    /// compare would run the item closure for the whole collection on every frame,
    /// which for text means measuring it. So it watches the elements instead,
    /// which is the thing the items are derived from. That is why the width-aware
    /// initializer requires `Element: Equatable`.
    ///
    /// The payload is type-erased because the two paths compare different types,
    /// and `onChange(of:)` needs one `Equatable` value.
    private struct ChangeToken: Equatable {
        let ids: [ID]
        let payload: AnyEquatable
        let layout: Layout
    }

    /// The width-aware path's change payload: the elements the items derive
    /// from, plus whatever the caller declared as an outside dependency.
    private struct ElementsAndTrigger<E: Equatable, Trigger: Equatable>: Equatable {
        let elements: [E]
        let trigger: Trigger
    }

    private struct AnyEquatable: Equatable {
        private let value: Any
        private let isEqual: (Any) -> Bool

        init<Wrapped: Equatable>(_ value: Wrapped) {
            self.value = value
            isEqual = { other in
                guard let other = other as? Wrapped else { return false }
                return other == value
            }
        }

        static func == (lhs: AnyEquatable, rhs: AnyEquatable) -> Bool {
            lhs.isEqual(rhs.value)
        }
    }

    @State private var snapshot: LayoutSnapshot<ID>?
    @State private var containerWidth: Double = 0
    @State private var viewport = LayoutRect(x: 0, y: 0, width: 0, height: 0)
    @State private var placed: [Placed] = []
    @State private var scrollPosition = ScrollPosition(idType: ID.self)
    @State private var hasWarnedAboutDuplicates = false
    /// The last ``LazyLayoutPosition/token`` taken from the binding. Zero means
    /// nothing has been serviced; real tokens start at 1.
    @State private var servicedToken: UInt64 = 0
    /// A target adopted from the binding that no snapshot could resolve yet.
    @State private var pendingTarget: LazyLayoutPosition<ID>.Target?
    /// Whether ``pendingTarget`` came from an initial request, and so spends the
    /// birth-token exemption when it is applied.
    @State private var pendingIsInitial = false
    /// The highest request token issued when this container's state was created.
    ///
    /// A `@State` default is evaluated once per view identity, at the moment the
    /// state is set up — before any `onChange` can run — which is what makes this
    /// an exact "when was I born" marker rather than a racy one.
    @State private var birthToken: UInt64 = currentScrollRequestToken()

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
    ///   - position: An optional handle for scrolling to an item by its id. See
    ///     ``LazyLayoutPosition``.
    ///   - item: The layout input for an element. Must be cheap: it is called
    ///     once per element whenever the view is created.
    ///   - content: The view for an element. Called only for on-screen items.
    public init<Data: RandomAccessCollection>(
        _ data: Data,
        id: KeyPath<Element, ID>,
        layout: Layout,
        overscan: Overscan = .default,
        position: Binding<LazyLayoutPosition<ID>>? = nil,
        item: (Element) -> Layout.Item,
        @ViewBuilder content: @escaping (Element) -> Cell
    ) where Data.Element == Element {
        let elements = Array(data)
        let mapped = elements.map(item)
        self.elements = elements
        ids = elements.map { $0[keyPath: id] }
        items = .fixed(mapped)
        changeToken = ChangeToken(
            ids: elements.map { $0[keyPath: id] },
            payload: AnyEquatable(mapped),
            layout: layout
        )
        self.layout = layout
        self.overscan = overscan
        self.position = position
        self.content = content
        onInstrumentation = nil
    }

    /// Creates a container whose item sizes depend on the width they'll be laid
    /// out in — self-sizing text, most of all.
    ///
    /// The difference from ``init(_:id:layout:overscan:position:item:content:)`` is when
    /// `item` runs. There it runs once, at initialization. Here it runs at solve
    /// time, once the container has been measured, and again whenever the width
    /// changes. That is the only way a text height can be correct, because it is a
    /// function of the width.
    ///
    /// ```swift
    /// LazyLayoutView(posts, layout: MasonryLayout(columns: 1)) { post, width in
    ///     .fixedHeight(measurer.height(of: post.body, width: width))
    /// } content: { post in
    ///     Text(post.body).lineLimit(3)
    /// }
    /// ```
    ///
    /// ## Cost
    ///
    /// `item` is called for **every** element on every width change, not just the
    /// visible ones — the layout has to place the whole collection to know how
    /// tall the content is. With ``TextMeasurer`` that is a cache hit for anything
    /// measured before, at about 470 ns each on device; the expensive pass is the
    /// first one at a given width, at roughly 31 µs per item.
    ///
    /// That puts self-sizing text at a different scale from the rest of this
    /// package: comfortable to about **10,000 items**, against 1,000,000 for
    /// layouts driven by ``ItemMetric``. Above a few thousand, measure with
    /// ``TextMeasurer/heights(of:width:chunkSize:)`` before handing the data over,
    /// so the first pass happens off the main actor instead of inside a solve.
    ///
    /// ## Declaring what else invalidates a size
    ///
    /// The closure captures things the container cannot see. A ``TextMeasurer``
    /// carries a font, a line limit and line spacing, none of which appear in the
    /// elements, the ids or the layout — so when the user changes their text size,
    /// every measured height becomes wrong while nothing the container watches has
    /// moved.
    ///
    /// `recomputeOn` is that missing dependency, and it is required rather than
    /// optional because forgetting it produces silently stale layout rather than a
    /// compile error. For measured text, pass the style:
    ///
    /// ```swift
    /// @Environment(\.fontResolutionContext) private var fontContext
    /// @State private var measurers = TextMeasurerStore()
    ///
    /// let style = TextStyle(font: .body, in: fontContext, lineLimit: 3)
    /// let measurer = measurers.measurer(for: style)
    ///
    /// LazyLayoutView(posts, layout: layout, recomputeOn: style) { post, width in
    ///     .fixedHeight(measurer.height(of: post.body, width: width))
    /// } content: { post in
    ///     Text(post.body).font(.body).lineLimit(3)
    /// }
    /// ```
    ///
    /// ``TextStyle`` compares by value, so an equal style costs nothing — passing
    /// it on every render does not re-measure anything.
    ///
    /// - Parameters:
    ///   - data: The items to lay out.
    ///   - id: Key path to a stable identity.
    ///   - layout: The placement algorithm.
    ///   - overscan: How much content to build beyond the viewport.
    ///   - position: An optional handle for scrolling to an item by its id. See
    ///     ``LazyLayoutPosition``.
    ///   - trigger: Anything outside the collection that changes what `item`
    ///     returns. Changing it re-solves; an equal value does nothing.
    ///   - item: The layout input for an element at a given container width.
    ///   - content: The view for an element. Called only for on-screen items.
    public init<Data: RandomAccessCollection>(
        _ data: Data,
        id: KeyPath<Element, ID>,
        layout: Layout,
        overscan: Overscan = .default,
        position: Binding<LazyLayoutPosition<ID>>? = nil,
        recomputeOn trigger: some Equatable,
        item: @escaping (Element, Double) -> Layout.Item,
        @ViewBuilder content: @escaping (Element) -> Cell
    ) where Data.Element == Element, Element: Equatable {
        let elements = Array(data)
        self.elements = elements
        ids = elements.map { $0[keyPath: id] }
        items = .widthAware(item)
        changeToken = ChangeToken(
            ids: elements.map { $0[keyPath: id] },
            payload: AnyEquatable(ElementsAndTrigger(elements: elements, trigger: trigger)),
            layout: layout
        )
        self.layout = layout
        self.overscan = overscan
        self.position = position
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
        overscan: Overscan = .default,
        position: Binding<LazyLayoutPosition<ID>>? = nil,
        item: (Element) -> Layout.Item,
        onInstrumentation: @escaping (LazyLayoutInstrumentationEvent) -> Void,
        @ViewBuilder content: @escaping (Element) -> Cell
    ) where Data.Element == Element {
        let elements = Array(data)
        let mapped = elements.map(item)
        self.elements = elements
        ids = elements.map { $0[keyPath: id] }
        items = .fixed(mapped)
        changeToken = ChangeToken(
            ids: elements.map { $0[keyPath: id] },
            payload: AnyEquatable(mapped),
            layout: layout
        )
        self.layout = layout
        self.overscan = overscan
        self.position = position
        self.content = content
        self.onInstrumentation = onInstrumentation
    }

    /// Instrumented width-aware initializer, for the demo's text scenarios.
    @_spi(Instrumentation)
    public init<Data: RandomAccessCollection>(
        _ data: Data,
        id: KeyPath<Element, ID>,
        layout: Layout,
        overscan: Overscan = .default,
        position: Binding<LazyLayoutPosition<ID>>? = nil,
        recomputeOn trigger: some Equatable,
        item: @escaping (Element, Double) -> Layout.Item,
        onInstrumentation: @escaping (LazyLayoutInstrumentationEvent) -> Void,
        @ViewBuilder content: @escaping (Element) -> Cell
    ) where Data.Element == Element, Element: Equatable {
        let elements = Array(data)
        self.elements = elements
        ids = elements.map { $0[keyPath: id] }
        items = .widthAware(item)
        changeToken = ChangeToken(
            ids: elements.map { $0[keyPath: id] },
            payload: AnyEquatable(ElementsAndTrigger(elements: elements, trigger: trigger)),
            layout: layout
        )
        self.layout = layout
        self.overscan = overscan
        self.position = position
        self.content = content
        self.onInstrumentation = onInstrumentation
    }

    public var body: some View {
        // The width is read from a `GeometryReader` wrapping the scroll view
        // rather than from the scroll view itself, and the content plane is then
        // clamped to that width. Both halves are load-bearing, and each fixes a
        // bug the other one caused.
        //
        // A vertical scroll view treats its content width as a floor it will not
        // go below. Cells are pinned to widths from the last solve, so narrowing
        // the container deadlocks: the scroll view keeps reporting the old width
        // because last solve's cells hold it open, so the container never
        // re-solves, so the cells never narrow. Measured on macOS: content
        // holding 500pt cells never reported a change to 300pt.
        //
        // A `GeometryReader` takes the size it is *proposed* and is unaffected by
        // what is inside it, so it always sees the true available width. Clamping
        // the content plane to that width then means oversized cells from the
        // previous solve can overflow visually for one frame but can never widen
        // the content, so the scroll view is free to narrow.
        //
        // The cells stay in a `ZStack`. An earlier version put them in an
        // `overlay` on the spacer, which also stops them widening the content —
        // but it silently broke absolute positioning, drawing masonry cells on
        // top of each other. `WidthAndPositionTests` covers both failures.
        GeometryReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    // Establishes the scrollable extent without materializing
                    // anything.
                    Color.clear
                        .frame(width: 1, height: snapshot?.contentHeight ?? 0)

                    ForEach(placed) { item in
                        // `placed` is @State and survives the parent handing this
                        // view a new collection, but `elements` is replaced
                        // immediately and `body` runs before the onChange handler
                        // re-solves. A stale position would read out of bounds
                        // after a deletion and pair an id with the wrong element
                        // after an insertion.
                        //
                        // Skipping the cell is safe but blanks the entire window
                        // for one frame, because a single insertion invalidates
                        // *every* position at once. Falling back to the element
                        // captured at solve time keeps the right content on
                        // screen for that frame instead — same identity, just one
                        // frame stale.
                        let current = item.position < elements.count && ids[item.position] == item.id
                            ? elements[item.position]
                            : item.element
                        content(current)
                            .frame(width: item.frame.width, height: item.frame.height)
                            .offset(x: item.frame.x, y: item.frame.y)
                    }
                }
                .frame(width: proxy.size.width, alignment: .topLeading)
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
            .onChange(of: proxy.size.width, initial: true) { _, width in
                guard width > 0, width != containerWidth else { return }
                containerWidth = width
                resolve(anchored: false)
            }
            // One trigger, not three: ids, metrics and layout configuration very
            // often change together, and three separate handlers would run two or
            // three full solves for a single mutation.
            .onChange(of: changeToken) { _, _ in
                resolve(anchored: true)
            }
            // Deliberately not `initial: true`. Two initial handlers on one view
            // have no defined relative order, and the width handler above is the
            // one that produces the first snapshot. A request that predates any
            // layout is applied by that first solve instead — see
            // `applyScrollRequest(in:)`.
            .onChange(of: position?.wrappedValue) { _, _ in
                guard let snapshot else { return }
                if applyScrollRequest(in: snapshot) {
                    updateWindow()
                }
            }
        }
    }

    /// Adopts any new request from the caller's binding, then tries to satisfy
    /// whatever is outstanding against `snapshot`. Returns whether an offset was
    /// written.
    ///
    /// ## Why a generation rather than clearing the request
    ///
    /// Servicing a request by writing `nil` back through the binding would mutate
    /// the caller's state, re-run their `body`, and re-run this view's O(n)
    /// initializer — during a scroll, in the worst case. So the request stays put
    /// and the container remembers what it has already seen.
    ///
    /// ## Absent targets
    ///
    /// An empty snapshot is the genuine "nothing has been laid out yet" state: the
    /// data has not arrived, or the width is still zero. A request made then is
    /// held, which is what makes a deep link fired before an async load work.
    ///
    /// A *non-empty* snapshot that does not contain the id means the id is not in
    /// this collection. Holding on would mean a jump firing much later, when some
    /// unrelated change happened to introduce that id, so it is dropped instead.
    ///
    /// ## Stale requests
    ///
    /// A position outlives the containers that read it, and servicing a request
    /// does not clear it. So a container created fresh against a well-used
    /// position finds a target that was satisfied long ago — and since nothing is
    /// ever read back, that target is the last thing the *caller asked for*, not
    /// where the user actually was. Acting on it would jump somewhere arbitrary on
    /// every tab switch or `.id()` change.
    ///
    /// Tokens are monotonic, so "made before I existed" is exactly
    /// `token <= birthToken`, and those are retired unread. The single exception is
    /// ``LazyLayoutPosition/init(initiallyScrolledTo:anchor:)``, whose whole
    /// purpose is to be honoured by a container that did not yet exist — and which
    /// is spent once a container has acted on it, so it cannot re-open at a deep
    /// link the user has already read past.
    @discardableResult
    private func applyScrollRequest(in snapshot: LayoutSnapshot<ID>) -> Bool {
        guard let value = position?.wrappedValue else {
            // The caller detached the binding. Anything captured from it was their
            // intent for a handle they have since taken away, so it is withdrawn
            // rather than left to fire whenever the data happens to arrive.
            pendingTarget = nil
            return false
        }
        if value.token != servicedToken {
            servicedToken = value.token
            // `cancelScroll()` sets `target` to nil, which also clears anything
            // still deferred.
            let isLive = value.token > birthToken
                || (value.isInitialRequest && !isInitialRequestConsumed(value.token))
            pendingTarget = isLive ? value.target : nil
            pendingIsInitial = isLive && value.isInitialRequest
        }
        guard let target = pendingTarget else { return false }

        guard let y = snapshot.offset(
            toShow: target.id,
            anchor: target.anchor,
            viewportHeight: effectiveViewport.height,
            currentOffset: viewport.y
        ) else {
            if snapshot.count > 0 {
                pendingTarget = nil
            }
            return false
        }
        pendingTarget = nil
        if pendingIsInitial {
            // Spend the birth-token exemption: this deep link has now been shown.
            markInitialRequestConsumed(servicedToken)
            pendingIsInitial = false
        }
        scroll(toContentPlaneY: y)
        // Adopt the destination locally before the window is resolved. `scrollTo`
        // is not synchronous, so without this the following `updateWindow()` would
        // build the *new* offset's neighbourhood at the *old* offset — for a small
        // anchoring nudge that is one wrong frame, but for a jump across a million
        // items it is a blank screen until the geometry callback arrives.
        viewport = LayoutRect(
            x: viewport.x,
            y: y,
            width: viewport.width,
            height: viewport.height
        )
        return true
    }

    /// Moves the scroll view so the content plane's `y` sits at the top of the
    /// visible region.
    ///
    /// `y` is in the content plane — the space the geometry callback reports, where
    /// 0 means "the top of the content is at the top of what the user can see".
    /// `scrollTo(y:)` turns out to take that same space, content insets included:
    /// a hosted test that jumps to an item under a 120pt `safeAreaInset` lands it
    /// at the top of the *visible* region, not 120pt under the inset. Converting
    /// by the inset here was tried and is wrong — it moves the target by exactly
    /// one inset height.
    ///
    /// Anchoring writes through here too, and always did the same thing: its
    /// adjustment is a delta, so any constant offset between the two spaces would
    /// have cancelled anyway.
    private func scroll(toContentPlaneY y: Double) {
        // The whole point is that this does not look like motion.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollPosition.scrollTo(y: y)
        }
    }

    /// The viewport to reason about, with a plausible phone height standing in
    /// before the scroll view has reported any geometry.
    private var effectiveViewport: LayoutRect {
        viewport.height > 0
            ? viewport
            : LayoutRect(x: 0, y: viewport.y, width: containerWidth, height: 900)
    }

    /// Build a fresh exact snapshot, optionally shifting the scroll offset so the
    /// item the user is looking at does not move.
    private func resolve(anchored: Bool) {
        guard containerWidth > 0 else { return }
        let previous = snapshot

        let state = Signposts.signposter.beginInterval(Signposts.solve)
        // For the width-aware path this is where the item closure runs, and for
        // text it is where measurement happens. It is timed separately and
        // included in the total: on a cold cache it is the single largest
        // component of a solve, and a "total" that omitted it would under-report
        // exactly the number this instrumentation exists to capture.
        var resolvedItems: [Layout.Item]!
        let itemsDuration = ContinuousClock().measure {
            resolvedItems = items.resolve(for: elements, containerWidth: containerWidth)
        }
        var result: LazyLayoutResult!
        let layoutDuration = ContinuousClock().measure {
            result = layout.layout(items: resolvedItems, containerWidth: containerWidth)
        }
        var next: LayoutSnapshot<ID>!
        let snapshotDuration = ContinuousClock().measure {
            next = LayoutSnapshot(ids: ids, result: result, containerWidth: containerWidth)
        }
        Signposts.signposter.endInterval(Signposts.solve, state)
        onInstrumentation?(
            .solve(
                items: itemsDuration,
                layout: layoutDuration,
                snapshot: snapshotDuration,
                total: itemsDuration + layoutDuration + snapshotDuration
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

        // An explicit request wins over anchoring: the caller said where to be,
        // and applying both would add two offsets together. This also means the
        // anchor scan is skipped entirely when a scroll fires — and because the
        // condition short-circuits, `viewport` is still the pre-solve one
        // whenever `anchor(in:)` is reached.
        if !applyScrollRequest(in: next),
           anchored, let previous,
           let anchor = previous.anchor(in: viewport),
           let adjustment = next.offsetAdjustment(keeping: anchor, alignedWith: previous),
           abs(adjustment) > 0.5
        {
            scroll(toContentPlaneY: viewport.y + adjustment)
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
        // Before the scroll view reports geometry there is no viewport to widen,
        // so assume a plausible phone height rather than building nothing.
        let measured = effectiveViewport

        let state = Signposts.signposter.beginInterval(Signposts.visibility)
        var positions: [Int] = []
        // Window resolution is inside the interval. For `.screens` it is
        // arithmetic and costs nothing; for `.items` it is a bisection over a
        // dozen visibility queries, and excluding it would make the reported
        // query cost a small fraction of the work actually done.
        let duration = ContinuousClock().measure {
            let window = snapshot.window(
                for: measured,
                overscan: overscan,
                containerWidth: containerWidth
            )
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
        overscan: Overscan = .default,
        position: Binding<LazyLayoutPosition<ID>>? = nil,
        item: (Element) -> Layout.Item,
        @ViewBuilder content: @escaping (Element) -> Cell
    ) where Data.Element == Element {
        self.init(
            data,
            id: \.id,
            layout: layout,
            overscan: overscan,
            position: position,
            item: item,
            content: content
        )
    }

    /// Convenience for `Identifiable` elements whose sizes depend on the
    /// container width — see
    /// the width-aware initializer.
    init<Data: RandomAccessCollection>(
        _ data: Data,
        layout: Layout,
        overscan: Overscan = .default,
        position: Binding<LazyLayoutPosition<ID>>? = nil,
        recomputeOn trigger: some Equatable,
        item: @escaping (Element, Double) -> Layout.Item,
        @ViewBuilder content: @escaping (Element) -> Cell
    ) where Data.Element == Element, Element: Equatable {
        self.init(
            data,
            id: \.id,
            layout: layout,
            overscan: overscan,
            position: position,
            recomputeOn: trigger,
            item: item,
            content: content
        )
    }
}
