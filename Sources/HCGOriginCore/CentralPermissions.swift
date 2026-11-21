import Foundation
import HCGOriginProtocol
import HCGHTTP

/// HCG Origin's centrally governed features (PROPOSED keys for product `hcg.origin`; see the main-site
/// proposal docs/hcg-origin/registration-proposal.md). ERP App Access decides; Origin only asks.
public enum OriginFeature: String, CaseIterable, Sendable, Codable {
    case appAccess = "origin.app.access"
    case gatewayManage = "origin.gateway.manage"
    case devicesEnroll = "origin.devices.enroll"
    case requestsReview = "origin.requests.review"
    case devicesRead = "origin.devices.read"
    case diagnostics = "origin.gateway.diagnostics"
    case serverConnect = "origin.server.connect"
    case actionsApprove = "origin.actions.approve"
    case auditRead = "origin.audit.read"
    case settingsAdmin = "origin.settings.admin"

    public static let productId = "hcg.origin"

    /// Execution-related features are disabled in this build, whatever central says.
    public var isExecutionRelated: Bool { self == .actionsApprove }

    public var title: String {
        switch self {
        case .appAccess: return "Application access"
        case .gatewayManage: return "Gateway management"
        case .devicesEnroll: return "Device enrollment"
        case .requestsReview: return "Connection request review"
        case .devicesRead: return "Device inventory"
        case .diagnostics: return "Gateway diagnostics"
        case .serverConnect: return "HCG Server connectivity"
        case .actionsApprove: return "Remote action approval"
        case .auditRead: return "Audit log access"
        case .settingsAdmin: return "Administrative settings"
        }
    }
}

/// Command execution is not part of this milestone. No setting, licence, role (including Founder) or
/// central answer can turn it on: there is no code path that executes anything.
public enum ExecutionPolicy {
    public static let enabledInThisBuild = false
    public static let reason = "Remote actions and command execution are disabled in this build of HCG Origin. They need a separate review, a registered action type and explicit approval on the target device."
}

public struct PermissionDecision: Equatable, Sendable {
    public var feature: OriginFeature
    public var allowed: Bool
    /// Central `reason` or a local reason (e.g. execution_disabled, not_signed_in, central_unavailable).
    public var reason: String
    public var layer: String?
    public var at: Date
    public var source: String // "central" | "local"

    public var message: String {
        if allowed { return "\(feature.title): allowed" }
        switch reason {
        case "execution_disabled": return ExecutionPolicy.reason
        case "not_signed_in": return "Sign in to check “\(feature.title)” with HCG."
        case "not_configured": return "Central permission checks are not configured for this environment; “\(feature.title)” is refused."
        case "central_unavailable": return "HCG could not be asked about “\(feature.title)”, so it is refused (fail closed)."
        case "session_ended": return "Your HCG session is no longer accepted; sign in again."
        case "feature_unavailable": return "“\(feature.title)” (\(feature.rawValue)) is not registered or not enabled for HCG Origin."
        case "user_not_permitted": return "Your account has no grant for “\(feature.title)” (\(feature.rawValue))."
        default: return "“\(feature.title)” refused by HCG: \(reason)."
        }
    }
}

public enum PermissionError: Error, CustomStringConvertible, Equatable {
    case denied(PermissionDecision)
    public var description: String {
        switch self { case .denied(let d): return d.message }
    }
}

/// Asks HCG's Ecosystem API (`POST {base}/check`) with the signed-in person's own token.
/// Only `allowed === true` allows; any other answer, error or outage refuses. Allows are cached 60 s,
/// refusals 10 s; a 401 clears the cache.
public final class CentralPermissionClient: @unchecked Sendable {
    public let ecosystemBase: URL
    private let http = HTTPClient(timeout: 6)
    private let lock = NSLock()
    private var cache: [String: (PermissionDecision, Date)] = [:]

    public init(ecosystemBase: URL) { self.ecosystemBase = ecosystemBase }

    /// No organisation: the placeholder documented by main HCG for personal accounts.
    public static let noOrganisation = "00000000-0000-0000-0000-000000000000"

    public func clearCache() { lock.lock(); cache.removeAll(); lock.unlock() }

    private func cached(_ key: String, now: Date) -> PermissionDecision? {
        lock.lock(); defer { lock.unlock() }
        if let (d, until) = cache[key], until > now { return d }
        return nil
    }

    private func store(_ d: PermissionDecision, key: String, now: Date) {
        lock.lock(); defer { lock.unlock() }
        cache[key] = (d, now.addingTimeInterval(d.allowed ? 60 : 10))
    }

    public func check(_ feature: OriginFeature, token: String, organisation: String?, now: Date) async -> PermissionDecision {
        if feature.isExecutionRelated && !ExecutionPolicy.enabledInThisBuild {
            return PermissionDecision(feature: feature, allowed: false, reason: "execution_disabled", layer: "local", at: now, source: "local")
        }
        let org = organisation ?? Self.noOrganisation
        let key = "\(Encoding.sha256Hex(Data(token.utf8)).prefix(16))|\(org)|\(feature.rawValue)"
        if let d = cached(key, now: now) { return d }

        struct Body: Encodable { var org_id: String; var product_id: String; var feature_key: String }
        struct Answer: Decodable { var allowed: Bool?; var reason: String?; var layer: String? }
        var decision: PermissionDecision
        do {
            try HTTPClient.checkTransport(ecosystemBase)
            let url = ecosystemBase.appendingPathComponent("check")
            let r = try await http.send(method: "POST", url: url, headers: ["Authorization": "Bearer \(token)"],
                                        body: Wire.encode(Body(org_id: org, product_id: OriginFeature.productId, feature_key: feature.rawValue)))
            if r.status == 401 {
                clearCache()
                return PermissionDecision(feature: feature, allowed: false, reason: "session_ended", layer: "identity", at: now, source: "central")
            }
            guard r.status == 200, let a = try? JSONDecoder().decode(Answer.self, from: r.body) else {
                decision = PermissionDecision(feature: feature, allowed: false, reason: r.status == 200 ? "malformed_answer" : "central_unavailable",
                                              layer: nil, at: now, source: "central")
                return decision // not cached: retry next time
            }
            decision = PermissionDecision(feature: feature, allowed: a.allowed == true, reason: a.allowed == true ? "allowed" : (a.reason ?? "denied"),
                                          layer: a.layer, at: now, source: "central")
        } catch {
            return PermissionDecision(feature: feature, allowed: false, reason: "central_unavailable", layer: nil, at: now, source: "central")
        }
        store(decision, key: key, now: now)
        return decision
    }
}
