import SwiftUI
import AppKit
import AVFoundation
import LaserGRBLCore

/// A USB or Continuity camera next to the laser: live picture, snapshots and an optional time-lapse while a job runs.
final class CameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    static let shared = CameraModel()

    @Published private(set) var devices: [AVCaptureDevice] = []
    @Published var selectedID: String = UserDefaults.standard.string(forKey: "cameraDevice") ?? "" {
        didSet { UserDefaults.standard.set(selectedID, forKey: "cameraDevice") }
    }
    @Published private(set) var running = false
    @Published private(set) var message: String?
    @Published var timelapse: Bool = UserDefaults.standard.object(forKey: "timelapse") as? Bool ?? false {
        didSet { UserDefaults.standard.set(timelapse, forKey: "timelapse") }
    }
    @Published var interval: Double = UserDefaults.standard.object(forKey: "timelapseInterval") as? Double ?? 10 {
        didSet { UserDefaults.standard.set(interval, forKey: "timelapseInterval") }
    }
    @Published private(set) var frames = 0
    @Published private(set) var folder: URL?

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var timer: Timer?
    private var configured = false

    override init() { super.init(); refreshDevices() }

    func refreshDevices() {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]
        devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        if !devices.contains(where: { $0.uniqueID == selectedID }) { selectedID = devices.first?.uniqueID ?? "" }
        if devices.isEmpty { message = L("No camera found. Connect a USB camera or bring an iPhone close to the Mac.") } else { message = nil }
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { if ok { self.configureAndRun() } else { self.message = L("Camera access was refused. Allow it in System Settings → Privacy & Security → Camera.") } }
            }
        default:
            message = L("Camera access was refused. Allow it in System Settings → Privacy & Security → Camera.")
        }
    }

    private func configureAndRun() {
        guard let device = devices.first(where: { $0.uniqueID == selectedID }) ?? devices.first else { message = L("No camera found. Connect a USB camera or bring an iPhone close to the Mac."); return }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
            if !configured, session.canAddOutput(photoOutput) { session.addOutput(photoOutput); configured = true }
            message = nil
        } catch { message = error.localizedDescription }
        session.commitConfiguration()
        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
            DispatchQueue.main.async { self.running = self.session.isRunning }
        }
    }

    func stop() {
        stopTimelapse()
        DispatchQueue.global(qos: .userInitiated).async {
            self.session.stopRunning()
            DispatchQueue.main.async { self.running = false }
        }
    }

    // MARK: pictures

    /// Where snapshots and time-lapse frames go.
    static var picturesFolder: URL {
        (FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("LaserCraft", isDirectory: true)
    }

    func snapshot() { capture(into: CameraModel.picturesFolder, name: "Snapshot-\(CameraModel.stamp())") }

    private static func stamp() -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private func capture(into dir: URL, name: String) {
        guard running, photoOutput.connections.first != nil else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        pendingTarget = dir.appendingPathComponent(name + ".jpg")
        photoOutput.capturePhoto(with: AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]), delegate: self)
    }

    private var pendingTarget: URL?

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(), let url = pendingTarget else { return }
        do { try data.write(to: url) } catch { return }                  // a picture that could not be saved is not counted
        DispatchQueue.main.async { if self.timer != nil { self.frames += 1 } }
    }

    // MARK: time-lapse

    /// Called by the app when a job starts: takes a picture every `interval` seconds until the job ends.
    func jobStarted(name: String) {
        guard timelapse else { return }
        if !running { start() }
        let dir = CameraModel.picturesFolder.appendingPathComponent("Timelapse-\((name as NSString).deletingPathExtension)-\(CameraModel.stamp())", isDirectory: true)
        folder = dir; frames = 0
        var n = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(1, interval), repeats: true) { [weak self] _ in
            n += 1
            self?.capture(into: dir, name: String(format: "frame-%05d", n))
        }
        // one frame right away (after the camera had a moment to start)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in n += 1; self?.capture(into: dir, name: String(format: "frame-%05d", n)) }
    }

    func jobEnded() { stopTimelapse() }

    private func stopTimelapse() { timer?.invalidate(); timer = nil }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        layer.frame = v.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer = CALayer(); v.layer?.backgroundColor = NSColor.black.cgColor
        v.layer?.addSublayer(layer)
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct CameraWindow: View {
    @ObservedObject var camera = CameraModel.shared

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if camera.running {
                    CameraPreview(session: camera.session)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "camera").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text(camera.message ?? L("The camera is off.")).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                }
            }
            .frame(minWidth: 480, minHeight: 300)
            Divider()
            HStack {
                Picker("Camera", selection: $camera.selectedID) {
                    if camera.devices.isEmpty { Text("No camera found").tag("") }
                    ForEach(camera.devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
                .frame(width: 220).disabled(camera.running)
                Button { camera.refreshDevices() } label: { IconLabel("Refresh Ports", icon: "refresh", size: 12) }.labelStyle(.iconOnly)
                if camera.running { Button("Stop Camera") { camera.stop() } } else { Button("Start Camera") { camera.start() }.disabled(camera.devices.isEmpty) }
                Button("Take Picture") { camera.snapshot() }.disabled(!camera.running)
                Spacer()
            }
            .padding(10)
            HStack {
                Toggle("Time-lapse while a job runs", isOn: $camera.timelapse)
                HStack(spacing: 4) {
                    Text("every")
                    TextField("", value: $camera.interval, format: .number).frame(width: 50).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    Text("seconds")
                }.disabled(!camera.timelapse)
                Spacer()
                if let f = camera.folder { Button(L("%d pictures", camera.frames)) { NSWorkspace.shared.activateFileViewerSelecting([f]) } .buttonStyle(.link) }
                Button("Open Pictures Folder") { NSWorkspace.shared.open(CameraModel.picturesFolder) }
            }
            .padding([.horizontal, .bottom], 10)
        }
    }
}
