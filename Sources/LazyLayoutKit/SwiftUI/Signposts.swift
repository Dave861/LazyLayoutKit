import os

/// Instruments signposts.
///
/// The names are API in every practical sense: renaming an interval invalidates
/// anyone's saved Instruments template, so they are fixed deliberately here
/// rather than sprinkled through the container as string literals.
///
/// - Subsystem: `com.lazylayoutkit`
/// - Category: `layout`
/// - Intervals: `solve` (a full layout pass) and `visibility` (resolving the
///   on-screen window, which runs on every scroll tick)
enum Signposts {
    static let subsystem = "com.lazylayoutkit"
    static let category = "layout"

    static let signposter = OSSignposter(subsystem: subsystem, category: category)

    static let solve: StaticString = "solve"
    static let visibility: StaticString = "visibility"
}
