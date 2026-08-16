# Writing a layout

Return one frame per item and a total height. That is the whole obligation.

## Overview

``LazyLayoutAlgorithm`` has a single requirement, and it never sees a view:

```swift
public protocol LazyLayoutAlgorithm: Equatable, Sendable {
    associatedtype Item: Equatable & Sendable
    func layout(items: [Item], containerWidth: Double) -> LazyLayoutResult
}
```

`Item` is an associated type rather than a fixed height on purpose. A masonry
grid wants an aspect ratio; a timeline wants a start and a duration; a calendar
wants a date range. Pinning it to "height" would have made this a masonry
protocol wearing a general name.

## A worked example

A chip flow — wrapping tags, like a tag cloud:

```swift
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

No views, no measurement, no `GeometryReader` — arithmetic over data you already
have. The package's test suite compiles this exact source, so it cannot rot.

## The rules

**`layout` must be pure.** The same items and width must produce the same frames.
The container caches results and re-solves on width changes, so a layout that
consults external mutable state will appear to glitch.

**One frame per item, in item order.** The container `precondition`s on this: a
mismatch is a programming error, not a recoverable condition.

**Frames may be anything.** They can overlap, arrive unordered, and use negative
coordinates. ``VerticalVisibilityIndex`` assumes none of it, and normalisation
shifts a negative-origin layout onto a zero-based plane for you.
``TimelineLayout`` exists partly to keep this honest — its frames overlap
vertically and are not monotonic in y in item order, so anything that had quietly
assumed masonry's shape breaks on it.

**`contentHeight` should span every frame.** Returning less clips scrolling. The
snapshot clamps it up to cover the frames you returned rather than trusting an
under-report, but the layout is the right place to get it right.

**Guard degenerate input.** A non-finite or negative size will propagate into
frames and then into the index. ``ItemMetric/height(forWidth:)`` shows the
pattern: clamp rather than trap.

## Sizes that depend on the width

If an item's size is a function of the container width — text, most of all — the
input cannot be computed until the width is known. That is a container concern
rather than a layout one: use the width-aware initializer on ``LazyLayoutView``,
which runs the item closure at solve time and hands your layout plain numbers as
usual. See <doc:MeasuringText>.

## Topics

### Protocol and result types

- ``LazyLayoutAlgorithm``
- ``LazyLayoutResult``
- ``LayoutRect``
- ``ItemMetric``

### Reference implementations

- ``MasonryLayout``
- ``JustifiedLayout``
- ``TimelineLayout``
