# Measuring text

Self-sizing text in a lazy container, and what it costs.

## Overview

Text is the one thing whose size genuinely is not a property of your data. It
depends on the string, the font, and the width available — and the width is not
known until the container has been measured.

It is, however, *computable* without building a view. CoreText will typeset a
string and report the height with no view, no layer, and nothing rasterised, off
the main actor. So the contract in <doc:TheSizingContract> holds: the size is
still known before the view exists.

```swift
struct Feed: View {
    @Environment(\.fontResolutionContext) private var fontContext
    @State private var measurers = TextMeasurerStore()
    let posts: [Post]

    var body: some View {
        let style = TextStyle(font: .body, in: fontContext, lineLimit: 3)
        let measurer = measurers.measurer(for: style)
        return LazyLayoutView(
            posts,
            layout: MasonryLayout(columns: 1, spacing: 12),
            recomputeOn: style
        ) { post, width in
            .fixedHeight(measurer.height(of: post.body, width: width))
        } content: { post in
            Text(post.body).font(.body).lineLimit(3)
        }
    }
}
```

Two details in there are not decoration. ``TextMeasurerStore`` keeps one measurer
alive per style, because building one in `body` throws the cache away on every
parent render — and the cache is worth ~65x. `recomputeOn:` tells the container
that the style is a dependency it cannot otherwise see, so a Dynamic Type change
re-solves instead of leaving every cell at a height measured for the old font.

> Note: The `Font` bridge requires **Xcode 26** to build — `Font.Resolved` is an
> iOS 26 SDK symbol, and availability annotations cannot conjure a symbol the SDK
> does not have. On an older toolchain ``TextMeasurer`` and the `CTFont`
> initializer work unchanged; only ``TextStyle`` initializer taking a `Font` is
> absent.

## Matching what SwiftUI renders

The measurement is only useful if it agrees with the view. Two things make that
work, and one of them is new.

**Resolving the font.** `Font.body` is not a font; it is a request that resolves
differently depending on the user's text size. `Font.Resolved` (iOS 26, macOS 26)
exposes the concrete `CTFont` a `Text` will actually use, carrying Dynamic Type,
weight, width, leading and small caps with it. Before this existed, measuring
SwiftUI text with CoreText meant guessing which font to measure against.

Reading `\.fontResolutionContext` from the environment is also what makes text
re-measure when the user changes their text size: the context is `Equatable`, so
it changes, the measurer is rebuilt, and the container re-solves.

**Erring tall.** Where the two engines disagree, ``TextMeasurer`` reports the
larger height — up to about 2pt per line. A slightly generous measurement leaves a
hairline gap; a short one clips the last line in every affected cell at once. Only
one of those is recoverable.

`TextFidelityTests` checks this against real hosted `Text` across 880 combinations
of corpus, width, line limit and point size from 11 to 53, including CJK, RTL,
ZWJ emoji, hard newlines and unbreakable words.

> Important: The `lineLimit` and `lineSpacing` on your ``TextStyle`` must match
> the modifiers on the `Text` you render. Nothing enforces it — the measurer never
> sees the view.

## What it costs

Measured on an M4, then confirmed on an iPhone 14 Pro (A16), iOS 26.5.2:

| | M4 | **iPhone 14 Pro (A16)** |
|---|---|---|
| One realistic feed item, cold | ~28 µs | **~31 µs** |
| The same item, cached | ~130 ns | **~470 ns** |
| Cold-to-cached ratio | ~215x | **~65x** |
| 1,000 items, first pass | 28 ms | **32 ms** |
| 10,000 items, first pass | 270 ms | **315 ms** |
| 100,000 items, first pass | 2,650 ms | **3,115 ms** |

**Self-sizing text is practical to roughly 10,000 items.** The million-item
figures elsewhere belong to layouts driven by ``ItemMetric``, where sizing is
arithmetic. This is a different scale and it is worth planning around rather than
discovering.

The gap between a hit and a miss — **~65x on device** — is the whole performance
story. Steady state is cheap; the first pass at a given width is not. Since apps
realistically use two widths (portrait and landscape), that is two passes over the
lifetime of a screen, not one per frame.

Above the cache limit there is no warm case at all: a pass larger than
``TextMeasurer/init(_:cacheLimit:)`` evicts its own contents, so every item is a
miss. Measured at 100,000 items against the 20,000-entry default, a repeated pass
cost 3,135 ms against 3,115 ms cold — no reuse whatsoever. Raise the limit or
expect cold-cost re-solves.

Past a few thousand items, do that pass off the main actor:

```swift
let heights = try await measurer.heights(of: bodies, width: width, chunkSize: 256)
```

## Three things that are not obvious

**Cost is linear in string length**, roughly 1 µs per word. A `lineLimit` bounds
it: only enough of the string to fill that many lines is examined. This takes a
pathological 10 kB string from 8.9 ms — a dropped frame on its own — to
0.10 ms, about 90x. It is exact, not an estimate, because line breaking depends only on
preceding text, so a break found inside a prefix is the break the whole string
would produce.

For ordinary feed text it is not a speedup — cold cost lands either side of the
noise with and without a limit. Its entire value is the tail: one long string
cannot stall a frame.

**It does not parallelise.** CoreText serialises internally: 1.27x on ten cores,
and building the attributed strings is measurably *slower* in parallel. There is
deliberately no concurrent API. ``TextMeasurer/heights(of:width:chunkSize:)``
exists to yield between chunks so it does not block, which is a different problem
from going faster.

**A "single line" is not a shortcut.** `CTLineCreateWithAttributedString` shapes
the entire string into one very long line, so measuring one line of a long string
costs nearly as much as measuring all of it. Setting `lineLimit: 1` is cheap
because of prefix bounding, not because one line is inherently less work.

## Not supported

- **`minimumScaleFactor`.** Shrink-to-fit is a measure-then-shrink loop — the
  height depends on a scale that depends on the height. That is the
  measure-and-correct lifecycle this package does not implement.
- **Attributed text with mixed runs.** One style over one string. Mixed fonts
  within a paragraph change line height per line, which the arithmetic here does
  not model.
- **An empty string** measures a full line, while SwiftUI floors `Text("")` at
  14pt at every point size. Matching that would mean hardcoding an undocumented
  constant, and returning zero would clip. An empty cell one line too tall is the
  cheap direction to be wrong in.

## Topics

### Types

- ``TextMeasurer``
- ``TextMeasurerStore``
- ``TextStyle``

### Related

- ``ItemMetric``
