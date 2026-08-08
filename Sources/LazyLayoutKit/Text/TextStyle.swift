import CoreText

/// Everything that affects how tall a string renders, and nothing that doesn't.
///
/// Deliberately small. Colour, alignment and decoration change how text *looks*
/// but not how much vertical space it needs, so they are not here — including
/// them would invite the impression that this type describes rendering, which it
/// does not.
///
/// ## Not supported, and why
///
/// - **`minimumScaleFactor`.** Shrinking text to fit is a measure-then-shrink
///   loop: the height depends on a scale that depends on the height. That is the
///   measure-and-correct lifecycle this package has declined to implement since
///   0.1, and adding a property without the behaviour would be worse than not
///   having it.
/// - **Attributed text with mixed runs.** One style over one string is the 0.2
///   surface. Mixed fonts within a paragraph change line height per line, which
///   the arithmetic here does not model.
public struct TextStyle: Hashable, @unchecked Sendable {
    /// The font the text will be rendered in.
    ///
    /// On iOS 26 / macOS 26 and later there is an initializer taking a SwiftUI
    /// `Font` instead, which is almost always what you want: it resolves to the
    /// concrete font the `Text` will render as, carrying Dynamic Type through.
    public let font: CTFont

    /// Maximum number of lines, or `nil` for unlimited.
    ///
    /// Setting this is not only a visual choice. It bounds measurement cost: with
    /// a limit, only as much of the string as can possibly fill that many lines
    /// is examined, so one unexpectedly long string cannot stall a scroll. See
    /// ``TextMeasurer`` for the measured difference.
    public let lineLimit: Int?

    /// Extra space between lines, matching SwiftUI's `.lineSpacing(_:)`.
    ///
    /// Applies *between* lines only, so a single line is unaffected.
    public let lineSpacing: Double

    /// - Parameters:
    ///   - font: The font the text will render in.
    ///   - lineLimit: Maximum lines, or `nil` for unlimited. A limit bounds
    ///     measurement cost as well as height.
    ///   - lineSpacing: Extra space between lines. Negative values are clamped
    ///     to zero.
    public init(font: CTFont, lineLimit: Int? = nil, lineSpacing: Double = 0) {
        self.font = font
        self.lineLimit = lineLimit.map { max(1, $0) }
        self.lineSpacing = lineSpacing.isFinite ? max(0, lineSpacing) : 0
    }

    public static func == (lhs: TextStyle, rhs: TextStyle) -> Bool {
        CFEqual(lhs.font, rhs.font)
            && lhs.lineLimit == rhs.lineLimit
            && lhs.lineSpacing == rhs.lineSpacing
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(font))
        hasher.combine(lineLimit)
        hasher.combine(lineSpacing)
    }
}

// `CTFont` is immutable and CoreText documents its objects as safe to use from
// multiple threads; the type simply predates `Sendable` annotation, so the
// conformance has to be asserted rather than derived. `Hashable` is likewise
// hand-written on `CFHash`/`CFEqual` rather than derived, because CF types carry
// no Swift value-equality semantics of their own.
