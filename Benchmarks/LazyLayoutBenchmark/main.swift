import CoreText
import Foundation
@_spi(Instrumentation) import LazyLayoutKit

let itemCount = Int(CommandLine.arguments.dropFirst().first ?? "100000") ?? 100_000
let containerWidth = 402.0
let viewportHeight = 874.0
let layout = MasonryLayout(columns: 3, spacing: 8)

var randomState: UInt64 = 0xF00D
@MainActor
func nextUnit() -> Double {
    randomState ^= randomState << 13
    randomState ^= randomState >> 7
    randomState ^= randomState << 17
    return Double(randomState % 1000) / 1000
}

let items = (0 ..< itemCount).map { _ in ItemMetric.aspectRatio(0.5 + nextUnit() * 1.5) }
let ids = Array(0 ..< itemCount)
let clock = ContinuousClock()

func nanoseconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) * 1_000_000_000 + Double(parts.attoseconds) / 1_000_000_000
}

func formatted(_ duration: Duration) -> String {
    let ns = nanoseconds(duration)
    if ns >= 1_000_000 {
        return String(format: "%.3f ms", ns / 1_000_000)
    }
    if ns >= 1000 {
        return String(format: "%.3f µs", ns / 1000)
    }
    return String(format: "%.1f ns", ns)
}

func measure(iterations: Int, _ body: () -> Void) -> Duration {
    body()
    return clock.measure {
        for _ in 0 ..< iterations {
            body()
        }
    } / iterations
}

func bytes(_ value: Int) -> String {
    String(format: "%.2f MiB", Double(value) / 1_048_576)
}

print("LazyLayoutKit shipping benchmark")
print("items: \(itemCount), container: \(Int(containerWidth))pt, viewport: \(Int(viewportHeight))pt\n")

var latestResult = layout.layout(items: items, containerWidth: containerWidth)
let layoutTime = measure(iterations: 20) {
    latestResult = layout.layout(items: items, containerWidth: containerWidth)
}

var snapshot = LayoutSnapshot(ids: ids, result: latestResult, containerWidth: containerWidth)
let snapshotTime = measure(iterations: 20) {
    snapshot = LayoutSnapshot(ids: ids, result: latestResult, containerWidth: containerWidth)
}

var standaloneIndex = VerticalVisibilityIndex(frames: latestResult.frames)
let indexTime = measure(iterations: 20) {
    standaloneIndex = VerticalVisibilityIndex(frames: latestResult.frames)
}

let fullSnapshotTime = measure(iterations: 20) {
    let result = layout.layout(items: items, containerWidth: containerWidth)
    snapshot = LayoutSnapshot(ids: ids, result: result, containerWidth: containerWidth)
}

var scrollY = 0.0
var buffer: [Int] = []
buffer.reserveCapacity(128)
var checksum = 0

let warmQuery = measure(iterations: 100_000) {
    scrollY += 13
    if scrollY > snapshot.contentHeight - viewportHeight {
        scrollY = 0
    }
    buffer.removeAll(keepingCapacity: true)
    snapshot.appendVisibleItems(
        in: LayoutRect(x: 0, y: scrollY, width: containerWidth, height: viewportHeight),
        to: &buffer
    )
    checksum &+= buffer.count
}

scrollY = 0
let freshQuery = measure(iterations: 100_000) {
    scrollY += 13
    if scrollY > snapshot.contentHeight - viewportHeight {
        scrollY = 0
    }
    let found = snapshot.visibleItems(
        in: LayoutRect(x: 0, y: scrollY, width: containerWidth, height: viewportHeight)
    )
    checksum &+= found.count
}

var scratch = [UInt8](repeating: 0, count: 32 << 20)
@inline(never)
@MainActor
func evictCaches() -> UInt64 {
    var sink: UInt64 = 0
    for position in stride(from: 0, to: scratch.count, by: 64) {
        sink &+= UInt64(scratch[position])
    }
    return sink
}

scrollY = 0
var coldTotal = Duration.zero
var coldSink: UInt64 = 0
for _ in 0 ..< 200 {
    coldSink &+= evictCaches()
    scrollY += 9973
    if scrollY > snapshot.contentHeight - viewportHeight {
        scrollY = 0
    }
    coldTotal += clock.measure {
        let found = snapshot.visibleItems(
            in: LayoutRect(x: 0, y: scrollY, width: containerWidth, height: viewportHeight)
        )
        checksum &+= found.count
    }
}

let coldQuery = coldTotal / 200

let middle = snapshot.visibleItems(
    in: LayoutRect(
        x: 0,
        y: snapshot.contentHeight / 2,
        width: containerWidth,
        height: viewportHeight
    )
)

let framePayload = snapshot.frames.count * MemoryLayout<LayoutRect>.stride
let idPayload = snapshot.ids.count * MemoryLayout<Int>.stride
let indexPayload = snapshot.visibilityIndexStorageByteCount

