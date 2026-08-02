import Foundation
import Observation
import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

/// A finished measurement run, formatted for reporting.
struct BenchmarkResult: Identifiable, Sendable {
    let id = UUID()
    let mode: String
    let itemCount: Int
    let seconds: Double
    let device: String
    let os: String
    let displayHz: Double

    let averageFPS: Double
    let medianMs: Double
    let p95Ms: Double
    let p99Ms: Double
    let worstMs: Double
    let hitches8: Int
    let hitches17: Int
    let frames: Int
    let hitchSamples: [HitchSample]

    let peakCells: Int
    let deepestIndex: Int
    let scrolledPoints: Double
    let averageQueryUs: Double
    let peakQueryUs: Double
    let lastSolveMs: Double
    let solves: Int

    var passed: Bool {
        hitches17 == 0 && p99Ms <= 8.4 && peakCells < 600
    }

    /// Where the long frames landed in the window. Clustering at the edges points
    /// at the recording UI rather than the container.
    var hitchSummary: String {
        guard !hitchSamples.isEmpty else { return "none" }
        return hitchSamples
            .map { String(format: "%.1fs (%.0fms)", $0.offset, $0.milliseconds) }
            .joined(separator: ", ")
    }

    /// Plain text for pasting into a report.
    var reportText: String {
        func f(_ value: Double, _ places: Int = 1) -> String {
            String(format: "%.\(places)f", value)
        }
        return """
        LazyLayoutKit — \(mode), \(itemCount.formatted()) items
        \(device) · \(os) · \(f(displayHz, 0))Hz · \(f(seconds, 0))s

        fps avg      \(f(averageFPS, 0))
        median       \(f(medianMs, 2)) ms
        p95          \(f(p95Ms, 2)) ms
        p99          \(f(p99Ms, 2)) ms
        worst        \(f(worstMs, 1)) ms
        hitch >8.3   \(hitches8)
        hitch >16.7  \(hitches17)
        frames       \(frames)
        hitches at   \(hitchSummary)

        peak cells   \(peakCells)
        deepest item \(deepestIndex.formatted())
        scrolled     \(f(scrolledPoints / 1000, 1))k pt
        query avg    \(f(averageQueryUs, 1)) µs
        query peak   \(f(peakQueryUs, 1)) µs
        last solve   \(f(lastSolveMs, 2)) ms (×\(solves))

        verdict      \(passed ? "PASS" : "REVIEW")
        """
    }
}

/// Drives a timed measurement window.
///
/// The container owns its own scroll position and 0.1 exposes no way to drive it
/// from outside, so this does not fake scrolling — it opens a fixed window, asks
/// you to scroll, and freezes the numbers at the end. Manual scrolling also keeps
/// the measurement representative of real use.
@Observable
@MainActor
final class BenchmarkRunner {
    enum Phase: Equatable {
        case idle
        case countdown(Int)
        case running(remaining: Double)
        case finished
    }

    var phase: Phase = .idle
    var latest: BenchmarkResult?
    var history: [BenchmarkResult] = []

    private var task: Task<Void, Never>?
    private(set) var duration: Double = 20

    var isActive: Bool {
        switch phase {
        case .idle, .finished: false
        case .countdown, .running: true
        }
    }

    func start(duration: Double, diagnostics: Diagnostics, mode: Mode, itemCount: Int) {
        cancel()
        self.duration = duration
        task = Task { [weak self] in
            guard let self else { return }
            for step in stride(from: 3, through: 1, by: -1) {
                phase = .countdown(step)
                try? await Task.sleep(for: .seconds(0.7))
                if Task.isCancelled {
                    return
                }
            }

            // Show the recording banner, then let its insertion settle before
            // the window opens. Inserting it is a view transition costing about
            // one 60 Hz frame, and with the capture starting first that stall
            // landed at 0.0s inside every single run.
            phase = .running(remaining: duration)
            try? await Task.sleep(for: .milliseconds(600))
            if Task.isCancelled {
                return
            }

            diagnostics.reset()
            diagnostics.beginCapture()

            let started = ContinuousClock.now
            var lastShownSecond = -1
            while true {
                let elapsed = Double((ContinuousClock.now - started).components.seconds)
                    + Double((ContinuousClock.now - started).components.attoseconds) / 1e18
                if elapsed >= duration || Task.isCancelled {
                    break
                }
                // Publishing every tick invalidated the stats bar twenty times
                // a second for the whole run; the countdown only renders whole
                // seconds, so only whole seconds need publishing.
                let remaining = duration - elapsed
                let second = Int(remaining.rounded())
                if second != lastShownSecond {
                    lastShownSecond = second
                    phase = .running(remaining: remaining)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if Task.isCancelled {
                return
            }

            let result = diagnostics.endCapture(
                mode: mode.rawValue,
                itemCount: itemCount,
                seconds: duration
            )
            latest = result
            history.insert(result, at: 0)
            phase = .finished
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    func dismissResult() {
        latest = nil
        phase = .idle
    }
}

@MainActor
enum DeviceInfo {
    static var name: String {
        #if canImport(UIKit)
            // `UIDevice.model` is generic ("iPhone"); the machine identifier is what
            // actually distinguishes an A16 from an A18.
            var info = utsname()
            uname(&info)
            let identifier = withUnsafePointer(to: &info.machine) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
            }
            return identifier.isEmpty ? UIDevice.current.model : identifier
        #else
            return "Mac"
        #endif
    }

    static var os: String {
        #if canImport(UIKit)
            "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        #else
            ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }
}
