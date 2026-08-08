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
    /// Whether this scenario's tab is the one on screen. Only the visible
    /// scenario reports instrumentation; see `DemoApp`.
    var isActive = true

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
        case .feed:
            FeedScenario(model: model, diagnostics: diagnostics, isActive: isActive)
                .padding(.horizontal, 12)
                .frame(maxWidth: model.isNarrowed ? 260 : .infinity)
                .id(scenarioIdentity)
        case .timeline:
            LazyLayoutView(
                model.items,
                id: \.id,
                layout: model.timeline,
                overscan: model.overscan.resolved,
                item: { $0.interval },
                onInstrumentation: {
                    if isActive {
                        diagnostics.record($0)
                    }
                }
            ) { item in
                DemoCell(index: item.id, compact: true)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: model.isNarrowed ? 260 : .infinity)
            .id(scenarioIdentity)
        default:
            LazyLayoutView(
                model.items,
                id: \.id,
                layout: model.masonry,
                overscan: model.overscan.resolved,
                item: { $0.metric },
                onInstrumentation: {
                    if isActive {
                        diagnostics.record($0)
                    }
                }
            ) { item in
                DemoCell(index: item.id)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: model.isNarrowed ? 260 : .infinity)
            .id(scenarioIdentity)
        }
    }

    /// Re-create the container when the dataset changes, so one run can never
    /// inherit another's scroll position.
    private var scenarioIdentity: String {
        """
        \(mode.rawValue)-\(model.count.rawValue)-\(model.generation)\
        -\(model.overscan.label)-\(model.textCacheGeneration)
        """
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Items", selection: Binding(
                    get: { model.count },
                    set: { model.count = $0 }
                )) {
                    // Feed stops at 100K: a million measured strings is
                    // minutes of CoreText, not a configuration worth offering.
                    ForEach(ItemCount.available(for: mode)) { count in
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
                Section("Device protocol") {
                    if mode == .feed {
                        // Warm: re-solve with the measurement cache intact.
                        Button("Force re-solve (warm)", systemImage: "arrow.clockwise") {
                            model.forceFeedResolve()
                        }
                        // Cold: rebuild the scenario and its cache first.
                        Button("Clear text cache (cold)", systemImage: "snowflake") {
                            model.clearTextCacheAndResolve()
                        }
                    }
                    // T5: a width change that is not a rotation. Rotation also
                    // relays out the whole hierarchy, which would mask the
                    // scroll-view width deadlock rather than test it.
                    Toggle(isOn: Binding(
                        get: { model.isNarrowed },
                        set: { model.isNarrowed = $0 }
                    )) {
                        Label("Narrow to 260pt", systemImage: "arrow.right.and.line.vertical.and.arrow.left")
                    }
                    if mode == .feed {
                        // T3: one ~10 kB string, to see whether a single item
                        // can stall a frame.
                        Button("Insert 10 kB string", systemImage: "doc.text.below.ecg") {
                            model.insertPathologicalString()
                        }
                        Button("Clear inserted", systemImage: "trash") {
                            model.clearInsertedItems()
                        }
                    }
                }
                Section("Overscan") {
                    Picker("Overscan", selection: Binding(
                        get: { model.overscan },
                        set: { model.overscan = $0 }
                    )) {
                        ForEach(DemoModel.OverscanChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
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

/// Self-sizing text, on device.
///
/// This is the scenario the 0.2 performance claims are measured against: heights
/// come from ``TextMeasurer`` at solve time rather than from the data, so the
/// solve interval in the HUD now includes measurement.
///
/// It is a separate view rather than another branch of `ScenarioView.container`
/// because it needs `@Environment(\.fontResolutionContext)` and a measurer whose
/// lifetime follows it. Reading the context here is also what makes the scenario
/// re-measure when Dynamic Type changes — the context is `Equatable`, so a text
/// size change rebuilds the measurer and the container re-solves.
private struct FeedScenario: View {
    let model: DemoModel
    let diagnostics: Diagnostics
    let isActive: Bool

    @Environment(\.fontResolutionContext) private var fontContext

    /// One measurer per style, resolved and retained in the same step.
    ///
    /// Building it in `body` would discard the cache on every parent render, and
    /// the `.task`-stores-it variant is worse than it looks: `body` runs first,
    /// so the frame after a style change uses a measurer built and thrown away
    /// on the spot while a *different* instance gets stored with an empty cache.
    /// `TextMeasurerStore` hands back the instance it keeps.
    @State private var measurers = TextMeasurerStore()
    @State private var captionMeasurers = TextMeasurerStore()

    private var captionStyle: TextStyle {
        #if compiler(>=6.2)
            if #available(iOS 26, *) {
                TextStyle(font: .caption.weight(.semibold), in: fontContext, lineLimit: 1)
            } else {
                TextStyle(font: UIFont.preferredFont(forTextStyle: .caption1), lineLimit: 1)
            }
        #else
            TextStyle(font: UIFont.preferredFont(forTextStyle: .caption1), lineLimit: 1)
        #endif
    }

    private var style: TextStyle {
        // Both paths, because the package supports both. The SwiftUI `Font`
        // bridge needs iOS 26; below that the measurer takes a `CTFont` directly
        // and `UIFont` is toll-free bridged to one. The iOS 18 path still tracks
        // Dynamic Type — `preferredFont(forTextStyle:)` resolves against the
        // current content size category — it just cannot see anything
        // SwiftUI-specific about the font.
        #if compiler(>=6.2)
            if #available(iOS 26, *) {
                TextStyle(font: .body, in: fontContext, lineLimit: 3)
            } else {
                TextStyle(font: UIFont.preferredFont(forTextStyle: .body), lineLimit: 3)
            }
        #else
            TextStyle(font: UIFont.preferredFont(forTextStyle: .body), lineLimit: 3)
        #endif
    }

    var body: some View {
        let style = style
        let measurer = measurers.measurer(for: style)
        // The caption scales with Dynamic Type too, so it is measured rather
        // than assumed. A constant here is what clipped the body text at
        // accessibility sizes.
        let captionStyle = captionStyle
        // A representative caption at a representative width. The id is the
        // widest part, so measure with a large one rather than "Item 0".
        let captionHeight = captionMeasurers
            .measurer(for: captionStyle)
            .height(of: "Item 000,000", width: 200)
        return LazyLayoutView(
            model.feedItems,
            id: \.id,
            layout: model.feedLayout,
            overscan: model.overscan.resolved,
            // Without this the container watches only the collection, and a
            // Dynamic Type change would leave every cell at a height measured
            // for the old font.
            // Both styles matter: either one changing invalidates every height.
            recomputeOn: FeedResolveKey(
                style: style,
                captionStyle: captionStyle,
                revision: model.feedRevision
            ),
            item: { item, width in
                .fixedHeight(FeedCell.height(
                    measuring: item.body,
                    width: width,
                    with: measurer,
                    captionHeight: captionHeight
                ))
            },
            onInstrumentation: {
                if isActive {
                    diagnostics.record($0)
                }
            }
        ) { item in
            FeedCell(item: item, captionHeight: captionHeight)
        }
    }
}

/// Everything outside the collection that changes a Feed height.
private struct FeedResolveKey: Equatable {
    let style: TextStyle
    let captionStyle: TextStyle
    let revision: Int
}

private struct FeedCell: View {
    private static let padding: Double = 12
    private static let spacing: Double = 6

    let item: FeedItem
    /// Measured, not assumed: `.caption` grows with Dynamic Type like anything
    /// else, and pinning it to a constant clips the body text at large sizes.
    let captionHeight: Double

    /// The cell's total height, and the single definition of it.
    ///
    /// The layout input goes through here and the view fills whatever frame that
    /// produces, so the two cannot drift apart. Nothing inside sizes itself: the
    /// caption is pinned, and the body text takes exactly the space left over,
    /// which by construction is the height that was measured for it.
    ///
    /// A loose "chrome" constant plus self-sizing content is the version of this
    /// that silently overlaps cells as soon as the font or the padding changes.
    static func height(
        measuring text: String,
        width: Double,
        with measurer: TextMeasurer,
        captionHeight: Double
    ) -> Double {
        // The text is inset by the cell's own horizontal padding, so it has to be
        // measured at the width it will actually wrap at, not the cell's width.
        let textWidth = max(1, width - padding * 2)
        return measurer.height(of: text, width: textWidth)
            + captionHeight + spacing + padding * 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            Text("Item \(item.id.formatted())")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                // Measured as a single line, so it has to render as one. Without
                // this, "Item 52,096" at an accessibility text size wraps to two
                // lines, overflows the frame it was given, and pushes the body
                // text out of the cell — which reads as the body being clipped.
                .lineLimit(1)
                .frame(height: captionHeight, alignment: .leading)
            Text(item.body)
                .font(.body)
                .lineLimit(3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
    }
}
