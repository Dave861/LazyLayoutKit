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
