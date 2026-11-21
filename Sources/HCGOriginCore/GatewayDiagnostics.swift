import Foundation
import HCGOriginProtocol
import HCGHTTP
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A process that holds a listening socket on a port.
public struct PortOwner: Equatable, Sendable, Codable {
    public var pid: Int32
    public var command: String
    public var executablePath: String?
    public var address: String
    /// True when the process is a copy of HCG Origin (any path).
    public var isHCGOrigin: Bool
    public var isThisProcess: Bool
}

public enum PortOwnerLookup {
    /// Who listens on TCP `port` (uses `lsof`, read-only). Empty when unknown or when lsof is unavailable.
    public static func owners(port: UInt16) -> [PortOwner] {
        let candidates = ["/usr/sbin/lsof", "/usr/bin/lsof", "/bin/lsof"]
        guard let lsof = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: lsof)
        p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpcn"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Parses `lsof -F pcn` output.
    static func parse(_ text: String) -> [PortOwner] {
        var result: [PortOwner] = []
        var pid: Int32?
        var command = ""
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value); command = ""
            case "c": command = value
            case "n":
                guard let pid else { continue }
                let path = executablePath(pid: pid)
                let isOrigin = path?.hasSuffix("/Contents/MacOS/HCGOrigin") == true || command == "HCGOrigin"
                if !result.contains(where: { $0.pid == pid }) {
                    result.append(PortOwner(pid: pid, command: command, executablePath: path, address: value,
                                            isHCGOrigin: isOrigin, isThisProcess: pid == getpid()))
                }
            default: break
            }
        }
        return result
    }

    static func executablePath(pid: Int32) -> String? {
        #if os(macOS)
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
        #else
        return try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe")
        #endif
    }

    /// True when 127.0.0.1:`port` can be bound right now (probe; the socket is closed immediately).
    public static func isFreeOnLoopback(_ port: UInt16) -> Bool {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return r == 0
    }
}

/// Exclusive lock on the data folder: exactly one Origin process may run a gateway for it.
/// Released automatically if the process exits or crashes (flock semantics).
public final class GatewayLock: @unchecked Sendable {
    public let url: URL
    private let fd: Int32

    public struct Held: Error, CustomStringConvertible, Equatable {
        public var pid: Int32?
        public var path: String?
        public var description: String {
            "Another HCG Origin is already running the gateway for this data folder"
                + (pid.map { " (process \($0)\(path.map { ", \($0)" } ?? ""))" } ?? "")
                + ". Only one copy can run at a time: switch to that copy, or quit it and reopen this one."
        }
    }

    private init(url: URL, fd: Int32) { self.url = url; self.fd = fd }

    public static func acquire(directory: URL) throws -> GatewayLock {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("gateway.lock")
        let fd = open(url.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw Held(pid: nil, path: nil) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let other = (try? String(contentsOf: url, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            close(fd)
            throw Held(pid: other, path: other.flatMap { PortOwnerLookup.executablePath(pid: $0) })
        }
        _ = ftruncate(fd, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        return GatewayLock(url: url, fd: fd)
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

/// Why the listener is not running, with what the owner can do about it.
public struct ListenerFailure: Equatable, Sendable {
    public enum Kind: String, Sendable { case portInUse = "port_in_use", tlsIdentity = "tls_identity", encryptionRequired = "encryption_required", notReady = "not_ready", other }
    public var kind: Kind
    public var message: String
    public var port: UInt16
    public var owners: [PortOwner]
    public var at: Date
    public var attempts: Int
    public var nextRetryAt: Date?

    public var otherOriginOwnsPort: Bool { owners.contains { $0.isHCGOrigin && !$0.isThisProcess } }

    public var summary: String {
        switch kind {
        case .portInUse:
            if let o = owners.first(where: { !$0.isThisProcess }) {
                let who = o.isHCGOrigin ? "another copy of HCG Origin" : "“\(o.command)”"
                return "Port \(port) is already used by \(who) (process \(o.pid)\(o.executablePath.map { ", \($0)" } ?? ""))."
            }
            return "Port \(port) is already in use by another program (the owner could not be identified)."
        case .tlsIdentity: return "The gateway's TLS certificate could not be prepared: \(message)"
        case .encryptionRequired: return message
        case .notReady: return "The listener did not become ready: \(message)"
        case .other: return message
        }
    }
}

public struct SelfTestResult: Equatable, Sendable {
    public var passed: Bool
    public var detail: String
    public var at: Date
    public var encrypted: Bool
}

enum GatewaySelfTest {
    /// Sends a real request to the gateway's own listener (pinned TLS when encrypted) and verifies the signed answer.
    static func run(port: UInt16, transport: TransportSecurity, gatewayFingerprint: String) async -> SelfTestResult {
        let nonce = SignedEnvelope.newNonce()
        let scheme = transport.isEncrypted ? "https" : "http"
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)\(OriginPath.heartbeat)") else {
            return SelfTestResult(passed: false, detail: "bad self-test URL", at: Date(), encrypted: transport.isEncrypted)
        }
        let client = HTTPClient(timeout: 5, pinnedTLSFingerprint: transport.tlsFingerprint)
        do {
            let r = try await client.send(method: "POST", url: url,
                                          headers: [OriginHeader.protocolVersion: OriginProtocol.version, OriginHeader.nonce: nonce],
                                          body: Data("{}".utf8))
            guard r.status == 401,
                  let keyText = r.headers[OriginHeader.publicKey], let key = Encoding.fromBase64url(keyText),
                  SignedEnvelope.verifyResponse(status: r.status, headers: r.headers, body: r.body, expectedRequestNonce: nonce,
                                                pinnedFingerprint: gatewayFingerprint, publicKeyDER: key) else {
                return SelfTestResult(passed: false, detail: "The listener answered, but not with a valid signed refusal (HTTP \(r.status)).",
                                      at: Date(), encrypted: transport.isEncrypted)
            }
            let how = transport.tlsFingerprint.map { "TLS 1.3 to the pinned key \(KeyFingerprint.short($0))" } ?? "cleartext loopback (development)"
            return SelfTestResult(passed: true, detail: "127.0.0.1:\(port) answered over \(how); the unsigned probe was refused with a correctly signed response.",
                                  at: Date(), encrypted: transport.isEncrypted)
        } catch {
            return SelfTestResult(passed: false, detail: "Could not reach the gateway's own listener: \(error)", at: Date(), encrypted: transport.isEncrypted)
        }
    }
}
