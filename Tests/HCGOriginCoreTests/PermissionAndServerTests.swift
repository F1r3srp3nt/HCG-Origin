import XCTest
import HCGOriginProtocol
import HCGHTTP
@testable import HCGOriginCore
@testable import HCGCentralDevKit
@testable import ConnectorTestKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class PermissionTests: XCTestCase {
    func testFeatureCatalogueMatchesContract() {
        XCTAssertEqual(OriginFeature.allCases.map(\.rawValue), OriginFeatureKey.all)
        XCTAssertEqual(OriginFeature.allCases.filter(\.isExecutionRelated).map(\.rawValue), OriginFeatureKey.disabled)
        XCTAssertFalse(ExecutionPolicy.enabledInThisBuild)
    }

    func testCentralGrantRevocationIsEnforced() async throws {
        let h = try Harness()
        defer { Task { await h.tearDown() } }
        try await h.start()
        _ = try await h.engine.startPairing()               // granted by default in development
        try h.dev.setGrant(email: "owner@dev.local", featureKey: "origin.devices.enroll", granted: false)
        h.clock.advance(61)                                   // past the 60 s allow cache
        do {
            _ = try await h.engine.startPairing()
            XCTFail("a revoked grant must refuse pairing")
        } catch let e as PermissionError {
            guard case .denied(let d) = e else { return XCTFail() }
            XCTAssertEqual(d.reason, "user_not_permitted")
            XCTAssertEqual(d.source, "central")
        }
        let snap = await h.snapshot()
        XCTAssertEqual(snap.permissions[.devicesEnroll]?.allowed, false)
        XCTAssertTrue(snap.activity.contains { $0.title == "Action refused by central permissions" })
    }

    func testExecutionIsNeverAllowedWhateverCentralSays() async throws {
        let h = try Harness()
        defer { Task { await h.tearDown() } }
        try await h.start()
        XCTAssertThrowsError(try h.dev.setGrant(email: "owner@dev.local", featureKey: "origin.actions.approve", granted: true))
        let d = await h.engine.checkPermission(.actionsApprove)
        XCTAssertFalse(d.allowed)
        XCTAssertEqual(d.reason, "execution_disabled")
        XCTAssertEqual(d.source, "local", "Origin must not even ask central for an execution feature")
    }

    func testOutageFailsClosedButNeverBlocksRemovingAccess() async throws {
        let h = try Harness()
        defer { Task { await h.tearDown() } }
        try await h.start()
        h.dev.setOutage(true)
        h.clock.advance(61)
        do {
            _ = try await h.engine.startPairing()
            XCTFail("pairing must fail closed during an outage")
        } catch {}
        let reduction = try await h.engine.requireForReduction(.gatewayManage)
        XCTAssertFalse(reduction.allowed)
        XCTAssertEqual(reduction.reason, "central_unavailable", "an outage must not prevent revoking or rejecting")
        h.dev.setOutage(false)
        try h.dev.setGrant(email: "owner@dev.local", featureKey: "origin.gateway.manage", granted: false)
        h.clock.advance(11)
        do {
            _ = try await h.engine.requireForReduction(.gatewayManage)
            XCTFail("an explicit central refusal applies to access reduction too")
        } catch {}
    }

    func testSignedOutRefusesAndAttributionIsLocal() async throws {
        let h = try Harness()
        defer { Task { await h.tearDown() } }
        try await h.start(signIn: false)
        let d = await h.engine.checkPermission(.devicesEnroll)
        XCTAssertEqual(d.reason, "not_signed_in")
        let who = await h.engine.attribution()
        XCTAssertTrue(who.contains("not signed in"))
    }
}

// MARK: - Against a REAL HCG Server agent

