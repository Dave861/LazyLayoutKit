import CoreText
import Synchronization

/// Computes how tall a string will be, without building a view.
///
/// This is what makes self-sizing text compatible with a lazy container. The
/// package's layout contract has always been that sizes are known *before* a view
/// exists — 0.1 simply had no way to know the size of text. Measuring with
/// CoreText closes that gap without introducing a measure-and-correct lifecycle:
/// the height is still known up front, it is just computed rather than supplied.
/// Layout stays pure arithmetic over known sizes.
///
/// ```swift
/// let measurer = TextMeasurer(TextStyle(font: font, lineLimit: 3))
/// let height = measurer.height(of: post.body, width: columnWidth)
/// ```
///
/// In a SwiftUI view, hold it in a ``TextMeasurerStore`` rather than constructing
/// one in `body` — the cache is the whole performance story, and `body` runs
/// often.
///
/// ## Cost, and why the cache is not optional
///
/// Measurement is roughly **31 µs per realistic feed item** on an iPhone 14 Pro
/// and 28 µs on an M4, scaling at about 1 µs per word. A cached lookup is
/// **~470 ns** on device and ~130 ns on an M4. That ~65x gap on device is the
/// whole performance story: measuring the same text at the same width twice is
/// cheap, and measuring a large collection for the first time is not.
///
/// | items | first pass, A16 |
/// |---|---|
/// | 1,000 | 32 ms |
/// | 10,000 | 315 ms |
/// | 100,000 | 3,115 ms |
///
/// **Self-sizing text is practical to roughly 10,000 items.** The package's
/// 100k-and-beyond figures belong to layouts driven by ``ItemMetric``, where
/// sizing is arithmetic. Above a few thousand text items, drive the first pass
/// with ``heights(of:width:chunkSize:)`` off the main actor.
///
/// Measurement does not parallelise — CoreText serialises internally, and a
/// ten-core machine measured 1.27x, so this type deliberately offers no
/// concurrent bulk API. The async variant exists to *yield*, not to go faster.
///
/// ## Accuracy
///
/// Where CoreText and SwiftUI's own text layout disagree, this errs **tall**.
/// A slightly generous measurement leaves a hairline gap; a short one clips the
/// last line, which is a visible bug. Heights are rounded up to whole points and
/// widths are quantised downward for the same reason.
///
/// How generous, measured against hosted `Text`: up to **2pt per line on macOS**,
/// and about **2pt per line on iOS**, where the system font carries leading that
/// macOS's does not. Nothing has been observed to clip on either. For a
/// three-line cell that is roughly 8% of extra height, which reads as a small gap
/// beneath short cells. Tightening it is tracked; the conservative rule is kept
/// because every tighter candidate tested came in *short* at small point sizes,
/// and short is the failure that is actually visible.
public final class TextMeasurer: Sendable {
    /// The style every measurement uses.
    public let style: TextStyle

    /// Height of a single line.
    ///
    /// See ``lineHeight(for:)`` — this is not simply `ceil(ascent + descent +
    /// leading)`, and the difference is the difference between clipping and not.
    private let lineHeight: Double

    /// Average advance of a lowercase Latin glyph, used only to size the initial
    /// prefix budget. An inaccurate value costs a retry, never a wrong answer.
    private let averageAdvance: Double

    private let cacheLimit: Int
    private let state: Mutex<State>

    private struct State {
        var heights: [Key: Double] = [:]
        var hits = 0
        var misses = 0
    }

    private struct Key: Hashable {
        let text: String
        let width: Double
    }

    /// - Parameters:
    ///   - style: The font, line limit and line spacing to measure against.
    ///   - cacheLimit: How many measured results to retain. When exceeded the
    ///     cache is emptied rather than evicted one entry at a time — for the
    ///     access pattern here (a bounded collection re-measured at a couple of
    ///     widths) a scan-resistant policy would cost more than it saves. The
    ///     default holds a 10,000-item feed at two widths.
    public init(_ style: TextStyle, cacheLimit: Int = 20000) {
        self.style = style
        self.cacheLimit = max(1, cacheLimit)
        lineHeight = Self.lineHeight(for: style.font)
        averageAdvance = Self.averageAdvance(of: style.font)
        state = Mutex(State())
    }

    // MARK: - Measuring

