import Synchronization

/// Process-wide source of request tokens.
///
/// Tokens have to be unique across *every* position instance, not just within
/// one. A per-instance counter collides: replacing a position with a fresh one —
/// a natural way to reset scroll state for a new context — restarts the count at
/// 1, and a container that had already serviced its own request number 1 would
/// see an equal value and silently ignore the new request.
private let scrollRequestTokens = Atomic<UInt64>(0)

private func nextScrollRequestToken() -> UInt64 {
    // Wrapping: a counter that cannot trap matters more than one that stays
    // meaningful past 2^64 requests.
    scrollRequestTokens.wrappingAdd(1, ordering: .relaxed).newValue
}

/// Initial requests that some container has already acted on.
///
/// ``LazyLayoutPosition/init(initiallyScrolledTo:anchor:)`` is exempt from the
/// "made before I existed" rule, because being honoured by a container that does
/// not yet exist is the whole point of it. Without this the exemption would be
/// permanent: the position keeps its target forever, so *every* container built
/// against it would re-open at that item, long after the first one did and the
/// user moved on — the very thing the rule exists to prevent.
///
/// So the exemption is spent on first use. Keyed by token, which is unique per
/// request, and recorded only when a container actually scrolls — a request still
/// waiting for data has not been used up.
///
/// One `UInt64` per honoured deep link, for the life of the process. Deep links
/// are rare enough for that to be nothing, and a high-water mark would be wrong:
/// two positions can be honoured out of order, and the older one is not spent by
/// the younger one being used.
private let consumedInitialTokens = Mutex<Set<UInt64>>([])

func markInitialRequestConsumed(_ token: UInt64) {
    consumedInitialTokens.withLock { _ = $0.insert(token) }
}

func isInitialRequestConsumed(_ token: UInt64) -> Bool {
    consumedInitialTokens.withLock { $0.contains(token) }
}

/// The highest token issued so far, without issuing one.
///
/// A container records this when its state is created, which lets it tell a
/// request made *after* it existed — a live one to act on — from one left over
/// from an earlier container's lifetime.
func currentScrollRequestToken() -> UInt64 {
    scrollRequestTokens.load(ordering: .relaxed)
}

/// A handle for scrolling a ``LazyLayoutView`` to an item by its stable id.
///
/// Hold one in `@State` and hand the container a binding to it:
///
/// ```swift
/// @State private var position = LazyLayoutPosition<Photo.ID>()
///
/// var body: some View {
///     LazyLayoutView(photos, layout: JustifiedLayout(), position: $position) { photo in
///         .aspectRatio(photo.aspectRatio)
///     } content: { photo in
///         PhotoCell(photo)
///     }
///     .toolbar {
///         Button("Latest") { position.scrollTo(id: photos[0].id, anchor: .center) }
///     }
/// }
/// ```
///
/// ## Why this is not SwiftUI's `ScrollPosition`
///
/// `ScrollPosition`'s id targeting finds the *view* with that identity. In a
/// virtualized container the item you want to reach usually has no view — that is
/// the entire point — so there is nothing for it to find. This resolves the id
/// through the layout instead: ``LayoutSnapshot/frame(of:)`` gives the item's
/// geometry, computed long before any view existed, and
/// ``LayoutSnapshot/offset(toShow:anchor:viewportHeight:currentOffset:)->Double?`` turns
/// that into a scroll offset. Jumping to item 900,000 costs one identity scan.
///
/// ## A request is not a record of where the user is
///
/// This carries requests *to* the container and never reads anything back, so the
/// target it holds is the last thing you asked for — not where the collection
/// actually ended up. The moment the user scrolls, the two diverge, and nothing
/// here notices.
///
/// That is what separates it from SwiftUI's `ScrollPosition`, which updates its
/// `viewID` as the user scrolls and so can genuinely restore a position. This
/// cannot, and does not try to.
///
/// It follows that a stale target must not be re-applied. Servicing a request
/// does not clear it — the container records which token it handled rather than
/// writing back through your binding — so a container created fresh against a
/// long-used position would otherwise jump to whatever was last asked for, which
/// by then is very likely nowhere near where the user was. Containers therefore
/// **ignore any request minted before they existed**, and act only on ones made
/// while they were alive.
///
/// To have a *new* container open at an item, say so explicitly with
/// ``init(initiallyScrolledTo:anchor:)``. That is the one form a container will
/// honour at birth, and it is spent once honoured — so it opens the collection,
/// it does not keep dragging the user back there.
///
/// ## What it does not do in 0.3
///
/// This is a write-only handle: it carries requests to the container and reports
/// nothing back. There is no `isScrollPending` and no "which item is on screen".
/// Both would mean the container writing through your binding, which invalidates
/// your view and re-runs the container's initializer — O(n) in the collection —
/// and it would do so while the user is scrolling. Read-back needs a design that
/// does not sit on that path.
///
/// Programmatic scrolls are also immediate rather than animated. Animating an
/// offset across content that was never built would animate through blank space.
public struct LazyLayoutPosition<ID: Hashable & Sendable>: Equatable, Sendable {
    /// A request the caller has made and the container has not yet serviced.
    struct Target: Equatable, Sendable {
        let id: ID
        let anchor: ScrollAnchor
    }

