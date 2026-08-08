/// Answers "which items intersect this vertical range?" for an arbitrary set of
/// frames, without assuming anything about how the layout produced them.
///
/// This is the piece that makes the package general rather than masonry-shaped.
/// Masonry can answer the question with a binary search per column because it is
/// monotonic within a column; a calendar, a timeline or a packed board is not
/// monotonic in any convenient way. A uniform bucket index makes no structural
/// assumption at all.
///
/// ## Layout
///
/// Compressed-sparse-row, not a dictionary of buckets:
///
/// - `bucketStarts` has `bucketCount + 1` entries; bucket `b` owns
///   `entries[bucketStarts[b] ..< bucketStarts[b + 1]]`.
/// - `entries` holds item indices, grouped by bucket and ascending within each.
///
/// Both are contiguous, so a query is a couple of sequential reads rather than a
/// hash lookup and a pointer chase per bucket. That matters more than it looks:
/// the query runs once per frame with an entire render in between, so it is
/// cache-latency bound, not compute bound.
///
/// ## Oversized items
///
/// An item spanning many buckets would otherwise be duplicated into every one of
/// them, which makes worst-case memory quadratic for tall or sparse content. Any
/// item spanning more than `maxBucketSpan` buckets is instead put in
/// `oversized` and tested on every query. In normal layouts that list is
/// empty or tiny. A pathological layout where most items are oversized degrades
/// the query to a linear scan — correct, just not fast.
public struct VerticalVisibilityIndex: Sendable {
    /// Above this many buckets, an item goes in `oversized` instead of being
    /// duplicated. 8 is a guess that keeps duplication bounded without pushing
    /// ordinary tall cells onto the linear path; it is not tuned.
    static let maxBucketSpan = 8

    /// Target average occupancy per bucket. Small enough that a query touches
    /// few items, large enough that the offset array stays cheap.
    static let targetItemsPerBucket = 12

    let originY: Double
    let bucketHeight: Double
    let bucketCount: Int
    let bucketStarts: [Int]
    let entries: [Int]
    /// Items too tall to bucket, checked on every query.
    let oversized: [Int]

    /// Contiguous payload owned by this index, excluding Array headers and
    /// allocator bookkeeping. Used by the package benchmark, not public API.
    @_spi(Instrumentation)
    public var storageByteCount: Int {
        bucketStarts.count * MemoryLayout<Int>.stride
            + entries.count * MemoryLayout<Int>.stride
            + oversized.count * MemoryLayout<Int>.stride
    }

    public init(frames: [LayoutRect]) {
        guard !frames.isEmpty else {
            originY = 0
            bucketHeight = 1
            bucketCount = 0
            bucketStarts = [0]
            entries = []
            oversized = []
            return
        }

        // The indexed extent must come from *finite* frames only. Letting a
        // single infinite or NaN frame widen the span collapsed the whole index
        // to a one-point extent, after which the bucket sweep was skipped for
        // every query and no valid frame was ever found. Invalid frames are
        // excluded here and handled individually below.
        var lowest = Double.infinity
        var highest = -Double.infinity
        var sawFiniteFrame = false
        for frame in frames where Self.isBucketable(frame) {
            sawFiniteFrame = true
            // A negative-height frame would invert the range; treat it as its
            // own normalised span rather than trusting the caller.
            lowest = min(lowest, min(frame.minY, frame.maxY))
            highest = max(highest, max(frame.minY, frame.maxY))
        }
        if !sawFiniteFrame {
            lowest = 0
            highest = 0
        }

        let span = max(0, highest - lowest)
        let targetBuckets = max(1, frames.count / Self.targetItemsPerBucket)
        let height = span > 0 ? max(1, span / Double(targetBuckets)) : 1
        let count = span > 0 ? max(1, min(frames.count, Int(span / height) + 1)) : 1

        originY = lowest
        bucketHeight = height
        bucketCount = count

        // Pass 1: count per bucket, and set aside anything oversized.
        var counts = [Int](repeating: 0, count: count)
        var tall: [Int] = []
        var spans = [(first: Int, last: Int)]()
        spans.reserveCapacity(frames.count)

        for frame in frames {
            // Non-finite frames cannot be bucketed meaningfully. They go on the
            // oversized path so the same intersection predicate still decides
            // them, which keeps the index in agreement with a linear scan.
            guard Self.isBucketable(frame) else {
                spans.append((first: -1, last: -1))
                continue
            }
            let (first, last) = Self.bucketRange(
                for: frame, originY: lowest, bucketHeight: height, bucketCount: count
            )
            if last - first + 1 > Self.maxBucketSpan {
                spans.append((first: -1, last: -1))
            } else {
                spans.append((first: first, last: last))
                for bucket in first ... last {
                    counts[bucket] += 1
                }
            }
        }
        for (index, span) in spans.enumerated() where span.first < 0 {
            tall.append(index)
        }

        // Pass 2: prefix sums, then fill in item order so each bucket's slice is
        // ascending by index — that keeps query results in source order and
        // makes the z-ordering deterministic.
        var starts = [Int](repeating: 0, count: count + 1)
        var running = 0
        for bucket in 0 ..< count {
            starts[bucket] = running
            running += counts[bucket]
        }
        starts[count] = running

        var cursors = starts
        var filled = [Int](repeating: 0, count: running)
        for (index, span) in spans.enumerated() where span.first >= 0 {
            for bucket in span.first ... span.last {
                filled[cursors[bucket]] = index
                cursors[bucket] += 1
            }
        }

        bucketStarts = starts
        entries = filled
        oversized = tall
    }

