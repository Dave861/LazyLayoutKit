# Performance

What has been measured, on what, and what has not.

## Overview

Two scales live in this package and conflating them is the easiest way to be
disappointed:

- **The measured masonry configuration** — three columns of aspect-ratio cells —
  holds 120 fps at a million items.
- **Self-sizing text** is comfortable to roughly ten thousand.
- **A dense timeline is an exception at either scale**, and not because of the
  index. See below.

Both are measured on an iPhone 14 Pro (A16), iOS 26.5.2, Release.

## Masonry, the measured configuration

`MasonryLayout(columns: 3, spacing: 10)` over aspect-ratio cells:

| | 100,000 items | 1,000,000 items |
|---|---|---|
| Sustained scroll | 120 fps, 8.34 ms p99, zero frames over 16.7 ms | 120 fps, 8.34 ms p99, zero frames over 16.7 ms |
| Visibility query | 2.1 µs | 2.0 µs |
| Cells materialized | 54 | 54 |

The query being flat from 100k to 1M on device is the result the package exists
to produce.

**This is one configuration, not a guarantee for every layout.** What scales is
the index and the solve; what does not necessarily scale is building the cells,
and a layout that puts many more of them through the viewport per point scrolled
behaves differently — see the timeline section below.

## Text measurement

| | M4 | **iPhone 14 Pro (A16)** |
|---|---|---|
| One realistic feed item, cold | ~28 µs | **~31 µs** |
| The same item, cached | ~130 ns | **~470 ns** |
| Cold-to-cached ratio | ~215x | **~65x** |
| 1,000 items, first pass | 28 ms | **32 ms** |
| 10,000 items, first pass | 270 ms | **315 ms** |
| 100,000 items, first pass | 2,650 ms | **3,115 ms** |

Cold cost is flat at ~31.5 µs per item from 1,000 to 100,000, and close to the
M4's 28. That is worth stating because this package has been wrong that way
before: snapshot construction in 0.1 measured 3 ms on an M4 and 28 ms on an A16
for identical code, a 9x miss, because it was memory-bound. Text measurement is
compute-bound and moves with the CPU.

**The cached figure does not transfer**: A16 lookups cost about 3.6x an M4's, so
the hit-to-miss ratio is ~65x on device rather than ~215x. Plan with the device
number.

Scrolling measured text is unaffected by any of this — 120 fps, p99 8.34 ms and
zero frames over 16.7 ms at 1K, 10K and 100K. Once heights are known, a text feed
behaves exactly like a metric-driven one.

**Above the cache limit there is no warm case.** A pass larger than
``TextMeasurer/init(_:cacheLimit:)`` evicts its own contents, so every item is a
miss. At 100,000 items against the 20,000-entry default, a repeated pass cost
3,135 ms against 3,115 ms cold.

Three results that shaped the design:

- **Cost is linear in string length**, about 1 µs per word. A "single line" is
  not a shortcut — `CTLine` shapes the entire string.
- **A line limit does not speed up ordinary text.** What it does is bound the
  tail: a pathological 10 kB string goes from 8.9 ms — a dropped frame on its
  own — to 0.10 ms.
- **Measurement does not parallelise.** 1.27x on ten cores, and building the
  attributed strings is *slower* in parallel, so there is no concurrent API.

## Dense Timeline is not smooth at 100,000 items

Worth stating plainly, because no setting fixes it: Timeline at 100,000 items with
`.screens(1)` — about 129 concurrent cells — measures **p99 33–38 ms with 17–31%
of frames over 16.7 ms** on an iPhone 14 Pro. That is true of **0.1 and 0.2
alike**; a build-to-build comparison found no detectable difference.

It is consistent with the overscan finding below: the cost tracks how many cells
are *constructed per second*, which at 67 items per 1,000 pt is high, rather than
how many exist at once.

Masonry at the same item count does not have this problem — 120 fps, zero frames
over 16.7 ms — because it traverses 26 items per 1,000 pt.

## Overscan does not control hitching

``Overscan/items(_:)`` hits its target — 81 cells for a budget of 80, 151 for 150
— but the hitch rate barely moves with it:

| layout | overscan | cells | hitches per 100k pt |
|---|---|---|---|
| masonry | `.screens(1)` | 56 | 0.0 |
| masonry | `.items(80)` | 81 | 0.0 |
| timeline | `.screens(1)` | 108 | 34.2 |
| timeline | `.items(80)` | 81 | 32.3 |
| timeline | `.items(150)` | 151 | 37.2 |

Masonry at 81 cells does not hitch; timeline at 81 cells does. Window size is not
the driver — construction rate is, at 67 items per 1,000 pt against 26. See
<doc:TuningTheWindow>.

## What has not been measured

**Text fidelity on iOS.** `TextFidelityTests` hosts real `Text` and compares it
against the measurer across 880 combinations of corpus, width, line limit and
point size — but only on macOS, because that is where the suite can run.
Simulator observation shows iOS never clips either, while running about 2pt per
line generous. Tightening that rule is deliberately blocked on an automated iOS
sweep existing first.

**Whether Timeline's hitch rate differs between 0.1 and 0.2 by less than about
10%.** A matched-scroll A/B on device put the two builds' ranges on top of each
other — 0.1 measured 35.5 and 42.7 hitches per 100k pt, 0.2 measured 42.5 — so
there is no detectable regression, but the within-build spread (~17% at n=2) is
too large to rule out a small one.

## Reproducing

```
swift run -c release LazyLayoutBenchmark 100000
```

Signposts are emitted under the `com.lazylayoutkit` subsystem, `layout` category,
with `solve` and `visibility` intervals. The names are treated as API.

The demo app records on-device frame statistics — fps, p99, hitches, peak cells,
and the solve breakdown including the item-resolution component that text
measurement lands in — and shares them as text.

## Topics

### Related

- <doc:TuningTheWindow>
