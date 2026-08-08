#if os(macOS)
    import AppKit
    import CoreText
    @testable import LazyLayoutKit
    import SwiftUI
    import XCTest

    /// The width-aware closure captures things the container cannot see.
    ///
    /// A text measurer carries a font, a line limit and line spacing, none of
    /// which appear in the elements, the ids or the layout. When the user changes
    /// their text size the resolved font changes, every measured height becomes
    /// wrong, and nothing in the container's change token has moved — so without
    /// an explicit dependency the layout silently keeps stale heights.
    ///
    /// This is exactly the case the documentation claimed worked before it did,
    /// so it gets its own suite rather than a line in another one.
    final class RecomputeTriggerTests: XCTestCase {
        private struct Row: Identifiable, Equatable {
            let id: Int
        }

        private final class Box<T>: @unchecked Sendable {
            var value: T
            init(_ value: T) {
                self.value = value
            }
        }

        private final class StyleModel: ObservableObject {
            @Published var pointSize: Double = 17
        }

        /// Mirrors the real integration: a measurer built from state outside the
        /// collection, captured by the item closure.
        private struct Harness: View {
            @ObservedObject var model: StyleModel
            let data: [Row]
            let record: (Double) -> Void

            var body: some View {
                let font = CTFontCreateWithName("Helvetica" as CFString, model.pointSize, nil)
                let measurer = TextMeasurer(TextStyle(font: font, lineLimit: 3))
                return LazyLayoutView(
                    data,
                    id: \.id,
                    layout: MasonryLayout(columns: 1, spacing: 0),
                    recomputeOn: measurer.style,
                    item: { _, width in
                        let height = measurer.height(of: "some body text to measure", width: width)
                        record(height)
                        return .fixedHeight(height)
                    }
                ) { _ in
                    Color.gray
                }
                .frame(width: 400)
            }
        }

        @MainActor
        func testChangingTheResolvedStyleReRunsTheItemClosure() {
            let heights = Box<[Double]>([])
            let model = StyleModel()
            let harness = Harness(
                model: model,
                data: (0 ..< 50).map(Row.init),
                record: { heights.value.append($0) }
            )

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: harness)
            hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
            window.contentView = hosting
            window.orderFront(nil)
            window.layoutIfNeeded()

            var deadline = Date().addingTimeInterval(3)
            while heights.value.isEmpty, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            let atDefaultSize = Set(heights.value)
            XCTAssertFalse(atDefaultSize.isEmpty, "The item closure never ran.")

            // The user turns text size up. Every measured height is now wrong.
            model.pointSize = 34
            deadline = Date().addingTimeInterval(3)
            while Set(heights.value) == atDefaultSize, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            window.close()

            let afterChange = Set(heights.value).subtracting(atDefaultSize)
            XCTAssertFalse(
                afterChange.isEmpty,
                """
                Text size changed but the container never re-solved, so every cell \
                keeps a height measured for the old font. Saw only \(atDefaultSize).
                """
            )
            XCTAssertTrue(
                afterChange.contains { $0 > (atDefaultSize.max() ?? 0) },
                "Larger text must produce larger measured heights. Before \(atDefaultSize), after \(afterChange)."
            )
        }

        /// The trigger must not cause a re-solve when nothing about it changed,
        /// or every parent render would re-measure the whole collection.
        @MainActor
        func testAnUnchangedTriggerDoesNotReSolve() {
            let heights = Box<[Double]>([])
            let model = StyleModel()
            let harness = Harness(
                model: model,
                data: (0 ..< 50).map(Row.init),
                record: { heights.value.append($0) }
            )

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: harness)
            hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
            window.contentView = hosting
            window.orderFront(nil)
            window.layoutIfNeeded()

            let deadline = Date().addingTimeInterval(3)
            while heights.value.isEmpty, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            let afterFirstSolve = heights.value.count

            // Republish the same value: a new measurer instance, an equal style.
            model.pointSize = 17
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            window.close()

            XCTAssertEqual(
                heights.value.count,
                afterFirstSolve,
                "An equal trigger re-measured the collection. TextStyle equality is by value, so this should be free."
            )
        }
    }
#endif
