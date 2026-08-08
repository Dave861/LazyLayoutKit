# Tuning the window

How much to build ahead, and why distance is the wrong unit for it.

## Overview

The container builds views for the viewport plus a margin. More margin gives you
runway during a fast fling; less cuts view construction. ``Overscan`` expresses
that margin in either of two units:

```swift
LazyLayoutView(items, layout: layout, overscan: .screens(1))  // a distance
LazyLayoutView(items, layout: layout, overscan: .items(80))   // an amount of work
```

`.screens(n)` is the default and the original behaviour. A bare number still means
screens, so `overscan: 1` and `overscan: 0.5` mean what they always did.

## What a cell count buys, and what it does not

Screen-heights do not give you a predictable amount of work. On an iPhone 14 Pro
at 100,000 items, one screen height is 56 masonry cells but 108 timeline cells.
``Overscan/items(_:)`` fixes that: asking for 80 gives 81 in both.

| layout | overscan | cells built | hitches per 100k pt |
|---|---|---|---|
| masonry | `.screens(1)` | 56 | 0.0 |
| masonry | `.items(80)` | **81** | 0.0 |
| timeline | `.screens(1)` | 108 | 34.2 |
| timeline | `.items(80)` | **81** | 32.3 |
| timeline | `.items(150)` | **151** | 37.2 |

**Bounding concurrent cells is the whole of what it does.** That is worth having —
it caps peak build cost and memory whatever the layout's density — but read the
last column before reaching for it as a performance fix.

Timeline hitches at about the same rate on 81 cells as on 151, and masonry does
not hitch at 81 at all. Same device, same count, opposite outcome, so window size
is not the cause. What differs is items crossing the viewport per point scrolled:
67 per 1,000 pt for timeline against 26 for masonry.

Every item that crosses the viewport is constructed once no matter how large the
window is, so **a smaller window cannot lower the construction rate.** When a
dense layout drops frames during a fling, the cell is what needs to get cheaper.

> Note: An earlier version of this article cited a 2×2 measurement as showing
> that only a large window *combined with* an expensive cell dropped frames. A
> controlled re-run does not reproduce it, and the original runs recorded no
> scroll distance, so they were very likely comparing unequal amounts of
> scrolling. The claim is withdrawn.

## Choosing between them

Use **`.screens(n)`** when cells are uniform and cheap. Distance is what matters
for a fling, and if every cell costs the same, distance and work are proportional
anyway.

Use **`.items(n)`** when cells are expensive or vary in height. Self-sizing text
is squarely this case: how many cells fill a screen depends on how long the
strings turn out to be, so a fixed distance means an unpredictable amount of work.

## How the item budget is met

For `.screens` the window is arithmetic. For `.items` the container consults the
index, because how far to reach depends on how densely packed the content is *at
that point* — which varies down the content for masonry or a timeline, and varies
with string length for text.

The materialised count rises monotonically with the margin, so the container
**bisects** for the window whose count is closest to the budget: ten steps, each
one visibility query at 1.8–4.3 µs, so roughly 25–50 µs in total. That is a
fraction of a frame and far less than building a single unwanted cell.

Content is discrete, so an exact hit is often impossible. Where two windows
bracket the budget the smaller count wins — the unit exists because too many
expensive cells drops frames, so it errs toward less work.

The guarantees:

- Never fewer than are **genuinely visible**. A budget below one screenful cannot
  make on-screen cells disappear.
- Clamped at the ends of the content, where there is nothing to expand into.
- Bounded at 20 viewport heights either side, so sparse content cannot run away.

**An earlier version estimated a margin from the viewport's density and accepted
the first window at or above the budget.** It never looked at whether a smaller
window would have been closer, and on device it overshot by up to 1.55x — 124
cells for a budget of 80, which is barely less work than the setting it was meant
to improve on.

## Topics

### Types

- ``Overscan``
