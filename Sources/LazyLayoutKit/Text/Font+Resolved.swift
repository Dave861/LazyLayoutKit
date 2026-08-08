import CoreText
import SwiftUI

@available(iOS 26, macOS 26, tvOS 26, watchOS 26, visionOS 26, *)
public extension TextStyle {
    /// Builds a style from a SwiftUI `Font`.
    ///
    /// This is the bridge that makes measured text match rendered text. `Font` is
    /// opaque — `.body` means different point sizes at different Dynamic Type
    /// settings — so before `Font.Resolved` there was no supported way to learn
    /// which concrete font a `Text` would actually use, and measuring it was
    /// guesswork. Resolving against the environment's context carries Dynamic
    /// Type, weight, width, leading and small-caps through to the measurement.
    ///
    /// ```swift
    /// struct Feed: View {
    ///     @Environment(\.fontResolutionContext) private var fontContext
    ///     @State private var measurers = TextMeasurerStore()
    ///     let posts: [Post]
    ///
    ///     var body: some View {
    ///         let style = TextStyle(font: .body, in: fontContext, lineLimit: 3)
    ///         let measurer = measurers.measurer(for: style)
    ///         return LazyLayoutView(
    ///             posts,
    ///             layout: MasonryLayout(columns: 1),
    ///             recomputeOn: style
    ///         ) { post, width in
    ///             .fixedHeight(measurer.height(of: post.body, width: width))
    ///         } content: { post in
    ///             Text(post.body).font(.body).lineLimit(3)
    ///         }
    ///     }
    /// }
    /// ```
    ///
    /// Two details there are load-bearing. ``TextMeasurerStore`` keeps one
    /// measurer alive per style — building one in `body` discards its cache on
    /// every parent render. And `recomputeOn:` is what makes a text-size change
    /// re-solve: `Font.Context` is `Equatable`, so the style changes, the store
    /// hands back a fresh measurer, and the container re-measures.
    ///
    /// - Important: The `lineLimit` and `lineSpacing` here must match the
    ///   modifiers on the `Text` being measured. Nothing enforces that — the
    ///   measurer never sees the view.
    init(font: Font, in context: Font.Context, lineLimit: Int? = nil, lineSpacing: Double = 0) {
        self.init(
            font: font.resolve(in: context).ctFont,
            lineLimit: lineLimit,
            lineSpacing: lineSpacing
        )
    }
}
