import CoreText
@testable import LazyLayoutKit
import Testing

/// Properties of ``TextMeasurer`` that hold without reference to a rendered view.
///
/// Agreement with SwiftUI is `TextFidelityTests`' job and needs a hosted view, so
/// it is macOS-only. Everything here — purity, cache transparency, the exactness
/// of the prefix shortcut, degenerate input — is checkable anywhere, and is where
/// the correctness argument actually lives.
@Suite("Text measurement")
struct TextMeasurementTests {
    /// A concrete font rather than a resolved SwiftUI one, so these run on the
    /// package's iOS 18 / macOS 15 floor without the iOS 26 `Font.Resolved` bridge.
    private static func font(size: Double = 17) -> CTFont {
        CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    private static let body = String(
        repeating: "The quick brown fox jumps over the lazy dog. ",
        count: 4
    )

    // MARK: - Purity and caching

    @Test("The same text at the same width always measures the same")
    func measurementIsPure() {
        let measurer = TextMeasurer(TextStyle(font: Self.font()))
        let first = measurer.height(of: Self.body, width: 300)
        let second = measurer.height(of: Self.body, width: 300)
        #expect(first == second)
        #expect(first > 0)
    }

    /// The cache must be invisible. If a cached answer could differ from a fresh
    /// one, every measurement would depend on history.
    @Test("A cached result equals an uncached one")
    func cacheIsTransparent() {
        let style = TextStyle(font: Self.font(), lineLimit: 3)
        let warm = TextMeasurer(style)
        _ = warm.height(of: Self.body, width: 250)
        let cached = warm.height(of: Self.body, width: 250)

        let cold = TextMeasurer(style)
        let fresh = cold.height(of: Self.body, width: 250)

        #expect(cached == fresh)
    }

    @Test("Clearing the cache does not change results")
    func clearingCacheIsTransparent() {
        let measurer = TextMeasurer(TextStyle(font: Self.font()))
        let before = measurer.height(of: Self.body, width: 300)
        measurer.clearCache()
        #expect(measurer.height(of: Self.body, width: 300) == before)
    }

    /// Overflowing the cache empties it, which must cost speed and nothing else.
    @Test("Overflowing the cache does not corrupt results")
    func cacheOverflowIsSafe() {
        let measurer = TextMeasurer(TextStyle(font: Self.font()), cacheLimit: 8)
        let reference = measurer.height(of: Self.body, width: 300)
        for index in 0 ..< 100 {
            _ = measurer.height(of: "filler string number \(index)", width: 300)
        }
        #expect(measurer.height(of: Self.body, width: 300) == reference)
    }

    // MARK: - The prefix shortcut

    /// The load-bearing correctness claim. With a line limit, the measurer reads
    /// only a bounded prefix of the string. That is exact only because line
    /// breaking depends solely on preceding text — so a limited measurer must
    /// agree exactly with capping an unlimited one, for every string shape.
    @Test(
        "Prefix-bounded line counting equals capping a full walk",
        arguments: [1, 2, 3, 5]
    )
    func prefixShortcutIsExact(limit: Int) {
        let unlimited = TextMeasurer(TextStyle(font: Self.font()))
        let limited = TextMeasurer(TextStyle(font: Self.font(), lineLimit: limit))

        var failures: [String] = []
        for wordCount in [1, 2, 3, 5, 8, 12, 20, 35, 60, 150, 600] {
            for width in [80.0, 150.0, 300.0, 500.0] {
                let text = (0 ..< wordCount)
                    .map { "word\($0 % 7)" }
                    .joined(separator: " ")
                let expected = min(unlimited.lineCount(of: text, width: width), limit)
                let actual = limited.lineCount(of: text, width: width)
                if expected != actual {
                    failures.append("\(wordCount) words @ \(width)pt: expected \(expected), got \(actual)")
                }
            }
        }
        #expect(failures.isEmpty, "\(failures)")
    }

    /// A prefix budget sized from Latin advances badly underestimates scripts with
    /// wider glyphs, which is exactly when the retry path has to work.
    @Test("The prefix shortcut is exact for wide-glyph scripts too")
    func prefixShortcutHandlesWideGlyphs() {
        let unlimited = TextMeasurer(TextStyle(font: Self.font()))
        let limited = TextMeasurer(TextStyle(font: Self.font(), lineLimit: 3))
        for repeats in [1, 3, 10, 40] {
            let text = String(repeating: "日本語のテキストを測定する。", count: repeats)
            let expected = min(unlimited.lineCount(of: text, width: 200), 3)
            #expect(limited.lineCount(of: text, width: 200) == expected)
        }
    }

    @Test("A line limit caps height at that many lines")
    func lineLimitCapsHeight() {
        let oneLine = TextMeasurer(TextStyle(font: Self.font(), lineLimit: 1))
        let threeLines = TextMeasurer(TextStyle(font: Self.font(), lineLimit: 3))
        let unlimited = TextMeasurer(TextStyle(font: Self.font()))

        let short = oneLine.height(of: Self.body, width: 200)
        let medium = threeLines.height(of: Self.body, width: 200)
        let full = unlimited.height(of: Self.body, width: 200)

        #expect(short < medium)
        #expect(medium < full)
        #expect(medium <= short * 3)
    }

    // MARK: - Monotonicity

    /// Narrowing the container can only wrap more, never less. This is what makes
    /// quantising the width downward safe.
    @Test("A narrower width never measures shorter")
    func narrowerIsNeverShorter() {
        let measurer = TextMeasurer(TextStyle(font: Self.font()))
        let widths = [500.0, 400.0, 300.0, 200.0, 150.0, 100.0]
        var previous = 0.0
        for width in widths {
            let height = measurer.height(of: Self.body, width: width)
            #expect(height >= previous, "width \(width) measured \(height), narrower than \(previous)")
            previous = height
        }
    }

    @Test("Larger text never measures shorter")
    func largerTextIsNeverShorter() {
        var previous = 0.0
        for size in [9.0, 13.0, 17.0, 24.0, 34.0] {
            let measurer = TextMeasurer(TextStyle(font: Self.font(size: size)))
            let height = measurer.height(of: Self.body, width: 300)
            #expect(height >= previous)
            previous = height
        }
    }

    // MARK: - Line spacing

    @Test("Line spacing applies between lines and not after the last")
    func lineSpacingAppliesBetweenLines() {
        let font = Self.font()
        let none = TextMeasurer(TextStyle(font: font, lineSpacing: 0))
        let spaced = TextMeasurer(TextStyle(font: font, lineSpacing: 10))

        // A single line has no gaps, so spacing must not change it.
        #expect(none.height(of: "short", width: 400) == spaced.height(of: "short", width: 400))

        // A multi-line string gains exactly (lines - 1) gaps.
        let lines = none.lineCount(of: Self.body, width: 200)
        #expect(lines > 1)
        let delta = spaced.height(of: Self.body, width: 200) - none.height(of: Self.body, width: 200)
        #expect(delta == Double(lines - 1) * 10)
    }

    @Test("Negative line spacing is clamped rather than shrinking text")
    func negativeLineSpacingIsClamped() {
        #expect(TextStyle(font: Self.font(), lineSpacing: -20).lineSpacing == 0)
        #expect(TextStyle(font: Self.font(), lineSpacing: .nan).lineSpacing == 0)
    }

    // MARK: - Degenerate input

    @Test(
        "A width that cannot hold content measures zero rather than something enormous",
        arguments: [0.0, -1.0, -500.0, Double.nan, Double.infinity, -Double.infinity]
    )
    func degenerateWidthsMeasureZero(width: Double) {
        let measurer = TextMeasurer(TextStyle(font: Self.font()))
        #expect(measurer.height(of: Self.body, width: width) == 0)
    }

    @Test("An empty string occupies one line rather than nothing")
    func emptyStringOccupiesALine() {
        let measurer = TextMeasurer(TextStyle(font: Self.font()))
        let empty = measurer.height(of: "", width: 300)
        #expect(empty > 0)
        #expect(empty == measurer.height(of: "x", width: 300))
    }

    @Test("Whitespace-only and newline-only strings measure sanely")
    func whitespaceOnlyStrings() {
        let measurer = TextMeasurer(TextStyle(font: Self.font()))
        #expect(measurer.height(of: " ", width: 300) > 0)
        #expect(measurer.height(of: "\n", width: 300) > 0)
        #expect(measurer.height(of: "\n\n\n", width: 300) > measurer.height(of: " ", width: 300))
    }

    /// A width too narrow for a single glyph must terminate rather than loop
    /// forever suggesting zero-length breaks.
    @Test("An impossibly narrow width terminates")
    func impossiblyNarrowWidthTerminates() {
        let measurer = TextMeasurer(TextStyle(font: Self.font()))
        let height = measurer.height(of: Self.body, width: 0.5)
        #expect(height.isFinite)
        #expect(height >= 0)
    }

    /// `width` and `lineLimit` are both public input, and the prefix budget is
    /// derived by dividing and multiplying them. `Int(_:)` *traps* rather than
    /// saturating, so a large finite width crashes the naive version — on a value
    /// any caller is free to pass.
    @Test(
        "An enormous but finite width does not trap",
        arguments: [1e6, 1e12, 1e30, 1e300, Double.greatestFiniteMagnitude]
    )
    func enormousFiniteWidthIsSafe(width: Double) {
        for limit in [Int?.none, 1, 3] {
            let measurer = TextMeasurer(TextStyle(font: Self.font(), lineLimit: limit))
            let height = measurer.height(of: Self.body, width: width)
            #expect(height.isFinite)
            #expect(height > 0)
        }
    }

    /// The same arithmetic multiplies by the line limit, which is also public.
    @Test(
        "An enormous line limit does not trap",
        arguments: [1000, 1_000_000, Int.max / 2, Int.max]
    )
    func enormousLineLimitIsSafe(limit: Int) {
        let measurer = TextMeasurer(TextStyle(font: Self.font(), lineLimit: limit))
        for width in [10.0, 300.0, 1e12] {
            let height = measurer.height(of: Self.body, width: width)
            #expect(height.isFinite)
            #expect(height >= 0)
        }
    }

    /// Both extremes at once, on a string long enough that the retry loop runs
    /// and could double an already-enormous budget.
    @Test("Extreme width and limit together, on a long string")
    func extremeWidthAndLimitTogether() {
        let long = String(repeating: "a long unbroken stretch of prose ", count: 500)
        for limit in [3, Int.max] {
            for width in [1e300, Double.greatestFiniteMagnitude] {
                let measurer = TextMeasurer(TextStyle(font: Self.font(), lineLimit: limit))
                let height = measurer.height(of: long, width: width)
                #expect(height.isFinite)
                #expect(height > 0)
            }
        }
    }

    /// A width so large the whole string fits on one line should measure one
    /// line, not fall back to something degenerate.
    @Test("A width wider than the text measures a single line")
    func veryWideWidthMeasuresOneLine() {
        let measurer = TextMeasurer(TextStyle(font: Self.font()))
        #expect(measurer.lineCount(of: "a short phrase", width: 1e9) == 1)
    }

    /// One pathological string must not cost unbounded time. With a line limit the
    /// prefix shortcut bounds it; this checks the answer stays correct at size.
    @Test("A very long string measures correctly under a line limit")
    func veryLongStringUnderLineLimit() {
        let huge = String(repeating: "a long unbroken stretch of prose ", count: 300)
        let measurer = TextMeasurer(TextStyle(font: Self.font(), lineLimit: 3))
        #expect(measurer.lineCount(of: huge, width: 300) == 3)
    }

    @Test("Line limits below one are clamped to one")
    func lineLimitIsClamped() {
        #expect(TextStyle(font: Self.font(), lineLimit: 0).lineLimit == 1)
        #expect(TextStyle(font: Self.font(), lineLimit: -5).lineLimit == 1)
        #expect(TextStyle(font: Self.font(), lineLimit: nil).lineLimit == nil)
    }

    // MARK: - Concurrency

    /// The cache is shared mutable state behind a lock. Concurrent readers must
    /// get the same answers as serial ones, and must not trip the lock.
    @Test("Concurrent measurement agrees with serial measurement")
    func concurrentMeasurementMatchesSerial() async {
        let texts = (0 ..< 200).map { index in
            String(repeating: "word\(index % 11) ", count: 3 + index % 17)
        }
        let serialMeasurer = TextMeasurer(TextStyle(font: Self.font(), lineLimit: 3))
        let expected = texts.map { serialMeasurer.height(of: $0, width: 280) }

        let concurrentMeasurer = TextMeasurer(TextStyle(font: Self.font(), lineLimit: 3))
        let actual = await withTaskGroup(of: (Int, Double).self) { group in
            for (index, text) in texts.enumerated() {
                group.addTask { (index, concurrentMeasurer.height(of: text, width: 280)) }
            }
            var results = [Double](repeating: 0, count: texts.count)
            for await (index, height) in group {
                results[index] = height
            }
            return results
        }

        #expect(actual == expected)
    }

    @Test("The chunked async pass agrees with the synchronous one")
    func asyncPassMatchesSynchronous() async throws {
        let texts = (0 ..< 500).map { "item \($0) " + String(repeating: "text ", count: $0 % 23) }
        let style = TextStyle(font: Self.font(), lineLimit: 2)
        let expected = TextMeasurer(style).heights(of: texts, width: 300)
        let actual = try await TextMeasurer(style).heights(of: texts, width: 300, chunkSize: 64)
        #expect(actual == expected)
    }

    @Test("A cancelled async pass throws rather than returning a partial answer")
    func asyncPassIsCancellable() async {
        let texts = (0 ..< 20000).map { "item \($0) with a reasonable amount of body text to measure" }
        let measurer = TextMeasurer(TextStyle(font: Self.font()))
        let task = Task { try await measurer.heights(of: texts, width: 300, chunkSize: 16) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("A cancelled pass returned a value instead of throwing.")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }
    }

    // MARK: - Style identity

    /// The style is a cache key and a re-solve trigger, so equality has to be by
    /// value even though `CTFont` is a reference type.
    @Test("Styles compare by value, not by font identity")
    func stylesCompareByValue() {
        let a = TextStyle(font: Self.font(), lineLimit: 2, lineSpacing: 4)
        let b = TextStyle(font: Self.font(), lineLimit: 2, lineSpacing: 4)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)

        #expect(a != TextStyle(font: Self.font(size: 18), lineLimit: 2, lineSpacing: 4))
        #expect(a != TextStyle(font: Self.font(), lineLimit: 3, lineSpacing: 4))
        #expect(a != TextStyle(font: Self.font(), lineLimit: 2, lineSpacing: 5))
    }
}