    private(set) var target: Target?

    /// Identifies this specific request, uniquely for the lifetime of the process.
    ///
    /// Set afresh by every mutating call, ``cancelScroll()`` included. Two things
    /// depend on it:
    ///
    /// - A *repeated* request fires. Asking twice for the same id with the same
    ///   anchor produces an equal ``target``, so a container comparing only the
    ///   value would ignore the second tap — exactly the case where the user has
    ///   scrolled away and wants to go back.
    /// - A *replaced* position fires. The token is drawn from a process-wide
    ///   counter rather than one per instance, so a brand new position cannot
    ///   accidentally present a value the container has already serviced.
    /// - A *stale* request does not fire. Because the counter is monotonic, a
    ///   container that recorded the highest token at its own birth can tell a
    ///   live request from one left behind by an earlier container.
    ///
    /// The container records which token it has serviced rather than clearing the
    /// request, because clearing would mean writing to caller state.
    private(set) var token: UInt64 = 0

    /// Whether ``target`` came from ``init(initiallyScrolledTo:anchor:)`` rather
    /// than a call on a live position. Only this form is honoured by a container
    /// that did not exist when the request was made, and only until some container
    /// has actually acted on it.
    private(set) var isInitialRequest = false

    /// A position with no request outstanding.
    public init() {}

    /// A position that is already asking for `id` before anything has been laid
    /// out.
    ///
    /// Use this for a deep link, where the destination is known before the view
    /// appears. The request is honoured by the first solve, so the container
    /// opens at the item rather than opening at the top and jumping.
    ///
    /// It also survives data arriving late: while the collection is empty there is
    /// nothing to resolve against, and the request is held rather than discarded.
    ///
    /// This is the only form a container honours at *birth*. A plain
    /// ``scrollTo(id:anchor:)`` issued before the container existed is treated as
    /// left over from an earlier one and ignored — see the note on the type.
    ///
    /// The exemption is **used once**. After a container has actually scrolled to
    /// it, this behaves like any other spent request: a later container built
    /// against the same position starts at the top rather than dragging the user
    /// back to a deep link they have already read past. Call
    /// ``scrollTo(id:anchor:)`` if you want to go there again.
    public init(initiallyScrolledTo id: ID, anchor: ScrollAnchor = .top) {
        target = Target(id: id, anchor: anchor)
        token = nextScrollRequestToken()
        isInitialRequest = true
    }

    /// Scrolls so that `id` sits at `anchor`.
    ///
    /// Nothing happens if `id` is not in the collection *and* the container has
    /// already laid something out — a request for an item that does not exist is
    /// dropped rather than left waiting, so it cannot fire unexpectedly later when
    /// some unrelated change happens to introduce that id. If your data loads in
    /// pages, re-issue the request when the page arrives; calling this again
    /// always re-fires.
    public mutating func scrollTo(id: ID, anchor: ScrollAnchor = .top) {
        target = Target(id: id, anchor: anchor)
        token = nextScrollRequestToken()
        isInitialRequest = false
    }

    /// Withdraws a request that has not been serviced yet.
    ///
    /// For a deep link the user navigated away from before the data arrived.
    public mutating func cancelScroll() {
        target = nil
        token = nextScrollRequestToken()
        isInitialRequest = false
    }
}