/// Requires two binaries from HCG Server (branch claude/devicelink-testdevice):
///   HCG_SERVER_FIXTURE_BIN      → go build ./cmd/hcg-devicelink-fixture   (real agent + hcgmock identities)
///   HCG_DEVICELINK_TESTDEVICE_BIN → go build ./cmd/hcg-devicelink-testdevice (test installation)
/// Skipped when they are not set (e.g. CI without access to the private HCG Server repository).
final class HCGServerIntegrationTests: XCTestCase {
    final class Proc {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        var buffer = Data()
        init(_ path: String, _ args: [String]) throws {
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
        }
        func send(_ line: String) -> [String: Any] {
            input.fileHandleForWriting.write(Data((line + "\n").utf8))
            while true {
                if let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    return (try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any]) ?? [:]
                }
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { return [:] }
                buffer.append(chunk)
            }
        }
        func stop() { if process.isRunning { process.terminate() } }
    }

    struct Fixture: Decodable { var adminUrl: String; var adminToken: String; var peerAddress: String; var fingerprint: String }

    var fixtureProc: Process?
    var fixtureDir: URL!

    func startFixture() throws -> (Fixture, URL) {
        guard let fixtureBin = ProcessInfo.processInfo.environment["HCG_SERVER_FIXTURE_BIN"],
              ProcessInfo.processInfo.environment["HCG_DEVICELINK_TESTDEVICE_BIN"] != nil else {
            throw XCTSkip("Set HCG_SERVER_FIXTURE_BIN and HCG_DEVICELINK_TESTDEVICE_BIN to run against a real HCG Server agent.")
        }
        fixtureDir = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-server-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
        let out = fixtureDir.appendingPathComponent("fixture.json")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: fixtureBin)
        p.arguments = ["-out", out.path, "-data-dir", fixtureDir.appendingPathComponent("agent").path, "-invitations", "1"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        fixtureProc = p
        for _ in 0..<100 where (try? Data(contentsOf: out))?.isEmpty ?? true { usleep(100_000) }
        let fx = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: out))
        return (fx, out)
    }

    override func tearDown() {
        if let p = fixtureProc, p.isRunning { kill(p.processIdentifier, SIGCONT); p.terminate() }
        if let d = fixtureDir { try? FileManager.default.removeItem(at: d) }
    }

    func device(_ fixture: URL) throws -> Proc {
        try Proc(ProcessInfo.processInfo.environment["HCG_DEVICELINK_TESTDEVICE_BIN"]!, ["--fixture", fixture.path])
    }

    // swiftlint:disable:next function_body_length
    func testOwnerReviewApproveInventoryRevokeAgainstRealHCGServer() async throws {
        let (fx, fixtureFile) = try startFixture()
        let h = try Harness()
        defer { Task { await h.tearDown() } }
        try await h.start()

        // 1. Connect Origin to HCG Server's owner API (real HTTP to the real agent).
        try await h.engine.connectHCGServer(adminURL: fx.adminUrl, token: fx.adminToken, source: "manual")
        var snap = await h.snapshot()
        guard case .reachable = snap.server.reachability else { return XCTFail("HCG Server not reachable: \(snap.server.reachability)") }
        XCTAssertEqual(snap.server.device?.fingerprint, fx.fingerprint)
        XCTAssertEqual(snap.server.link?.configured, true)
        XCTAssertEqual(snap.server.link?.actionsEnabled, false, "HCG Server must have remote actions disabled")

        // 2. Origin creates the HCG Server invitation; a device pairs with it (HCG Server verifies signature, token, ERP).
        let inv = try await h.engine.createServerInvitation(ttlSeconds: 300)
        let code = try XCTUnwrap(inv.code)
        XCTAssertTrue(code.hasPrefix("hcg1-"))
        let phone = try device(fixtureFile)
        defer { phone.stop() }
        let pair = phone.send("pair \(code) hcg.sentinel Lab_iPhone")
        XCTAssertEqual(pair["ok"] as? Bool, true, "\(pair)")
        let requestId = try XCTUnwrap(pair["requestId"] as? String)
        let keyFP = try XCTUnwrap(pair["keyFingerprint"] as? String)

        // 3. Origin shows the request with the HCG-verified account.
        await h.engine.syncHCGServer(force: true)
        snap = await h.snapshot()
        let pending = try XCTUnwrap(snap.server.pendingPairings.first { $0.requestId == requestId })
        XCTAssertEqual(pending.account.email, "owner@example.test")
        XCTAssertEqual(pending.installation.app, "hcg.sentinel")

        // 4. Approval needs the fingerprint the owner compared — a wrong one approves nothing.
        do {
            try await h.engine.approveServerPairing(requestId: requestId, confirmedFingerprint: String(repeating: "0", count: 64))
            XCTFail("wrong fingerprint must not approve")
        } catch {}
        XCTAssertEqual(phone.send("status")["status"] as? String, "pending")

        // 5. Approval needs the central permission — revoke the grant and it is refused.
        try h.dev.setGrant(email: "owner@dev.local", featureKey: "origin.requests.review", granted: false)
        h.clock.advance(61)
        do {
            try await h.engine.approveServerPairing(requestId: requestId, confirmedFingerprint: keyFP)
            XCTFail("approval without origin.requests.review must be refused")
        } catch let e as PermissionError { _ = e }
        XCTAssertEqual(phone.send("status")["status"] as? String, "pending")
        try h.dev.setGrant(email: "owner@dev.local", featureKey: "origin.requests.review", granted: true)
        h.clock.advance(11)

        // 6. Explicit, attributable approval.
        try await h.engine.approveServerPairing(requestId: requestId, confirmedFingerprint: keyFP)
        XCTAssertEqual(phone.send("status")["status"] as? String, "approved")
        XCTAssertEqual(phone.send("heartbeat")["ok"] as? Bool, true)
        await h.engine.syncHCGServer(force: true)
        snap = await h.snapshot()
        let inst = try XCTUnwrap(snap.server.installations.first { $0.keyFingerprint == keyFP })
        XCTAssertEqual(inst.state, "online")
        let approval = try XCTUnwrap(snap.activity.first { $0.title == "Device Link pairing approved" })
        XCTAssertTrue(approval.detail.contains("approved by owner@dev.local"), approval.detail)

        // 7. The protocol refuses replay, tampering and actions (execution disabled) — on the real agent.
        let replay = phone.send("replay-heartbeat")
        XCTAssertEqual(replay["second"] as? String, "replayed_request")
        XCTAssertEqual(phone.send("tamper-heartbeat")["code"] as? String, "bad_signature")
        XCTAssertEqual(phone.send("action")["code"] as? String, "action_execution_disabled")

        // 8. Unauthorized user: another HCG account cannot join this server's boundary.
        let inv2 = try await h.engine.createServerInvitation(ttlSeconds: 300)
        let stranger = try device(fixtureFile)
        defer { stranger.stop() }
        let refused = stranger.send("pair \(inv2.code!) hcg.terminal Stranger other")
        XCTAssertEqual(refused["ok"] as? Bool, false, "\(refused)")
        XCTAssertNotNil(refused["code"] as? String)

        // 9. Denial: Origin rejects a request.
        let inv3 = try await h.engine.createServerInvitation(ttlSeconds: 300)
        let tablet = try device(fixtureFile)
        defer { tablet.stop() }
        let p3 = tablet.send("pair \(inv3.code!) hcg.terminal Unknown_tablet")
        let rid3 = try XCTUnwrap(p3["requestId"] as? String)
        try await h.engine.rejectServerPairing(requestId: rid3)
        XCTAssertEqual(tablet.send("status")["status"] as? String, "rejected")

        // 10. Network interruption: HCG Server stops answering, then recovers.
        let fixturePid = try XCTUnwrap(fixtureProc?.processIdentifier)
        kill(fixturePid, SIGSTOP)
        await h.engine.syncHCGServer(force: true)
        snap = await h.snapshot()
        guard case .unreachable = snap.server.reachability else { kill(fixturePid, SIGCONT); return XCTFail("expected unreachable") }
        kill(fixturePid, SIGCONT)
        await h.engine.syncHCGServer(force: true)
        snap = await h.snapshot()
        guard case .reachable = snap.server.reachability else { return XCTFail("did not recover") }
        XCTAssertTrue(snap.activity.contains { $0.title == "HCG Server reachable again" })

        // 11. Revocation from Origin is enforced by HCG Server on the device's next request.
        try await h.engine.revokeServerInstallation(installationId: inst.installationId)
        XCTAssertEqual(phone.send("heartbeat")["code"] as? String, "device_revoked")
        await h.engine.syncHCGServer(force: true)
        snap = await h.snapshot()
        XCTAssertEqual(snap.server.installations.first { $0.installationId == inst.installationId }?.state, "revoked")

        // 12. Audit: events reach central with the decisions.
        await h.engine.syncNow()
        let types = Set(h.dev.receivedEvents().map(\.type))
        for t in ["gateway.server.connected", "gateway.server.invitation_created", "gateway.server.pairing_approved",
                  "gateway.server.pairing_rejected", "gateway.server.installation_revoked"] {
            XCTAssertTrue(types.contains(t), "missing audit event \(t)")
        }

        // 13. Restart: Origin reconnects with the stored connection and sees the same inventory.
        await h.engine.shutdown()
        let restarted = GatewayEngine(dataDirectory: h.dir, secrets: h.secrets, production: ProductionConfiguration(),
                                      hostName: "Test Mac", preferSecureEnclave: false)
        await restarted.start(runLoop: false)
        await restarted.syncHCGServer(force: true)
        let after = await restarted.snapshot()
        guard case .reachable = after.server.reachability else { return XCTFail("not reconnected after restart") }
        XCTAssertTrue(after.server.installations.contains { $0.installationId == inst.installationId && $0.state == "revoked" })
        await restarted.shutdown()
    }
}
