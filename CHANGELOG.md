# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.2] - 2026-11-11

### Fixed

- **A crash when the collection shrinks while the container is being laid out.**
  `updateWindow()` read `elements[position]` for every position in the window,
  and it runs from the scroll geometry action as well as after a solve. That
  action can fire with a freshly handed-in collection before
  `onChange(of: changeToken)` re-solves — a navigation pop laying the container
  out does exactly that — so a position from the old snapshot could index past
  the end of the new collection. `body` already guarded the same read; the window
  now does too, through `LayoutSnapshot.place(_:elements:ids:previous:)`, which
  trusts a position only where the current collection holds the same id, falls
  back to the element the item was last placed with, and otherwise leaves the
  item out until the re-solve. `StaleWindowTests` pins it.

## [0.3.0] - 2026-08-16

### Added

- **Programmatic scrolling by stable id.** `LazyLayoutPosition` is a value type
  held in `@State` and passed to the container as a binding, with
  `scrollTo(id:anchor:)` and an `init(initiallyScrolledTo:)` for deep links.

  This is not a wrapper around SwiftUI's `ScrollPosition`. Its id targeting finds
  the *view* with that identity, and in a virtualized container the item being
  named usually has no view — so there is nothing to find. The id is resolved
  through the layout instead: `LayoutSnapshot.frame(of:)` already knows where the
  item is, because that was arithmetic done before any view existed.

  The offset math is public and framework-free —
  `LayoutSnapshot.offset(toShow:anchor:viewportHeight:currentOffset:)` and
  `ScrollAnchor` — so a scroll offset can be computed and tested without
  rendering anything.

  Requests carry a token from a process-wide counter rather than a per-instance
  one. A per-instance count collides: replacing a position with a fresh instance —
  the natural way to reset scroll state for a new context — restarts it low, and a
  container that had already serviced that number would ignore the new request
  silently. `MacRuntimeScrollTests` pins this.

  A container **ignores any request made before it existed**. Servicing a request
  does not clear it, and nothing is read back, so the target a position holds is
  the last thing the caller asked for rather than where the user is — a container
  created fresh against a well-used position would otherwise jump to a target
  satisfied long ago, on every tab switch or `.id()` change. Tokens are monotonic,
  so "made before I existed" is an exact test, recorded when the container's state
  is created. `init(initiallyScrolledTo:)` is the deliberate exception.

  This is where the comparison to `ScrollPosition` stops: that type updates its
  `viewID` as the user scrolls and can restore a position. `LazyLayoutPosition`
  reads nothing back and cannot, so re-applying its target would not be
  restoration.

  Behaviour worth knowing: a request is **held** while nothing has been laid out
  yet, which is what makes a deep link fired before an async load work, and
  **dropped** once a non-empty snapshot still lacks the id, so it cannot fire
  much later when an unrelated change happens to introduce that id. Re-issuing
  always re-fires, including for an id already requested — which is what makes a
  "back to top" button work the second time it is pressed.

  A jump replaces the entire materialized window in one pass rather than after a
  scroll-geometry round trip. That means an entire window of cells is constructed
  in a single frame, which on an expensive cell will be visible; no device
  measurement of that is published here.

  The handle is write-only. Reporting the visible item back would mean the
  container writing through the caller's binding, which invalidates the caller's
  view and re-runs the container's O(n) initializer — on the scroll path.
- **`JustifiedLayout`**, the Photos/Flickr arrangement: aspect ratios preserved,
  every completed row filling the container width. Configurable target row
  height, horizontal and vertical spacing, and a last-row policy of `.natural` or
  `.justified`.

  It is the layout a grid genuinely cannot express, since the number of items in
  a row is a result of the content rather than a configured column count.
  Placement is one O(n) pass over the items — the same complexity as masonry, by
  inspection. No timing claim is made for it: every device figure in this project
  was measured with `MasonryLayout`, and none has been re-run for this layout.

  Rows close greedily and keep the item that overflowed, so a completed row is
  never taller than the target — and a single very wide image can pull its own
  row below it. The one-item look-back that would fix that is not implemented;
  it reopens the following row for a second decision for a purely aesthetic gain.

  Aspect ratios are clamped to 0.05–20 and `.fixedHeight` is treated as square.
  The clamp is load-bearing rather than cosmetic: row height is
  `available / Σratios`, so one absurd ratio drives its whole row to zero height,
  and a zero-height frame intersects no viewport — meaning one bad input would
  silently delete every other item beside it.

