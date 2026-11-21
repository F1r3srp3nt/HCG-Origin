#if canImport(Network) && canImport(Security)
import Foundation
import Network
import Security

/// HTTP/1.1 over TLS 1.3 (Network.framework). The server presents the gateway's
/// self-signed transport certificate; Connectors authenticate it by pinning the
/// SHA-256 of its public key, which they receive in the pairing invitation.
/// TLS 1.2 and earlier are refused. No client certificate is required: every request
/// is additionally signed with the device key (hcg-origin/2).
public final class TLSHTTPServer: ConnectorServer, @unchecked Sendable {
    public let loopbackOnly: Bool
    public private(set) var port: UInt16
    public var maxBodyBytes = 256 * 1024
    public var maxHeaderBytes = 16 * 1024
    public var readTimeoutSeconds = 10
    public var maxConcurrentConnections = 64
    /// Diagnostics: called (on a background queue) when a connection fails, e.g. a TLS handshake error.
    public var onConnectionFailure: (@Sendable (_ remote: String, _ reason: String) -> Void)?

    private let identity: SecIdentity
    private let handler: HTTPServer.Handler
    private let queue = DispatchQueue(label: "hcg.origin.tls-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var active = 0

    public init(identity: SecIdentity, port: UInt16, loopbackOnly: Bool, handler: @escaping HTTPServer.Handler) {
        self.identity = identity
        self.port = port
        self.loopbackOnly = loopbackOnly
        self.handler = handler
    }

    private final class StartBox: @unchecked Sendable {
        let lock = NSLock()
        var error: String?
        var done = false
    }

    @discardableResult
    public func start() throws -> UInt16 {
        let tls = NWProtocolTLS.Options()
        let sp = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sp, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(sp, .TLSv13)
        guard let secIdentity = sec_identity_create(identity) else {
            throw HTTPServerError.socket("the transport certificate cannot be used for TLS")
        }
        sec_protocol_options_set_local_identity(sp, secIdentity)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = readTimeoutSeconds
        let params = NWParameters(tls: tls, tcp: tcp)
        params.allowLocalEndpointReuse = true
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        if loopbackOnly { params.requiredInterfaceType = .loopback }
        let nwPort: NWEndpoint.Port = port == 0 ? .any : (NWEndpoint.Port(rawValue: port) ?? .any)
        let l: NWListener
        do { l = try NWListener(using: params, on: nwPort) }
        catch { throw HTTPServerError.socket("\(error)") }

        let box = StartBox()
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { state in
            box.lock.lock(); defer { box.lock.unlock() }
            switch state {
            case .ready:
                if !box.done { box.done = true; ready.signal() }
            case .failed(let e), .waiting(let e):
                if !box.done { box.error = Self.describe(e); box.done = true; ready.signal() }
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut {
            l.cancel()
            throw HTTPServerError.socket("the TLS listener did not start within 5 s")
        }
        box.lock.lock(); let failure = box.error; box.lock.unlock()
        if let failure {
            l.cancel()
            throw HTTPServerError.socket(failure)
        }
        lock.lock()
        listener = l
        port = l.port?.rawValue ?? port
        lock.unlock()
        return port
    }

    static func describe(_ e: NWError) -> String {
        if case .posix(let code) = e, code == .EADDRINUSE { return "the port is already in use by another program" }
        return "\(e)"
    }

    public func stop() {
        lock.lock()
        let l = listener
        listener = nil
        lock.unlock()
        l?.cancel()
    }

    deinit { listener?.cancel() }

    private func accept(_ c: NWConnection) {
        lock.lock()
        let admitted = active < maxConcurrentConnections
        if admitted { active += 1 }
        lock.unlock()
        guard admitted else { c.cancel(); return }

        let remote = Self.remoteAddress(c.endpoint)
        let finished = FinishOnce { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.active -= 1; self.lock.unlock()
        }
        let report = onConnectionFailure
        c.stateUpdateHandler = { state in
            switch state {
            case .failed(let e):
                report?(remote, "\(e)")
                c.cancel()
            case .waiting(let e):
                report?(remote, "waiting: \(e)")
                c.cancel()
            case .cancelled: finished.run()
            default: break
            }
        }
        c.start(queue: queue)
        queue.asyncAfter(deadline: .now() + .seconds(readTimeoutSeconds + 20)) { c.cancel() }
        receive(c, buffer: Data(), remote: remote)
    }

    private final class FinishOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        func run() {
            lock.lock(); let first = !done; done = true; lock.unlock()
            if first { action() }
        }
    }

    private func receive(_ c: NWConnection, buffer: Data, remote: String) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { c.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            switch HTTPWire.parse(buf, maxHeaderBytes: self.maxHeaderBytes, maxBodyBytes: self.maxBodyBytes) {
            case .needMore:
                if isComplete || error != nil { c.cancel() } else { self.receive(c, buffer: buf, remote: remote) }
            case .failure(let status, let message):
                self.respond(c, HTTPWire.errorResponse(status: status, message: message))
            case .complete(var request):
                request.remoteAddress = remote
                let handler = self.handler
                Task.detached {
                    let response = await handler(request)
                    self.respond(c, response)
                }
            }
        }
    }

    private func respond(_ c: NWConnection, _ response: HTTPResponse) {
        c.send(content: HTTPWire.serialize(response), completion: .contentProcessed { _ in c.cancel() })
    }

    static func remoteAddress(_ endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "unknown" }
        let text: String
        switch host {
        case .ipv4(let a): text = "\(a)"
        case .ipv6(let a): text = "\(a)"
        case .name(let n, _): text = n
        @unknown default: text = "unknown"
        }
        // Strip an interface scope such as "%lo0".
        return text.split(separator: "%").first.map(String.init) ?? text
    }
}
#endif
