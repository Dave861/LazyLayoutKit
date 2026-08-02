/// A timeline / calendar-day layout: items are intervals on a vertical time
/// axis, and overlapping intervals are split into side-by-side lanes.
///
/// This exists mainly to keep the protocol honest. It differs from
/// ``MasonryLayout`` in every way that matters to the machinery:
///
/// - Its ``Item`` is an interval, not a height. A protocol that fixed the layout
///   input to "height or aspect ratio" could not express it at all.
/// - Frames are **not monotonic in y** in item order, and items **overlap**
///   vertically. Any visibility scheme that assumed sorted or column-monotonic
///   output would be wrong here — which is why the package indexes frames
///   generically rather than letting layouts hand-roll their own queries.
/// - Content height comes from the time range, not from stacking.
/// - An all-day event spans the whole content, exercising the visibility index's
///   oversized path.
public struct TimelineLayout: LazyLayoutAlgorithm {
    /// A half-open interval on the timeline, in whatever unit the caller likes
    /// (seconds, minutes, days). ``pointsPerUnit`` converts to layout space.
    public struct Interval: Hashable, Sendable {
        public var start: Double
        public var duration: Double

        public init(start: Double, duration: Double) {
            self.start = start
            self.duration = duration
        }

        var end: Double {
            start + max(0, duration)
        }
    }

    public typealias Item = Interval

    public var pointsPerUnit: Double
    public var laneSpacing: Double
    /// Minimum rendered height, so a zero-length item is still tappable.
    public var minimumHeight: Double

    public init(pointsPerUnit: Double = 1, laneSpacing: Double = 4, minimumHeight: Double = 12) {
        self.pointsPerUnit = pointsPerUnit > 0 && pointsPerUnit.isFinite ? pointsPerUnit : 1
        self.laneSpacing = max(0, laneSpacing.isFinite ? laneSpacing : 0)
        self.minimumHeight = max(0, minimumHeight.isFinite ? minimumHeight : 0)
    }

    public func layout(items: [Interval], containerWidth: Double) -> LazyLayoutResult {
        guard !items.isEmpty else { return LazyLayoutResult(frames: [], contentHeight: 0) }

        let sanitised = items.map { interval -> Interval in
            let start = interval.start.isFinite ? interval.start : 0
            let duration = interval.duration.isFinite ? max(0, interval.duration) : 0
            return Interval(start: start, duration: duration)
        }

        // Earliest start becomes y = 0 so the content plane starts at the top of
        // the first item regardless of the caller's time origin.
        let origin = sanitised.map(\.start).min() ?? 0

        // Greedy lane assignment in start order. Each lane remembers the end of
        // the last interval placed in it; an interval takes the first lane it
        // does not collide with.
        let order = sanitised.indices.sorted {
            sanitised[$0].start == sanitised[$1].start
                ? $0 < $1
                : sanitised[$0].start < sanitised[$1].start
        }
        var laneEnds: [Double] = []
        var laneOf = [Int](repeating: 0, count: sanitised.count)

        // Lanes are assigned on the *rendered* extent, not the semantic one.
        // `minimumHeight` can make a very short event taller than its duration,
        // so two sequential one-minute events would be given the same lane by a
        // duration-based test and then drawn overlapping. Reserving the space
        // actually drawn keeps lanes consistent with what appears on screen.
        let minimumDuration = minimumHeight / pointsPerUnit
        for position in order {
            let interval = sanitised[position]
            let renderedEnd = interval.start + max(minimumDuration, max(0, interval.duration))
            var assigned: Int?
            for lane in laneEnds.indices where laneEnds[lane] <= interval.start {
                assigned = lane
                break
            }
            let lane = assigned ?? laneEnds.count
            if assigned == nil {
                laneEnds.append(renderedEnd)
            } else {
                laneEnds[lane] = renderedEnd
            }
            laneOf[position] = lane
        }

        let laneCount = max(1, laneEnds.count)
        let gaps = laneSpacing * Double(laneCount - 1)
        let laneWidth = max(0, (containerWidth - gaps) / Double(laneCount))

        // Frames are emitted in *item* order, not lane or start order.
        var frames = [LayoutRect]()
        frames.reserveCapacity(sanitised.count)
        var contentBottom = 0.0
        for (position, interval) in sanitised.enumerated() {
            let y = (interval.start - origin) * pointsPerUnit
            let height = max(minimumHeight, interval.duration * pointsPerUnit)
            frames.append(
                LayoutRect(
                    x: Double(laneOf[position]) * (laneWidth + laneSpacing),
                    y: y,
                    width: laneWidth,
                    height: height
                )
            )
            contentBottom = max(contentBottom, y + height)
        }

        return LazyLayoutResult(frames: frames, contentHeight: contentBottom)
    }
}
