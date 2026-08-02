# LazyLayoutKit

Write an arbitrary custom layout — masonry, timeline, calendar, board — and have SwiftUI build views only for what's on screen.

SwiftUI makes you choose. [`Layout`](https://developer.apple.com/documentation/swiftui/layout) gives you arbitrary geometry but is eager: every subview is constructed and measured, so it falls over past a few thousand items. `LazyVStack` and `LazyVGrid` are lazy but their geometry is fixed — a vertical run, or a uniform grid. There is nothing in between, and in between is where photo grids, feeds, calendars and boards live.

Asked at the [WWDC26 SwiftUI Group Lab](https://developer.apple.com/videos/play/wwdc2026/8006/) whether custom layouts can be lazy, Apple's answer was: not today, the `Layout` protocol is eager-only, file a Feedback.

```swift
LazyLayoutView(photos, layout: MasonryLayout(columns: 3)) { photo in
    .aspectRatio(photo.width / photo.height)   // layout input — no view built
} content: { photo in
    PhotoCell(photo)                           // called only when on screen
}
```

## How it works

**The layout function never sees a view.** That is the entire idea. A `LazyLayoutAlgorithm` maps per-item *inputs* to frames using arithmetic alone, so frames for a hundred thousand items cost a few milliseconds and no views at all. Only the frames intersecting the viewport become views.

```swift
public protocol LazyLayoutAlgorithm: Equatable, Sendable {
    associatedtype Item: Equatable & Sendable
    func layout(items: [Item], containerWidth: Double) -> LazyLayoutResult
}
```

`Item` is an associated type on purpose. A masonry grid wants an aspect ratio; a timeline wants a start and a duration; a calendar wants a date range. Fixing the input to "height" would have made this a masonry library wearing a general name.

Visibility is answered by a **uniform bucket index** built over whatever frames the layout produced — compressed-sparse-row, contiguous, no per-bucket hashing. It assumes nothing about the layout's structure, so frames may overlap, be unordered, or use negative coordinates. Items spanning many buckets go on a separate oversized list instead of being duplicated into each one, which keeps worst-case memory linear.

Scroll position is preserved across collection changes by **anchoring on caller-supplied identity**, never on index. Insert one item at the front and every index shifts; anchoring by index would silently start holding a different item still.

## Two reference layouts

`MasonryLayout` — fixed columns, each item placed in whichever is shortest.

`TimelineLayout` — intervals on a vertical time axis, overlapping ones split into lanes. It exists mostly to keep the protocol honest: its items overlap vertically and its frames are *not* monotonic in y in item order, so any machinery that had quietly assumed masonry's shape would break on it. There is a test asserting exactly that.

## Requirements

iOS 18 · macOS 15. The container is built on `ScrollGeometry` / `onScrollGeometryChange`, which is where those land. Nothing here needs iOS 27.

```swift
.package(url: "https://github.com/Dave861/LazyLayoutKit.git", from: "0.1.0")
```

## What 0.1 deliberately does not do

Narrow beats vague. Each of these is absent because doing it properly is real work, not because it was forgotten:

- **Vertical scrolling only.** A layout may place items anywhere across the width, but the scroll axis and the index are y. Horizontal and two-axis canvases are a different index design.
- **No intrinsic measurement.** Item size must be known before the view exists. There is no `.estimated` or `.measured` metric, because those names imply a measure-and-correct lifecycle this version does not implement. Text inside a caller-sized card is fine; text that determines its own height is not supported yet.
- **No animated insertion or removal.** Collection changes are applied correctly and preserve scroll position, but they do not animate.
- **Exact eager snapshots.** Every frame is computed up front. There is no chunking or estimation, so unbounded collections are out of scope.
- **No custom query overrides.** One generic index, package-owned. A capability protocol for layouts that can do better is deferred until a real layout demonstrates it needs one.

### One property worth knowing about masonry

Masonry placement is a fold, so inserting an item or changing one item's height can change which *column* every later item lands in. Scroll position is preserved across such a change — the container anchors on identity — but the content will visibly reflow. That is inherent to masonry, not a container bug. A fixed grid does not have this property.

### Overscan

`overscan` is the extra distance materialized above and below the viewport, in viewport heights. The default is `1`. Larger values provide more runway during a fast fling; smaller values reduce view construction for dense layouts or expensive cells. This is deliberately caller-configurable because the same distance can contain 50 large cards or hundreds of compact timeline events.

## Accessibility

Items that have not been materialized are not in the accessibility tree, so VoiceOver cannot reach them until they scroll into range.

This is worth stating plainly, and worth stating in context: **`LazyVStack` behaves identically.** Measured with an XCUITest probe over 100,000 items, both this container and Apple's put 32 elements in the tree and both hid item 50,000. Virtualized containers work this way on this platform; the tree refills as the container scrolls, including under VoiceOver's own scroll action.

Expanding the window when VoiceOver is active is a genuine improvement over that baseline and is planned, but it is not in 0.1 — a wider window helps nearby traversal without making 100,000 items globally reachable, and claiming otherwise would be overselling it.

## Performance

The design target is that visibility resolution costs a negligible fraction of a frame, and that materialization stays bounded no matter how deep you scroll.

Measured on an **iPhone 14 Pro (A16), iOS 26.5.2, Release**, running this package's shipping container and generic index — not a prototype:

| | 100,000 items | 1,000,000 items |
|---|---|---|
| Sustained scroll | 120 fps, 8.34 ms p99, **zero frames over 16.7 ms** | 120 fps, 8.34 ms p99, **zero frames over 16.7 ms** |
| Visibility query | **2.1 µs** average | **2.0 µs** average |
| Cells materialized at any depth | 54 | 54 |
| Full re-solve (width change) | 4.7–5.1 ms | — |

The query being **flat from 100k to 1M on device** is the property the design exists to produce: the viewport maps directly to a small bucket range, then the index scans contiguous entries for that window. Cost normally follows window occupancy rather than total collection size. Layouts where most items span many buckets can still degrade to a linear scan; queries remain correct in that pathological case.

Apple's `LazyVStack` over the same 100,000 items scored 120 fps with the same 8.34 ms p99 and zero visible hitches. Read that as *generality cost little against a simpler container on this device*, not as a claim to be faster — it is one run each over different content.

Two things that measurement taught, kept here because they are easy to get wrong:

- Microbenchmarks of the visibility query are not the per-frame cost. Looping the query back-to-back keeps the frame array hot in cache; in a real app it runs once per frame with an entire render evicting it in between. The same code measured 341 ns warm and 5.62 µs cold on the same machine.
- Debug builds are not indicative. The same solve measured 30.2 ms in Debug and 1.4 ms in Release.
- **A desktop benchmark cannot predict a phone for memory-bound work.** Building a 100,000-entry hash table costs ~1.4 ms on an M4 and **~29 ms on an A16** — 20× for identical code — while pure layout arithmetic differs by less than 2×. Only the cache-hostile random-write workload diverges that far. This package therefore avoids building such a table on any hot path: identity lookups are served by a sequential scan, which for the one-lookup-per-snapshot pattern anchoring actually uses is roughly **400× faster** on device than the hash table it replaced.

Run the shipping architecture's benchmark in Release:

```bash
swift run -c release LazyLayoutBenchmark 100000
```

It reports layout time, generic-index and snapshot construction, warm/fresh/cold visibility queries, visible count, and the known contiguous storage payload.

## Demo

`Demo/` contains an iOS app for exploring masonry and timeline layouts, comparing eager and lazy baselines, and recording on-device frame statistics. Generate the Xcode project with [XcodeGen](https://github.com/yonaskolb/XcodeGen), then select your own development team in Xcode:

```bash
cd Demo
xcodegen generate
open LazyLayoutKitDemo.xcodeproj
```

## Instruments

The container emits signposts under subsystem `com.lazylayoutkit`, category `layout`, with two intervals: `solve` (a full layout pass) and `visibility` (resolving the on-screen window). Add the os_signpost instrument alongside Animation Hitches and the two line up.

Signpost names are treated as API — renaming one invalidates saved Instruments templates.

## License

Apache 2.0.
