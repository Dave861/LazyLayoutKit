import Foundation
@_spi(Instrumentation) import LazyLayoutKit
import Observation

/// A frame that exceeded one 60 Hz interval, and when it happened.
///
/// Recorded because a count alone cannot tell you whether the stalls are the
/// container's or the apparatus's. Two hitches clustered at the very start and
/// end of a window are the recording UI appearing and disappearing; hitches
/// spread through the middle are something real.
struct HitchSample: Sendable, Identifiable {
    let id = UUID()
    /// Seconds from the start of the measurement window.
    let offset: Double
    let milliseconds: Double
}

/// Live readouts, and the capture used for a measurement run.
///
/// ## Why so much of this is `@ObservationIgnored`
///
/// This type is read by an on-screen HUD. Every observed property mutated here
/// invalidates that HUD, and `recordFrame` runs on every display refresh — so
/// naively storing per-frame state in observed properties re-rendered the HUD
/// 120 times a second *while measuring*, and the instrument produced the stalls
/// it then reported. Everything on the per-frame path is therefore
/// non-observed, and the published values are refreshed a few times a second —
/// and not at all while a run is open.
@Observable
@MainActor
final class Diagnostics {
    // MARK: Published — read by the HUD

    var fps: Double = 0
    var refreshHz: Double = 0
    var worstFrameMs: Double = 0
    var p99Ms: Double = 0
    var medianMs: Double = 0
    var hitches8 = 0
    var hitches17 = 0

    var lastItemsMs: Double = 0
    var lastTotalSolveMs: Double = 0
    var lastLayoutMs: Double = 0
    var lastSnapshotMs: Double = 0
    var solveCount = 0
    var lastQueryUs: Double = 0
    var materialized = 0
    var visibleLow = 0
    var visibleHigh = 0
    var scrollY: Double = 0

    // MARK: Per-frame accumulation — never observed

    @ObservationIgnored private var recent: [Double] = []
    @ObservationIgnored private var pendingWorst: Double = 0
    @ObservationIgnored private var pendingHitches8 = 0
    @ObservationIgnored private var pendingHitches17 = 0
    @ObservationIgnored private static let frameWindow = 900

    // MARK: Capture state — never observed

    @ObservationIgnored private var capturing = false
    @ObservationIgnored private var captured: [Double] = []
    @ObservationIgnored private var capturedQueries: [Double] = []
    @ObservationIgnored private var hitches: [HitchSample] = []
    @ObservationIgnored private var elapsedMs: Double = 0
    @ObservationIgnored private var peakCells = 0
    @ObservationIgnored private var deepestIndex = 0
    @ObservationIgnored private var scrollLow = Double.infinity
    @ObservationIgnored private var scrollHigh = -Double.infinity
    @ObservationIgnored private var pendingSolve: (items: Double, layout: Double, snapshot: Double, total: Double)?
    @ObservationIgnored private var pendingSolveCount = 0

    var isCapturing: Bool {
        capturing
    }

    func reset() {
        pendingWorst = 0
        pendingHitches8 = 0
        pendingHitches17 = 0
        recent.removeAll(keepingCapacity: true)
        worstFrameMs = 0
        p99Ms = 0
        medianMs = 0
        hitches8 = 0
        hitches17 = 0
        lastItemsMs = 0
        solveCount = 0
    }

    func beginCapture() {
        reset()
        capturing = true
        captured.removeAll(keepingCapacity: true)
        hitches.removeAll(keepingCapacity: true)
        elapsedMs = 0
        // Seeded from the resting state: an idle run fires no instrumentation
        // events at all, so starting these at zero reported "0 cells" for a
        // container that was in fact holding a full window.
        peakCells = materialized
        deepestIndex = visibleHigh
        scrollLow = scrollY
        scrollHigh = scrollY
        pendingSolveCount = 0
        capturedQueries = lastQueryUs > 0 ? [lastQueryUs] : []
    }

    func endCapture(mode: String, itemCount: Int, seconds: Double) -> BenchmarkResult {
        capturing = false
        let sorted = captured.sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
        }
        let totalMs = captured.reduce(0, +)
        let scrolled = scrollHigh.isFinite && scrollLow.isFinite ? max(0, scrollHigh - scrollLow) : 0