    /// The height `text` needs at `width`, in points.
    ///
    /// Returns 0 for a non-positive or non-finite width: a container with no room
    /// gets no height, rather than the enormous one that measuring at zero width
    /// would otherwise produce.
    public func height(of text: String, width: Double) -> Double {
        guard width > 0, width.isFinite else { return 0 }
        // Quantise downward so near-identical widths share a cache entry. Down
        // rather than to-nearest: a narrower measurement is never shorter than
        // the true height, so the rounding error can only add a hairline gap.
        let quantised = (width * 2).rounded(.down) / 2
        guard quantised > 0 else { return 0 }

        let key = Key(text: text, width: quantised)
        if let cached = state.withLock({ state -> Double? in
            if let hit = state.heights[key] {
                state.hits += 1
                return hit
            }
            state.misses += 1
            return nil
        }) {
            return cached
        }

        let height = computeHeight(of: text, width: quantised)
        state.withLock { state in
            if state.heights.count >= cacheLimit {
                state.heights.removeAll(keepingCapacity: true)
            }
            state.heights[key] = height
        }
        return height
    }

    /// Heights for a whole collection, measured in order.
    ///
    /// Synchronous, so it blocks for as long as the table in this type's
    /// documentation says. Past a few thousand uncached items, prefer
    /// ``heights(of:width:chunkSize:)``.
    public func heights(of texts: some Sequence<String>, width: Double) -> [Double] {
        texts.map { height(of: $0, width: width) }
    }

    /// Heights for a whole collection, yielding between chunks so a long first
    /// pass does not block whatever is driving it.
    ///
    /// This is cooperative, not parallel: CoreText does not scale across cores,
    /// so the total work is the same as the synchronous version. What changes is
    /// that it can be cancelled and does not monopolise the actor it runs on.
    ///
    /// - Parameter texts: The strings to measure, in order.
    /// - Parameter width: The width they will be laid out in, in points.
    /// - Parameter chunkSize: How many items to measure between yields. There is
    ///   deliberately no default: it is the only knob that trades responsiveness
    ///   against overhead, and the right value depends on how long the caller can
    ///   afford to block. At roughly 31 µs per item on device, 256 is about 8 ms
    ///   per chunk — a reasonable starting point. Requiring it also keeps this overload
    ///   distinct from the synchronous ``heights(of:width:)``, which the compiler
    ///   would otherwise not be able to tell apart at the call site.
    ///
    /// - Throws: `CancellationError` if the surrounding task is cancelled.
    public func heights(
        of texts: [String],
        width: Double,
        chunkSize: Int
    ) async throws -> [Double] {
        let chunk = max(1, chunkSize)
        var results: [Double] = []
        results.reserveCapacity(texts.count)
        var index = texts.startIndex
        while index < texts.endIndex {
            try Task.checkCancellation()
            let end = min(index + chunk, texts.endIndex)
            for position in index ..< end {
                results.append(height(of: texts[position], width: width))
            }
            index = end
            await Task.yield()
        }
        return results
    }

    /// How many lines `text` occupies at `width`, capped by the style's line limit.
    public func lineCount(of text: String, width: Double) -> Int {
        guard width > 0, width.isFinite else { return 0 }
        return countLines(in: text, width: (width * 2).rounded(.down) / 2)
    }

    // MARK: - Cache

    /// Empties the cache. Worth calling when the underlying content has churned
    /// completely; not needed for a width change, which keys separately.
    public func clearCache() {
        state.withLock { $0 = State() }
    }

    @_spi(Instrumentation)
    public var cacheStatistics: (hits: Int, misses: Int, entries: Int) {
        state.withLock { ($0.hits, $0.misses, $0.heights.count) }
    }

    // MARK: - Implementation

    private func computeHeight(of text: String, width: Double) -> Double {
        let lines = countLines(in: text, width: width)
        guard lines > 0 else { return 0 }
        let total = Double(lines) * lineHeight + Double(lines - 1) * style.lineSpacing
        return total.rounded(.up)
    }

    private func countLines(in text: String, width: Double) -> Int {
        // An empty string still occupies a line, the same as an empty `Text`.
        guard !text.isEmpty else { return 1 }

        guard let limit = style.lineLimit else {
            // Without a limit every line counts, so there is nothing to bound:
            // the whole string has to be walked.
            return breakLines(in: text, width: width, limit: Int.max).lines
        }

        // With a limit, only enough text to fill that many lines matters. Line
        // breaking depends solely on *preceding* text, so any break found
        // strictly inside a prefix is the break the full string would produce —
        // this is exact, not an approximation. The only unsafe outcome is running
        // out of prefix before reaching the limit, which is detected below and
        // retried with more text rather than guessed at.
        //
        // The payoff is entirely at the tail. For ordinary feed text it saves
        // nothing; for a 10 kB string it is the difference between 0.10 ms and
        // 8.9 ms, which is a dropped frame.
        let length = text.count
        var budget = prefixBudget(width: width, limit: limit, textLength: length)
        while true {
            guard budget < length else {
                return breakLines(in: text, width: width, limit: limit).lines
            }
            let prefix = String(text.prefix(budget))
            let result = breakLines(in: prefix, width: width, limit: limit)
            if result.lines >= limit || !result.exhaustedInput {
                return result.lines
            }
            // Inconclusive: the prefix ran out first, so the real string may have
            // more lines. Double and retry, saturating at the string's length so
            // the doubling cannot overflow.
            budget = budget >= length / 2 ? length : budget * 2
        }
    }

