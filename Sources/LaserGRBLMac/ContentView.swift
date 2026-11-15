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
                    PreviewView(preview: app.preview, controller: controller)
                        .frame(minHeight: 260)
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
