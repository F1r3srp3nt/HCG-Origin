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

public enum HTTPServerError: Error, CustomStringConvertible {
    case socket(String)
    case bind(host: String, port: UInt16, errno: Int32)
    case invalidHost(String)

    public var description: String {
        switch self {
        case .socket(let s): return "Could not open a listening socket: \(s)"
        case .bind(let host, let port, let e):
            let detail = String(cString: strerror(e))
            if e == EADDRINUSE { return "Port \(port) on \(host) is already in use by another program." }
            return "Could not listen on \(host):\(port): \(detail)"
        case .invalidHost(let h): return "Invalid listening address \(h)"
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
            let t = Thread { [weak self] in self?.serve(client: client, remoteAddress: remoteAddress) }
            t.start()
        }
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
            response = HTTPResponse.json(failure.status, Data("{\"error\":{\"code\":\"bad_request\",\"message\":\"\(failure.message)\"}}".utf8))
        }
        write(response: response, to: client)
    }

    private final class ResponseBox: @unchecked Sendable { var value: HTTPResponse? }

    private struct ReadFailure: Error { var status: Int; var message: String }

    private func readRequest(client: Int32, remoteAddress: String) -> Result<HTTPRequest, ReadFailure> {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        let separator = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let n = recv(client, &chunk, chunk.count, 0)
            if n <= 0 { return .failure(ReadFailure(status: 400, message: "incomplete request")) }
            data.append(contentsOf: chunk[0..<n])
            headerEnd = data.range(of: separator)
            if headerEnd == nil && data.count > maxHeaderBytes {
                return .failure(ReadFailure(status: 413, message: "headers too large"))
            }
        }
        guard let end = headerEnd,
              let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .failure(ReadFailure(status: 400, message: "malformed headers"))
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            return .failure(ReadFailure(status: 400, message: "malformed request line"))
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .failure(ReadFailure(status: 400, message: "malformed header")) }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil {
            return .failure(ReadFailure(status: 400, message: "transfer-encoding is not supported"))
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .failure(ReadFailure(status: 400, message: "bad content-length")) }
        guard length <= maxBodyBytes else { return .failure(ReadFailure(status: 413, message: "body too large")) }
        var body = Data(data[end.upperBound...])
        while body.count < length {
            let n = recv(client, &chunk, min(chunk.count, length - body.count), 0)
            if n <= 0 { return .failure(ReadFailure(status: 400, message: "incomplete body")) }
            body.append(contentsOf: chunk[0..<n])
        }
        if body.count > length { body = body.prefix(length) }

        let target = String(requestLine[1])
        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<q])
            for pair in target[target.index(after: q)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                let key = kv[0].removingPercentEncoding ?? kv[0]
                let value = kv.count > 1 ? (kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[1]) : ""
                query[key] = value
            }
        }
        return .success(HTTPRequest(method: String(requestLine[0]).uppercased(), path: path, query: query,
                                    headers: headers, body: body, remoteAddress: remoteAddress))
    }

    private func write(response: HTTPResponse, to client: Int32) {
        var head = "HTTP/1.1 \(response.status) \(HTTPResponse.reason(response.status))\r\n"
        var headers = response.headers
        headers["content-length"] = String(response.body.count)
        headers["connection"] = "close"
        headers["cache-control"] = headers["cache-control"] ?? "no-store"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(k): \(v.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: ""))\r\n"
        }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(response.body)
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
