import SwiftUI
import LaserGRBLCore

// MARK: - Status colours

extension MachineState {
    var color: Color {
        switch self {
        case .idle: return .green
        case .run, .home, .jog: return .blue
        case .hold, .autoHold, .door, .cooling, .connecting: return .orange
        case .alarm: return .red
        case .check: return .purple
        default: return .gray
        }
    }
}

// MARK: - Left column (same order as the Windows version)

/// Connection, file, progress, command line, command list and jog pad.
struct LeftPanel: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var controller: GrblController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            connectionRow
            fileRow
            progressRow
            CommandField(controller: controller)
            CommandList(controller: controller)
            JogPanel(controller: controller)
        }
        .padding(12)
    }

    private func rowLabel(_ key: LocalizedStringKey) -> some View {
        Text(key).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
    }

    private var connectionRow: some View {
        HStack(spacing: 6) {
            rowLabel("Port")
            Picker("Port", selection: $app.selectedPort) {
                if app.ports.isEmpty { Text("No port found").tag("") }
                ForEach(app.ports, id: \.self) { Text(($0 as NSString).lastPathComponent).tag($0) }
            }
            .labelsHidden()
            .disabled(controller.state != .disconnected)
            .help("Serial port of the laser")
            Picker("Baud rate", selection: $app.baud) {
                ForEach(AppModel.bauds, id: \.self) { Text(verbatim: String($0)).tag($0) }
            }
            .labelsHidden().frame(width: 84)
            .disabled(controller.state != .disconnected)
            .help("Baud rate (115200 for most controllers)")
            Button { app.refreshPorts() } label: { IconLabel("Refresh Ports", icon: "refresh", size: 13) }
                .labelStyle(.iconOnly)
                .disabled(controller.state != .disconnected)
                .help("Refresh the list of ports")
            Button { app.toggleConnection() } label: {
                if controller.state == .disconnected { IconLabel("Connect", icon: "plug", size: 13) }
                else { IconLabel("Disconnect", icon: "unplug", size: 13) }
            }
            .labelStyle(.iconOnly)
            .help(L(controller.state == .disconnected ? "Connect to the laser (⌘K)" : "Disconnect from the laser (⌘K)"))
        }
    }

    private var fileRow: some View {
        HStack(spacing: 6) {
            rowLabel("File")
            TextField("File", text: .constant(controller.program?.name ?? ""), prompt: Text("No file loaded"))
                .labelsHidden().disabled(true)
            Button { app.openGCode() } label: { IconLabel("Open G-code", icon: "folder", size: 13) }
                .labelStyle(.iconOnly).help("Open a G-code file (⌘O)")
        }
    }

    private var progressRow: some View {
        HStack(spacing: 6) {
            rowLabel("Progress")
            ProgressView(value: controller.jobProgress)
                .overlay {
                    Text(progressText).font(.caption).monospacedDigit().foregroundStyle(.primary)
                        .shadow(color: Color(nsColor: .controlBackgroundColor), radius: 2)
                }
            Stepper(value: $controller.jobSettings.passes, in: 1...50) {
                Text("\(controller.jobSettings.passes)").monospacedDigit()
            }
            .help("Passes")
            .disabled(controller.jobRunning)
            Button { app.confirmStart() } label: { IconLabel("Start", icon: "play", size: 13) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .disabled(!controller.canStartJob)
                .help("Start the job")
        }
    }

    private var progressText: String {
        if let r = controller.remainingSeconds { return GCodeProgram.formatDuration(r) }
        if controller.program != nil, !controller.jobRunning, controller.jobExecuted > 0 {
            return L("%d errors", controller.jobErrors)
        }
        return ""
    }
}

// MARK: - Command line

struct CommandField: View {
    @ObservedObject var controller: GrblController
    @State private var input = ""
    @State private var history: [String] = []
    @State private var historyIndex = 0

