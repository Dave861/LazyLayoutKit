import SwiftUI

/// Live stats, attached as a bottom safe-area inset so it sits in the chrome
/// rather than floating over the content and swallowing scroll gestures.
struct LiveStatsBar: View {
    let diagnostics: Diagnostics
    let runner: BenchmarkRunner
    @State private var expanded = false

    private var fpsTone: Color {
        guard diagnostics.refreshHz > 0, diagnostics.fps > 0 else { return .secondary }
        let ratio = diagnostics.fps / diagnostics.refreshHz
        return ratio > 0.92 ? .green : (ratio > 0.75 ? .orange : .red)
    }

    var body: some View {
        VStack(spacing: 0) {
            if case let .running(remaining) = runner.phase {
                recordingBanner(remaining: remaining)
            } else if case let .countdown(step) = runner.phase {
                banner("Get ready to scroll — \(step)", tint: .secondary)
            }

            HStack(spacing: 0) {
                reading(
                    "fps",
                    diagnostics.fps > 0 ? "\(Int(diagnostics.fps.rounded()))" : "—",
                    tone: fpsTone
                )
                reading(
                    "p99",
                    String(format: "%.1f", diagnostics.p99Ms),
                    tone: diagnostics.p99Ms > 8.34 ? .orange : .green
                )
                reading("cells", "\(diagnostics.materialized)")
                reading("query", String(format: "%.0fµs", diagnostics.lastQueryUs))

                Button {
                    withAnimation(.snappy(duration: 0.22)) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("hud-toggle")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if expanded {
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 6) {
                    GridRow {
                        reading("median", String(format: "%.1f", diagnostics.medianMs))
                        reading(
                            "worst",
                            String(format: "%.1f", diagnostics.worstFrameMs),
                            tone: diagnostics.worstFrameMs > 16.7 ? .red : nil
                        )
                        reading(
                            ">8.3",
                            "\(diagnostics.hitches8)",
                            tone: diagnostics.hitches8 > 0 ? .orange : nil
                        )
                        reading(
                            ">16.7",
                            "\(diagnostics.hitches17)",
                            tone: diagnostics.hitches17 > 0 ? .red : .green
                        )
                    }
                    GridRow {
                        reading("solve ×\(diagnostics.solveCount)", String(format: "%.2f", diagnostics.lastTotalSolveMs))
                        reading("layout", String(format: "%.2f", diagnostics.lastLayoutMs))
                        reading("snapshot", String(format: "%.2f", diagnostics.lastSnapshotMs))
                        reading("hz", String(format: "%.0f", diagnostics.refreshHz))
                    }
                    GridRow {
                        reading("range", "\(diagnostics.visibleLow)–\(diagnostics.visibleHigh)")
                        reading("scrolled", String(format: "%.1fk", diagnostics.scrollY / 1000))
                        Color.clear.frame(height: 1)
                        Color.clear.frame(height: 1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(.opacity)
            }
        }
        .background(.bar)
        .accessibilityIdentifier("hud")
    }

    private func recordingBanner(remaining: Double) -> some View {
        HStack(spacing: 8) {
            // No .symbolEffect here: a continuous animation runs for the whole
            // measurement window and shows up in the frame timings.
            Image(systemName: "record.circle")
                .foregroundStyle(.red)
            Text("Recording — scroll hard")
                .font(.footnote.weight(.semibold))
            Spacer()
            Text("\(Int(remaining.rounded()))s")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.red.opacity(0.12))
    }

    private func banner(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.4))
    }

    private func reading(_ label: String, _ value: String, tone: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(tone ?? .primary)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stat-\(label)")
    }
}
