#if os(macOS)
    import AppKit
    import CoreText
    @testable import LazyLayoutKit
    import SwiftUI
    import XCTest

    /// Does ``TextMeasurer`` agree with what SwiftUI actually renders?
    ///
    /// Everything else about self-sizing text is arithmetic that can be reasoned
    /// about. This cannot: it is a claim that two independent text engines — Core
    /// Text driven directly, and SwiftUI's own layout — arrive at the same height.
    /// The claim has to be measured against real hosted views, because if the
    /// measurement ever comes in *under* what SwiftUI renders, the last line of
    /// text is clipped, and that is a visible bug in every cell at once.
    ///
    /// The asymmetry is the point. Measuring tall costs a hairline gap; measuring
    /// short costs correctness. So the assertions are asymmetric too: `measured >=
    /// actual` is a hard failure, while `measured - actual` merely has to stay
    /// within a tolerance.
    ///
    /// XCTest rather than Swift Testing because these host real SwiftUI in a
    /// window, matching `MacRuntimeTests`.
    final class TextFidelityTests: XCTestCase {
        /// Strings chosen to break naive measurement, not to look realistic.
        private static let corpus: [(name: String, text: String)] = [
            ("empty", ""),
            ("single word", "Hello"),
            ("short line", "A short line of text"),
            ("exactly wrapping", String(repeating: "wrap ", count: 12)),
            ("two paragraphs", "First paragraph here.\n\nSecond paragraph follows after a blank line."),
            ("embedded newlines", "one\ntwo\nthree\nfour"),
            ("trailing whitespace", "text with trailing space     "),
            ("leading whitespace", "     text with leading space"),
            ("unbreakable word", "Supercalifragilisticexpialidociousandthensomemorelettersafterthat"),
            ("long body", String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 4)),
            ("CJK", "日本語のテキストを測定する速度を確認したい。漢字と仮名が混ざる文章です。"),
            ("CJK long", String(repeating: "日本語のテキストを測定する。", count: 6)),
            ("emoji simple", "Hello 🙂 world 🔥 again"),
            ("emoji ZWJ", "Family 👨‍👩‍👧‍👦 and flag 🏳️‍🌈 and person 👩‍💻"),
            ("emoji only", "🙂🔥👩‍💻🏳️‍🌈🇬🇧"),
            ("RTL Arabic", "مرحبا بالعالم هذا نص عربي للاختبار"),
            ("RTL Hebrew", "שלום עולם זהו טקסט לבדיקה"),
            ("bidi mixed", "English then مرحبا بالعالم then English again"),
            ("combining marks", "e\u{0301}a\u{0300}o\u{0302} combining accents"),
            ("hyphenated", "well-known state-of-the-art double-barrelled compound-words"),
            ("punctuation heavy", "Really?! Yes... (maybe) — \"quoted\" [bracketed] {braced}"),
            ("numbers", "1234567890 3.14159 42% $1,000,000"),
        ]

        private static let widths: [Double] = [120, 200, 358, 500]
        private static let lineLimits: [Int?] = [nil, 1, 2, 3]

        /// Sweeping point size is not optional. An earlier version of this suite
        /// fixed the font at 17pt and passed while the measurer was clipping at
        /// 11pt, because the line-height rule that works at 17 is a point short at
        /// 11. Any font metric derived by formula has to be checked across the
        /// range Dynamic Type actually produces.
        private static let pointSizes: [Double] = [11, 13, 15, 17, 20, 24, 28, 34, 44, 53]

        /// Height SwiftUI actually lays out for this text, from a hosted view.
        @MainActor
        private func actualHeight(
            _ text: String,
            width: Double,
            font: Font,
            lineLimit: Int?,
            lineSpacing: Double
        ) -> Double {
            let view = Text(text)
                .font(font)
                .lineLimit(lineLimit)
                .lineSpacing(lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: width, alignment: .topLeading)
            let hosting = NSHostingView(rootView: view)
            // The root view already fixes the width, so the fitting size's height
            // is what SwiftUI decided this text needs.
            hosting.layoutSubtreeIfNeeded()
            return Double(hosting.fittingSize.height)
        }

        @MainActor
        private func makeMeasurer(
            font: Font,
            lineLimit: Int?,
            lineSpacing: Double
        ) throws -> TextMeasurer {
            guard #available(macOS 26, *) else {
                throw XCTSkip("Font.Resolved, and so the Font-to-CTFont bridge, needs macOS 26.")
            }
            let context = EnvironmentValues().fontResolutionContext
            return TextMeasurer(
                TextStyle(font: font, in: context, lineLimit: lineLimit, lineSpacing: lineSpacing)
            )
        }

        // MARK: - The gate

        /// The shipping gate: measured height must never be less than rendered
        /// height, across every combination of corpus, width and line limit.
        @MainActor
        func testMeasuredHeightNeverClipsRenderedText() throws {
            let font = Font.system(size: 17)
            var clipping: [String] = []
            var worstOvershoot = 0.0
            var worstOvershootCase = ""
            var comparisons = 0

            for lineLimit in Self.lineLimits {
                let measurer = try makeMeasurer(font: font, lineLimit: lineLimit, lineSpacing: 0)
                for width in Self.widths {
                    for entry in Self.corpus {
                        let actual = actualHeight(
                            entry.text,
                            width: width,
                            font: font,
                            lineLimit: lineLimit,
                            lineSpacing: 0
                        )
                        let measured = measurer.height(of: entry.text, width: width)
                        comparisons += 1
                        let delta = measured - actual
                        let limitLabel = lineLimit.map(String.init) ?? "none"
                        let label = "\(entry.name) @ \(Int(width))pt, limit \(limitLabel)"
                        if delta < 0 {
                            clipping.append(
                                String(format: "%@: measured %.1f < rendered %.1f", label, measured, actual)
                            )
                        } else if delta > worstOvershoot {
                            worstOvershoot = delta
                            worstOvershootCase = label
                        }
                    }
                }
            }

            print("fidelity: \(comparisons) comparisons, worst overshoot \(worstOvershoot)pt (\(worstOvershootCase))")
            XCTAssertTrue(
                clipping.isEmpty,
                "Measured height was shorter than rendered height, which clips text:\n"
                    + clipping.joined(separator: "\n")
            )
        }

        /// A measurement that never clips is trivially satisfiable by returning a
        /// huge number, so bound the error in the other direction too.
        @MainActor
        func testMeasuredHeightStaysWithinToleranceOfRenderedText() throws {
            let font = Font.system(size: 17)
            // One line of 17pt system text is about 20pt, so this permits roughly
            // one spare line before failing. Tightening it is a good thing to
            // attempt; loosening it should require a reason.
            let tolerance = 24.0
            var excessive: [String] = []

            for lineLimit in Self.lineLimits {
                let measurer = try makeMeasurer(font: font, lineLimit: lineLimit, lineSpacing: 0)
                for width in Self.widths {
                    for entry in Self.corpus {
                        let actual = actualHeight(
                            entry.text,
                            width: width,
                            font: font,
                            lineLimit: lineLimit,
                            lineSpacing: 0
                        )
                        let measured = measurer.height(of: entry.text, width: width)
                        let delta = measured - actual
                        if delta > tolerance {
                            let limitLabel = lineLimit.map(String.init) ?? "none"
                            excessive.append(
                                String(
                                    format: "%@ @ %dpt, limit %@: measured %.1f vs rendered %.1f (+%.1f)",
                                    entry.name, Int(width), limitLabel, measured, actual, delta
                                )
                            )
                        }
                    }
                }
            }

            XCTAssertTrue(
                excessive.isEmpty,
                "Measured height overshot rendered height by more than \(tolerance)pt:\n"
                    + excessive.joined(separator: "\n")
            )
        }

        /// The same gate, swept across point size.
        ///
        /// This exists because the fixed-17pt version above passed while the
        /// measurer was clipping at 11pt: the line-height rule that is a point
        /// generous at 17 was a point short at 11. Dynamic Type spans roughly
        /// 11–53pt for body text, so the whole range has to hold.
        @MainActor
        func testMeasuredHeightNeverClipsAcrossPointSizes() throws {
            var clipping: [String] = []
            var worstOvershootPerLine = 0.0
            var comparisons = 0

            for size in Self.pointSizes {
                let font = Font.system(size: size)
                for lineLimit in [Int?.none, 2] {
                    let measurer = try makeMeasurer(font: font, lineLimit: lineLimit, lineSpacing: 0)
                    for width in [200.0, 358.0] {
                        for entry in Self.corpus {
                            let actual = actualHeight(
                                entry.text,
                                width: width,
                                font: font,
                                lineLimit: lineLimit,
                                lineSpacing: 0
                            )
                            let measured = measurer.height(of: entry.text, width: width)
                            comparisons += 1
                            if measured < actual {
                                let limitLabel = lineLimit.map(String.init) ?? "none"
                                clipping.append(String(
                                    format: "%@ @ %.0fpt font, %.0fpt wide, limit %@: measured %.1f < rendered %.1f",
                                    entry.name, size, width, limitLabel, measured, actual
                                ))
                            } else if !entry.text.isEmpty {
                                // The empty string is excluded from the slack
                                // statistic and covered by its own test: SwiftUI
                                // floors it at 14pt at every size, so at large
                                // text the gap is structural rather than drift.
                                let lines = max(1, measurer.lineCount(of: entry.text, width: width))
                                worstOvershootPerLine = max(
                                    worstOvershootPerLine,
                                    (measured - actual) / Double(lines)
                                )
                            }
                        }
                    }
                }
            }

            print("""
            fidelity across sizes: \(comparisons) comparisons, \
            worst overshoot \(String(format: "%.2f", worstOvershootPerLine))pt per line
            """)
            XCTAssertTrue(
                clipping.isEmpty,
                "Measured height was shorter than rendered height:\n" + clipping.joined(separator: "\n")
            )
            // Never clipping is trivially satisfiable by measuring huge, so bound
            // the slack too. Measured worst case is 2pt per line at 53pt text;
            // 3 leaves room for a font whose metrics round differently without
            // permitting a whole spare line.
            XCTAssertLessThanOrEqual(
                worstOvershootPerLine,
                3.0,
                "Measurement is drifting too generous per line."
            )
        }

        /// SwiftUI gives `Text("")` a height of 14pt at *every* point size — a
        /// fixed floor rather than anything derived from font metrics — while this
        /// measurer returns a full line. At 53pt text that is 64 against 14.
        ///
        /// Left as is deliberately. Matching it would mean hardcoding an
        /// undocumented constant, and the alternative of returning zero would
        /// clip. An empty string in a text feed is a rare cell that is a line
        /// taller than it needs to be, which is the cheap direction to be wrong in.
        @MainActor
        func testEmptyStringMeasuresGenerouslyRatherThanClipping() throws {
            for size in Self.pointSizes {
                let font = Font.system(size: size)
                let measurer = try makeMeasurer(font: font, lineLimit: nil, lineSpacing: 0)
                let actual = actualHeight("", width: 358, font: font, lineLimit: nil, lineSpacing: 0)
                let measured = measurer.height(of: "", width: 358)
                XCTAssertGreaterThanOrEqual(
                    measured,
                    actual,
                    "Empty string clipped at \(size)pt"
                )
            }
        }

        /// Dynamic Type is the reason the `Font` bridge exists rather than a
        /// `CTFont` parameter alone, so check it actually tracks.
        @MainActor
        func testMeasurementTracksTextSize() throws {
            guard #available(macOS 26, *) else {
                throw XCTSkip("Needs macOS 26 for Font.Resolved.")
            }
            let text = String(repeating: "The quick brown fox. ", count: 3)
            let width = 300.0
            var heights: [Double] = []
            for size in [11.0, 17.0, 28.0] {
                let context = EnvironmentValues().fontResolutionContext
                let measurer = TextMeasurer(
                    TextStyle(font: .system(size: size), in: context, lineLimit: nil)
                )
                heights.append(measurer.height(of: text, width: width))
            }
            XCTAssertEqual(heights, heights.sorted(), "Larger text must not measure shorter.")
            XCTAssertLessThan(heights[0], heights[2], "Text size must change the measurement.")
        }

        /// `lineSpacing` is applied between lines only, so it must scale with line
        /// count and leave a single line untouched.
        @MainActor
        func testLineSpacingMatchesRenderedText() throws {
            let font = Font.system(size: 17)
            let width = 358.0
            for spacing in [0.0, 4.0, 12.0] {
                let measurer = try makeMeasurer(font: font, lineLimit: nil, lineSpacing: spacing)
                for entry in Self.corpus where !entry.text.isEmpty {
                    let actual = actualHeight(
                        entry.text,
                        width: width,
                        font: font,
                        lineLimit: nil,
                        lineSpacing: spacing
                    )
                    let measured = measurer.height(of: entry.text, width: width)
                    XCTAssertGreaterThanOrEqual(
                        measured,
                        actual,
                        "\(entry.name) clipped at lineSpacing \(spacing)"
                    )
                }
            }
        }
    }
#endif
