import SwiftUI

struct ResultsView: View {
    let runner: BenchmarkRunner

    var body: some View {
        NavigationStack {
            Group {
                if runner.history.isEmpty {
                    ContentUnavailableView {
                        Label("No runs yet", systemImage: "stopwatch")
                    } description: {
                        Text("Open a scenario and tap Record, then scroll hard for twenty seconds.")
                    }
                } else {
                    List {
                        Section {
                            ForEach(runner.history) { result in
                                NavigationLink {
                                    ResultDetail(result: result)
                                } label: {
                                    ResultRow(result: result)
                                }
                            }
                            .onDelete { runner.history.remove(atOffsets: $0) }
                        } footer: {
                            Text("A run passes when p99 stays within one 120 Hz frame, no frame exceeds 16.7 ms, and materialization stays under 600 cells.")
                        }
                    }
                }
            }
            .navigationTitle("Results")
            .toolbar {
                if !runner.history.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { EditButton() }
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: runner.history.map(\.reportText).joined(separator: "\n\n---\n\n")) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
    }
}

struct ResultRow: View {
    let result: BenchmarkResult

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: result.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(result.passed ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.mode)
                    .font(.headline)
                Text("\(result.itemCount.formatted()) items · \(Int(result.displayHz)) Hz")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(result.averageFPS.rounded())) fps")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Text(String(format: "p99 %.1f ms", result.p99Ms))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The run in full. A plain grouped list — the values are the point, and this
/// is what gets screenshotted.
struct ResultDetail: View {
    let result: BenchmarkResult
    @State private var copied = false

    var body: some View {
        List {
            Section {
                LabeledContent("Scenario", value: result.mode)
                LabeledContent("Items", value: result.itemCount.formatted())
                LabeledContent("Duration", value: "\(Int(result.seconds))s")
                LabeledContent("Verdict") {
                    Text(result.passed ? "PASS" : "REVIEW")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(result.passed ? .green : .orange)
                }
            } header: {
                Text("Run")
            } footer: {
                Text("\(result.device) · \(result.os) · \(Int(result.displayHz)) Hz")
            }

            Section("Frame timing") {
                metric("Average", "\(Int(result.averageFPS.rounded())) fps", tone: fpsTone)
                metric("Median", format(result.medianMs))
                metric("p95", format(result.p95Ms))
                metric("p99", format(result.p99Ms), tone: result.p99Ms > 8.4 ? .orange : .green)
                metric("Worst", format(result.worstMs), tone: result.worstMs > 16.7 ? .red : nil)
                metric("Frames", "\(result.frames)")
            }

            Section {
                metric(
                    "Over 8.3 ms", "\(result.hitches8)",
                    tone: result.hitches8 > 0 ? .orange : nil
                )
                metric(
                    "Over 16.7 ms", "\(result.hitches17)",
                    tone: result.hitches17 > 0 ? .red : .green
                )
            } header: {
                Text("Hitches")
            } footer: {
                Text("On a 60 Hz display every frame trips the 8.3 ms threshold, so only the 16.7 ms count is meaningful there.")
            }

            if !result.hitchSamples.isEmpty {
                Section {
                    ForEach(result.hitchSamples) { hitch in
                        LabeledContent(String(format: "%.1f s", hitch.offset)) {
                            Text(String(format: "%.1f ms", hitch.milliseconds))
                                .font(.body.monospacedDigit())
                                .foregroundStyle(hitch.milliseconds > 33 ? .red : .orange)
                        }
                    }
                } header: {
                    Text("When the long frames happened")
                } footer: {
                    Text("Offsets from the start of the window. Stalls at the very beginning or end are the recording UI appearing and disappearing; stalls spread through the middle are the container's.")
                }
            }

            Section("Container") {
                metric(
                    "Peak cells", "\(result.peakCells)",
                    tone: result.peakCells < 600 ? .green : .red
                )
                metric("Deepest item", result.deepestIndex.formatted())
                metric("Scrolled", String(format: "%.1fk pt", result.scrolledPoints / 1000))
                metric("Query average", String(format: "%.1f µs", result.averageQueryUs))
                metric("Query peak", String(format: "%.1f µs", result.peakQueryUs))
                metric("Last solve", format(result.lastSolveMs, places: 2) + " (×\(result.solves))")
            }

            Section {
                Button {
                    #if canImport(UIKit)
                        UIPasteboard.general.string = result.reportText
                    #endif
                    withAnimation { copied = true }
                } label: {
                    Label(copied ? "Copied" : "Copy report", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityIdentifier("copy-report")

                ShareLink(item: result.reportText) {
                    Label("Share report", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle(result.mode)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var fpsTone: Color? {
        guard result.displayHz > 0 else { return nil }
        return result.averageFPS / result.displayHz > 0.92 ? .green : .orange
    }

    private func format(_ value: Double, places: Int = 1) -> String {
        String(format: "%.\(places)f ms", value)
    }

    private func metric(_ label: String, _ value: String, tone: Color? = nil) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(tone ?? .primary)
        }
    }
}

#if canImport(UIKit)
    import UIKit
#endif
