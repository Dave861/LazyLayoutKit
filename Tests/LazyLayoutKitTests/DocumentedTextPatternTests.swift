#if os(macOS)
    import AppKit
    @_spi(Instrumentation) @testable import LazyLayoutKit
    import SwiftUI
    import XCTest

    /// The documented self-sizing-text pattern, compiled.
    ///
    /// Every code fence in this package's documentation is prose as far as the
    /// compiler is concerned. That is how the text examples drifted: they built a
    /// `TextMeasurer` inside `body`, throwing the cache away on every render, and
    /// omitted the `recomputeOn:` argument that the initializer now requires — so
    /// they would not have compiled at all, and nothing noticed, because the whole
    /// suite and DocC were green.
    ///
    /// `READMEExampleTests` does the same job for the layout walkthrough. This
    /// does it for the text pattern: if the documented shape stops compiling, or
    /// stops behaving, this fails.
    @available(macOS 26, *)
    final class DocumentedTextPatternTests: XCTestCase {
        private struct Post: Identifiable, Equatable {
            let id: Int
            let body: String
        }

        /// Transcribed from `Font+Resolved`, `MeasuringText.md` and the README.
        /// Keep them in step.
        private struct Feed: View {
            @Environment(\.fontResolutionContext) private var fontContext
            @State private var measurers = TextMeasurerStore()
            let posts: [Post]

            var body: some View {
                let style = TextStyle(font: .body, in: fontContext, lineLimit: 3)
                let measurer = measurers.measurer(for: style)
                return LazyLayoutView(
                    posts,
                    layout: MasonryLayout(columns: 1, spacing: 12),
                    recomputeOn: style
                ) { post, width in
                    .fixedHeight(measurer.height(of: post.body, width: width))
                } content: { post in
                    Text(post.body).font(.body).lineLimit(3)
                }
            }
        }

        @MainActor
        func testDocumentedPatternBuildsCells() {
            final class Box: @unchecked Sendable {
                var ids: Set<Int> = []
            }
            let built = Box()
            let posts = (0 ..< 200).map {
                Post(id: $0, body: String(repeating: "word\($0 % 7) ", count: 4 + $0 % 15))
            }

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 700),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(
                rootView: Feed(posts: posts).onAppear { built.ids.insert(-1) }
            )
            hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 700)
            window.contentView = hosting
            window.orderFront(nil)
            window.layoutIfNeeded()

            let deadline = Date().addingTimeInterval(5)
            while built.ids.isEmpty, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            window.close()
            XCTAssertFalse(built.ids.isEmpty, "The documented pattern did not render.")
        }

        /// The reason the pattern uses a store: the cache has to survive renders.
        @MainActor
        func testDocumentedPatternKeepsItsCacheAcrossRenders() {
            let store = TextMeasurerStore()
            let context = EnvironmentValues().fontResolutionContext
            let style = TextStyle(font: .body, in: context, lineLimit: 3)
            let text = String(repeating: "some body text ", count: 6)

            // Ten renders, each resolving the measurer the way `body` does.
            for _ in 0 ..< 10 {
                _ = store.measurer(for: style).height(of: text, width: 320)
            }

            let stats = store.measurer(for: style).cacheStatistics
            XCTAssertEqual(stats.misses, 1, "Expected one cold measurement.")
            XCTAssertEqual(stats.hits, 9, "Expected the other nine to be cached.")
        }
    }
#endif
