import SwiftUI
@_spi(Instrumentation) import LazyLayoutKit

/// One scrollable scenario, in a standard navigation stack: title, toolbar,
/// and the live stats attached as a bottom safe-area inset rather than floating
/// over the content.
struct ScenarioView: View {
    let title: String
    let mode: Mode
    let model: DemoModel
    let diagnostics: Diagnostics
    let runner: BenchmarkRunner

    var body: some View {
        NavigationStack {
            container
                .navigationTitle(title)
                .toolbar { toolbar }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    LiveStatsBar(diagnostics: diagnostics, runner: runner)
                }
                .measuringFrameRate(into: diagnostics)
        }
    }

    @ViewBuilder
    private var container: some View {
        switch mode {
        case .timeline:
            LazyLayoutView(
                model.items,
                id: \.id,
                layout: model.timeline,
                overscan: model.overscan,
                item: { $0.interval },
                onInstrumentation: { diagnostics.record($0) }
            ) { item in
                DemoCell(index: item.id, compact: true)
            }
            .padding(.horizontal, 12)
            .id(scenarioIdentity)
        default:
            LazyLayoutView(
                model.items,
                id: \.id,
                layout: model.masonry,
                overscan: model.overscan,
                item: { $0.metric },
                onInstrumentation: { diagnostics.record($0) }
            ) { item in
                DemoCell(index: item.id)
            }
            .padding(.horizontal, 12)
            .id(scenarioIdentity)
        }
    }

    /// Re-create the container when the dataset changes, so one run can never
    /// inherit another's scroll position.
    private var scenarioIdentity: String {
        "\(mode.rawValue)-\(model.count.rawValue)-\(model.generation)-\(model.overscan)"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Items", selection: Binding(
                    get: { model.count },
                    set: { model.count = $0 }
                )) {
                    ForEach(ItemCount.allCases) { count in
                        Text(count.description).tag(count)
                    }
                }
            } label: {
                // A toolbar `Label` collapses to its icon and `.titleAndIcon`
                // does not survive the glass treatment, so the count — the part
                // actually worth reading — is set as text.
                Text(model.count.label)
                    .monospacedDigit()
            }
            .accessibilityIdentifier("item-count")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section("Mutations") {
                    Button("Resize item #10", systemImage: "arrow.up.and.down") {
                        model.toggleSizeOfItemNearTop()
                    }
                    Button("Insert 25 at front", systemImage: "text.insert") {
                        model.insertAtFront()
                    }
                }
                Section("Overscan") {
                    Picker("Overscan", selection: Binding(
                        get: { model.overscan },
                        set: { model.overscan = $0 }
                    )) {
                        Text("0.25 screens").tag(0.25)
                        Text("0.5 screens").tag(0.5)
                        Text("1 screen").tag(1.0)
                        Text("2 screens").tag(2.0)
                    }
                }
                Section {
                    Button("Reset counters", systemImage: "arrow.counterclockwise") {
                        diagnostics.reset()
                    }
                    Button("Regenerate data", systemImage: "shuffle") {
                        model.regenerate()
                    }
                }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("actions")
        }

        ToolbarItem(placement: .topBarTrailing) {
            RecordButton(mode: mode, model: model, diagnostics: diagnostics, runner: runner)
        }
    }
}

/// The baselines live behind one segmented control rather than two tabs — they
/// are the same question asked twice.
struct BaselinesView: View {
    let model: DemoModel
    let diagnostics: Diagnostics
    let runner: BenchmarkRunner

    @State private var baseline: Mode = .lazyStack

    var body: some View {
        NavigationStack {
            Group {
                switch baseline {
                case .eager:
                    EagerMasonryView(items: model.eagerItems, layout: model.masonry) { item in
                        DemoCell(index: item.id)
                    }
                default:
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(model.items) { item in
                                DemoCell(index: item.id).frame(height: 130)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }
            }
            .id("\(baseline.rawValue)-\(model.count.rawValue)-\(model.generation)")
            .navigationTitle("Baselines")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Baseline", selection: $baseline) {
                            Text("LazyVStack").tag(Mode.lazyStack)
                            Text("Eager").tag(Mode.eager)
                        }
                    } label: {
                        Text(baseline.rawValue)
                    }
                    .accessibilityIdentifier("baseline-picker")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    RecordButton(
                        mode: baseline,
                        model: model,
                        diagnostics: diagnostics,
                        runner: runner
                    )
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if baseline == .eager {
                        Text("Eager builds every subview up front, so it is capped at \(DemoModel.eagerCap.formatted()) items.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(.bar)
                    }
                    LiveStatsBar(diagnostics: diagnostics, runner: runner)
                }
            }
            .measuringFrameRate(into: diagnostics)
        }
    }
}

/// Starts a measurement window, and shows the countdown in its place while one
/// is open.
struct RecordButton: View {
    let mode: Mode
    let model: DemoModel
    let diagnostics: Diagnostics
    let runner: BenchmarkRunner

    var body: some View {
        switch runner.phase {
        case .idle, .finished:
            Button {
                runner.start(
                    duration: 20,
                    diagnostics: diagnostics,
                    mode: mode,
                    itemCount: mode.isCapped ? DemoModel.eagerCap : model.items.count
                )
            } label: {
                Label("Record", systemImage: "stopwatch")
            }
            .accessibilityIdentifier("run-benchmark")

        case let .countdown(step):
            Text("\(step)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(countsDown: true))

        case let .running(remaining):
            Button {
                runner.cancel()
            } label: {
                Label("\(Int(remaining.rounded()))s", systemImage: "stop.circle.fill")
                    .monospacedDigit()
            }
            .tint(.red)
            .accessibilityIdentifier("cancel-benchmark")
        }
    }
}

/// Deliberately not a flat colour: a real cell has a gradient, a border and a
/// label, so materialization in the demo costs roughly what a real one does.
struct DemoCell: View {
    let index: Int
    var compact = false

    private var hue: Double {
        // Golden-angle stepping: neighbours differ clearly, the whole collection
        // still reads as one palette.
        (Double(index) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: compact ? 8 : 14, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: 0.5, brightness: 0.95),
                        Color(hue: (hue + 0.07).truncatingRemainder(dividingBy: 1),
                              saturation: 0.75, brightness: 0.6),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(alignment: .bottomLeading) {
                Text("\(index)")
                    .font(.system(size: compact ? 9 : 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.3), in: Capsule())
                    .padding(compact ? 4 : 7)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Item \(index)")
            .accessibilityIdentifier("cell-\(index)")
    }
}

/// The contrast case: identical geometry, every subview built up front.
struct EagerMasonryView<CellView: View>: View {
    let items: [DemoItem]
    let layout: MasonryLayout
    @ViewBuilder let cell: (DemoItem) -> CellView

    @State private var result: LazyLayoutResult?

    var body: some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: 1, height: result?.contentHeight ?? 0)
                if let result {
                    ForEach(items.indices, id: \.self) { position in
                        let frame = result.frames[position]
                        cell(items[position])
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.x, y: frame.y)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onGeometryChange(for: Double.self) { $0.size.width } action: { width in
            guard width > 0 else { return }
            result = layout.layout(items: items.map(\.metric), containerWidth: width)
        }
    }
}
