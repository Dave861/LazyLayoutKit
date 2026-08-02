import SwiftUI
import UIKit

private final class FrameRateReporter: NSObject {
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var accumulated: CFTimeInterval = 0
    private var frames = 0

    var onSample: ((Double, Double, Double) -> Void)?

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        lastTimestamp = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard lastTimestamp != 0 else { return }

        let frameDuration = link.timestamp - lastTimestamp
        let expected = link.targetTimestamp - link.timestamp
        accumulated += frameDuration
        frames += 1

        let averaged = accumulated >= 0.25 ? Double(frames) / accumulated : -1
        onSample?(averaged, frameDuration * 1000, expected * 1000)
        if accumulated >= 0.25 {
            accumulated = 0
            frames = 0
        }
    }
}

private struct FrameRateModifier: ViewModifier {
    let diagnostics: Diagnostics
    @State private var reporter = FrameRateReporter()

    func body(content: Content) -> some View {
        content
            .onAppear {
                reporter.onSample = { fps, frameMs, expectedMs in
                    MainActor.assumeIsolated {
                        diagnostics.recordFrame(durationMs: frameMs)
                        // Published values and the percentile sort happen only
                        // at the ~4 Hz tick, never on the per-frame path, and
                        // are frozen entirely while a run is open.
                        if fps >= 0 {
                            diagnostics.recordDisplay(
                                fps: fps,
                                refreshHz: expectedMs > 0 ? 1000 / expectedMs : 0
                            )
                            diagnostics.publishLiveValues()
                        }
                    }
                }
                reporter.start()
            }
            .onDisappear { reporter.stop() }
    }
}

extension View {
    func measuringFrameRate(into diagnostics: Diagnostics) -> some View {
        modifier(FrameRateModifier(diagnostics: diagnostics))
    }
}
