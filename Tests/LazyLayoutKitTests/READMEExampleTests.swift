@testable import LazyLayoutKit
import Testing

/// Compiles the "write your own layout" example from the README, so it cannot
/// silently rot.
struct ChipFlowLayout: LazyLayoutAlgorithm {
    struct Chip: Equatable, Sendable {
        var width: Double
        var height: Double
    }

    var spacing: Double = 8

    func layout(items: [Chip], containerWidth: Double) -> LazyLayoutResult {
        var frames: [LayoutRect] = []
        frames.reserveCapacity(items.count)

        var x = 0.0, y = 0.0, rowHeight = 0.0
        for chip in items {
            if x > 0, x + chip.width > containerWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(LayoutRect(x: x, y: y, width: chip.width, height: chip.height))
            x += chip.width + spacing
            rowHeight = max(rowHeight, chip.height)
        }
        return LazyLayoutResult(frames: frames, contentHeight: y + rowHeight)
    }
}

@Test("README chip-flow example wraps and reports a sane content height")
func readmeChipFlowExample() {
    let chips = (0 ..< 30).map { ChipFlowLayout.Chip(width: 60 + Double($0 % 4) * 20, height: 32) }
    let result = ChipFlowLayout().layout(items: chips, containerWidth: 320)
    #expect(result.frames.count == 30)
    #expect(result.frames.allSatisfy { $0.maxX <= 320.001 })
    #expect(result.contentHeight > 32)
    let snapshot = LayoutSnapshot(ids: Array(0 ..< 30), result: result, containerWidth: 320)
    #expect(!snapshot.visibleItems(in: LayoutRect(x: 0, y: 0, width: 320, height: 100)).isEmpty)
}

// Compiles the README's justified-gallery and scroll-to-item snippets, so they
// cannot silently rot either.
//
// The scrolling one has to be a real `View` body: the point of the snippet is
// the `position:` parameter and the binding it takes, neither of which exists
// outside a view.
#if canImport(SwiftUI)
    import SwiftUI

    private struct READMEPhoto: Identifiable, Equatable {
        let id: Int
        let width: Double
        let height: Double
        var aspectRatio: Double {
            width / height
        }
    }

    private struct READMEJustifiedGallery: View {
        let photos: [READMEPhoto]

        var body: some View {
            LazyLayoutView(photos, layout: JustifiedLayout(targetRowHeight: 200)) { photo in
                .aspectRatio(photo.width / photo.height)
            } content: { photo in
                Color.gray.overlay(Text("\(photo.id)"))
            }
        }
    }

    private struct READMEScrollToItem: View {
        let photos: [READMEPhoto]
        let today: READMEPhoto

        @State private var position = LazyLayoutPosition<READMEPhoto.ID>()

        var body: some View {
            LazyLayoutView(photos, layout: JustifiedLayout(), position: $position) { photo in
                .aspectRatio(photo.aspectRatio)
            } content: { photo in
                Color.gray.overlay(Text("\(photo.id)"))
            }
            .toolbar {
                Button("Jump to today") { position.scrollTo(id: today.id, anchor: .center) }
            }
        }
    }

    @Test("README justified and scroll-to-item examples stay valid")
    func readmeJustifiedAndScrollExamples() {
        let photos = (0 ..< 40).map {
            READMEPhoto(id: $0, width: 400 + Double($0 % 5) * 60, height: 300)
        }
        _ = READMEJustifiedGallery(photos: photos)
        _ = READMEScrollToItem(photos: photos, today: photos[0])

        // And the documented behaviour of the snippet's two moving parts.
        let result = JustifiedLayout(targetRowHeight: 200)
            .layout(items: photos.map { .aspectRatio($0.aspectRatio) }, containerWidth: 402)
        let snapshot = LayoutSnapshot(ids: photos.map(\.id), result: result, containerWidth: 402)

        #expect(snapshot.offset(toShow: 0, anchor: .center, viewportHeight: 800) == 0)
        #expect(snapshot.offset(toShow: 999, anchor: .center, viewportHeight: 800) == nil)
    }
#endif
