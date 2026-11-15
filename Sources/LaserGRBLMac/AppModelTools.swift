import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LaserGRBLCore

enum MainMode: String, CaseIterable { case job, layout }

enum VectorSource: Equatable {
    case svg(URL)
    case trace(URL)
    case text
}

enum ToolSheet: Identifiable, Equatable {
    case vector(VectorSource)
    case testPatterns, materials, profiles, statistics, network
    var id: String {
        switch self {
        case .vector(let s): return "vector-\(s)"
        case .testPatterns: return "tests"
        case .materials: return "materials"
        case .profiles: return "profiles"
        case .statistics: return "statistics"
        case .network: return "network"
        }
    }
}

extension AppModel {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("LaserCraft", isDirectory: true)
    }

    /// Materials.json from the app bundle, or from the Resources folder next to the sources when run outside a bundle.
    static func builtinMaterialsData() -> Data? {
        var candidates: [URL] = []
        if let u = Bundle.main.url(forResource: "Materials", withExtension: "json") { candidates.append(u) }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Materials.json"))
        for u in candidates { if let d = try? Data(contentsOf: u) { return d } }
        return nil
    }

    var maxS: Double { Double(controller.settings[30] ?? "") ?? 1000 }
    var dynamicPowerDefault: Bool { UserDefaults.standard.object(forKey: "dynamicPower") as? Bool ?? true }

    /// Size of the machine area in mm ($130/$131), or a default.
    var machineArea: (Double, Double) {
        (Double(controller.settings[130] ?? "") ?? 300, Double(controller.settings[131] ?? "") ?? 200)
    }

    // MARK: layout

    /// Makes the job from the layout (it replaces the loaded job).
    func useLayoutAsJob() {
        guard !layout.doc.isEmpty else { return }
        guard !controller.jobRunning else { alertMessage = L("Stop the running job first."); return }
        let lines = layout.generate(maxS: maxS, dynamicPower: dynamicPowerDefault)
        let name = layout.fileURL.map { $0.deletingPathExtension().lastPathComponent } ?? L("Layout")
        let program = GCodeProgram(text: lines.joined(separator: "\n"), name: name + ".nc", rapidRate: rapidRate)
        layout.markGenerated()
        setProgram(program, fromLayout: true)
    }

    func newProject() { layout.newDocument(); mainMode = .layout }

    func openProject(_ url: URL? = nil) {
        var target = url
        if target == nil {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = true
            panel.message = L("Open Project…")
            guard panel.runModal() == .OK else { return }
            target = panel.url
        }
        guard let u = target else { return }
        do {
            let p = try layout.open(u)
            if let id = p.machineProfileID, profiles.profile(id: id) != nil { activeProfileID = id }
            if !p.header.isEmpty || !p.footer.isEmpty { controller.jobSettings.header = p.header; controller.jobSettings.footer = p.footer }
            mainMode = .layout
            noteRecent(u)
        } catch { alertMessage = L("Could not read the file: %@", error.localizedDescription) }
    }

    func saveProject(saveAs: Bool = false) {
        var url = layout.fileURL
        if url == nil || saveAs {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Project." + ProjectIO.fileExtension
            panel.message = L("Save Project…")
            guard panel.runModal() == .OK, var u = panel.url else { return }
            if u.pathExtension != ProjectIO.fileExtension { u.appendPathExtension(ProjectIO.fileExtension) }
            url = u
        }
        guard let u = url else { return }
        layout.header = controller.jobSettings.header; layout.footer = controller.jobSettings.footer
        do { try layout.save(to: u, profileID: activeProfileID); noteRecent(u) }
        catch { alertMessage = L("Could not save: %@", error.localizedDescription) }
    }

    func addPictureToLayout() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .bmp, .tiff, .gif, .heic]
        panel.message = L("Choose an image to engrave")
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        var o = RasterOptions(); o.widthMM = 60
        if layout.addImage(data: data, name: url.deletingPathExtension().lastPathComponent, options: o) == nil {
            alertMessage = L("This file could not be read as an image.")
        }
        mainMode = .layout
    }

    func addSVGToLayout() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "svg") ?? .xml]
        panel.message = L("Choose an SVG file")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        tool = .vector(.svg(url))
    }

    func traceImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .bmp, .tiff, .gif, .heic]
        panel.message = L("Choose an image to trace")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        tool = .vector(.trace(url))
    }

    // MARK: profiles and statistics

    var activeProfile: MachineProfile? { profiles.profile(id: activeProfileID) }

    /// Loads the settings of the laser that belongs to this port or address, if there is one.
    func applyProfile(forConnection c: String) {
        guard let p = profiles.profile(forConnection: c) else { return }
        activeProfileID = p.id
        baud = p.baud
        controller.jobSettings.header = p.header
        controller.jobSettings.footer = p.footer
        UserDefaults.standard.set(p.rapidRate, forKey: "rapidRate")
        UserDefaults.standard.set(p.spotSize, forKey: "laserSpotSize")
        saveJobSettings()
    }

    /// The profile that statistics are counted for: the active one, or a first one made on demand.
    func profileForStatistics() -> MachineProfile {
        if let p = activeProfile { return p }
        if let p = profiles.profile(forConnection: selectedPort) ?? profiles.profiles.first { activeProfileID = p.id; return p }
        var p = MachineProfile(name: L("My Laser"))
        p.connection = selectedPort == AppModel.simulatorPort ? "" : selectedPort
        p.baud = baud
        profiles.upsert(p)
        activeProfileID = p.id
        return p
    }

    func recordUsage(aborted: Bool, errors: Int, seconds: Double, name: String) {
        guard selectedPort != AppModel.simulatorPort, controller.program != nil else { return }
        let p = profileForStatistics()
        var e = ProfileStore.entry(profileID: p.id, program: controller.program, executedCommands: aborted ? controller.executedProgramCommands : (controller.program?.commands.count ?? 0),
                                   seconds: seconds, aborted: aborted, errors: errors, maxS: maxS, name: name)
        if !aborted {
            let passes = Double(max(1, controller.jobSettings.passes))
            e.laserSeconds *= passes; e.fullPowerSeconds *= passes
        }
        profiles.record(e)
        objectWillChange.send()
        let s = profiles.summary(for: p)
        if p.ratedHours > 0, s.lifeUsed >= 1, !aborted {
            presentInfo(title: L("Laser lifetime reached"),
                        message: L("%@ has been used for %@ hours at full power; its rated life is %@ hours.", p.name,
                                   String(format: "%.0f", s.fullPowerHours), String(format: "%.0f", p.ratedHours)))
        }
    }

    // MARK: network machines

    func addNetworkMachine(_ address: NetworkAddress) {
        let url = address.url
        if !networkMachines.contains(url) { networkMachines.append(url) }
        UserDefaults.standard.set(networkMachines, forKey: "networkMachines")
        refreshPorts()
        selectedPort = url
    }

    func forgetNetworkMachine(_ url: String) {
        networkMachines.removeAll { $0 == url }
        UserDefaults.standard.set(networkMachines, forKey: "networkMachines")
        refreshPorts()
    }

    func startDiscovery() {
        discovery.onChange = { [weak self] list in self?.discovered = list; self?.refreshPorts() }
        discovery.start()
    }
}
