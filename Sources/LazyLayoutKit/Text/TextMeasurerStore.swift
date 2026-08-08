import Synchronization

/// Keeps one ``TextMeasurer`` alive per style.
///
/// ``TextMeasurer``'s cache is the load-bearing part of measured text — roughly
/// 65x between a hit and a miss on an A16 — so where the measurer *lives* matters
/// as much as what it does. Building one inside a SwiftUI `body` throws the cache away on
/// every unrelated parent render, turning each re-solve back into a cold pass.
///
/// The obvious repair, storing it in `@State` and replacing it in `.task`, has a
/// subtler version of the same fault: `body` runs before the task does, so the
/// frame after a style change uses a measurer built and discarded on the spot,
/// and the instance that eventually gets stored is a *different* one whose cache
/// starts empty. This type closes that gap by resolving and storing in the same
/// step, so the instance you are handed is the instance that is kept.
///
/// ```swift
/// @State private var store = TextMeasurerStore()
/// @Environment(\.fontResolutionContext) private var fontContext
///
/// var body: some View {
///     let style = TextStyle(font: .body, in: fontContext, lineLimit: 3)
///     let measurer = store.measurer(for: style)      // same instance every render
///     return LazyLayoutView(posts, layout: layout, recomputeOn: style) { post, width in
///         .fixedHeight(measurer.height(of: post.body, width: width))
///     } content: { post in
///         Text(post.body).font(.body).lineLimit(3)
///     }
/// }
/// ```
///
/// A style change discards the previous measurer deliberately: every height it
/// cached was measured against the old font and is wrong.
public final class TextMeasurerStore: Sendable {
    private let cacheLimit: Int
    private let state: Mutex<TextMeasurer?>

    /// - Parameter cacheLimit: Passed through to each ``TextMeasurer`` this
    ///   creates. See ``TextMeasurer/init(_:cacheLimit:)``.
    public init(cacheLimit: Int = 20000) {
        self.cacheLimit = cacheLimit
        state = Mutex(nil)
    }

    /// The measurer for `style`, creating and retaining one if the stored
    /// measurer is for a different style.
    ///
    /// Calling this repeatedly with an equal style returns the identical
    /// instance, so it is safe — and intended — to call from `body`.
    public func measurer(for style: TextStyle) -> TextMeasurer {
        state.withLock { stored in
            if let stored, stored.style == style {
                return stored
            }
            let fresh = TextMeasurer(style, cacheLimit: cacheLimit)
            stored = fresh
            return fresh
        }
    }

    /// The retained measurer, if one has been created. Diagnostics only.
    @_spi(Instrumentation)
    public var current: TextMeasurer? {
        state.withLock { $0 }
    }
}
