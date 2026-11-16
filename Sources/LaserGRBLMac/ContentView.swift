import SwiftUI
import LaserGRBLCore

/// Same arrangement as the Windows version: connection / file / progress / command list / jog pad on the left,
/// preview with the button row on the right, status bar at the bottom. Controls are standard macOS ones.
struct ContentView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var controller: GrblController

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                LeftPanel(controller: controller)
                    .frame(minWidth: 320, idealWidth: 360, maxWidth: 460)
                VStack(spacing: 0) {
                    if app.mainMode == .layout {
                        LayoutEditor(layout: app.layout).frame(minHeight: 260)
                    } else {
                        PreviewView(preview: app.preview, controller: controller)
                            .frame(minHeight: 260)
                    }
                    Divider()
                    ActionRow(controller: controller)
                        .background(.bar)
                }
                .frame(minWidth: 440)
            }
            .frame(maxHeight: .infinity)
            StatusBar(controller: controller)   // a normal row below the split view, so nothing is covered
        }
        .navigationTitle(controller.program?.name ?? L("No Job Loaded"))
        .navigationSubtitle(controller.state.localizedName)
        .toolbar { toolbarContent }
        .alert(L("LaserCraft"), isPresented: Binding(get: { app.alertMessage != nil }, set: { if !$0 { app.alertMessage = nil } })) {
            Button("Close", role: .cancel) {}
        } message: { Text(app.alertMessage ?? "") }
        .sheet(isPresented: $app.showImageImport) {
            if let url = app.importURL { ImageImportView(url: url).environmentObject(app) }
        }
        .sheet(item: $app.tool) { tool in
            Group {
                switch tool {
                case .vector(let source): VectorSheet(source: source)
                case .testPatterns: TestPatternsSheet()
                case .materials: MaterialsSheet()
                case .profiles: ProfilesSheet()
                case .statistics: StatisticsSheet()
                case .network: NetworkSheet()
                case .history: JobHistorySheet()
                }
            }.environmentObject(app)
        }
        .sheet(isPresented: $app.showResume) { ResumeSheet(controller: controller).environmentObject(app) }
        .sheet(isPresented: $app.showGrblConfig) { GrblConfigView(controller: controller).environmentObject(app) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url else { return }
                DispatchQueue.main.async { app.openFile(url) }
            }
            return true
        }
    }

    // MARK: toolbar

    /// macOS 26+ draws toolbar items as grouped capsules; a fixed spacer separates the groups.
    @ToolbarContentBuilder
    private var groupSpacer: some ToolbarContent {
        if #available(macOS 26.0, *) { ToolbarSpacer(.fixed) }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $app.mainMode) {
                Text("Job").tag(MainMode.job)
                Text("Layout").tag(MainMode.layout)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 160)
            .help("Switch between the job preview and the layout editor")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { app.openGCode() } label: { IconLabel("Open G-code", icon: "folder") }
                .help("Open a G-code file (⌘O)")
            Button { app.importImage() } label: { IconLabel("Import Image", icon: "image") }
                .help("Turn a picture into an engraving (⌘I)")
            Button { app.saveGCode() } label: { IconLabel("Save G-code", icon: "save") }
                .disabled(controller.program == nil)
                .help("Save the job as a G-code file (⌘S)")
        }
        groupSpacer
        ToolbarItem(placement: .primaryAction) {
            Button { app.showGrblConfig = true } label: { IconLabel("Grbl configuration…", icon: "sliders") }
                .disabled(!controller.isConnected)
                .help("Grbl configuration…")
        }
    }
}


/// "Resume Job from Line…": choose the line, see what the machine will do first, then continue after the safety check.
struct ResumeSheet: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var controller: GrblController
    @Environment(\.dismiss) var dismiss

    private var program: GCodeProgram? { controller.program }

    var body: some View {
        let count = program?.commands.count ?? 1
        VStack(alignment: .leading, spacing: 12) {
            Text("Resume Job from Line").font(.title2).fontWeight(.semibold)
            if let s = app.stopInfo, s.name == program?.name, s.count == count {
                Text(L("The last run of this job stopped near line %d. The suggestion starts a few lines earlier, because Grbl had already buffered some lines.", s.line + AppModel.resumeSafetyLines + 1))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Start at line")
                TextField("Line", value: Binding(get: { app.resumeLine + 1 }, set: { app.resumeLine = min(max(0, $0 - 1), count - 1) }), format: .number)
                    .frame(width: 80).multilineTextAlignment(.trailing)
                Stepper("", value: Binding(get: { app.resumeLine + 1 }, set: { app.resumeLine = min(max(0, $0 - 1), count - 1) }), in: 1...count).labelsHidden()
                Text(L("of %d", count)).foregroundStyle(.secondary)
            }
            if let p = program, app.resumeLine < p.commands.count {
                GroupBox {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("First the machine does this (laser off):").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(p.resumeCommands(from: app.resumeLine).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 11, design: .monospaced))
                        }
                        if app.resumeLine == 0 { Text("Nothing: the job starts from the beginning.").font(.caption) }
                        Divider().padding(.vertical, 4)
                        Text(L("Then it continues with line %d:", app.resumeLine + 1)).font(.caption).foregroundStyle(.secondary)
                        Text(p.commands[app.resumeLine]).font(.system(size: 11, design: .monospaced))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Continue Job") {
                    dismiss()
                    DispatchQueue.main.async { app.resumeJob(fromLine: app.resumeLine) }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!controller.canStartJob)
            }
        }
        .padding(20).frame(width: 520)
    }
}
