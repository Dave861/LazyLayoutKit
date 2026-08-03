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
