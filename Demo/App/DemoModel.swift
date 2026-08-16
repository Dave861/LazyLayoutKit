import Foundation
import Observation
import SwiftUI
@_spi(Instrumentation) import LazyLayoutKit

struct DemoItem: Identifiable, Equatable, Sendable {
    let id: Int
    var metric: ItemMetric
    var interval: TimelineLayout.Interval
}

/// The Feed scenario's data, kept separate from ``DemoItem`` on purpose.
///
/// Gallery and Timeline run to a million items. Generating and retaining a
/// string for each of those would cost far more memory than the scenario that
/// uses them, and none of it would ever be measured — Feed is capped well below
/// that ceiling because text measurement is.
struct FeedItem: Identifiable, Equatable, Sendable {
    let id: Int
    var body: String
}

enum Mode: String, CaseIterable, Identifiable, Sendable {
    /// The package, doing what it exists for.
    case masonry = "Masonry"
    /// The package again, with a layout whose frames overlap and are not
    /// monotonic in y — the genericity proof, running live.
    case timeline = "Timeline"
    /// Apple's lazy container, as a fairness baseline.
    case lazyStack = "LazyVStack"
    /// The same masonry geometry with every subview built up front.
    case eager = "Eager"
    /// Self-sizing text: heights measured with CoreText at solve time rather
    /// than supplied by the caller.
    case feed = "Feed"
    /// Rows that preserve aspect ratios and fill the width — the layout a grid
    /// cannot express, because the row size is a result of the content.
    case justified = "Justified"
    /// Programmatic scrolling: jump to an item by id, materialized or not.
    case navigate = "Deep link"

    var id: String {
        rawValue
    }

    var symbol: String {
        switch self {
        case .masonry: "square.grid.3x3.fill"
        case .timeline: "calendar.day.timeline.left"
        case .lazyStack: "list.bullet"
        case .eager: "exclamationmark.triangle.fill"
        case .feed: "text.alignleft"
        case .justified: "rectangle.grid.2x2"
        case .navigate: "arrow.down.to.line"
        }
    }

    var caption: String {
        switch self {
        case .masonry: "LazyLayoutKit · virtualized"
        case .timeline: "LazyLayoutKit · overlapping frames"
        case .lazyStack: "Apple baseline · fixed geometry"
        case .eager: "Every subview built up front"
        case .feed: "LazyLayoutKit · measured text"
        case .justified: "LazyLayoutKit · rows fill the width"
        case .navigate: "LazyLayoutKit · scroll to any id"
        }
    }

    /// Eager mode is capped far below the others because it cannot survive them.
    var isCapped: Bool {
        self == .eager
    }
}

enum ItemCount: Int, CaseIterable, Identifiable, Sendable {
    case thousand = 1000
    case tenThousand = 10000
    case hundredThousand = 100_000
    case million = 1_000_000

    var id: Int {
        rawValue
    }

    var label: String {
        switch self {
        case .thousand: "1K"
        case .tenThousand: "10K"
        case .hundredThousand: "100K"
        case .million: "1M"
        }
    }

    var description: String {
        "\(rawValue.formatted()) items"
    }

    /// Counts offered for a given scenario.
    ///
    /// Feed stops at 100K. A million measured strings is several minutes of
    /// CoreText on any machine, so offering it would only invite a hang — and the
    /// package documents ~10,000 as the practical ceiling, which is the number
    /// the run is there to test.
    static func available(for mode: Mode) -> [ItemCount] {
        mode == .feed ? [.thousand, .tenThousand, .hundredThousand] : allCases
    }

    /// The nearest permitted count for a scenario, so switching into Feed at 1M
    /// lands somewhere sane instead of refusing.
    func clamped(for mode: Mode) -> ItemCount {
        let allowed = Self.available(for: mode)
        return allowed.contains(self) ? self : (allowed.last ?? self)
    }
}

@Observable
@MainActor
final class DemoModel {
    static let eagerCap = 3000
    /// The largest Feed dataset, and the largest count the picker offers there.
    static let feedCap = 100_000

    private(set) var items: [DemoItem] = []
    /// Feed's own corpus. Generated to `feedCap` regardless of `count`, then
    /// sliced, so switching between Feed counts never regenerates strings.
    private(set) var feedCorpus: [FeedItem] = []
    private(set) var isGenerating = false
    /// Bumped whenever the dataset is rebuilt, so a view can key its identity on
    /// it and start from a clean scroll position.
    private(set) var generation = 0