    var body: some View {
        TextField("Command", text: $input, prompt: Text("Type G-code here"))
            .labelsHidden()
            .font(.system(size: 12, design: .monospaced))
            .onSubmit(submit)
            .onKeyPress(.upArrow) { recall(-1); return .handled }
            .onKeyPress(.downArrow) { recall(1); return .handled }
            .disabled(!controller.isConnected)
            .help("Type a command (e.g. $$ or G0 X10) and press Return")
    }

    private func submit() {
        let t = input.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        controller.send(t)
        history.append(t); historyIndex = history.count
        input = ""
    }

    private func recall(_ d: Int) {
        guard !history.isEmpty else { return }
        historyIndex = max(0, min(history.count, historyIndex + d))
        input = historyIndex < history.count ? history[historyIndex] : ""
    }
}

// MARK: - Command list (G-code lines with ✓ / ✕, or the console messages)

struct CommandList: View {
    @ObservedObject var controller: GrblController
    private enum Mode: String { case program, messages }
    @State private var mode: Mode = .program
    @State private var lastScroll = Date.distantPast

    var body: some View {
        VStack(spacing: 6) {
            Picker("List", selection: $mode) {
                Text("G-code").tag(Mode.program)
                Text("Console").tag(Mode.messages)
            }
            .pickerStyle(.segmented).labelsHidden()
            Group {
                if mode == .program { programList } else { messageList }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
        .frame(minHeight: 140)
        .onChange(of: controller.program?.name) { _, new in if new != nil { mode = .program } }
    }

    private var programList: some View {
        let commands = controller.program?.commands ?? []
        let done = controller.executedProgramCommands
        return ScrollViewReader { proxy in
            ScrollView {
                if commands.isEmpty {
                    Text("Open a G-code file or import an image")
                        .foregroundStyle(.secondary).padding(12).frame(maxWidth: .infinity)
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<commands.count, id: \.self) { i in
                        HStack(spacing: 6) {
                            statusIcon(i, done: done)
                            Text(commands[i]).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 6).frame(height: 18)
                        .id(i)
                    }
                }
            }
            .onChange(of: controller.jobExecuted) {
                guard controller.jobRunning, Date().timeIntervalSince(lastScroll) > 0.2 else { return }
                lastScroll = Date()
                proxy.scrollTo(min(commands.count - 1, done + 6), anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ i: Int, done: Int) -> some View {
        if controller.errorLines.contains(i) {
            UIcon(name: "cross", size: 10).foregroundStyle(.red).accessibilityLabel(Text("Error"))
        } else if i < done {
            UIcon(name: "check", size: 10).foregroundStyle(.green).accessibilityLabel(Text("Done"))
        } else {
            Circle().fill(.tertiary).frame(width: 5, height: 5).frame(width: 10, height: 10)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(controller.console) { line in
                        Text(prefix(line) + line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(line))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(line.id)
                    }
                }
                .padding(6)
            }
            .onChange(of: controller.console.count) {
                if let last = controller.console.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { controller.clearConsole() } label: { IconLabel("Clear Console", icon: "trash", size: 11) }
                .labelStyle(.iconOnly).buttonStyle(.borderless).help("Clear the console").padding(4)
        }
    }

    private func prefix(_ l: ConsoleLine) -> String {
        switch l.kind { case .sent: return "> "; case .received: return "< "; default: return "" }
    }

    private func color(_ l: ConsoleLine) -> Color {
        switch l.kind {
        case .sent: return .primary
        case .received: return .secondary
        case .info: return .blue
        case .error: return .red
        }
    }
}

// MARK: - Jog pad with speed and step sliders

struct JogPanel: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var controller: GrblController

    private let steps: [Double] = [0.1, 0.5, 1, 5, 10, 50, 100]

    private var stepIndex: Binding<Double> {
        Binding(get: { Double(steps.firstIndex(of: app.jogStep) ?? 4) },
                set: { app.jogStep = steps[max(0, min(steps.count - 1, Int($0.rounded())))] })
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            verticalSlider(value: $app.jogFeed, range: 100...10000, step: 100, label: "F\(Int(app.jogFeed))", help: "Jog speed (mm/min)")
            VStack(spacing: 6) {
                pad
                HStack(spacing: 6) {
                    Button { jog(.zUp) } label: { IconLabel("Z up", icon: "up", size: 11) }.help("Z axis up")
                    Button { jog(.zDown) } label: { IconLabel("Z down", icon: "down", size: 11) }.help("Z axis down")
                }
                .labelStyle(.iconOnly).controlSize(.small)
            }
            verticalSlider(value: stepIndex, range: 0...6, step: 1, label: app.jogStep.formatted(), help: "Jog step (mm)")
        }
        .frame(maxWidth: .infinity)
        .disabled(!(controller.state == .idle || controller.state == .jog))
    }

    private func verticalSlider(value: Binding<Double>, range: ClosedRange<Double>, step: Double, label: String, help: LocalizedStringKey) -> some View {
        VStack(spacing: 4) {
            Slider(value: value, in: range, step: step)
                .frame(width: 104)
                .rotationEffect(.degrees(-90))
                .frame(width: 22, height: 104)
                .accessibilityLabel(Text(help))
            Text(label).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .help(help)
    }

    private func jog(_ d: JogDirection) { controller.jog(d, step: app.jogStep, feed: app.jogFeed) }

    private var pad: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow { arrow(.nw, "upleft", 0, "Up left"); arrow(.n, "up", 0, "Up"); arrow(.ne, "upright", 0, "Up right") }
            GridRow { arrow(.w, "left", 0, "Left"); arrow(.home, "home", 0, "Go to work zero (X0 Y0)"); arrow(.e, "right", 0, "Right") }
            GridRow { arrow(.sw, "downleft", 0, "Down left"); arrow(.s, "down", 0, "Down"); arrow(.se, "downright", 0, "Down right") }
        }
    }

