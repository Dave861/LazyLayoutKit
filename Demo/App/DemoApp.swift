import SwiftUI

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

enum AppTab: Hashable {
    case gallery, justified, navigate, timeline, feed, baselines, results
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
                    runner: runner,
                    // TabView keeps every tab alive, so a scenario that is not on
                    // screen still solves — and without this its numbers land in
                    // the shared diagnostics and are read as the visible tab's.
                    isActive: tab == .gallery
                )
            }

            Tab("Justified", systemImage: "rectangle.grid.2x2", value: .justified) {
                ScenarioView(
                    title: "Justified",
                    mode: .justified,
                    model: model,
                    diagnostics: diagnostics,
                    runner: runner,
                    isActive: tab == .justified
                )
            }

            Tab("Deep link", systemImage: "arrow.down.to.line", value: .navigate) {
                ScenarioView(
                    title: "Deep link",
                    mode: .navigate,
                    model: model,
                    diagnostics: diagnostics,
                    runner: runner,
                    isActive: tab == .navigate
                )
            }

            Tab("Timeline", systemImage: "calendar.day.timeline.left", value: .timeline) {
                ScenarioView(
                    title: "Timeline",
                    mode: .timeline,
                    model: model,
                    diagnostics: diagnostics,
                    runner: runner,
                    // TabView keeps every tab alive, so a scenario that is not on
                    // screen still solves — and without this its numbers land in
                    // the shared diagnostics and are read as the visible tab's.
                    isActive: tab == .timeline
                )
            }

            Tab("Feed", systemImage: "text.alignleft", value: .feed) {
                // Built only while it is the visible tab.
                //
                // `TabView` keeps tabs alive, and a hidden Feed does not merely
                // report misleading numbers — it *solves*, which measures every
                // string and warms the cache. The first reading after switching
                // to the tab was then a warm one labelled cold. Constructing it
                // on demand means entering the tab is always a genuine cold pass.
                if tab == .feed {
                    ScenarioView(
                        title: "Feed",
                        mode: .feed,
                        model: model,
                        diagnostics: diagnostics,
                        runner: runner
                    )
                } else {
                    Color.clear
                }
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