    var mode: Mode = .masonry {
        didSet {
            guard mode != oldValue else { return }
            modeChangedAt = .now
            // Feed cannot run at a million items, so entering it from a larger
            // count has to land somewhere valid rather than refuse.
            let clamped = count.clamped(for: mode)
            if clamped != count {
                count = clamped
            }
        }
    }

    var count: ItemCount = .hundredThousand {
        didSet {
            if count != oldValue {
                regenerate()
            }
        }
    }

    var modeChangedAt: Date = .now

    /// How much extra content the container builds above and below the viewport.
    ///
    /// Both units are selectable because comparing them on device is the point:
    /// one screen height is ~56 cells of masonry but ~108 of timeline, so the
    /// same setting means very different amounts of concurrent work.
    ///
    /// Device measurement also showed the item budget does *not* reduce timeline
    /// hitching — that tracks construction rate, not concurrent count — so these
    /// runs exist to measure both properties, not to confirm one.
    var overscan: OverscanChoice = .screens(1)

    enum OverscanChoice: Hashable, CaseIterable, Identifiable {
        case screens(Double)
        case items(Int)

        static let allCases: [OverscanChoice] = [
            .screens(0.25), .screens(0.5), .screens(1), .screens(2),
            .items(40), .items(80), .items(150),
        ]

        var id: String {
            label
        }

        var label: String {
            switch self {
            case let .screens(multiple): "\(multiple.formatted()) screens"
            case let .items(count): "\(count) cells"
            }
        }

        var resolved: Overscan {
            switch self {
            case let .screens(multiple): .screens(multiple)
            case let .items(count): .items(count)
            }
        }
    }

    /// Ever-decreasing, so inserted items can never collide with each other or
    /// with the 0..<n range used by the generated data.
    private var nextInsertedID = 0

    /// Word pool for generated body text. Deliberately ordinary English of
    /// varying length — the interesting variable is how many lines each item
    /// wraps to, not what it says.
    private static let words = """
    the quick brown fox jumps over a lazy dog while sunlight filters through     leaves and someone somewhere is reading a feed on a phone waiting for a     train that has not arrived yet but will eventually
    """.split(separator: " ").map(String.init)

    let masonry = MasonryLayout(columns: 3, spacing: 10)
    /// One column, because the feed scenario is about height varying per item.
    let feedLayout = MasonryLayout(columns: 1, spacing: 10)
    let timeline = TimelineLayout(pointsPerUnit: 3, laneSpacing: 8, minimumHeight: 44)
    let justified = JustifiedLayout(
        targetRowHeight: 200,
        horizontalSpacing: 6,
        verticalSpacing: 6
    )

    init() {
        regenerate()
    }

    var eagerItems: [DemoItem] {
        Array(items.prefix(Self.eagerCap))
    }

    /// Feed's data at the selected count, plus anything inserted by a test action.
    var feedItems: [FeedItem] {
        inserted + feedCorpus.prefix(min(count.rawValue, Self.feedCap))
    }

    /// Items prepended by the pathological-string action, newest first.
    private(set) var inserted: [FeedItem] = []

    /// T3: one ~10 kB string, to see whether a single item can stall a frame.
    ///
    /// Prepended rather than appended so it is on screen immediately. Ids are
    /// negative and monotonic, so they cannot collide with the corpus.
    func insertPathologicalString() {
        nextInsertedID -= 1
        let body = String(repeating: "a long unbroken stretch of prose ", count: 300)
        inserted.insert(FeedItem(id: nextInsertedID, body: body), at: 0)
    }

    /// Bumped to force a Feed re-solve without rebuilding anything.
    ///
    /// `Resize item #10` mutates `DemoItem`, which Feed does not use — Feed has
    /// its own collection — so it could not force a Feed re-solve on its own.
    /// This goes into the container's `recomputeOn`, so bumping it re-solves with
    /// the measurement cache intact: the warm case.
    private(set) var feedRevision = 0

    /// Bumped to force a *cold* Feed solve. The scenario keys its identity on
    /// this, so it is rebuilt from scratch along with its measurer, which is the
    /// only reliable way to empty the cache mid-session.
    private(set) var textCacheGeneration = 0

