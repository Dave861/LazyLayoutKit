/// A frame in the layout's content plane.
///
/// Deliberately not `CGRect`: this layer is arithmetic only, so it stays
/// testable without a UI framework and its meaning does not change with the
/// platform's coordinate conventions. The SwiftUI layer converts at the
/// boundary.
///
/// Coordinates may be negative. The origin of the content plane is wherever the
/// layout algorithm puts it; the container normalises when it positions views.
public struct LayoutRect: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minY: Double {
        y
    }

    public var maxY: Double {
        y + height
    }

    public var minX: Double {
        x
    }

    public var maxX: Double {
        x + width
    }

    /// Vertical overlap, half-open in y.
    ///
    /// Only the y axis is tested. 0.1 scrolls vertically, and a layout is free
    /// to place items anywhere across the container's width — but everything on
    /// screen is within that width by construction, so an x test would always
    /// pass and only cost time.
    ///
    /// Half-open means a rect ending exactly at the viewport's top edge is *not*
    /// visible, and one starting exactly at the bottom edge is not either.
    ///
    /// An empty span — zero or negative height on either side — intersects
    /// nothing. There is nothing to draw for a zero-height item, so materializing
    /// a view for it would be pure waste, and treating an empty interval as
    /// intersecting is not consistent with the half-open rule above.
    public func intersectsVertically(_ other: LayoutRect) -> Bool {
        guard height > 0, other.height > 0 else { return false }
        return minY < other.maxY && other.minY < maxY
    }
}
