/// One materialised cell of the window: an item's identity, its position and
/// frame in the snapshot it was placed from, and the element it was given.
struct PlacedItem<ID: Hashable & Sendable, Element>: Identifiable {
    let id: ID
    let position: Int
    let frame: LayoutRect
    /// The element as of the last placement. Used only as a fallback for the
    /// one frame between a collection mutation and the re-solve, when positions
    /// no longer address the new collection.
    let element: Element
}

extension LayoutSnapshot {
    /// Pairs the positions of a window over this snapshot with elements to draw.
    ///
    /// `elements` and `currentIDs` are the collection the container holds now,
    /// which can be newer than this snapshot: the parent replaces the collection
    /// at once, while the snapshot is solved again only in the change handler,
    /// and the scroll geometry action can rebuild the window in between. So a
    /// position is trusted only where the current collection still holds the
    /// same id there. Otherwise the element the item was last placed with is
    /// drawn for that frame — the same fallback `body` makes — and an item with
    /// neither is left out until the re-solve places it.
    func place<Element>(
        _ positions: [Int],
        elements: [Element],
        ids currentIDs: [ID],
        previous: [PlacedItem<ID, Element>]
    ) -> [PlacedItem<ID, Element>] {
        var previousElements: [ID: Element]?
        return positions.compactMap { position in
            let id = self.ids[position]
            let element: Element
            if position < currentIDs.count, currentIDs[position] == id {
                element = elements[position]
            } else {
                if previousElements == nil {
                    previousElements = Dictionary(
                        previous.map { ($0.id, $0.element) },
                        uniquingKeysWith: { first, _ in first }
                    )
                }
                guard let fallback = previousElements?[id] else { return nil }
                element = fallback
            }
            return PlacedItem(id: id, position: position, frame: frames[position], element: element)
        }
    }
}
