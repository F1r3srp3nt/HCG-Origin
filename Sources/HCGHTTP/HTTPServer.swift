import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header names are lowercased.
    public var headers: [String: String]
    public var body: Data
    public var remoteAddress: String

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:],
                body: Data = Data(), remoteAddress: String = "") {
        self.method = method; self.path = path; self.query = query; self.headers = headers
        self.body = body; self.remoteAddress = remoteAddress
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }

    public static func json(_ status: Int, _ body: Data, headers: [String: String] = [:]) -> HTTPResponse {
        var h = headers
        h["content-type"] = "application/json; charset=utf-8"
        return HTTPResponse(status: status, headers: h, body: body)
    }

    public static func text(_ status: Int, _ text: String, contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, headers: ["content-type": contentType], body: Data(text.utf8))
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 410: return "Gone"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

public enum HTTPServerError: Error, CustomStringConvertible, Equatable {
    case socket(String)
    case bind(host: String, port: UInt16, errno: Int32)
    case invalidHost(String)
    /// The port is already bound by another socket (another program, or another copy of Origin).
    case addressInUse(port: UInt16)
    /// The listener did not become ready in time; `detail` is the last state the system reported.
    case notReady(String)

    public var description: String {
        switch self {
        case .socket(let s): return "Could not open a listening socket: \(s)"
        case .bind(let host, let port, let e):
            let detail = String(cString: strerror(e))
            if e == EADDRINUSE { return "Port \(port) on \(host) is already in use by another program." }
            return "Could not listen on \(host):\(port): \(detail)"
        case .invalidHost(let h): return "Invalid listening address \(h)"
        case .addressInUse(let port): return "Port \(port) is already in use by another program."
        case .notReady(let d): return "The listener did not become ready: \(d)"
        }
    }
}

/// A deliberately small HTTP/1.1 server: one request per connection, bounded
/// header and body sizes, read timeouts. Portable across macOS and Linux so the
/// gateway, the development service and their tests share one implementation.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    public let host: String
    public private(set) var port: UInt16
    public var maxBodyBytes = 256 * 1024
    public var maxHeaderBytes = 16 * 1024
    public var readTimeoutSeconds = 10
    /// Connections served at the same time; further connections are closed immediately.
    public var maxConcurrentConnections = 64
    private var activeConnections = 0

    private let handler: Handler
    private var listenFD: Int32 = -1
    private let lock = NSLock()
    private var running = false
    private var acceptThread: Thread?

    public init(host: String, port: UInt16, handler: @escaping Handler) {
        self.host = host
        self.port = port
        self.handler = handler
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// Starts listening. Returns the bound port (useful with port 0).
    @discardableResult
    public func start() throws -> UInt16 {
        signal(SIGPIPE, SIG_IGN)
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw HTTPServerError.socket(String(cString: strerror(errno))) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            close(fd)
            throw HTTPServerError.invalidHost(host)
        }
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let e = errno
            close(fd)
            if e == EADDRINUSE { throw HTTPServerError.addressInUse(port: port) }
            throw HTTPServerError.bind(host: host, port: port, errno: e)
        }
        guard listen(fd, 64) == 0 else {
            let e = errno
            close(fd)
            throw HTTPServerError.bind(host: host, port: port, errno: e)
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let actualPort = UInt16(bigEndian: bound.sin_port)

        lock.lock()
        listenFD = fd
        port = actualPort
        running = true
        lock.unlock()

        let thread = Thread { [weak self] in self?.acceptLoop(fd: fd) }
        thread.name = "hcg-http-accept-\(actualPort)"
        acceptThread = thread
        thread.start()
        return actualPort
    }

    public func stop() {
        lock.lock()
        let fd = listenFD
        running = false
        listenFD = -1
        lock.unlock()
        if fd >= 0 {
            shutdown(fd, Int32(SHUT_RDWR))
            close(fd)
        }
    }

    deinit { stop() }

    private func acceptLoop(fd: Int32) {
        while isRunning {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 250)
            if ready <= 0 { continue }
            var remote = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &remote) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) }
            }
            if client < 0 { continue }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var inAddr = remote.sin_addr
            inet_ntop(AF_INET, &inAddr, &buf, socklen_t(INET_ADDRSTRLEN))
            let remoteAddress = String(cString: buf)
            lock.lock()
            let admitted = activeConnections < maxConcurrentConnections
            if admitted { activeConnections += 1 }
            lock.unlock()
            guard admitted else { close(client); continue }
            let t = Thread { [weak self] in
                self?.serve(client: client, remoteAddress: remoteAddress)
                self?.connectionFinished()
            }
            t.start()
        }
    }

    private func connectionFinished() {
        lock.lock(); activeConnections -= 1; lock.unlock()
    }

    private func serve(client: Int32, remoteAddress: String) {
        defer { close(client) }
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var tv = timeval(tv_sec: readTimeoutSeconds, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let response: HTTPResponse
        switch readRequest(client: client, remoteAddress: remoteAddress) {
        case .success(let request):
            let box = ResponseBox()
            let sem = DispatchSemaphore(value: 0)
            let handler = self.handler
            Task.detached {
                box.value = await handler(request)
                sem.signal()
            }
            sem.wait()
            response = box.value ?? HTTPResponse(status: 500)
        case .failure(let failure):
            response = HTTPWire.errorResponse(status: failure.status, message: failure.message)
        }
        write(response: response, to: client)
    }

    private final class ResponseBox: @unchecked Sendable { var value: HTTPResponse? }

    private struct ReadFailure: Error { var status: Int; var message: String }

    private func readRequest(client: Int32, remoteAddress: String) -> Result<HTTPRequest, ReadFailure> {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            switch HTTPWire.parse(data, maxHeaderBytes: maxHeaderBytes, maxBodyBytes: maxBodyBytes) {
            case .complete(var request):
                request.remoteAddress = remoteAddress
                return .success(request)
            case .failure(let status, let message):
                return .failure(ReadFailure(status: status, message: message))
            case .needMore:
                let n = recv(client, &chunk, chunk.count, 0)
                if n <= 0 { return .failure(ReadFailure(status: 400, message: "incomplete request")) }
                data.append(contentsOf: chunk[0..<n])
            }
        }
    }

    private func write(response: HTTPResponse, to client: Int32) {
        let out = HTTPWire.serialize(response)
        out.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                #if canImport(Darwin)
                let n = send(client, base + sent, raw.count - sent, 0)
                #else
                let n = send(client, base + sent, raw.count - sent, Int32(MSG_NOSIGNAL))
                #endif
                if n <= 0 { break }
                sent += n
            }
        }
    }
}