print("layout arithmetic                 \(formatted(layoutTime))")
print("generic-index construction        \(formatted(indexTime))")
print("complete snapshot construction    \(formatted(snapshotTime))")
print("complete solve + index            \(formatted(fullSnapshotTime))")
print("warm query, reused buffer         \(formatted(warmQuery))")
print("warm query, fresh result          \(formatted(freshQuery))")
print("cold query after 32 MiB sweep     \(formatted(coldQuery))")
print("visible items at mid-scroll       \(middle.count)")
print("content height                    \(Int(snapshot.contentHeight))pt")
print("frame payload                     \(bytes(framePayload))")
print("id payload                        \(bytes(idPayload))")
print("generic-index payload             \(bytes(indexPayload))")
print("known contiguous payload          \(bytes(framePayload + idPayload + indexPayload))")
print("checksum                          \(checksum &+ Int(coldSink) &+ standaloneIndex.storageByteCount)")

// MARK: - Text measurement

//
// The text ceiling published in the README rests on these numbers, so they have
// to be reproducible rather than recalled from a spike. The cold/warm split is
// the important one: the ratio between them is what makes the width-aware item
// closure viable at all.

print("\ntext measurement")

let textFont = CTFontCreateUIFontForLanguage(.system, 17, nil)!
let textWidth = 358.0
var textState: UInt64 = 0xBEEF
@MainActor
func textUnit() -> Double {
    textState ^= textState << 13
    textState ^= textState >> 7
    textState ^= textState << 17
    return Double(textState % 10000) / 10000
}

let vocabulary = """
the quick brown fox jumps over a lazy dog while sunlight filters through leaves
and someone somewhere is reading a feed on a phone waiting for a train arriving
""".split(separator: " ").map(String.init)

/// 4 to 50 words, matching the demo's feed corpus so the two are comparable.
let corpus = (0 ..< min(itemCount, 20000)).map { _ -> String in
    let words = 4 + Int(textUnit() * 46)
    return (0 ..< words)
        .map { _ in vocabulary[Int(textUnit() * Double(vocabulary.count - 1))] }
        .joined(separator: " ")
}

@MainActor
func measureText(_ label: String, _ style: TextStyle, texts: [String]) {
    // Cold: a fresh measurer, so nothing is cached. This is the first pass a
    // container pays at a new width.
    let cold = TextMeasurer(style)
    var sink = 0.0
    let coldTime = clock.measure {
        for text in texts {
            sink += cold.height(of: text, width: textWidth)
        }
    }
    // Warm: the same measurer, same inputs. This is every subsequent solve.
    let warmTime = clock.measure {
        for text in texts {
            sink += cold.height(of: text, width: textWidth)
        }
    }
    checksum &+= Int(sink)

    let coldPer = nanoseconds(coldTime) / Double(texts.count)
    let warmPer = nanoseconds(warmTime) / Double(texts.count)
    let padded = label.padding(toLength: 26, withPad: " ", startingAt: 0)
    print(String(
        format: "  %@cold %7.2f µs   warm %7.1f ns   ratio %5.0fx",
        padded, coldPer / 1000, warmPer, coldPer / max(warmPer, 1)
    ))
}

measureText("unlimited lines", TextStyle(font: textFont), texts: corpus)
measureText("lineLimit 3", TextStyle(font: textFont, lineLimit: 3), texts: corpus)
measureText("lineLimit 1", TextStyle(font: textFont, lineLimit: 1), texts: corpus)

// Extrapolated first-pass cost, which is the number the ceiling is stated in.
let ceilingMeasurer = TextMeasurer(TextStyle(font: textFont, lineLimit: 3))
var ceilingSink = 0.0
let ceilingTime = clock.measure {
    for text in corpus {
        ceilingSink += ceilingMeasurer.height(of: text, width: textWidth)
    }
}

checksum &+= Int(ceilingSink)
let perItem = nanoseconds(ceilingTime) / Double(corpus.count)
print("\n  first pass over a collection, lineLimit 3")
for count in [1000, 10000, 100_000] {
    print(String(format: "    %7d items  %8.1f ms", count, perItem * Double(count) / 1_000_000))
}

// One pathological string, with and without the prefix bound that a line limit
// enables. This is the tail risk: a single item stalling a frame.
let pathological = String(repeating: "a long unbroken stretch of prose ", count: 300)
var pathologicalSink = 0.0
let unbounded = clock.measure {
    pathologicalSink += TextMeasurer(TextStyle(font: textFont))
        .height(of: pathological, width: textWidth)
}

let bounded = clock.measure {
    pathologicalSink += TextMeasurer(TextStyle(font: textFont, lineLimit: 3))
        .height(of: pathological, width: textWidth)
}

checksum &+= Int(pathologicalSink)
print(String(
    format: "\n  one ~10 kB string: unlimited %8.2f ms   lineLimit 3 %8.3f ms",
    nanoseconds(unbounded) / 1_000_000, nanoseconds(bounded) / 1_000_000
))

print("\ntext checksum                     \(checksum)")
