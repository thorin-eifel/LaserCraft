import Foundation
import Combine

public enum JogDirection: CaseIterable {
    case n, ne, e, se, s, sw, w, nw, home, zUp, zDown
}

public struct ConsoleLine: Identifiable {
    public enum Kind { case sent, received, info, error }
    public let id: Int
    public let text: String
    public let kind: Kind
    public let date: Date
}

/// Things the app may want to tell the person about (sound, alert, notification).
public enum ControllerEvent {
    /// The controller answered after `connect`.
    case connected
    /// The port could not be opened, or the controller never answered.
    case connectionFailed(message: String)
    case jobStarted
    /// `aborted` is true when the job was stopped or failed; the other events explain why.
    case jobFinished(aborted: Bool, errors: Int, seconds: Double, name: String)
    /// Grbl rejected a line of the running job (the job carries on).
    case lineError(message: String, line: String)
    case alarm(message: String)
    case connectionLost
    case controllerRestarted
}

public struct JobSettings: Equatable {
    public var header = "G90 (use absolute coordinates)"
    public var footer = "G0 X0 Y0 (move back to origin)"
    public var passes = 1
    public init() {}
}

/// Talks to a Grbl controller: connection, character-counting streaming of a job,
/// real-time commands, status polling, jogging and overrides.
/// All members must be used from the main thread.
public final class GrblController: ObservableObject {
    public static let defaultBufferSize = 127

    // MARK: published state
    @Published public private(set) var state: MachineState = .disconnected
    @Published public private(set) var subState: Int?
    @Published public private(set) var machinePosition = Point3()
    @Published public private(set) var workOffset = Point3()
    @Published public private(set) var version: GrblVersion?
    @Published public private(set) var console: [ConsoleLine] = []
    @Published public private(set) var settings: [Int: String] = [:]
    @Published public private(set) var overrideFeed = 100
    @Published public private(set) var overrideRapid = 100
    @Published public private(set) var overrideSpindle = 100
    @Published public private(set) var buffer: (blocks: Int, bytes: Int)?
    @Published public private(set) var lastAlarm: String?
    @Published public private(set) var program: GCodeProgram?
    @Published public private(set) var jobSent = 0
    @Published public private(set) var jobExecuted = 0
    @Published public private(set) var jobErrors = 0
    /// Indices (into `program.commands`) of lines Grbl answered with an error.
    @Published public private(set) var errorLines: Set<Int> = []
    @Published public private(set) var jobRunning = false
    @Published public private(set) var jobStart: Date?
    @Published public private(set) var currentFeed: Double = 0
    @Published public private(set) var currentSpindle: Double = 0

    public var jobSettings = JobSettings()
    /// Called for start, end, errors and alarms of a job.
    public var onEvent: ((ControllerEvent) -> Void)?

    // MARK: private state
    private var port: SerialPort?
    private var rxBuffer = Data()
    private var manualQueue: [String] = []
    private var jobQueue: [String] = []
    private var pending: [(line: String, length: Int, isJob: Bool)] = []
    private var usedBuffer = 0
    private var bufferSize = GrblController.defaultBufferSize
    private var statusTimer: Timer?
    private var connectDeadline: Date?
    private var logCounter = 0
    private var holdByUser = false
    private var jobTotalCommands = 0
    private var jobRemainingPasses = 0
    private var jobFooterQueued = false
    private var targetFeed = 100, targetRapid = 100, targetSpindle = 100

    public init() {}

    public var isConnected: Bool { state != .disconnected && state != .connecting }
    public var workPosition: Point3 { machinePosition - workOffset }
    public var jobTarget: Int { jobTotalCommands }
    /// Bytes of Grbl's receive buffer currently in use by streamed lines.
    public var usedBufferBytes: Int { usedBuffer }
    public var bufferCapacity: Int { bufferSize }

    /// Fraction 0...1 of the job already executed by the machine.
    public var jobProgress: Double {
        jobTotalCommands == 0 ? 0 : min(1, Double(jobExecuted) / Double(jobTotalCommands))
    }

    /// How many lines of the loaded program (not header/footer) the machine has already accepted.
    public var executedProgramCommands: Int {
        guard let p = program, jobRunning || jobExecuted > 0 else { return 0 }
        let headerCount = jobSettings.header.split(whereSeparator: \.isNewline)
            .filter { !GrblParser.cleanLine(String($0)).isEmpty }.count
        let e = max(0, jobExecuted - headerCount)
        let n = max(1, p.commands.count)
        let passes = max(1, jobSettings.passes)
        if e >= n * passes { return p.commands.count }
        return e % n
    }