    private func arrow(_ d: JogDirection, _ icon: String, _ rotation: Double, _ help: LocalizedStringKey) -> some View {
        Button { jog(d) } label: { UIcon(name: icon, size: 15, rotation: rotation).frame(width: 34, height: 26) }
            .help(help)
            .accessibilityLabel(Text(help))
    }
}

// MARK: - Action row under the preview (machine and custom buttons, pause / stop)

struct ActionRow: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var controller: GrblController

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            FlowLayout(spacing: 6) {
                Button { app.runFrame() } label: { IconLabel("Frame", icon: "fit", size: 13) }
                    .disabled(controller.program == nil || controller.state != .idle)
                    .help("Trace the outline of the job")
                ForEach(app.customButtons) { b in
                    Button { app.runCustomButton(b) } label: {
                        if let icon = b.icon { Label { Text(b.displayTitle) } icon: { UIcon(name: icon, size: 13) } } else { Text(b.displayTitle) }
                    }
                    .help(b.gcode)
                }
            }
            .disabled(!controller.isConnected || controller.jobRunning)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if controller.state == .hold || controller.state == .autoHold {
                    Button { controller.resume() } label: { IconLabel("Resume", icon: "play", size: 15) }
                        .help("Resume after a pause")
                } else {
                    Button { controller.feedHold() } label: { IconLabel("Pause", icon: "pause", size: 15) }
                        .disabled(!(controller.state == .run || controller.state == .jog))
                        .help("Pause the machine (feed hold)")
                }
                Button(role: controller.jobRunning ? .destructive : nil) {
                    controller.jobRunning ? controller.abortJob() : controller.softReset()
                } label: {
                    if controller.jobRunning { IconLabel("Stop", icon: "stop", size: 15) } else { IconLabel("Reset", icon: "reset", size: 15) }
                }
                .disabled(!controller.isConnected)
                .help(L(controller.jobRunning ? "Stop the job and switch the laser off" : "Soft-reset the controller"))
            }
            .labelStyle(.iconOnly)
            .controlSize(.large)
        }
        .padding(12)
    }
}

// MARK: - Status bar with override read-outs

struct StatusBar: View {
    @ObservedObject var controller: GrblController
    @State private var showFeed = false
    @State private var showRapid = false
    @State private var showSpindle = false

