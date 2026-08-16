# Scrolling to an item

Jump to any item by its id, whether or not it has ever been built.

## Overview

A deep link into a photo library, a "jump to today" button, reopening at an item
id your app persisted itself: all of them name an item and expect the container to
go there. In a virtualized container that is harder than it sounds, because the
item you are naming almost certainly has no view.

(Note the third one names an id *your* code stored. This type never reports where
the user scrolled to, so it cannot tell you what to persist — see
<doc:ScrollingToAnItem#A-request-is-not-a-record-of-where-the-user-is>.)

Hold a ``LazyLayoutPosition`` and hand the container a binding to it:

```swift
@State private var position = LazyLayoutPosition<Photo.ID>()

var body: some View {
    LazyLayoutView(photos, layout: JustifiedLayout(), position: $position) { photo in
        .aspectRatio(photo.aspectRatio)
    } content: { photo in
        PhotoCell(photo)
    }
    .toolbar {
        Button("Jump to today") {
            position.scrollTo(id: today.id, anchor: .center)
        }
    }
}
```

## Why this is not SwiftUI's `ScrollPosition`

`ScrollPosition`'s id targeting looks for the *view* carrying that identity. In
this container the item you want usually has no view — that is the entire point
of the package — so there is nothing to find, and the request quietly does
nothing.

The resolution goes through the layout instead. ``LayoutSnapshot/frame(of:)``
returns the item's geometry, which was computed as arithmetic long before any
view existed, and
``LayoutSnapshot/offset(toShow:anchor:viewportHeight:currentOffset:)->Double?`` turns that
frame into a scroll offset. Jumping to item 900,000 in a collection of a million
costs one identity scan and one subtraction; nothing between here and there is
built, because nothing between here and there is on screen when you arrive.

Both of those are public, so a scroll offset is something you can compute and
test yourself without rendering anything.

## Anchors

``ScrollAnchor`` says where in the viewport the item should land.

| Anchor | Result |
|---|---|
| ``ScrollAnchor/top`` | The item's top edge at the top of the viewport. |
| ``ScrollAnchor/center`` | The item centred vertically. |
| ``ScrollAnchor/bottom`` | The item's bottom edge at the bottom of the viewport. |
| ``ScrollAnchor/nearest`` | Nothing at all if it is already fully visible; otherwise the smallest move that brings it in. |

Every offset is clamped to the scrollable range, so centring the first item pins
to the top rather than scrolling above the content, and content shorter than the
viewport never scrolls at all.

An item taller than the viewport cannot be made fully visible. ``ScrollAnchor/top``
still pins its top, ``ScrollAnchor/center`` centres on the item's own middle, and
``ScrollAnchor/nearest`` aligns the top — showing the item's beginning, rather
than scrolling past everything unseen to land at its end.

## Opening at an item

For a deep link the destination is known before the view appears. Use
``LazyLayoutPosition/init(initiallyScrolledTo:anchor:)`` and the container opens
at the item rather than opening at the top and jumping:

```swift
@State private var position: LazyLayoutPosition<Photo.ID>

init(deepLink photo: Photo.ID) {
    _position = State(initialValue: LazyLayoutPosition(initiallyScrolledTo: photo))
}
```

This works even when the data has not loaded yet. While the collection is empty
there is nothing to resolve against, so the request is held and applied by the
first solve that has something in it.

## A request is not a record of where the user is

Nothing is read back, so the target a position holds is the last thing *you asked
for*. It is not where the collection ended up: the moment the user scrolls, the
two diverge and nothing here notices.

This is the substantive difference from SwiftUI's `ScrollPosition`, which updates
its `viewID` as the user scrolls and can therefore genuinely restore a position.
``LazyLayoutPosition`` cannot, and does not claim to.

Servicing a request does not clear it either — the container tracks which token it
handled rather than writing back through your binding. Put together, that means a
container created fresh against a well-used position finds a target satisfied long
ago, pointing somewhere the user probably left minutes earlier. Acting on it would
jump somewhere arbitrary on every tab switch or `.id()` change.

So a container **ignores any request made before it existed**, and acts only on
ones issued while it was alive. Request tokens come from a monotonic counter, so
that test is exact rather than a heuristic.

The one exception is deliberate:
``LazyLayoutPosition/init(initiallyScrolledTo:anchor:)`` exists precisely to be
honoured by a container that does not yet exist, so use it when you want a new
container to open at an item.

That exception is **spent on first use**. Once a container has actually scrolled
to it, it behaves like any other used-up request, so a rebuild after the user has
read on starts at the top instead of hauling them back to the deep link.

## When the item is not there

A request for an id that is *not* in a collection that has already been laid out
is dropped rather than held. Holding it would mean a jump firing much later, when
some unrelated change happened to introduce that id, and a surprise scroll is
worse than no scroll.

The case this gives up on is paged loading, where the target legitimately arrives
later. The fix is one line: re-issue the request when the page lands. Calling
``LazyLayoutPosition/scrollTo(id:anchor:)`` always re-fires, including for an id
you have already asked for — which is also what makes a "back to top" button work
the second time the user presses it.

## What it does not do

- **No animation.** Programmatic scrolls are immediate. Animating an offset
  across content that was never built would animate through blank space.
- **No read-back.** ``LazyLayoutPosition`` carries requests to the container and
  reports nothing in return: no "is a scroll pending", no "which item is on
  screen". Both would mean the container writing through your binding, which
  invalidates your view and re-runs the container's initializer — an O(n) pass —
  and would do so while the user is scrolling.
- **It is a parameter, not a modifier.** A `.scrollPosition(_:)`-style modifier
  cannot reach the container's state; the only wiring is an environment value, and
  an `EnvironmentKey` cannot be generic over the id type. Erasing to `AnyHashable`
  to work around that would box the id on the comparison path.

## A note on cost

``LayoutSnapshot/position(of:)`` is a linear scan, deliberately. It runs once per
request — the same access pattern anchoring already pays on every solve — and a
contiguous scan beats building a hash table over the whole collection for that
pattern. It is not something to call per frame.

## Topics

### Types

- ``LazyLayoutPosition``
- ``ScrollAnchor``

### Computing an offset yourself

- ``LayoutSnapshot/offset(toShow:anchor:viewportHeight:currentOffset:)->Double?``
- ``LayoutSnapshot/frame(of:)``