        // Publish once, now that the run is closed.
        publishLiveValues()
        if let pendingSolve {
            lastItemsMs = pendingSolve.items
            lastLayoutMs = pendingSolve.layout
            lastSnapshotMs = pendingSolve.snapshot
            lastTotalSolveMs = pendingSolve.total
        }
        solveCount = pendingSolveCount

        return BenchmarkResult(
            mode: mode,
            itemCount: itemCount,
            seconds: seconds,
            device: DeviceInfo.name,
            os: DeviceInfo.os,
            displayHz: refreshHz,
            averageFPS: totalMs > 0 ? Double(captured.count) / (totalMs / 1000) : 0,
            medianMs: percentile(0.5),
            p95Ms: percentile(0.95),
            p99Ms: percentile(0.99),
            worstMs: sorted.last ?? 0,
            hitches8: captured.filter { $0 > 8.34 }.count,
            hitches17: captured.filter { $0 > 16.7 }.count,
            frames: captured.count,
            hitchSamples: hitches,
            peakCells: peakCells,
            deepestIndex: deepestIndex,
            scrolledPoints: scrolled,
            averageQueryUs: capturedQueries.isEmpty
                ? 0
                : capturedQueries.reduce(0, +) / Double(capturedQueries.count),
            peakQueryUs: capturedQueries.max() ?? 0,
            lastSolveMs: pendingSolve?.total ?? lastTotalSolveMs,
            lastItemsMs: pendingSolve?.items ?? lastItemsMs,
            solves: pendingSolveCount
        )
    }

    /// Per-frame. Must not touch observed state — see the note on the type.
    func recordFrame(durationMs: Double) {
        elapsedMs += durationMs
        pendingWorst = max(pendingWorst, durationMs)
        if durationMs > 8.34 {
            pendingHitches8 += 1
        }
        if durationMs > 16.7 {
            pendingHitches17 += 1
        }

        recent.append(durationMs)
        if recent.count > Self.frameWindow {
            recent.removeFirst(recent.count - Self.frameWindow)
        }

        if capturing {
            captured.append(durationMs)
            if durationMs > 16.7 {
                hitches.append(
                    HitchSample(offset: elapsedMs / 1000, milliseconds: durationMs)
                )
            }
        }
    }

    /// Called a few times a second, not per frame. Frozen while capturing so the
    /// HUD cannot invalidate itself during a measurement.
    func publishLiveValues() {
        guard !capturing else { return }
        worstFrameMs = pendingWorst
        hitches8 = pendingHitches8
        hitches17 = pendingHitches17
        guard !recent.isEmpty else { return }
        let sorted = recent.sorted()
        medianMs = sorted[sorted.count / 2]
        p99Ms = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
    }

    func recordDisplay(fps: Double, refreshHz: Double) {
        guard !capturing else { return }
        self.fps = fps
        self.refreshHz = refreshHz
    }

    /// Instrumentation from the container. Also gated: during a scroll run this
    /// fires on every visibility change, which is per-frame in practice.
    func record(_ event: LazyLayoutInstrumentationEvent) {
        switch event {
        case let .solve(items, layout, snapshot, total):
            if capturing {
                pendingSolve = (
                    items.milliseconds, layout.milliseconds,
                    snapshot.milliseconds, total.milliseconds
                )
                pendingSolveCount += 1
            } else {
                lastItemsMs = items.milliseconds
                lastLayoutMs = layout.milliseconds
                lastSnapshotMs = snapshot.milliseconds
                lastTotalSolveMs = total.milliseconds
                solveCount += 1
            }

        case let .visibility(duration, count, first, last):
            if capturing {
                capturedQueries.append(duration.microseconds)
                peakCells = max(peakCells, count)
                deepestIndex = max(deepestIndex, last ?? 0)
            } else {
                lastQueryUs = duration.microseconds
                materialized = count
                visibleLow = first ?? 0
                visibleHigh = last ?? 0
            }

        case let .viewport(offsetY):
            if capturing {
                scrollLow = min(scrollLow, offsetY)
                scrollHigh = max(scrollHigh, offsetY)
            } else {
                scrollY = offsetY
            }
        }
    }
}

extension Duration {
    var milliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    var microseconds: Double {
        milliseconds * 1000
    }
}