    public var supportsTrueJogging: Bool { (version ?? GrblVersion(major: 1, minor: 1)) >= GrblVersion(major: 1, minor: 1) }

    /// Estimated time still needed for the running job.
    public var remainingSeconds: Double? {
        guard jobRunning, let p = program, jobExecuted > 0, jobExecuted <= p.cumulativeSeconds.count else { return nil }
        let total = Double(p.estimatedSeconds)
        let done = Double(p.cumulativeSeconds[min(jobExecuted, p.cumulativeSeconds.count) - 1])
        let scale = Double(max(1, targetFeedScale))
        return max(0, (total - done) / scale)
    }
    private var targetFeedScale: Double { Double(overrideFeed) / 100 }

    // MARK: connection

    public func connect(path: String, baud: Int) {
        guard port == nil else { return }
        let p = SerialPort(path: path)
        p.onData = { [weak self] data in self?.receive(data) }
        p.onClose = { [weak self] in self?.connectionLost() }
        do {
            try p.open(baud: baud)
        } catch {
            log(L("Connection failed: %@", error.localizedDescription), .error)
            onEvent?(.connectionFailed(message: error.localizedDescription))
            return
        }
        port = p
        resetStreams()
        setState(.connecting)
        log(L("Connected to %@ at %d baud", path, baud), .info)
        connectDeadline = Date().addingTimeInterval(10)
        startTimer()
        // Many boards reboot when the port opens; if not, a soft reset makes Grbl send its welcome line.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, self.state == .connecting else { return }
            self.sendRealtime(0x18, quiet: true)
        }
    }

    public func disconnect() {
        guard port != nil else { return }
        if jobRunning {
            // never leave the laser burning: hold, then reset the controller before closing the port
            sendRealtime(0x21, quiet: true)
            sendRealtime(0x18, quiet: true)
            finishJob(aborted: true)
        }
        teardown()
        log(L("Disconnected"), .info)
    }

    private func connectionLost() {
        log(L("The connection to the machine was lost"), .error)
        onEvent?(.connectionLost)
        if jobRunning { finishJob(aborted: true) }
        teardown()
    }

    private func teardown() {
        statusTimer?.invalidate(); statusTimer = nil
        port?.onData = nil; port?.onClose = nil
        port?.close(); port = nil
        resetStreams()
        version = nil
        buffer = nil
        setState(.disconnected)
    }

    private func resetStreams() {
        rxBuffer.removeAll()
        manualQueue.removeAll(); jobQueue.removeAll(); pending.removeAll()
        usedBuffer = 0
        overrideFeed = 100; overrideRapid = 100; overrideSpindle = 100
        targetFeed = 100; targetRapid = 100; targetSpindle = 100
        holdByUser = false
    }

    private func startTimer() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        guard let port = port, port.isOpen else { return }
        if state == .connecting, let d = connectDeadline, Date() > d {
            log(L("Connection timeout: no answer from the machine"), .error)
            onEvent?(.connectionFailed(message: L("Connection timeout: no answer from the machine")))
            teardown()
            return
        }
        sendRealtime(0x3F, quiet: true)   // "?"
        pump()
    }

    // MARK: sending

    /// Queue a command typed by the user (or generated by a button).
    public func send(_ command: String) {
        guard isConnected else { log(L("Not connected"), .error); return }
        let clean = GrblParser.cleanLine(command)
        guard !clean.isEmpty else { return }
        manualQueue.append(clean)
        pump()
    }

    public func sendRealtime(_ byte: UInt8, quiet: Bool = false) {
        guard let port = port, port.isOpen else { return }
        do { try port.write(byte: byte) } catch { log(L("Write failed: %@", error.localizedDescription), .error) }
        if !quiet { log(String(format: "[realtime 0x%02X]", byte), .sent) }
    }

    private func nextLine() -> (String, Bool)? {
        if let m = manualQueue.first { return (m, false) }
        if jobRunning, let j = jobQueue.first {
            // pause streaming while a feed hold is active, like the Windows app
            return (j, true)
        }
        return nil
    }

    private func pump() {
        guard let port = port, port.isOpen, state != .connecting else { return }
        while let (line, isJob) = nextLine() {
            let length = line.utf8.count + 1
            if usedBuffer + length > bufferSize && usedBuffer > 0 { break }
            // "$" commands (settings, homing) and jog are synchronous: wait until the pipe is empty
            if line.hasPrefix("$") && !line.hasPrefix("$J=") && !pending.isEmpty { break }
            if isJob { jobQueue.removeFirst() } else { manualQueue.removeFirst() }
            do { try port.write(line + "\n") } catch {
                log(L("Write failed: %@", error.localizedDescription), .error)
                break
            }
            usedBuffer += length
            pending.append((line, length, isJob))
            if isJob { jobSent += 1 }
            if !isJob { log(line, .sent) }
        }
    }

    // MARK: receiving

    private func receive(_ data: Data) {
        rxBuffer.append(data)
        while let nl = rxBuffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = rxBuffer[rxBuffer.startIndex..<nl]
            rxBuffer.removeSubrange(rxBuffer.startIndex...nl)
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { handle(line) }
        }
    }

    private func handle(_ line: String) {
        switch GrblParser.classify(line) {
        case .status(let raw):
            if let r = GrblParser.parseStatus(raw) { apply(r) }
        case .ok:
            completePending(error: nil)
        case .error(let n):
            let text = GrblParser.describeError(n)
            let jobLine = pending.first.map { $0.line } ?? ""
            log(jobLine.isEmpty ? text : "\(text)  [\(jobLine)]", .error)
            if jobRunning, pending.first?.isJob == true { onEvent?(.lineError(message: text, line: jobLine)) }
            completePending(error: n)
        case .alarm(let n):
            let text = GrblParser.describeAlarm(n)
            lastAlarm = text
            log(text, .error)
            onEvent?(.alarm(message: text))
            if jobRunning { finishJob(aborted: true) }
            setState(.alarm)
        case .welcome(let w):
            log(w, .received)
            version = GrblParser.parseWelcome(w)
            // a (re)start empties Grbl's pipeline
            pending.removeAll(); usedBuffer = 0
            if jobRunning { log(L("The controller restarted during the job; job stopped"), .error); onEvent?(.controllerRestarted); finishJob(aborted: true) }
            if state == .connecting || state == .disconnected { setState(.idle) }
            queueStartupQueries()
        case .setting(let n, let v):
            settings[n] = v
            log(line, .received)
        case .info(let s):
            if s.hasPrefix("[VER:"), let v = GrblParser.parseWelcome("Grbl " + s.dropFirst(5)) { version = v }
            log(s, .received)
        case .other(let s):
            log(s, .received)
        }
    }

    private func queueStartupQueries() {
        if !manualQueue.contains("$$") { manualQueue.append("$$") }
        if version == nil && !manualQueue.contains("$I") { manualQueue.append("$I") }
        pump()
    }

    private func completePending(error: Int?) {
        guard !pending.isEmpty else { return }
        let done = pending.removeFirst()
        usedBuffer = max(0, usedBuffer - done.length)
        if done.isJob {
            jobExecuted += 1
            if error != nil {
                jobErrors += 1
                let idx = executedProgramCommands - 1
                if idx >= 0 { errorLines.insert(idx) }
            }
        }
        if state == .connecting { setState(.idle) }
        if jobRunning && jobQueue.isEmpty && !pending.contains(where: { $0.isJob }) { jobQueueDrained() }
        pump()
    }

    private func apply(_ r: StatusReport) {
        connectDeadline = nil
        var st = r.state
        if jobRunning && st == .idle { st = .run }   // Grbl reports Idle during G4 dwell
        if st == .hold && !holdByUser { st = .autoHold }
        if state == .connecting, version == nil {
            // The board was already running: no welcome line was seen.
            queueStartupQueries()
        }
        setState(st)
        subState = r.subState
        if let w = r.wco { workOffset = w }
        if let m = r.mpos {
            machinePosition = m
            if r.wco == nil, let wp = r.wpos { workOffset = m - wp }
        } else if let wp = r.wpos {
            machinePosition = wp + workOffset
        }
        if let ov = r.overrides {
            overrideFeed = ov.feed; overrideRapid = ov.rapid; overrideSpindle = ov.spindle
            manageOverrides()
        }
        buffer = r.buffer ?? buffer
        if let f = r.feed { currentFeed = f }
        if let s = r.spindle { currentSpindle = s }
    }

    private func setState(_ s: MachineState) {
        let was = state
        if state != s { state = s }
        if was == .connecting && s != .connecting && s != .disconnected { onEvent?(.connected) }
        if s != .hold && s != .autoHold { holdByUser = false }
    }

    // MARK: job control

    public func load(_ program: GCodeProgram) {
        self.program = program
        jobSent = 0; jobExecuted = 0; jobErrors = 0; errorLines = []
        log(L("Loaded %@: %d lines", program.name, program.commands.count), .info)
    }

    public func clearProgram() {
        guard !jobRunning else { return }
        program = nil
        jobSent = 0; jobExecuted = 0; jobErrors = 0; errorLines = []
    }

    public var canStartJob: Bool {
        isConnected && !jobRunning && (program?.isEmpty == false) && (state == .idle)
    }

    public func startJob() {
        guard canStartJob, let p = program else { return }
        jobSent = 0; jobExecuted = 0; jobErrors = 0; errorLines = []
        jobRemainingPasses = max(1, jobSettings.passes)
        jobStart = Date()
        jobFooterQueued = false
        jobRunning = true
        enqueuePass(first: true, program: p)
        log(L("Job started: %d lines × %d", p.commands.count, jobSettings.passes), .info)
        onEvent?(.jobStarted)
        pump()
    }

    private func enqueuePass(first: Bool, program p: GCodeProgram) {
        var lines: [String] = []
        if first { lines += jobSettings.header.split(whereSeparator: \.isNewline).map { GrblParser.cleanLine(String($0)) } }
        lines += p.commands
        jobQueue = lines.filter { !$0.isEmpty }
        // header lines are part of the progress counters so executed == target at the end
        if first { jobTotalCommands = 0 }
        jobTotalCommands += jobQueue.count
    }

    private func jobQueueDrained() {
        guard let p = program else { finishJob(aborted: false); return }
        if jobRemainingPasses > 1 {
            jobRemainingPasses -= 1
            enqueuePass(first: false, program: p)
            return
        }
        if !jobFooterQueued {
            jobFooterQueued = true
            let footer = jobSettings.footer.split(whereSeparator: \.isNewline).map { GrblParser.cleanLine(String($0)) }.filter { !$0.isEmpty }
            if !footer.isEmpty {
                jobQueue = footer
                jobTotalCommands += footer.count
                return
            }
        }
        finishJob(aborted: false)
    }

    private func finishJob(aborted: Bool) {
        guard jobRunning else { return }
        jobRunning = false
        jobQueue.removeAll()
        let secs = jobStart.map { Date().timeIntervalSince($0) } ?? 0
        let text = aborted
            ? L("Job stopped after %@", GCodeProgram.formatDuration(secs))
            : L("Job finished: %d lines, %d errors, %@", jobExecuted, jobErrors, GCodeProgram.formatDuration(secs))
        log(text, aborted ? .error : .info)
        onEvent?(.jobFinished(aborted: aborted, errors: jobErrors, seconds: secs, name: program?.name ?? ""))
    }

    /// Stops the job: removes queued lines, holds the machine and resets Grbl so the laser turns off.
    public func abortJob() {
        guard jobRunning else { return }
        jobQueue.removeAll()
        finishJob(aborted: true)
        sendRealtime(0x21)    // feed hold: stop moving
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.softReset()
        }
    }

    // MARK: realtime controls

    public func feedHold() { holdByUser = true; sendRealtime(0x21) }
    public func resume() { holdByUser = false; sendRealtime(0x7E) }
    public func safetyDoor() { sendRealtime(0x84) }

    public func softReset() {
        manualQueue.removeAll(); jobQueue.removeAll(); pending.removeAll(); usedBuffer = 0
        if jobRunning { finishJob(aborted: true) }
        overrideFeed = 100; overrideRapid = 100; overrideSpindle = 100
        targetFeed = 100; targetRapid = 100; targetSpindle = 100
        sendRealtime(0x18)
    }

    public func home() { send("$H") }
    public func unlock() { send("$X") }
    public func setZeroHere() { send("G92 X0 Y0") }
    public func refreshSettings() { send("$$") }
    public func requestInfo() { send("$I") }

    // MARK: jogging

    public func jog(_ dir: JogDirection, step: Double, feed: Double) {
        guard isConnected, state == .idle || state == .jog else { return }
        let s = String(format: "%.1f", step)
        var axes = ""
        switch dir {
        case .n: axes = "Y\(s)"
        case .ne: axes = "X\(s)Y\(s)"
        case .e: axes = "X\(s)"
        case .se: axes = "X\(s)Y-\(s)"
        case .s: axes = "Y-\(s)"
        case .sw: axes = "X-\(s)Y-\(s)"
        case .w: axes = "X-\(s)"
        case .nw: axes = "X-\(s)Y\(s)"
        case .zUp: axes = "Z\(s)"
        case .zDown: axes = "Z-\(s)"
        case .home:
            send(supportsTrueJogging ? "$J=G90X0Y0F\(Int(feed))" : "G90 G0 X0 Y0")
            return
        }
        if supportsTrueJogging {
            send("$J=G91\(axes)F\(Int(feed))")
        } else {
            send("G91 G1 \(axes) F\(Int(feed))")
            send("G90")
        }
    }

    public func jogTo(x: Double, y: Double, feed: Double) {
        guard isConnected, state == .idle || state == .jog else { return }
        if supportsTrueJogging {
            send(String(format: "$J=G90X%.2fY%.2fF%d", x, y, Int(feed)))
        } else {
            send(String(format: "G90 G1 X%.2f Y%.2f F%d", x, y, Int(feed)))
        }
    }

    public func cancelJog() { sendRealtime(0x85) }

    // MARK: overrides

    public func setOverrides(feed: Int? = nil, rapid: Int? = nil, spindle: Int? = nil) {
        if let f = feed { targetFeed = min(200, max(10, f)) }
        if let r = rapid { targetRapid = r }
        if let s = spindle { targetSpindle = min(200, max(10, s)) }
        manageOverrides()
    }

    public var targetOverrides: (feed: Int, rapid: Int, spindle: Int) { (targetFeed, targetRapid, targetSpindle) }

    /// Steps the real override toward the requested one with Grbl's coarse (±10%) and fine (±1%) real-time commands.
    func manageOverrides() {
        if targetFeed == 100 && overrideFeed != 100 { sendRealtime(0x90, quiet: true) }
        else if targetFeed - overrideFeed >= 10 { sendRealtime(0x91, quiet: true) }
        else if overrideFeed - targetFeed >= 10 { sendRealtime(0x92, quiet: true) }
        else if targetFeed - overrideFeed >= 1 { sendRealtime(0x93, quiet: true) }
        else if overrideFeed - targetFeed >= 1 { sendRealtime(0x94, quiet: true) }

        if targetSpindle == 100 && overrideSpindle != 100 { sendRealtime(0x99, quiet: true) }
        else if targetSpindle - overrideSpindle >= 10 { sendRealtime(0x9A, quiet: true) }
        else if overrideSpindle - targetSpindle >= 10 { sendRealtime(0x9B, quiet: true) }
        else if targetSpindle - overrideSpindle >= 1 { sendRealtime(0x9C, quiet: true) }
        else if overrideSpindle - targetSpindle >= 1 { sendRealtime(0x9D, quiet: true) }

        if targetRapid == 100 && overrideRapid != 100 { sendRealtime(0x95, quiet: true) }
        else if targetRapid == 50 && overrideRapid != 50 { sendRealtime(0x96, quiet: true) }
        else if targetRapid == 25 && overrideRapid != 25 { sendRealtime(0x97, quiet: true) }
    }

    // MARK: laser helpers

    /// Draws the bounding box of the loaded job with the laser off (or at low power) to position the work.
    public func frameCommands(power: Int = 0, feed: Int = 2000) -> [String]? {
        guard let p = program, !p.burnBounds.isEmpty || !p.travelBounds.isEmpty else { return nil }
        let b = p.burnBounds.isEmpty ? p.travelBounds : p.burnBounds
        func f(_ v: Double) -> String { String(format: "%.3f", v) }
        var out = ["G90", "G0 X\(f(b.minX)) Y\(f(b.minY))"]
        if power > 0 { out.append("M3 S\(power)") }
        out += ["G1 X\(f(b.maxX)) Y\(f(b.minY)) F\(feed)", "G1 X\(f(b.maxX)) Y\(f(b.maxY))",
                "G1 X\(f(b.minX)) Y\(f(b.maxY))", "G1 X\(f(b.minX)) Y\(f(b.minY))"]
        if power > 0 { out.append("M5") }
        return out
    }

    public func runFrame(power: Int = 0, feed: Int = 2000) {
        guard isConnected, state == .idle, let cmds = frameCommands(power: power, feed: feed) else { return }
        cmds.forEach { send($0) }
    }

    /// Lets a laser fire at low power for aiming. Turned off with `laserOff()`.
    public func laserOn(power: Int) { send("M3 S\(power)") }
    public func laserOff() { send("M5 S0") }

    // MARK: log

    public func clearConsole() { console.removeAll() }

    private func log(_ text: String, _ kind: ConsoleLine.Kind) {
        logCounter += 1
        console.append(ConsoleLine(id: logCounter, text: text, kind: kind, date: Date()))
        if console.count > 3000 { console.removeFirst(console.count - 2500) }
    }
}
