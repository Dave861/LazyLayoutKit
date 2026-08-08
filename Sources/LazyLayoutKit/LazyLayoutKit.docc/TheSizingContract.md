# The sizing contract

Why sizes are known before views exist, and what that buys.

## The rule

**Every item's size is determined before any view for it is constructed.**

That single rule is what makes everything else work. Frames for a hundred
thousand items are arithmetic over data you already have. The visibility index is
built over those frames. Only the frames intersecting the viewport become views.
Nothing in the chain needs to build a view in order to decide where it goes.

Break the rule and the whole structure collapses back into `Layout`: to know an
item's size you build it, to build it you place it, and to place it you need every
size — which means building everything.

## What this rules out, permanently

**A measure-and-correct lifecycle.** The common approach elsewhere is to guess a
size, build the view, observe what it actually wanted, then correct the layout and
scroll offset. It is a legitimate design — `UICollectionView` does a version of
it — but it is not this one, and mixing them gives you the worst of both.

``ItemMetric`` therefore has no `.estimated` and no `.measured` case. Those names
imply the correction pass, and shipping a name without the behaviour behind it is
worse than not shipping it. This has not changed and is not expected to.

## What it does not rule out

**Computing a size, rather than being told one.**

This is the distinction that self-sizing text turns on, and it is easy to miss.
The rule says the size must be *known* before the view exists. It does not say
the size must be *supplied by the caller*. If a size can be derived from the data
without constructing a view, the contract is satisfied.

Text can be. Given the string, the font, and the width, CoreText computes the
height with no view, no layer, and no rasterisation. So:

```swift
@State private var measurers = TextMeasurerStore()
// ...
let style = TextStyle(font: .body, in: fontContext, lineLimit: 3)
let measurer = measurers.measurer(for: style)

LazyLayoutView(posts, layout: MasonryLayout(columns: 1), recomputeOn: style) { post, width in
    .fixedHeight(measurer.height(of: post.body, width: width))
} content: { post in
    Text(post.body).lineLimit(3)
}
```

still hands the layout a `.fixedHeight`. From the layout's point of view nothing
has changed — it receives known sizes and does arithmetic. What changed is only
who worked the number out. See <doc:MeasuringText>.

## Why the width arrives late

Sizes that depend on the container width cannot be computed at initialization,
because the width is not known then — it arrives when the container is measured.
That is why there are two initializers on ``LazyLayoutView``:

- `item: (Element) -> Layout.Item` runs once, at initialization. Right for
  anything intrinsic to the element.
- `item: (Element, Double) -> Layout.Item` runs at solve time and again on every
  width change. Necessary for anything width-dependent.

The second is strictly more expensive: it runs for the whole collection each time
the width changes, not just for visible items, because the layout must place
everything to know the content height. With a cache that is cheap; cold, it is
not. ``TextMeasurer`` documents the numbers.

## The layout layer stays pure

``LazyLayoutAlgorithm/layout(items:containerWidth:)`` must be a pure function of
its inputs. The container caches results and re-solves on width changes, so a
layout that consults external mutable state will appear to glitch.

Text measurement does not compromise this. Measurement happens *before* the layout
call, in the item closure; the layout still receives plain numbers. This is
enforced structurally rather than by convention: CoreText may only be imported
under `Sources/LazyLayoutKit/Text`, and the geometry and layout directories may
not import a UI framework at all. CI checks both.

## Topics

### Related

- <doc:MeasuringText>
- ``ItemMetric``
- ``LazyLayoutAlgorithm``
