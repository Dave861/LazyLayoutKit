import Foundation
import Observation
import SwiftUI
@_spi(Instrumentation) import LazyLayoutKit

struct DemoItem: Identifiable, Equatable, Sendable {
    let id: Int
    var metric: ItemMetric
    var interval: TimelineLayout.Interval
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

    var id: String {
        rawValue
    }

    var symbol: String {
        switch self {
        case .masonry: "square.grid.3x3.fill"
        case .timeline: "calendar.day.timeline.left"
        case .lazyStack: "list.bullet"
        case .eager: "exclamationmark.triangle.fill"
        }
    }

    var caption: String {
        switch self {
        case .masonry: "LazyLayoutKit · virtualized"
        case .timeline: "LazyLayoutKit · overlapping frames"
        case .lazyStack: "Apple baseline · fixed geometry"
        case .eager: "Every subview built up front"
        }
    }

    /// Eager mode is capped far below the others because it cannot survive them.
    var isCapped: Bool {
        self == .eager
    }
}

enum ItemCount: Int, CaseIterable, Identifiable, Sendable {
    case tenThousand = 10000
    case hundredThousand = 100_000
    case million = 1_000_000

    var id: Int {
        rawValue
    }

    var label: String {
        switch self {
        case .tenThousand: "10K"
        case .hundredThousand: "100K"
        case .million: "1M"
        }
    }

    var description: String {
        "\(rawValue.formatted()) items"
    }
}

@Observable
@MainActor
final class DemoModel {
    static let eagerCap = 3000

    private(set) var items: [DemoItem] = []
    private(set) var isGenerating = false
    /// Bumped whenever the dataset is rebuilt, so a view can key its identity on
    /// it and start from a clean scroll position.
    private(set) var generation = 0

    var mode: Mode = .masonry {
        didSet {
            if mode != oldValue {
                modeChangedAt = .now
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

    /// How much extra content the container builds above and below the viewport,
    /// in screen-heights. Adjustable because it is the prime suspect for dense
    /// layouts: one screen-height of overscan is ~54 cells of masonry but ~127
    /// of timeline, whose items are much smaller.
    var overscan: Double = 1.0

    /// Ever-decreasing, so inserted items can never collide with each other or
    /// with the 0..<n range used by the generated data.
    private var nextInsertedID = 0

    let masonry = MasonryLayout(columns: 3, spacing: 10)
    let timeline = TimelineLayout(pointsPerUnit: 3, laneSpacing: 8, minimumHeight: 44)

    init() {
        regenerate()
    }

    var eagerItems: [DemoItem] {
        Array(items.prefix(Self.eagerCap))
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
        generation += 1
        isGenerating = false
    }

    /// The anchoring case: an item far above the viewport changes size.
    func toggleSizeOfItemNearTop() {
        guard items.count > 10 else { return }
        items[10].metric = items[10].metric == .fixedHeight(1400)
            ? .aspectRatio(1.2)
            : .fixedHeight(1400)
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
        let inserted = newIDs.map { id in
            DemoItem(
                id: id,
                metric: .aspectRatio(Double.random(in: 0.6 ... 1.8)),
                interval: .init(start: -Double.random(in: 20 ... 200), duration: 12)
            )
        }
        items.insert(contentsOf: inserted, at: 0)
    }
}
