import Foundation
import HCGOriginProtocol
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ListenerState: Equatable, Sendable {
    case stopped
    case listening(address: String, localNetwork: Bool)
    case failed(String)
}

public enum CentralReachability: Equatable, Sendable {
    case unknown
    case notConfigured([String])
    case reachable(service: String, at: Date)
    case unreachable(String, since: Date)
    case mismatch(String)
}

public struct CentralStatus: Equatable, Sendable {
    public var mode: CentralMode
    public var serviceURL: String?
    public var reachability: CentralReachability
    public var lastSyncAt: Date?
    public var lastError: String?
}

/// Exists only in memory: the code contains the invitation secret.
public struct ActiveInvitation: Equatable, Sendable {
    public var id: String
    public var code: String
    public var createdAt: Date
    public var expiresAt: Date
    public var address: String
    public var environment: String
}

public enum PairingAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
}

public struct DeviceView: Equatable, Sendable, Identifiable {
    public var record: DeviceRecord
    public var connection: ConnectionState
    public var id: String { record.id }
}

public struct GatewaySnapshot: Equatable, Sendable {
    public var now: Date
    public var settings: OriginSettings
    public var gatewayFingerprint: String
    public var proposedGatewayId: String
    public var keyStorage: String
    public var secretStorage: String
    public var listener: ListenerState
    public var central: CentralStatus
    public var account: CentralAccount?
    public var registration: GatewayCentralRecord?
    public var production: ProductionConfiguration
    public var pairing: PairingAvailability
    public var activeInvitation: ActiveInvitation?
    public var requests: [EnrollmentRecord]
    public var devices: [DeviceView]
    public var activity: [ActivityEntry]
    public var startupError: String?

    public var environment: String { settings.centralMode.wireEnvironment }
    public var isDevelopment: Bool { settings.centralMode == .development }
    public var openRequestCount: Int { requests.filter(\.isOpen).count }
    public var connectedCount: Int { devices.filter { $0.connection == .connected }.count }
    public var enrolledCount: Int { devices.filter { $0.record.status == .active }.count }
    public var revokedCount: Int { devices.filter { $0.record.status != .active }.count }
}

public enum NetworkAddress {
    /// Best private IPv4 address of this computer for LAN pairing (prefers en0).
    public static func primaryLANAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var candidates: [(name: String, addr: String)] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: p.pointee.ifa_name)
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                var a = sin.pointee.sin_addr
                inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
            }
            let addr = String(cString: buf)
            if addr.hasPrefix("127.") { continue }
            if let url = URL(string: "http://\(addr)/"), HTTPPrivate.isPrivate(url) { candidates.append((name, addr)) }
        }
        return (candidates.first { $0.name == "en0" } ?? candidates.first)?.addr
    }
}

enum HTTPPrivate {
    static func isPrivate(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        let p = host.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1]))
    }
}
