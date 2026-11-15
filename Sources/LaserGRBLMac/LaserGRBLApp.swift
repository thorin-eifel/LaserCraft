import SwiftUI
import AppKit
import LaserGRBLCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Notifier.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Double-clicking a G-code file or picture in Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { AppModel.shared.openFile(url) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // never leave the laser burning when the app quits
        AppModel.shared.controller.disconnect()
    }
}

/// The menu bar: every toolbar action is also a menu command (HIG: Mac toolbars mirror the menu bar),
/// with standard shortcuts left untouched.
struct AppCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var controller: GrblController
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { model.checkForUpdates(silent: false) }
        }
        CommandGroup(replacing: .newItem) {
            Button("Open G-code…") { model.openGCode() }.keyboardShortcut("o")
            Button("Import Image…") { model.importImage() }.keyboardShortcut("i")
            Menu("Open Recent") {
                ForEach(model.recentFiles, id: \.self) { url in
                    Button(url.lastPathComponent) { model.openFile(url) }
                }
                Divider()
                Button("Clear Menu") { model.clearRecents() }.disabled(model.recentFiles.isEmpty)
            }
            .disabled(model.recentFiles.isEmpty)
            Divider()
            Button("Import SVG…") { model.addSVGToLayout() }.keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Add Text…") { model.tool = .vector(.text) }
            Button("Trace Image…") { model.traceImage() }
            Divider()
            Button("New Project") { model.newProject() }.keyboardShortcut("n")
            Button("Open Project…") { model.openProject() }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Save Project…") { model.saveProject() }.keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(model.layout.doc.isEmpty)
            Button("Save Project As…") { model.saveProject(saveAs: true) }.disabled(model.layout.doc.isEmpty)
            Divider()
            Button("Save G-code…") { model.saveGCode() }.keyboardShortcut("s")
                .disabled(controller.program == nil)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { if model.mainMode == .layout { model.layout.undo() } else { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } }
                .keyboardShortcut("z")
            Button("Redo") { if model.mainMode == .layout { model.layout.redo() } else { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) } }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandMenu("Tools") {
            Button("Test Patterns…") { model.tool = .testPatterns }
            Button("Materials…") { model.tool = .materials }
            Divider()
            Button("Machine Profiles…") { model.tool = .profiles }
            Button("Laser Statistics…") { model.tool = .statistics }
            Button("Network Machines…") { model.tool = .network }
            Divider()
            Button("Camera") { openWindow(id: "camera") }
        }
        CommandGroup(before: .toolbar) {
            Button("Zoom In") { model.preview.perform(.zoomIn) }.keyboardShortcut("+")
            Button("Zoom Out") { model.preview.perform(.zoomOut) }.keyboardShortcut("-")
            Button("Fit to window") { model.preview.perform(.fit) }.keyboardShortcut("0")
            Divider()
        }
        CommandMenu("Machine") {
            Button(L(controller.isConnected || controller.state == .connecting ? "Disconnect" : "Connect")) { model.toggleConnection() }
                .keyboardShortcut("k")
            Button("Refresh Ports") { model.refreshPorts() }.disabled(controller.state != .disconnected)
            Divider()
            Button("Home ($H)") { controller.home() }.disabled(!controller.isConnected || controller.jobRunning)
            Button("Unlock ($X)") { controller.unlock() }.disabled(!controller.isConnected || controller.jobRunning)
            Button("Frame") { model.runFrame() }
                .disabled(controller.program == nil || controller.state != .idle)
            Divider()
            Button("Soft Reset") { controller.softReset() }.keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!controller.isConnected)
            Divider()
            Button("Grbl configuration…") { model.showGrblConfig = true }
                .disabled(!controller.isConnected)
            Divider()
            Button("Save Console Log…") { model.saveConsoleLog() }
            Button("Copy Diagnostic Report") { model.copyDiagnosticReport() }
        }
        CommandMenu("Job") {
            Button("Start") { model.confirmStart() }.keyboardShortcut("r")
                .disabled(!controller.canStartJob)
            if controller.state == .hold || controller.state == .autoHold || controller.state == .cooling {
                Button("Resume") { controller.resume() }.keyboardShortcut("p", modifiers: [.command, .option])
            } else {
                Button("Pause") { controller.feedHold() }.keyboardShortcut("p", modifiers: [.command, .option])
                    .disabled(!(controller.state == .run || controller.state == .jog))
            }
            Button("Stop") { controller.abortJob() }.keyboardShortcut(".")
                .disabled(!controller.jobRunning)
            Divider()
            Button("Resume Job from Line…") { model.openResume() }
                .disabled(!controller.canStartJob)
        }
    }
}

struct LaserGRBLApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("LaserCraft", id: "main") {
            ContentView(controller: model.controller)
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 600)
        }
        .defaultSize(width: 1240, height: 780)
        .commands { AppCommands(model: model, controller: model.controller) }

        Window("Camera", id: "camera") {
            CameraWindow()
        }
        .defaultSize(width: 640, height: 520)

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}