    var body: some View {
        HStack(spacing: 10) {
            item("Lines", value: String(controller.program?.commands.count ?? 0))
            Divider().frame(height: 14)
            HStack(spacing: 6) {
                Text("Buffer").foregroundStyle(.secondary).lineLimit(1).fixedSize()
                ProgressView(value: Double(controller.usedBufferBytes), total: Double(max(1, controller.bufferCapacity)))
                    .frame(width: 70)
            }
            Divider().frame(height: 14)
            item("Estimated Time", value: controller.program.map { GCodeProgram.formatDuration($0.estimatedSeconds) } ?? "–")
            Divider().frame(height: 14)
            Text(message).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(controller.state == .alarm ? Color.red : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if controller.state == .alarm {
                Button("Unlock") { controller.unlock() }.controlSize(.small)
            }
            overrideButton("S", value: controller.overrideSpindle, shown: $showSpindle) {
                OverrideSlider(title: "Power", actual: controller.overrideSpindle, target: controller.targetOverrides.spindle) { controller.setOverrides(spindle: $0) }
            }
            overrideButton("G1", value: controller.overrideFeed, shown: $showFeed) {
                OverrideSlider(title: "Speed", actual: controller.overrideFeed, target: controller.targetOverrides.feed) { controller.setOverrides(feed: $0) }
            }
            overrideButton("G0", value: controller.overrideRapid, shown: $showRapid) { RapidOverride(controller: controller) }
            Divider().frame(height: 14)
            HStack(spacing: 6) {
                Text("Status").foregroundStyle(.secondary)
                Circle().fill(controller.state.color).frame(width: 9, height: 9).accessibilityHidden(true)
                Text(controller.state.localizedName).fontWeight(.semibold)
            }
            .lineLimit(1).fixedSize()
            .accessibilityElement(children: .combine)
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var message: String {
        if controller.state == .alarm { return controller.lastAlarm ?? L("Alarm — unlock or home the machine") }
        if let v = controller.version { return L("Grbl %@", v.description) }
        return ""
    }

    private func item(_ title: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .lineLimit(1).fixedSize()
    }

    private func overrideButton<Content: View>(_ name: String, value: Int, shown: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        Button { shown.wrappedValue.toggle() } label: {
            Text("\(name) [\((Double(value) / 100).formatted(.number.precision(.fractionLength(2))))×]").monospacedDigit()
        }
        .buttonStyle(.plain)
        .disabled(!controller.isConnected)
        .popover(isPresented: shown, arrowEdge: .top) { content().padding(14).frame(width: 260) }
        .help("Real-time overrides need Grbl 1.1 or newer")
    }
}

struct OverrideSlider: View {
    let title: LocalizedStringKey
    let actual: Int
    let target: Int
    let change: (Int) -> Void
    @State private var value = 100.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            HStack {
                Slider(value: $value, in: 10...200, step: 1) { editing in if !editing { change(Int(value)) } }
                    .onChange(of: value) { _, new in change(Int(new)) }
                Text("\(actual)%").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            Button("Back to 100%") { value = 100; change(100) }.controlSize(.small)
        }
        .onAppear { value = Double(target) }
    }
}

struct RapidOverride: View {
    @ObservedObject var controller: GrblController
    @State private var rapid = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rapids").font(.headline)
            Picker("Rapids", selection: $rapid) {
                Text("100%").tag(100); Text("50%").tag(50); Text("25%").tag(25)
            }
            .pickerStyle(.segmented).labelsHidden()
            .onChange(of: rapid) { controller.setOverrides(rapid: $1) }
        }
        .onAppear { rapid = controller.targetOverrides.rapid }
    }
}

// MARK: - Layout helper: wraps buttons onto several lines

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? 280, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(bounds.width, subviews)
        for (i, f) in r.frames.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxW: CGFloat = 0
        var frames: [CGRect] = []
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            frames.append(CGRect(x: x, y: y, width: sz.width, height: sz.height))
            x += sz.width + spacing; rowH = max(rowH, sz.height); maxW = max(maxW, x - spacing)
        }
        return (CGSize(width: maxW, height: y + rowH), frames)
    }
}