    /// Warm: re-solve, cache intact.
    func forceFeedResolve() {
        feedRevision += 1
    }

    /// Cold: rebuild the scenario and its measurement cache, then solve.
    func clearTextCacheAndResolve() {
        textCacheGeneration += 1
    }

    /// T5: narrow the container without rotating, to classify the 0.1 width
    /// deadlock on iOS. Rotation changes width too, but it also relays out the
    /// whole hierarchy, which is exactly what would mask the bug.
    var isNarrowed = false

    func clearInsertedItems() {
        inserted.removeAll()
    }

    /// Deterministic, so two runs are comparable.
    func regenerate() {
        isGenerating = true
        let target = count.rawValue
        var state: UInt64 = 0xF00D
        func unit() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state % 10000) / 10000
        }

        var built: [DemoItem] = []
        built.reserveCapacity(target)
        var cursor = 0.0
        for index in 0 ..< target {
            let ratio = 0.55 + unit() * 1.35
            // Timeline items deliberately overlap: each one starts before its
            // predecessor ends, which is what forces multiple lanes. Kept to
            // roughly two or three concurrent so lanes stay wide enough to read
            // — the point is the overlap, not how many lanes fit.
            let gap = 2.5 + unit() * 5
            let duration = 3 + unit() * 9
            built.append(
                DemoItem(
                    id: index,
                    metric: .aspectRatio(ratio),
                    interval: .init(start: cursor, duration: duration)
                )
            )
            cursor += gap
        }
        items = built

        // Strings are generated once, to the feed cap, and independently of
        // `count`. At a million items this loop would build a million strings
        // nothing ever measures.
        if feedCorpus.count != Self.feedCap {
            var feedState: UInt64 = 0xC0FFEE
            func feedUnit() -> Double {
                feedState ^= feedState << 13
                feedState ^= feedState >> 7
                feedState ^= feedState << 17
                return Double(feedState % 10000) / 10000
            }
            var corpus: [FeedItem] = []
            corpus.reserveCapacity(Self.feedCap)
            for index in 0 ..< Self.feedCap {
                // 4 to 50 words, so items wrap to anywhere from one line to many.
                let wordCount = 4 + Int(feedUnit() * 46)
                var body = ""
                body.reserveCapacity(wordCount * 6)
                for position in 0 ..< wordCount {
                    if position > 0 {
                        body += " "
                    }
                    body += Self.words[Int(feedUnit() * Double(Self.words.count - 1))]
                }
                corpus.append(FeedItem(id: index, body: body))
            }
            feedCorpus = corpus
        }

        generation += 1
        isGenerating = false
    }

    /// The anchoring case: an item far above the viewport changes size.
    func toggleSizeOfItemNearTop() {
        guard items.count > 10 else { return }
        items[10].metric = items[10].metric == .fixedHeight(1400)
            ? .aspectRatio(1.2)
            : .fixedHeight(1400)
        // Feed reads a different collection, so mutating `items` alone would
        // leave it untouched. Bumping the revision makes this a re-solve in
        // every scenario, which is what the device protocol assumes.
        feedRevision += 1
    }

    /// Insert at the front — the mutation that shifts every index and proves
    /// anchoring is identity-based.
    func insertAtFront() {
        // Monotonic, never random: random ids in a small range collide with each
        // other and with earlier inserts, and duplicate identity is documented
        // to break anchoring — so a colliding id would look like an anchoring
        // bug when it is really invalid input.
        let newIDs = (0 ..< 25).map { _ -> Int in
            nextInsertedID -= 1
            return nextInsertedID
        }
        let newItems = newIDs.map { id in
            DemoItem(
                id: id,
                metric: .aspectRatio(Double.random(in: 0.6 ... 1.8)),
                interval: .init(start: -Double.random(in: 20 ... 200), duration: 12)
            )
        }
        items.insert(contentsOf: newItems, at: 0)
        // Feed keeps its own collection, so the front-insertion anchoring case
        // has to be exercised there too.
        inserted.insert(
            contentsOf: newIDs.map { id in
                FeedItem(
                    id: id,
                    body: "Inserted item \(-id). "
                        + Self.words.prefix(6 + abs(id) % 20).joined(separator: " ")
                )
            },
            at: 0
        )
    }
}
