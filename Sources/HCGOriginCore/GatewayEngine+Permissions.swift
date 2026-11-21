import Foundation
import HCGOriginProtocol

extension GatewayEngine {
    /// Ecosystem API used for `/check` in the current environment. Development: the local development service's
    /// emulation (loopback only). Production: the configured base, absent until issued.
    func ecosystemBase() -> URL? {
        switch settings.centralMode {
        case .production:
            return production.ecosystemAPIBase.isEmpty ? nil : URL(string: production.ecosystemAPIBase)
        case .development:
            guard var c = URLComponents(string: settings.developmentServiceURL) else { return nil }
            c.path = "/api/public/ecosystem/v1"
            c.query = nil
            return c.url
        }
    }

    func permissions() -> CentralPermissionClient? {
        guard let base = ecosystemBase() else { return nil }
        if permissionClientBase != base || permissionClient == nil {
            permissionClient = CentralPermissionClient(ecosystemBase: base)
            permissionClientBase = base
        }
        return permissionClient
    }

    /// Central decision for one feature (cached by the client). Records it for the UI.
    public func checkPermission(_ feature: OriginFeature) async -> PermissionDecision {
        let now = clock()
        let decision: PermissionDecision
        if feature.isExecutionRelated && !ExecutionPolicy.enabledInThisBuild {
            decision = PermissionDecision(feature: feature, allowed: false, reason: "execution_disabled", layer: "local", at: now, source: "local")
        } else if let token = currentToken() {
            if let client = permissions() {
                decision = await client.check(feature, token: token, organisation: nil, now: now)
            } else {
                decision = PermissionDecision(feature: feature, allowed: false, reason: "not_configured", layer: nil, at: now, source: "local")
            }
        } else {
            decision = PermissionDecision(feature: feature, allowed: false, reason: "not_signed_in", layer: "identity", at: now, source: "local")
        }
        permissionDecisions[feature] = decision
        return decision
    }

    /// Throws unless HCG allows `feature` for the signed-in person right now.
    @discardableResult
    func require(_ feature: OriginFeature) async throws -> PermissionDecision {
        let d = await checkPermission(feature)
        guard d.allowed else {
            securityLog("perm-\(feature.rawValue)", "Action refused by central permissions", d.message)
            notify()
            throw PermissionError.denied(d)
        }
        return d
    }

    /// For actions that only REMOVE access (reject, revoke, block): an explicit central "no" refuses, but an
    /// outage or a missing sign-in does not stop the owner from removing access. Returns the decision used.
    func requireForReduction(_ feature: OriginFeature) async throws -> PermissionDecision {
        let d = await checkPermission(feature)
        if d.allowed { return d }
        let centralSaidNo = d.source == "central" && d.reason != "central_unavailable" && d.reason != "malformed_answer"
        if centralSaidNo {
            securityLog("perm-\(feature.rawValue)", "Action refused by central permissions", d.message)
            notify()
            throw PermissionError.denied(d)
        }
        return d
    }

    func refreshPermissionsIfDue() async {
        let now = clock()
        if let last = lastPermissionRefresh, now.timeIntervalSince(last) < 60 { return }
        lastPermissionRefresh = now
        guard currentToken() != nil else { return }
        for f in OriginFeature.allCases { _ = await checkPermission(f) }
    }

    /// The signed-in person, for attributing decisions. Nil when not signed in.
    var attributedOwner: CentralAccount? { state.accounts[settings.centralMode.wireEnvironment] }

    func attribution() -> String {
        if let a = attributedOwner {
            return "\(a.email) (\(a.accountId), \(settings.centralMode == .development ? "development account" : "HCG Connect"))"
        }
        return "the local owner on this Mac (not signed in to HCG)"
    }
}