### Notes

No new device-performance figures were collected. The layout algorithms, the
visibility index and the steady-state visibility-query path are unchanged, so
0.2.0's measurements stand as they are rather than being restated for a release
that did not re-run them.

The solve path is *not* among the unchanged: every solve now also reads the scroll
binding and does token bookkeeping before anchoring. That is a handful of integer
comparisons against work already measured in milliseconds, and it is not on the
per-frame scrolling path — but it is a change, and calling the solve path
untouched would be wrong.

Animated mutations and horizontal scrolling remain out of scope.

## [0.2.0] - 2026-08-08

### Added

- **Self-sizing text.** `TextMeasurer` computes the height a string needs at a
  given width using CoreText — no view built, nothing rasterised, safe off the
  main actor. `TextStyle` carries the font, line limit and line spacing.

  This does *not* introduce a measure-and-correct lifecycle, and `ItemMetric`
  still has no `.measured` case. Heights are computed **before** layout, so the
  contract 0.1 was built on — sizes known before a view exists, layout as pure
  arithmetic — is unchanged. What changed is that a text height is now knowable
  up front.
- `TextStyle.init(font:in:lineLimit:lineSpacing:)`, converting a SwiftUI `Font`
  to the concrete font it will render as, via `Font.Resolved` (iOS 26 / macOS 26).
  This carries Dynamic Type through to measurement. The package floor stays at
  iOS 18 / macOS 15; the core measurer takes a `CTFont` and works there.

  **This one initializer requires Xcode 26 to build.** `Font.Resolved` is an
  iOS 26 SDK symbol, and `@available` gates runtime rather than whether a symbol
  exists to compile against, so it is behind `#if compiler(>=6.2)`. On Xcode 16
  the package still builds and `TextMeasurer` still works; only the `Font`
  convenience is absent.
- A width-aware initializer on `LazyLayoutView`, taking
  `item: (Element, Double) -> Layout.Item` and a required `recomputeOn:`
  dependency. The closure runs at solve time, when the container width is known,
  rather than at initialization. Requires `Element: Equatable`. The existing
  initializer is unchanged.

  `recomputeOn:` is required rather than optional because the closure captures
  things the container cannot see — a measurer's font, most of all. Without it a
  Dynamic Type change leaves every cell at a height measured for the old font,
  and the failure is silently stale layout rather than a compile error.
- `TextMeasurerStore`, which keeps one `TextMeasurer` alive per style and hands
  back the instance it retains. Building a measurer inside a SwiftUI `body`
  discards the cache on every parent render — worth ~65x on device — and the
  store-it-in-`.task` repair has a subtler version of the same fault, since
  `body` runs first and the instance eventually stored is a different one with an
  empty cache.
- `Overscan.items(_:)`, expressing the build-ahead window as a number of cells
  rather than a distance. On device one screen height is 56 masonry cells but 108
  timeline cells, so the same setting means very different amounts of concurrent
  work; `.items(80)` gives 81 on both.

  Resolves to the window whose count is *closest* to the budget, never below the
  genuinely visible count, ties biased downwards. Found by bisection, since count
  rises monotonically with margin.

  **It bounds concurrent cells, and that is all.** Device measurement shows it
  does not reduce hitching: timeline hitches at 32–37 per 100k pt whether it
  builds 81, 108 or 151 cells, while masonry at 81 does not hitch at all. That
  tracks construction rate — 67 items per 1,000 pt against 26 — which no window
  size can change. An earlier claim that a 2×2 measurement showed only
  large-window-plus-expensive-cell dropping frames is withdrawn; it did not
  reproduce, and those runs recorded no scroll distance.

### Changed

- `overscan:` now takes `Overscan` rather than `Double`. Numeric literals still
  mean screen heights, so `overscan: 1` and `overscan: 0.5` are unaffected;
  passing a non-literal `Double` needs `.screens(value)`.

### Fixed

