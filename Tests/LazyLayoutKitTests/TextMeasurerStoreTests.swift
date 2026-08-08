import CoreText
@_spi(Instrumentation) @testable import LazyLayoutKit
import Testing

/// Lifecycle of the retained measurer.
///
/// This is the demo's integration expressed as a testable type. The failure it
/// guards against is invisible rather than loud: a measurer rebuilt on each
/// render still returns correct heights, it just does so at 28 µs instead of
/// 130 ns, so the only symptom is that the package looks slow.
///
/// The specific trap is that resolving and storing must be the *same* step. A
/// version that returns a fresh measurer from `body` and stores a different one
/// from `.task` passes any test that only checks correctness.
@Suite("Text measurer store")
struct TextMeasurerStoreTests {
    private static func style(size: Double = 17, lineLimit: Int? = 3) -> TextStyle {
        TextStyle(font: CTFontCreateWithName("Helvetica" as CFString, size, nil), lineLimit: lineLimit)
    }

    private static let body = String(repeating: "The quick brown fox jumps. ", count: 4)

    @Test("An equal style returns the identical instance")
    func equalStyleReturnsSameInstance() {
        let store = TextMeasurerStore()
        let first = store.measurer(for: Self.style())
        let second = store.measurer(for: Self.style())
        #expect(first === second)
    }

    @Test("A changed style returns a different instance")
    func changedStyleReturnsNewInstance() {
        let store = TextMeasurerStore()
        let small = store.measurer(for: Self.style(size: 13))
        let large = store.measurer(for: Self.style(size: 28))
        #expect(small !== large)
        #expect(large.style == Self.style(size: 28))
    }

    /// The bug this type exists for: the instance handed back must be the one
    /// retained, not a transient built alongside a different stored one.
    @Test("The returned instance is the one retained")
    func returnedInstanceIsTheRetainedOne() {
        let store = TextMeasurerStore()
        let returned = store.measurer(for: Self.style(size: 20))
        #expect(store.current === returned)

        // And after a change, still the one just handed out.
        let afterChange = store.measurer(for: Self.style(size: 34))
        #expect(store.current === afterChange)
        #expect(afterChange !== returned)
    }

    /// The point of retaining it at all. If repeated resolution returned fresh
    /// instances this would read as all misses.
    @Test("Repeated resolution preserves the cache")
    func repeatedResolutionPreservesTheCache() {
        let store = TextMeasurerStore()
        let style = Self.style()

        // Simulate several renders, measuring the same text each time.
        for _ in 0 ..< 10 {
            _ = store.measurer(for: style).height(of: Self.body, width: 300)
        }

        let stats = store.measurer(for: style).cacheStatistics
        #expect(stats.misses == 1, "Expected one cold measurement, got \(stats.misses).")
        #expect(stats.hits == 9, "Expected nine cache hits, got \(stats.hits).")
    }

    /// A style change must *not* preserve it: every cached height was measured
    /// against the old font.
    @Test("A style change discards the previous cache")
    func styleChangeDiscardsTheCache() {
        let store = TextMeasurerStore()
        _ = store.measurer(for: Self.style(size: 17)).height(of: Self.body, width: 300)

        let afterChange = store.measurer(for: Self.style(size: 28))
        #expect(afterChange.cacheStatistics.hits == 0)
        #expect(afterChange.cacheStatistics.misses == 0)

        // And the new measurer actually measures differently.
        let smallHeight = TextMeasurer(Self.style(size: 17)).height(of: Self.body, width: 300)
        let largeHeight = afterChange.height(of: Self.body, width: 300)
        #expect(largeHeight > smallHeight)
    }

    @Test("Alternating between two styles does not thrash into a wrong measurer")
    func alternatingStylesStayCorrect() {
        let store = TextMeasurerStore()
        for _ in 0 ..< 5 {
            #expect(store.measurer(for: Self.style(size: 13)).style == Self.style(size: 13))
            #expect(store.measurer(for: Self.style(size: 28)).style == Self.style(size: 28))
        }
    }

    @Test("Concurrent resolution of one style converges on a single instance")
    func concurrentResolutionIsSafe() async {
        let store = TextMeasurerStore()
        let style = Self.style()
        let measurers = await withTaskGroup(of: ObjectIdentifier.self) { group in
            for _ in 0 ..< 100 {
                group.addTask { ObjectIdentifier(store.measurer(for: style)) }
            }
            var seen: Set<ObjectIdentifier> = []
            for await id in group {
                seen.insert(id)
            }
            return seen
        }
        // Any instance created must also be the one stored, so at most one can
        // survive; a torn read-then-write would leave several in circulation.
        #expect(measurers.count == 1, "Saw \(measurers.count) distinct measurers for one style.")
        #expect(measurers.first == store.current.map(ObjectIdentifier.init))
    }
}
