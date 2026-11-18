import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum HTTPClientError: Error, CustomStringConvertible, Equatable {
    case unreachable(String)
    case invalidResponse
    case insecureURL(String)

    public var description: String {
        switch self {
        case .unreachable(let d): return "Not reachable: \(d)"
        case .invalidResponse: return "The server sent an invalid response."
        case .insecureURL(let u): return "Refusing to use a non-HTTPS address outside this computer: \(u)"
        }
    }
}

public struct HTTPClientResponse: Sendable {
    public var status: Int
    /// Header names are lowercased.
    public var headers: [String: String]
    public var body: Data
}

/// Minimal async HTTP client. Uses an ephemeral session (no cookies, no cache,
/// no credential storage) and never follows redirects.
public final class HTTPClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private var session: URLSession!
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 10) {
        self.timeout = timeout
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// True for http(s) URLs on this computer (127.0.0.1, ::1, localhost).
    public static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }

    /// Production traffic must use HTTPS; plain HTTP is allowed only to this computer
    /// or, when `allowPrivateNetworkHTTP`, to a private-network peer (Connector → Origin on LAN).
    public static func checkTransport(_ url: URL, allowPrivateNetworkHTTP: Bool = false) throws {
        if url.scheme == "https" { return }
        if url.scheme == "http" && (isLoopback(url) || (allowPrivateNetworkHTTP && isPrivateNetwork(url))) { return }
        throw HTTPClientError.insecureURL(url.absoluteString)
    }

    public static func isPrivateNetwork(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return host.hasSuffix(".local") }
        switch (parts[0], parts[1]) {
        case (10, _), (192, 168), (127, _): return true
        case (172, let b) where (16...31).contains(b): return true
        case (169, 254): return true
        default: return false
        }
    }

    public func send(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) async throws -> HTTPClientResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if let body {
            request.httpBody = body
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        let session = self.session!
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: HTTPClientError.unreachable(Self.describe(error)))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: HTTPClientError.invalidResponse)
                    return
                }
                var h: [String: String] = [:]
                for (k, v) in http.allHeaderFields {
                    if let ks = k as? String, let vs = v as? String { h[ks.lowercased()] = vs }
                }
                continuation.resume(returning: HTTPClientResponse(status: http.statusCode, headers: h, body: data ?? Data()))
            }
            task.resume()
        }
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCannotConnectToHost: return "connection refused"
            case NSURLErrorTimedOut: return "timed out"
            case NSURLErrorNotConnectedToInternet: return "no network connection"
            case NSURLErrorCannotFindHost: return "host not found"
            case NSURLErrorNetworkConnectionLost: return "connection lost"
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted: return "secure connection failed"
            case NSURLErrorAppTransportSecurityRequiresSecureConnection: return "blocked by App Transport Security (HTTPS required)"
            default: break
            }
        }
        return ns.localizedDescription
    }

    // Never follow redirects: a redirect could move signed requests or tokens elsewhere.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
