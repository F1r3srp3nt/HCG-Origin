import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif

public enum HTTPClientError: Error, CustomStringConvertible, Equatable {
    case unreachable(String)
    case invalidResponse
    case insecureURL(String)
    case tlsPinMismatch(String)
    case tlsPinningUnsupported

    public var description: String {
        switch self {
        case .unreachable(let d): return "Not reachable: \(d)"
        case .invalidResponse: return "The server sent an invalid response."
        case .insecureURL(let u): return "Refusing to use a non-HTTPS address outside this computer: \(u)"
        case .tlsPinMismatch(let d): return "The gateway's TLS certificate does not match the pinned fingerprint (\(d)). Connection refused."
        case .tlsPinningUnsupported: return "Pinned TLS is not available on this platform; refusing to connect without it."
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
    /// When set, HTTPS connections succeed only if the server's leaf certificate carries a
    /// P-256 key whose SubjectPublicKeyInfo SHA-256 equals this value. There is no fallback.
    public let pinnedTLSFingerprint: String?
    private let pinLock = NSLock()
    private var lastPinFailure: String?

    public init(timeout: TimeInterval = 10, pinnedTLSFingerprint: String? = nil) {
        self.timeout = timeout
        self.pinnedTLSFingerprint = pinnedTLSFingerprint?.lowercased()
        super.init()
        let config = URLSessionConfiguration.ephemeral
        #if canImport(Security)
        config.tlsMinimumSupportedProtocolVersion = .TLSv13
        #endif
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

    /// HTTPS everywhere; plain HTTP only to this computer (the local development service and the
    /// Linux development harness). There is no cleartext path to another machine.
    public static func checkTransport(_ url: URL) throws {
        if url.scheme == "https" { return }
        if url.scheme == "http" && isLoopback(url) { return }
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
        if pinnedTLSFingerprint != nil {
            #if !canImport(Security)
            throw HTTPClientError.tlsPinningUnsupported
            #endif
            guard url.scheme == "https" else { throw HTTPClientError.insecureURL(url.absoluteString) }
        }
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
                    if let pin = self.takePinFailure() {
                        continuation.resume(throwing: HTTPClientError.tlsPinMismatch(pin))
                    } else {
                        continuation.resume(throwing: HTTPClientError.unreachable(Self.describe(error)))
                    }
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

    private func takePinFailure() -> String? {
        pinLock.lock(); defer { pinLock.unlock() }
        let f = lastPinFailure
        lastPinFailure = nil
        return f
    }

    #if canImport(Security)
    /// DER prefix of a P-256 SubjectPublicKeyInfo (id-ecPublicKey, prime256v1), followed by the 65-byte point.
    static let p256SPKIPrefix = Data([0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
                                      0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00])

    /// SHA-256 (hex) of the leaf certificate's P-256 SubjectPublicKeyInfo, or nil if it is not a P-256 key.
    public static func leafFingerprint(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              let key = SecCertificateCopyKey(leaf),
              let attrs = SecKeyCopyAttributes(key) as? [String: Any],
              (attrs[kSecAttrKeyType as String] as? String) == (kSecAttrKeyTypeECSECPrimeRandom as String),
              (attrs[kSecAttrKeySizeInBits as String] as? Int) == 256,
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?, raw.count == 65, raw.first == 0x04 else { return nil }
        let spki = p256SPKIPrefix + raw
        return SHA256.hash(data: spki).map { String(format: "%02x", $0) }.joined()
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let pin = pinnedTLSFingerprint else {
            // Not pinned: normal system trust evaluation (e.g. HTTPS to central HCG).
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let observed = Self.leafFingerprint(trust)
        if let observed, observed == pin {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            pinLock.lock()
            lastPinFailure = "expected \(pin.prefix(16))…, server presented \(observed.map { String($0.prefix(16)) + "…" } ?? "a non-P-256 key")"
            pinLock.unlock()
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
    #endif

    // Never follow redirects: a redirect could move signed requests or tokens elsewhere.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
