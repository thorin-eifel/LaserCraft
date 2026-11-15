import Foundation
import Network

/// What the controller needs from a connection: bytes in, bytes out, and a notice when it closes.
public protocol Transport: AnyObject {
    var onData: ((Data) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    var isOpen: Bool { get }
    func write(_ data: Data) throws
    func close()
}

extension Transport {
    public func write(_ string: String) throws { try write(Data(string.utf8)) }
    public func write(byte: UInt8) throws { try write(Data([byte])) }
}

extension SerialPort: Transport {}

public enum NetworkKind: String, Codable, CaseIterable {
    /// Plain TCP stream (Grbl bridges, serial-to-WiFi adapters).
    case tcp
    /// Telnet stream (FluidNC, Grbl_ESP32 on port 23): like TCP, but negotiation bytes are filtered out.
    case telnet
    /// WebSocket (ESP8266 add-ons such as Ortur WiFi, FluidNC on /ws).
    case webSocket

    public var scheme: String {
        switch self { case .tcp: return "tcp"; case .telnet: return "telnet"; case .webSocket: return "ws" }
    }
    public var defaultPort: Int {
        switch self { case .tcp: return 23; case .telnet: return 23; case .webSocket: return 81 }
    }
}

/// An address like `telnet://192.168.1.50`, `tcp://host:8080` or `ws://192.168.1.50:81`.
public struct NetworkAddress: Equatable, Hashable, Codable {
    public var kind: NetworkKind
    public var host: String
    public var port: Int
    public init(kind: NetworkKind, host: String, port: Int? = nil) {
        self.kind = kind; self.host = host; self.port = port ?? kind.defaultPort
    }

    public static func parse(_ s: String) -> NetworkAddress? {
        guard let r = s.range(of: "://") else { return nil }
        let scheme = s[s.startIndex..<r.lowerBound].lowercased()
        let rest = String(s[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !rest.isEmpty else { return nil }
        let kind: NetworkKind
        switch scheme {
        case "tcp": kind = .tcp
        case "telnet": kind = .telnet
        case "ws", "wss": kind = .webSocket
        default: return nil
        }
        // host[:port] (IPv6 in brackets is not needed for laser controllers)
        let pieces = rest.split(separator: ":", maxSplits: 1).map(String.init)
        guard let host = pieces.first, !host.isEmpty else { return nil }
        var port: Int? = nil
        if pieces.count > 1 { guard let p = Int(pieces[1]), p > 0, p < 65536 else { return nil }; port = p }
        return NetworkAddress(kind: kind, host: host, port: port)
    }

    public var url: String { "\(kind.scheme)://\(host):\(port)" }
    public static func isNetwork(_ path: String) -> Bool { parse(path) != nil }
}

public enum NetworkError: Error, LocalizedError {
    case notOpen
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .notOpen: return "The connection is not open"
        case .failed(let m): return m
        }
    }
}

/// A TCP, Telnet or WebSocket connection to a controller (Network.framework). Callbacks arrive on the main queue.
public final class NetworkPort: Transport {
    public let address: NetworkAddress
    public var onData: ((Data) -> Void)?
    public var onClose: (() -> Void)?
    /// Called once when the connection is up.
    public var onReady: (() -> Void)?
    /// Called once when the connection could not be made (before it was ready).
    public var onFail: ((String) -> Void)?

    private var connection: NWConnection?
    private var ready = false
    private var closed = false
    private var iac = 0                         // telnet negotiation state: 0 none, 1 after IAC, 2 after IAC+verb

    public init(address: NetworkAddress) { self.address = address }
    deinit { connection?.cancel() }

    public var isOpen: Bool { ready && !closed }

    public func open() {
        let params: NWParameters
        if address.kind == .webSocket {
            params = .tcp
            let ws = NWProtocolWebSocket.Options()
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        } else {
            params = .tcp
            if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options { tcp.noDelay = true }
        }
        guard let port = NWEndpoint.Port(rawValue: UInt16(address.port)) else { onFail?("Invalid port"); return }
        let c = NWConnection(host: NWEndpoint.Host(address.host), port: port, using: params)
        connection = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self = self, !self.closed else { return }
            switch state {
            case .ready:
                self.ready = true
                self.receiveLoop()
                self.onReady?()
            case .waiting(let e), .failed(let e):
                self.handleEnd(e.localizedDescription)
            case .cancelled:
                break
            default: break
            }
        }
        c.start(queue: .main)
    }

    private func handleEnd(_ message: String) {
        guard !closed else { return }
        let wasReady = ready
        closed = true; ready = false
        connection?.cancel()
        if wasReady { onClose?() } else { onFail?(message) }
    }

    private func receiveLoop() {
        guard let c = connection else { return }
        let handle: (Data?, Bool, NWError?) -> Void = { [weak self] data, complete, error in
            guard let self = self, !self.closed else { return }
            if let d = data, !d.isEmpty {
                let out = self.address.kind == .telnet ? self.stripTelnet(d) : d
                if !out.isEmpty { self.onData?(out) }
            }
            if let e = error { self.handleEnd(e.localizedDescription); return }
            if complete && (data == nil || data!.isEmpty) && self.address.kind != .webSocket { self.handleEnd("Connection closed"); return }
            self.receiveLoop()
        }
        if address.kind == .webSocket {
            c.receiveMessage { data, _, complete, error in handle(data, complete, error) }
        } else {
            c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in handle(data, complete, error) }
        }
    }

    /// Removes Telnet negotiation (IAC verb option) from the stream.
    func stripTelnet(_ d: Data) -> Data {
        var out = Data()
        for b in d {
            switch iac {
            case 0: if b == 0xFF { iac = 1 } else { out.append(b) }
            case 1:
                if b == 0xFF { out.append(0xFF); iac = 0 }
                else if b >= 0xFB && b <= 0xFE { iac = 2 }
                else { iac = 0 }                          // two-byte commands (NOP, …)
            default: iac = 0                              // the option byte
            }
        }
        return out
    }

    public func write(_ data: Data) throws {
        guard isOpen, let c = connection else { throw NetworkError.notOpen }
        if address.kind == .webSocket {
            let meta = NWProtocolWebSocket.Metadata(opcode: .text)
            let ctx = NWConnection.ContentContext(identifier: "grbl", metadata: [meta])
            c.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
        } else {
            c.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    public func close() {
        closed = true; ready = false
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }
}

/// Finds laser controllers on the local network with Bonjour (FluidNC and Grbl_ESP32 announce a Telnet service).
public final class NetworkDiscovery {
    public struct Found: Equatable, Hashable { public var name: String; public var address: NetworkAddress }
    private var browsers: [NWBrowser] = []
    public private(set) var found: [Found] = []
    public var onChange: (([Found]) -> Void)?

    public init() {}

    public func start() {
        stop()
        for (type, kind) in [("_telnet._tcp", NetworkKind.telnet), ("_ws._tcp", NetworkKind.webSocket)] {
            let b = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
            b.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self = self else { return }
                var list = self.found.filter { $0.address.kind != kind }
                for r in results {
                    if case let .service(name, _, _, _) = r.endpoint {
                        // resolve through the service name: Network.framework connects to .local names directly
                        list.append(Found(name: name, address: NetworkAddress(kind: kind, host: "\(name).local")))
                    }
                }
                self.found = list.sorted { $0.name < $1.name }
                self.onChange?(self.found)
            }
            b.start(queue: .main)
            browsers.append(b)
        }
    }

    public func stop() { browsers.forEach { $0.cancel() }; browsers = [] }
}
