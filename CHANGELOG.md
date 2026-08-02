# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