- **A width change could fail to re-solve, leaving the layout stale at the
  previous width.** Cells were pinned to widths from the last solve and built as
  siblings in a `ZStack`, so they contributed to the scroll view's content width —
  and a vertical scroll view will not narrow below its content. Narrowing the
  container deadlocked: the scroll view kept reporting the old width, so the
  container never re-solved, so the cells never narrowed.

  The width is now read from a `GeometryReader` wrapping the scroll view, which
  takes the size it is *proposed* and so cannot be misled by its own content, and
  the content plane is clamped to that width so oversized cells from the previous
  solve can never widen it.

  Present since 0.1 and not previously observable, because nothing in the API
  depended on the container having re-measured. Confirmed fixed on macOS and iOS.
  See `SCROLLVIEW-WIDTH-DEADLOCK.md` in the measurements repo.

- A first attempt at the above put the cells in an `overlay` rather than a
  `ZStack`, which stopped them widening the content but silently broke absolute
  positioning: masonry cells drew on top of one another, with vertical positions
  drifting progressively. The layout output was correct throughout — every test
  asserted on frames and none on rendered geometry, so nothing caught it.
  `RenderedPositionTests` now measures the cells themselves.

- `LazyLayoutInstrumentationEvent.solve` now carries an `items` duration and
  includes it in `total`. On a cold cache item resolution is the largest
  component of a solve for measured text, and a total that omitted it
  under-reported exactly the cost worth measuring. SPI, so no supported API
  changed.

### Known limitations

Self-sizing text is practical to roughly **10,000 items**, not the 1,000,000 that
metric-driven layouts reach. Measured on an iPhone 14 Pro: **~31.5 µs per item
cold**, flat from 1,000 to 100,000, against **~470 ns cached** — a ~65x ratio.
A 10,000-item first pass is 315 ms; 100,000 is 3.1 s.

The cold figure transfers well from the M4 (~28 µs); the cached one does not
(~130 ns there), so the ~215x ratio measured on the Mac is not what a device
sees.

**Above the measurement cache there is no warm case.** A pass larger than
`cacheLimit` (20,000 entries by default) evicts its own contents, so every item
is a miss — 100,000 items measured 3,135 ms repeated against 3,115 ms cold.

`TextFidelityTests` runs only on macOS; iOS has been checked by observation,
where it never clipped but ran about 2pt per line generous.

**Timeline at 100,000 items with `.screens(1)` is not smooth on an A16** — p99
33–38 ms, 17–31% of frames over 16.7 ms, in **0.1 and 0.2 alike**. A
matched-scroll A/B against the 0.1.0 tag found the two builds' ranges
overlapping, so this is not a 0.2 regression. An earlier 0.1 figure of p99
17.49 ms and 26 hitches is not reproducible by 0.1's own binary and has been
withdrawn. The cost tracks cells constructed per second, not concurrent count,
so no overscan setting changes it.

Everything listed under 0.1 below still applies except the sizing one.

## [0.1.0] - 2026-08-02

### Added

- `LazyLayoutAlgorithm`, the layout protocol. Maps per-item inputs to frames
  without constructing views. `Item` is an associated type so a layout can take
  whatever input it actually needs rather than a fixed height.
- `LazyLayoutView`, a vertically scrolling container that materializes only the
  items intersecting the viewport, with configurable overscan.
- `VerticalVisibilityIndex`, a uniform bucket index over arbitrary frames.
  Compressed-sparse-row storage, an oversized list so tall items are not
  duplicated into every bucket, and no assumption that frames are sorted,
  non-overlapping, or positive-coordinate.
- `LayoutSnapshot`, an exact eager solve keyed by caller-supplied identity, with
  visibility queries and identity-based scroll anchoring. Anchor lookup uses a
  contiguous identity scan rather than constructing a full hash table.
- `MasonryLayout` and `TimelineLayout` reference implementations.
- Instruments signposts under `com.lazylayoutkit` / `layout`: `solve` and
  `visibility`.
- A Release benchmark for the shipping generic visibility index and snapshot
  path, plus a physical-device demo with frame, solve, snapshot, query, and
  materialization diagnostics.

### Known limitations in 0.1

Vertical scrolling only; item sizes must be known before a view exists;
collection changes are unanimated; snapshots are exact and eager, so unbounded
collections are unsupported; no custom visibility-query override. See the README.
