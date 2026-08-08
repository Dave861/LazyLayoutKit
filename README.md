# LazyLayoutKit

[![CI](https://github.com/Dave861/LazyLayoutKit/actions/workflows/ci.yml/badge.svg)](https://github.com/Dave861/LazyLayoutKit/actions/workflows/ci.yml)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FDave861%2FLazyLayoutKit%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/Dave861/LazyLayoutKit)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FDave861%2FLazyLayoutKit%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/Dave861/LazyLayoutKit)

**You know `LazyVStack`, `LazyHStack` and `LazyVGrid`. Meet their cousin, one that lets you write the layout yourself.**

<p align="center">
  <img src="Docs/Images/hero-masonry.png" width="300" alt="Masonry gallery scrolled deep into 100,000 items, running at 120 fps with 48 cells materialized and a 3 µs visibility query.">
</p>

Masonry, timelines, calendars, boards. Any layout you can describe, with SwiftUI building only the views that are actually on screen.

```swift
LazyLayoutView(photos, layout: MasonryLayout(columns: 3)) { photo in
    .aspectRatio(photo.width / photo.height)   // layout input — no view built
} content: { photo in
    PhotoCell(photo)                           // called only when on screen
}
```

## Why this exists

SwiftUI makes you pick one:

- [`Layout`](https://developer.apple.com/documentation/swiftui/layout) gives you any geometry you like, but it's **eager**. It measures every subview, so it falls over a few thousand items in.
- `LazyVStack` and friends are lazy, but their geometry is **fixed** — a vertical run, or a uniform grid.

There's nothing in between. And in between is where photo grids, feeds, calendars and boards live.

This isn't an oversight on Apple's part, it's a consequence. `Layout` asks each subview how big it wants to be, and you can't ask a view that hasn't been built. Measurement-driven layout and laziness pull in opposite directions.

Asked at the [WWDC26 SwiftUI Group Lab](https://developer.apple.com/videos/play/wwdc2026/8006/) whether custom layouts can be lazy, Apple's answer was: not today, `Layout` is eager-only, file a Feedback.

**So this package takes a different approach.** Tell it your item sizes up front — an aspect ratio, a date range, a duration — and layout becomes arithmetic. Arithmetic over a million items takes milliseconds and builds nothing. Only the frames intersecting your viewport ever become views.

That is the trade, and it is worth being explicit about it. You give up asking views how big they want to be. You get arbitrary geometry, and a solve and visibility query that stay flat from a thousand items to a million — measured at 120 fps with zero dropped frames for a three-column masonry grid at 1,000,000 items on an iPhone 14 Pro.

What that does *not* promise is that every layout is smooth at every size. The index and the solve scale; building cells still costs what it costs. A dense timeline that puts 67 items through the viewport per 1,000 pt scrolled drops frames on the same device where masonry, at 26, does not — see [Is it fast?](#is-it-fast).

**Self-sizing text is the exception, and 0.2 adds it.** Not by measuring views after building them — that would give back the laziness — but by computing the height with CoreText before layout runs. No view is built and nothing is rasterised:

```swift
@Environment(\.fontResolutionContext) private var fontContext

@State private var measurers = TextMeasurerStore()   // one measurer per style

let style = TextStyle(font: .body, in: fontContext, lineLimit: 3)
let measurer = measurers.measurer(for: style)

LazyLayoutView(posts, layout: MasonryLayout(columns: 1), recomputeOn: style) { post, width in
    .fixedHeight(measurer.height(of: post.body, width: width))
} content: { post in
    Text(post.body).font(.body).lineLimit(3)
}
```

The size is still known before the view exists, so nothing about the contract changed — there is still no `.measured` metric and no measure-and-correct pass. What changed is that a text height is now *computable* up front. `Font.Resolved` (iOS 26) is what makes it exact: it turns a SwiftUI `Font` into the concrete font it will render as, Dynamic Type included, which was not publicly possible before.

`recomputeOn:` is the dependency the container cannot infer. The measurer's font lives in the closure, not in your data, so without it a Dynamic Type change would leave every cell at a height measured for the old font. `TextStyle` compares by value, so passing it on every render costs nothing.

**On which thread.** `TextMeasurer` is safe to call from any thread, but in the form above it runs *synchronously inside the solve*, on the main actor — which is fine at a few thousand items and is not fine at fifty thousand. To keep the first pass off the main actor you have to measure ahead of time and feed the results in.

Text has its own performance ceiling, lower than the rest of the package — see [Self-sizing text](#self-sizing-text).

## How it works

The layout function never sees a view. That's the entire idea.

```swift
public protocol LazyLayoutAlgorithm: Equatable, Sendable {
    associatedtype Item: Equatable & Sendable
    func layout(items: [Item], containerWidth: Double) -> LazyLayoutResult
}
```

`Item` is an associated type on purpose. Masonry wants an aspect ratio; a timeline wants a start and a duration; a calendar wants a date range. Pinning that to "height" would have made this a masonry library wearing a general name.

**Visibility** comes from a uniform bucket index built over whatever frames your layout produced — compressed-sparse-row, contiguous, no per-bucket hashing. It assumes nothing about structure, so your frames may overlap, arrive unordered, or use negative coordinates. Items spanning many buckets go on a separate oversized list rather than being copied into each one, which keeps worst-case memory linear.

**Scroll position** is anchored on your item identity, never on index. Insert one item at the front and every index shifts — anchor by index and you'd silently be holding a different item still.

## Two layouts in the box

**`MasonryLayout`** — fixed columns, each item dropped into whichever is shortest.

**`TimelineLayout`** — intervals on a vertical time axis, overlapping ones split into lanes.

Timeline is there to keep the protocol honest. Its items overlap vertically and its frames aren't monotonic in y in item order, so anything that had quietly assumed masonry's shape breaks on it. There's a test asserting exactly that.

<p align="center">
  <img src="Docs/Images/timeline.png" width="300" alt="Timeline layout: overlapping intervals split into lanes, with frames that are not monotonic in y.">
</p>

Both are written against the same public protocol you would use — about 60 and 90 lines each. Writing your own is the point.

## Writing your own layout

Return one frame per item and a total height. That is the entire obligation.

```swift
/// Wraps chips into rows, like a tag cloud.
struct ChipFlowLayout: LazyLayoutAlgorithm {
    struct Chip: Equatable, Sendable {
        var width: Double
        var height: Double
    }

    var spacing: Double = 8

    func layout(items: [Chip], containerWidth: Double) -> LazyLayoutResult {
        var frames: [LayoutRect] = []
        frames.reserveCapacity(items.count)

        var x = 0.0, y = 0.0, rowHeight = 0.0
        for chip in items {
            if x > 0, x + chip.width > containerWidth {   // wrap
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(LayoutRect(x: x, y: y, width: chip.width, height: chip.height))
            x += chip.width + spacing
            rowHeight = max(rowHeight, chip.height)
        }
        return LazyLayoutResult(frames: frames, contentHeight: y + rowHeight)
    }
}
```

No views, no measurement, no `GeometryReader` — just arithmetic over data you already have. Hand it to `LazyLayoutView` and it virtualizes for free:

```swift
LazyLayoutView(tags, layout: ChipFlowLayout()) { tag in
    .init(width: tag.estimatedWidth, height: 32)
} content: { tag in
    TagChip(tag)
}
```

Your frames can overlap, arrive in any order, and use negative coordinates. The visibility index assumes none of it. (This example is compiled by the test suite, so it cannot rot.)

## Install

iOS 18 · macOS 15. Built on `ScrollGeometry` / `onScrollGeometryChange`. 

```swift
.package(url: "https://github.com/Dave861/LazyLayoutKit.git", from: "0.2.0")
```

## Is it fast?

Measured on an **iPhone 14 Pro (A16), iOS 26.5.2, Release**, running the shipping container and index, with `MasonryLayout(columns: 3)` over aspect-ratio cells:

| | 100,000 items | 1,000,000 items |
|---|---|---|
| Sustained scroll | 120 fps, 8.34 ms p99, **zero frames over 16.7 ms** | 120 fps, 8.34 ms p99, **zero frames over 16.7 ms** |
| Visibility query | **2.1 µs** average | **2.0 µs** average |
| Cells materialized, any depth | 54 | 54 |
| Full re-solve on width change | 4.7–5.1 ms | — |

<p align="center">
  <img src="Docs/Images/result-1m.png" width="290" alt="Recorded run over 1,000,000 items: PASS, 120 fps average, 8.3 ms median, p95 and p99, 8.4 ms worst frame across 2,398 frames.">
  <img src="Docs/Images/result-1m-details.png" width="290" alt="Same run, continued: hitch counts, peak cells materialized, and visibility query timings.">
</p>

<p align="center"><em>A recorded twenty-second run over a million items, from the demo app in this repo.</em></p>

The query staying **flat from 100k to 1M on device** is the property the design exists to produce: a viewport maps to a small bucket range, then the index walks contiguous entries. Cost follows window occupancy, not collection size. A layout where most items span many buckets can still degrade to a linear scan, still correct, just not fast.

Apple's `LazyVStack` over the same 100,000 items also managed 120 fps, the same 8.34 ms p99, and zero visible hitches.

### Where it is not fast

A dense timeline is the honest counter-example. `TimelineLayout` at 100,000 items with `overscan: .screens(1)` — about 129 cells on screen at once — measures **p99 33–38 ms, with 17–31% of frames over 16.7 ms**.

The index is not the cause: the visibility query stays at 2.7–5.3 µs throughout. What differs is throughput. Timeline puts **67 items through the viewport per 1,000 pt scrolled** where masonry puts 26, and every item that crosses is built once. Cell construction rate is the cost, and no overscan setting changes it — `.items(80)` builds 81 cells instead of 129 and hitches at the same rate.

This is not new in 0.2. A matched-scroll A/B against the 0.1.0 tag put both versions' ranges on top of each other. If your layout is dense and your cells are not cheap, budget for the cell, not the window. Read that as *generality cost us very little against a simpler container*, not a claim to be faster. It's one run each, over different content.

<details>
<summary><strong>What I learnt from measuring</strong></summary>

**A desktop benchmark can't predict a phone for memory-bound work.** Building a 100,000-entry hash table costs ~1.4 ms on an M4 and **~29 ms on an A16** — 20× for identical code — while pure layout arithmetic differs by less than 2×. Only the cache-hostile random-write workload diverges like that. So this package builds no such table on any hot path: identity lookups use a sequential scan, which for the one-lookup-per-snapshot pattern anchoring actually needs is roughly **400× faster on device** than the hash table it replaced.

**A microbenchmark of the query isn't the per-frame cost.** Looping it back-to-back keeps the frame array hot in cache. In a real app it runs once per frame with an entire render evicting it in between. Same code: 341 ns warm, 5.62 µs cold, same machine.

**Debug builds tell you nothing.** The same solve measured 30.2 ms in Debug and 1.4 ms in Release.

</details>

Run it yourself:

```bash
swift run -c release LazyLayoutBenchmark 100000
```

## Self-sizing text

Measuring text is cheap compared with rendering it, but it is not free, and it does not scale the way the rest of this package does. Measured on an M4, then confirmed on an iPhone 14 Pro (A16), iOS 26.5.2, Release:

| | M4 | **iPhone 14 Pro (A16)** |
|---|---|---|
| One realistic feed item, cold | ~28 µs | **~31 µs** |
| The same item, cached | ~130 ns | **~470 ns** |
| Cold-to-cached ratio | ~215x | **~65x** |
| 1,000 items, first pass | 28 ms | **32 ms** |
| 10,000 items, first pass | 270 ms | **315 ms** |
| 100,000 items, first pass | 2,650 ms | **3,115 ms** |

The cold figure transfers almost exactly — 31 µs against 28 — which is worth noting because this package has been wrong that way before, by 9x. Text measurement is compute-bound, so it moves with the CPU rather than falling off a cliff.

**The cached figure does not transfer.** A16 lookups cost about 3.6x an M4's, so the gap between a hit and a miss is ~65x on device rather than ~215x. Still the difference between a solve you notice and one you do not, but plan with the device number.

So: **text layouts are comfortable to about 10,000 items.** The million-item figures elsewhere in this README belong to layouts driven by `ItemMetric`, where sizing is arithmetic.

Past a few thousand, do the first pass off the main actor and store the result, so the solve only ever reads it back:

```swift
@State private var heights: [Post.ID: Double] = [:]

// The width is a layout input here, so a precomputed pass is per width:
// re-run it when the container width changes, and on a style change.
.task(id: PassKey(width: width, style: style)) {
    let measured = try? await measurer.heights(of: posts.map(\.body), width: width, chunkSize: 256)
    guard let measured else { return }                 // cancelled by a newer pass
    heights = Dictionary(uniqueKeysWithValues: zip(posts.map(\.id), measured))
}

LazyLayoutView(posts, layout: layout, recomputeOn: heights) { post, _ in
    // A dictionary read, not a measurement. Anything not yet measured falls
    // back to the measurer, which is a cache hit for everything the pass covered.
    .fixedHeight(heights[post.id] ?? measurer.height(of: post.body, width: width))
} content: { post in
    Text(post.body).font(.body).lineLimit(3)
}
```

Note `recomputeOn: heights` — the container has to be told that the pass landing is what invalidates the layout. The fallback is what keeps the first frame correct rather than collapsed, and because the async pass populated the same measurer's cache, it costs ~130 ns rather than ~28 µs.

Three things worth knowing before you reach for it:

- **Cost is linear in string length**, roughly 1 µs per word. Setting a `lineLimit` bounds it: only enough of the string to fill that many lines is examined, which takes a pathological 10 kB string from **8.9 ms to 0.10 ms**, about 90x. For ordinary feed text it is not a speedup at all — measured either side of the noise, so treat it as free rather than faster. Its entire value is that one long string cannot stall a frame.
- **It does not parallelise.** CoreText serialises internally: 1.27x on ten cores, and building the attributed strings is *slower* in parallel. There is deliberately no concurrent API. The async variant exists to yield, not to go faster.
- **Measurement errs tall.** Where CoreText and SwiftUI disagree the measurement is up to 2pt per line generous, never short — a hairline gap is recoverable, a clipped last line is a visible bug. `TextFidelityTests` checks this against real hosted `Text` across 880 combinations of corpus, width, line limit and point size from 11 to 53.

`minimumScaleFactor` is not supported, and won't be: shrink-to-fit is a measure-then-shrink loop, which is exactly the lifecycle this package doesn't implement.

## What is not in 0.2.0

Narrow beats vague. Each of these is missing because doing it properly is real work, not because it was forgotten.

- **Vertical scrolling only.** Place items anywhere across the width you like, but the scroll axis and the index are y. Two-axis canvases need a different index.
- **No measure-and-correct pass.** Sizes are computed before layout, never observed from rendered views and reconciled afterwards. `ItemMetric` still has no `.estimated` or `.measured` case, because it still doesn't do that. Self-sizing text works by making the height computable in advance, not by relaxing this.
- **Text is `String` plus one style.** Attributed text with mixed fonts per run isn't modelled, because mixed runs change line height per line.
- **No animated insertion or removal.** Changes are applied correctly and preserve scroll position, but they don't animate.
- **Exact, eager snapshots.** Every frame is computed up front, so unbounded collections are out of scope.
- **No custom query overrides.** One index, package-owned. A capability protocol for layouts that can do better waits until a real layout proves it needs one.

**One quirk worth knowing about masonry:** placement is a fold, so inserting an item or resizing one can change which *column* every later item lands in. Your scroll position is preserved — the container anchors on identity — but content will visibly reflow. That's masonry, not a bug. A fixed grid doesn't do it.

## Tuning overscan

`overscan` is how much the container builds beyond the viewport. It takes two units, and which one you want depends on what varies in your layout.

```swift
LazyLayoutView(items, layout: layout, overscan: .screens(1))  // distance
LazyLayoutView(items, layout: layout, overscan: .items(80))   // work
```

`.screens(n)` is 0.1's behaviour and stays the default. A bare number still means screens, so `overscan: 1` and `overscan: 0.5` are unchanged.

**`.items(n)` gives you a predictable cell count where `.screens` does not.** On an iPhone 14 Pro at 100,000 items, one screen height is 56 masonry cells but 108 timeline cells. Asking for 80 gives 81 in both:

| layout | overscan | cells built | hitches per 100k pt |
|---|---|---|---|
| masonry | `.screens(1)` | 56 | 0.0 |
| masonry | `.items(80)` | **81** | 0.0 |
| timeline | `.screens(1)` | 108 | 34.2 |
| timeline | `.items(80)` | **81** | 32.3 |
| timeline | `.items(150)` | **151** | 37.2 |

That is what it is for: bounding concurrent cells, and so peak build cost and memory, regardless of how densely the layout happens to pack.

**What it does not do is stop a dense layout dropping frames.** Look at the last column. Timeline hitches at essentially the same rate whether it builds 81 cells or 151, and masonry does not hitch at 81. Same device, same cell count, opposite outcome — so the window size is not what is driving it.

The variable that does track is how many items pass through the viewport per point scrolled: 67 per 1,000 pt for timeline against 26 for masonry. Every item that crosses the viewport is built once, however large the window is, so **a smaller window cannot reduce construction rate.** If a dense layout drops frames during a fast fling, the fix is a cheaper cell, not a smaller window.

An earlier version of this section claimed a 2×2 measurement showed that only *large window plus expensive cell* dropped frames. A controlled re-run does not reproduce it — 81 timeline cells hitch about as much as 128 — and the original runs recorded no scroll distance, so they were almost certainly comparing different amounts of scrolling. The claim has been withdrawn.

## Accessibility

Items that haven't been materialized aren't in the accessibility tree, so VoiceOver can't reach them until they scroll into range.

Worth stating plainly, and worth the context: **`LazyVStack` behaves identically.** Measured with an XCUITest probe over 100,000 items, this container and Apple's both put 32 elements in the tree, and both hid item 50,000. That's how virtualized containers work here; the tree refills as you scroll, including under VoiceOver's own scroll action.

Widening the window while VoiceOver is running is a real improvement on that baseline and it's planned — but it still isn't, because a wider window helps nearby traversal without making 100,000 items globally reachable, and saying otherwise would be overselling it.

## Demo app

`Demo/` is an iOS app for exploring both layouts, comparing against lazy and eager baselines, and recording on-device frame statistics you can share as text.

```bash
cd Demo
xcodegen generate
open LazyLayoutKitDemo.xcodeproj
```

Set your own development team in Xcode, and run in **Release** — see above for why Debug numbers are meaningless.

## Instruments

Signposts under subsystem `com.lazylayoutkit`, category `layout`, with two intervals: `solve` (a full layout pass) and `visibility` (resolving the on-screen window). Add the os_signpost instrument next to Animation Hitches and they line up.

Signpost names are treated as API, renaming one invalidates anyone's saved template.

## Status

0.2.0 adds self-sizing text and a cell-count overscan unit. Every performance figure here is measured on an iPhone 14 Pro rather than extrapolated from a Mac, and the limitations are measured too — including a dense-timeline case that neither 0.1 nor 0.2 handles smoothly, and an earlier 0.1 measurement that turned out not to be reproducible by 0.1's own binary.

The scope is still deliberately narrow and the limitations above are real. The API may still change before 1.0 — issues and questions are welcome.

## License

Apache 2.0.
