import SwiftUI

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

enum AppTab: Hashable {
    case gallery, timeline, baselines, results
}

struct RootView: View {
    @State private var model = DemoModel()
    @State private var diagnostics = Diagnostics()
    @State private var runner = BenchmarkRunner()
    @State private var tab: AppTab = .gallery

    var body: some View {
        TabView(selection: $tab) {
            Tab("Gallery", systemImage: "square.grid.3x3.fill", value: .gallery) {
                ScenarioView(
                    title: "Gallery",
                    mode: .masonry,
                    model: model,
                    diagnostics: diagnostics,
                    runner: runner
                )
            }

            Tab("Timeline", systemImage: "calendar.day.timeline.left", value: .timeline) {
                ScenarioView(
                    title: "Timeline",
                    mode: .timeline,
                    model: model,
                    diagnostics: diagnostics,
                    runner: runner
                )
            }

            Tab("Baselines", systemImage: "chart.bar.xaxis", value: .baselines) {
                BaselinesView(model: model, diagnostics: diagnostics, runner: runner)
            }

            Tab("Results", systemImage: "list.clipboard", value: .results) {
                ResultsView(runner: runner)
            }
            .badge(runner.history.count)
        }
        .tint(.indigo)
        // A finished run surfaces wherever you are, then lands in Results.
        .sheet(item: $runner.latest) { result in
            NavigationStack {
                ResultDetail(result: result)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { runner.dismissResult() }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
    }
}