    /// Whether a frame can take part in bucketing at all. Anything non-finite
    /// must not influence the indexed extent, or one bad frame hides every good
    /// one.
    static func isBucketable(_ frame: LayoutRect) -> Bool {
        frame.minY.isFinite && frame.maxY.isFinite
    }

    static func bucketRange(
        for frame: LayoutRect,
        originY: Double,
        bucketHeight: Double,
        bucketCount: Int
    ) -> (Int, Int) {
        let low = min(frame.minY, frame.maxY)
        let high = max(frame.minY, frame.maxY)
        let firstRaw = (low - originY) / bucketHeight
        let lastRaw = (high - originY) / bucketHeight
        let first = firstRaw.isFinite ? Int(firstRaw.rounded(.down)) : 0
        let last = lastRaw.isFinite ? Int(lastRaw.rounded(.down)) : 0
        return (
            max(0, min(bucketCount - 1, first)),
            max(0, min(bucketCount - 1, last))
        )
    }

    /// Item indices whose frames intersect `range` vertically, ascending.
    ///
    /// `frames` must be the same array the index was built from.
    public func indices(intersecting range: LayoutRect, frames: [LayoutRect]) -> [Int] {
        var result: [Int] = []
        appendIndices(intersecting: range, frames: frames, to: &result)
        return result
    }

    /// Buffer-reusing variant for the per-frame path.
    public func appendIndices(
        intersecting range: LayoutRect,
        frames: [LayoutRect],
        to result: inout [Int]
    ) {
        guard bucketCount > 0 else { return }

        let start = result.count
        let (first, last) = Self.bucketRange(
            for: range, originY: originY, bucketHeight: bucketHeight, bucketCount: bucketCount
        )

        // A range entirely outside the indexed span still has to consult the
        // oversized list, but its bucket sweep is empty. `bucketRange` clamps,
        // so check for genuine non-overlap explicitly.
        let indexedTop = originY
        let indexedBottom = originY + Double(bucketCount) * bucketHeight
        if range.maxY > indexedTop, range.minY < indexedBottom {
            for bucket in first ... last {
                for slot in bucketStarts[bucket] ..< bucketStarts[bucket + 1] {
                    let item = entries[slot]
                    if frames[item].intersectsVertically(range) {
                        result.append(item)
                    }
                }
            }
        }

        for item in oversized where frames[item].intersectsVertically(range) {
            result.append(item)
        }

        // An item spanning several buckets is stored in each of them, so the
        // sweep can emit it more than once. Results are a viewport's worth of
        // items — tens, not thousands — so sorting and collapsing is cheaper
        // than carrying a per-item seen-set, and it leaves the output in source
        // order, which is also the z-order the container draws in.
        let appended = result.count - start
        guard appended > 1 else { return }
        var window = Array(result[start...])
        window.sort()
        result.removeLast(appended)
        var previous: Int?
        for item in window where item != previous {
            result.append(item)
            previous = item
        }
    }
}
