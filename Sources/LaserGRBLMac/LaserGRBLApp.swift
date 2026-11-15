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

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open G-code…") { model.openGCode() }.keyboardShortcut("o")
            Button("Import Image…") { model.importImage() }.keyboardShortcut("i")
            Divider()
            Button("Save G-code…") { model.saveGCode() }.keyboardShortcut("s")
                .disabled(controller.program == nil)
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
        }
        CommandMenu("Job") {
            Button("Start") { model.confirmStart() }.keyboardShortcut("r")
                .disabled(!controller.canStartJob)
            if controller.state == .hold || controller.state == .autoHold {
                Button("Resume") { controller.resume() }.keyboardShortcut("p", modifiers: [.command, .option])
            } else {
                Button("Pause") { controller.feedHold() }.keyboardShortcut("p", modifiers: [.command, .option])
                    .disabled(!(controller.state == .run || controller.state == .jog))
            }
            Button("Stop") { controller.abortJob() }.keyboardShortcut(".")
                .disabled(!controller.jobRunning)
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

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}