    /// Walks line breaks, stopping at `limit`.
    ///
    /// - Returns: the number of lines found, and whether the input ran out before
    ///   the limit was reached.
    private func breakLines(
        in text: String,
        width: Double,
        limit: Int
    ) -> (lines: Int, exhaustedInput: Bool) {
        let attributed = CFAttributedStringCreate(
            nil,
            text as CFString,
            [kCTFontAttributeName as String: style.font] as CFDictionary
        )
        guard let attributed else { return (1, true) }
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = CFAttributedStringGetLength(attributed)

        var start = 0
        var lines = 0
        while start < length, lines < limit {
            let take = CTTypesetterSuggestLineBreak(typesetter, start, width)
            // A zero-length suggestion means no further progress is possible —
            // a width too narrow for even one glyph, for instance. Stop rather
            // than spin.
            guard take > 0 else { break }
            start += take
            lines += 1
        }
        return (max(lines, 1), start >= length)
    }

    /// Characters worth measuring to establish `limit` lines at `width`.
    ///
    /// Doubled over the naive estimate because underestimating costs a retry
    /// while overestimating costs proportional work. Measured at 0 retries across
    /// 3,000 strings spanning one to three lines.
    ///
    /// Computed entirely in `Double` and only narrowed to `Int` once it is known
    /// to be below the string's length. `width` and `lineLimit` are both public
    /// input: a width of 1e300 makes `width / averageAdvance` exceed `Int.max`,
    /// and `Int(_:)` *traps* on that rather than saturating, so the obvious
    /// version crashes on a value a caller is free to pass. Multiplying by the
    /// limit can overflow for the same reason.
    ///
    /// Capping at the length is not just overflow safety: measuring more
    /// characters than the string has is wasted work in every case.
    private func prefixBudget(width: Double, limit: Int, textLength: Int) -> Int {
        let perLine = (width / averageAdvance).rounded(.down)
        guard perLine.isFinite, perLine >= 1 else { return textLength }

        let estimate = perLine * Double(limit) * 2
        guard estimate.isFinite, estimate < Double(textLength) else { return textLength }

        return min(max(32, Int(estimate)), textLength)
    }

    /// Height of one rendered line, chosen to never come in under SwiftUI's.
    ///
    /// The obvious rule — `ceil(ascent + descent + leading)` — is wrong, and
    /// wrong in the dangerous direction at small sizes. Measured against hosted
    /// SwiftUI `Text` on macOS 26:
    ///
    /// | point size | `ceil(a + d + l)` | SwiftUI | rounding each term |
    /// |---|---|---|---|
    /// | 11 | 13 | **14** | 14 |
    /// | 13 | 16 | 16 | 16 |
    /// | 17 | 21 | 20 | 21 |
    /// | 20 | 24 | 24 | 25 |
    /// | 28 | 33 | 33 | 34 |
    /// | 34 | 41 | 40 | 41 |
    ///
    /// At 11pt the summed rule measures 13 against a rendered 14 and clips the
    /// text. Rounding each metric up independently never came in under SwiftUI at
    /// any size tested, at a cost of up to about 1pt per line of extra height.
    ///
    /// SwiftUI's exact rule is not documented and evidently is not a simple
    /// function of these three metrics — the relationship is not even monotonic
    /// in the same direction across the range. Rather than reverse-engineer
    /// something that could change between OS releases, this takes the
    /// conservative bound and `TextFidelityTests` sweeps the size range to catch
    /// it if the relationship ever moves.
    private static func lineHeight(for font: CTFont) -> Double {
        CTFontGetAscent(font).rounded(.up)
            + CTFontGetDescent(font).rounded(.up)
            + CTFontGetLeading(font).rounded(.up)
    }

    /// Mean advance across lowercase Latin letters and a space.
    ///
    /// Only ever used to size the prefix budget, so a rough answer is fine — and
    /// for scripts where it is badly wrong (CJK advances are far wider) the retry
    /// loop corrects it without affecting the result.
    private static func averageAdvance(of font: CTFont) -> Double {
        let characters = Array("etaoinshrdlucmfwypvbgkjqxz ".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count) else {
            // No Latin coverage. Fall back to a fraction of the em square, which
            // is crude but only ever costs a retry.
            return max(1, CTFontGetSize(font) * 0.5)
        }
        var advances = [CGSize](repeating: .zero, count: characters.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, characters.count)
        let total = advances.reduce(0.0) { $0 + Double($1.width) }
        let mean = total / Double(characters.count)
        return mean > 0 ? mean : max(1, CTFontGetSize(font) * 0.5)
    }
}
