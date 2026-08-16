# ``LazyLayoutKit``

Write the layout yourself, and have SwiftUI build only the views on screen.

## Overview

SwiftUI makes you choose. `Layout` gives you any geometry you like but measures
every subview, so it falls over a few thousand items in. `LazyVStack` and
`LazyVGrid` are lazy but their geometry is fixed. Photo grids, feeds, calendars
and boards live in between.

That gap is a consequence rather than an oversight: `Layout` asks each subview how
big it wants to be, and you cannot ask a view that has not been built. Measurement
and laziness pull in opposite directions.

This package resolves it by inverting the question. Instead of asking views their
size, you supply it — an aspect ratio, a date range, a duration — and layout
becomes arithmetic over data. Arithmetic across a million items takes milliseconds
and builds nothing. Only the frames intersecting the viewport ever become views.

```swift
LazyLayoutView(photos, layout: MasonryLayout(columns: 3)) { photo in
    .aspectRatio(photo.width / photo.height)   // layout input — no view built
} content: { photo in
    PhotoCell(photo)                           // called only when on screen
}
```

Text is the interesting case, because its height genuinely is not known in
advance — but it is *computable* in advance. See <doc:MeasuringText>.

## Topics

### Essentials

- <doc:TheSizingContract>
- ``LazyLayoutView``
- ``LazyLayoutAlgorithm``

### Writing a layout

- <doc:WritingALayout>
- ``LazyLayoutResult``
- ``LayoutRect``
- ``ItemMetric``

### Layouts in the box

- ``MasonryLayout``
- ``JustifiedLayout``
- ``TimelineLayout``

### Scrolling to an item

- <doc:ScrollingToAnItem>
- ``LazyLayoutPosition``
- ``ScrollAnchor``

### Self-sizing text

- <doc:MeasuringText>
- ``TextMeasurer``
- ``TextMeasurerStore``
- ``TextStyle``

### Tuning what gets built

- <doc:TuningTheWindow>
- ``Overscan``

### What has been measured

- <doc:Performance>

### Under the hood

- ``LayoutSnapshot``
- ``VerticalVisibilityIndex``
