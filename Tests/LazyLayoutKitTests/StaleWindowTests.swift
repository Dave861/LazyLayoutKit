@testable import LazyLayoutKit
import Testing

/// The window is rebuilt from the scroll geometry action as well as after a
/// solve, and the geometry action can run with a freshly handed-in collection
/// before `onChange(of: changeToken)` re-solves — a navigation pop that lays
/// the container out does exactly that. The snapshot is then the old one while
/// `elements` is the new one.
@Suite("Placing a stale window")
struct StaleWindowTests {
    private struct Item: Equatable {
        let id: Int
        let tag: String
    }

    private func items(_ ids: [Int]) -> [Item] {
        ids.map { Item(id: $0, tag: "tag-\($0)") }
    }

    private func solved(_ ids: [Int]) -> LayoutSnapshot<Int> {
        let frames = ids.indices.map { LayoutRect(x: 0, y: Double($0) * 100, width: 400, height: 90) }
        return LayoutSnapshot(
            ids: ids,
            result: LazyLayoutResult(frames: frames, contentHeight: Double(ids.count) * 100),
            containerWidth: 400
        )
    }

    private func placeWindow(
        of snapshot: LayoutSnapshot<Int>,
        over elements: [Item],
        previous: [PlacedItem<Int, Item>] = []
    ) -> [PlacedItem<Int, Item>] {
        let viewport = LayoutRect(x: 0, y: 0, width: 400, height: Double(snapshot.count) * 100)
        return snapshot.place(
            snapshot.visibleItems(in: viewport),
            elements: elements,
            ids: elements.map(\.id),
            previous: previous
        )
    }

    @Test("a shrunk collection under the old snapshot reads nothing past its end")
    func shrinkUnderASolvedWindow() {
        let snapshot = solved(Array(0 ..< 6))
        let window = placeWindow(of: snapshot, over: items(Array(0 ..< 6)))
        #expect(window.map(\.id) == Array(0 ..< 6))

        let shrunk = items([0, 1, 2, 3, 5])
        let stale = placeWindow(of: snapshot, over: shrunk, previous: window)

        #expect(stale.map(\.id) == Array(0 ..< 6))
        #expect(stale.map(\.element) == items(Array(0 ..< 6)))
    }

    @Test("an id whose position now holds another element keeps the element it was placed with")
    func positionTakenByAnotherElement() {
        let snapshot = solved(Array(0 ..< 4))
        let window = placeWindow(of: snapshot, over: items(Array(0 ..< 4)))

        let stale = placeWindow(of: snapshot, over: items([0, 2, 3]), previous: window)

        #expect(stale.map(\.id) == Array(0 ..< 4))
        #expect(stale.allSatisfy { $0.element.id == $0.id })
    }

    @Test("a stale position with no element to show is left out of the window")
    func nothingToShow() {
        let snapshot = solved(Array(0 ..< 4))

        let stale = placeWindow(of: snapshot, over: items([0, 1]))

        #expect(stale.map(\.id) == [0, 1])
    }

    @Test("a current element replaces the one the window was placed with")
    func currentElementWins() {
        let snapshot = solved([0, 1])
        let window = placeWindow(of: snapshot, over: items([0, 1]))
        let edited = [Item(id: 0, tag: "edited"), Item(id: 1, tag: "tag-1")]

        let placed = placeWindow(of: snapshot, over: edited, previous: window)

        #expect(placed.map(\.element) == edited)
    }
}
