import XCTest
import HCGOriginProtocol
import HCGHTTP
@testable import HCGOriginCore
@testable import HCGCentralDevKit
@testable import ConnectorTestKit

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return Date().addingTimeInterval(offset) }
    func advance(_ s: TimeInterval) { lock.lock(); offset += s; lock.unlock() }
}

/// Real processes boundaries are replaced by real loopback sockets: the gateway engine
/// listens on 127.0.0.1, the development service listens on 127.0.0.1, and the test
/// client talks HTTP to the gateway exactly as it does from the command line.
final class Harness {
    let dir: URL
    let clock = TestClock()
    let dev: DevCentralService
    let engine: GatewayEngine
    let secrets = MemorySecretStore()

    init(mode: CentralMode = .development, production: ProductionConfiguration = ProductionConfiguration(),
         transport: ConnectorTransportFactory = .cleartextLoopback) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-origin-tests-\(UUID().uuidString)")
        dev = DevCentralService(port: 0)
        try dev.start()
        var settings = OriginSettings.defaults(hostName: "Test Mac")
        settings.listenPort = 0
        settings.centralMode = mode
        settings.developmentServiceURL = dev.baseURL.absoluteString
        settings.centralSyncSeconds = 0
        try JSONFileStore(directory: dir).save(settings, to: "settings.json")
        let c = clock
        engine = GatewayEngine(dataDirectory: dir, secrets: secrets, production: production, hostName: "Test Mac",
                               preferSecureEnclave: false, transport: transport, clock: { c.now() })
    }

    func start(signIn: Bool = true) async throws {
        await engine.start(runLoop: false)
        if signIn {
            try await engine.signInDevelopment(email: "owner@dev.local", displayName: "Dev Owner")
            await engine.syncNow()
        }
    }

    func client(_ name: String = "Test Device") throws -> ConnectorTestClient {
        try ConnectorTestClient(profileDirectory: dir.appendingPathComponent("client-\(name)-\(UUID().uuidString)"), name: name)
    }

    func pair() async throws -> String {
        try await engine.startPairing().code
    }

    func snapshot() async -> GatewaySnapshot { await engine.snapshot() }

    func centralEnrollmentId(for requestId: String) async throws -> String {
        await engine.syncNow()
        let s = await snapshot()
        return try XCTUnwrap(s.requests.first { $0.id == requestId }?.centralEnrollmentId, "request was not forwarded")
    }

    func tearDown() async {
        await engine.shutdown()
        dev.stop()
        try? FileManager.default.removeItem(at: dir)
    }
}

final class EnrollmentFlowTests: XCTestCase {
    func assertGatewayError(_ code: String, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected gateway error \(code)", file: file, line: line)
        } catch let e as ConnectorTestClient.ClientError {
            XCTAssertEqual(e.code, code, "\(e)", file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    func testFullFlowApproveConnectRevoke() async throws {
        let h = try Harness()
        defer { Task { await h.tearDown() } }
        try await h.start()
        var snap = await h.snapshot()
        XCTAssertEqual(snap.pairing, .available)
        XCTAssertNotNil(snap.registration)
        XCTAssertTrue(snap.registration!.gatewayId.hasPrefix("hcgdev_gw_"), "gateway ID must be issued by central")

        let code = try await h.pair()
        let client = try h.client("Lab iPad")
        let r = try await client.enroll(code: code, capabilities: [Capability.presence, Capability.statusReport])
        XCTAssertEqual(r.state, .received)
        XCTAssertEqual(r.environment, "development")
        snap = await h.snapshot()
        XCTAssertNil(snap.activeInvitation, "single-use invitation must be consumed")
        XCTAssertEqual(snap.requests.first?.checkCode, r.checkCode)

        let enrollmentId = try await h.centralEnrollmentId(for: r.requestId)
        var status = try await client.status()
        XCTAssertEqual(status.state, .awaitingDecision)
        XCTAssertNil(status.grant)

        // Not approved yet → no connection.
        await assertGatewayError(OriginErrorCode.unknownDevice) {
            client.profile.deviceId = "hcgdev_dev_guess"
            _ = try await client.heartbeat()
        }
        client.profile.deviceId = nil

        // ERP (development stand-in) grants presence only.
        try h.dev.approve(enrollmentId: enrollmentId, capabilities: [Capability.presence])
        await h.engine.syncNow()
        status = try await client.status()
        XCTAssertEqual(status.state, .approved)
        XCTAssertEqual(status.grant?.capabilities, [Capability.presence])
        XCTAssertEqual(status.grant?.executionAuthorized, false)
        XCTAssertTrue(status.deviceId?.hasPrefix("hcgdev_dev_") == true)

        // Connected, but only with what was granted.
        let hb = try await client.heartbeat()
        XCTAssertEqual(hb.state, "connected")
        await assertGatewayError(OriginErrorCode.capabilityNotGranted) {
            _ = try await client.heartbeat(report: ConnectorTestClient.localStatusReport())
        }
        snap = await h.snapshot()
        XCTAssertEqual(snap.devices.first?.connection, .connected)
        XCTAssertEqual(snap.connectedCount, 1)

        // Restart: enrollment persists, still connected on next contact.
        await h.engine.shutdown()
        let restarted = GatewayEngine(dataDirectory: h.dir, secrets: h.secrets, production: ProductionConfiguration(),
                                      hostName: "Test Mac", preferSecureEnclave: false)
        await restarted.start(runLoop: false)
        let afterRestart = await restarted.snapshot()
        XCTAssertEqual(afterRestart.devices.count, 1)
        XCTAssertEqual(afterRestart.gatewayFingerprint, snap.gatewayFingerprint, "identity must survive restarts")
        guard case .listening(let address, _) = afterRestart.listener else { return XCTFail("not listening") }
        client.profile.gateway?.address = address // listener used an ephemeral test port
        // Fail closed: no connection until admission is confirmed with central after the restart.
        await assertGatewayError(OriginErrorCode.admissionUnverified) { _ = try await client.heartbeat() }
        await restarted.syncNow()
        _ = try await client.heartbeat()
        await restarted.syncNow()

        // Revocation in ERP is reflected and enforced.
        try h.dev.revoke(deviceId: status.deviceId!, reason: "Lost device")
        await restarted.syncNow()
        let revokedSnap = await restarted.snapshot()
        XCTAssertEqual(revokedSnap.devices.first?.record.status, .revoked)
        XCTAssertEqual(revokedSnap.devices.first?.connection, .revoked)
        await assertGatewayError(OriginErrorCode.deviceRevoked) { _ = try await client.heartbeat() }
        let after = try await client.status()
        XCTAssertNil(after.grant, "a revoked device must not learn a usable grant")
        await restarted.syncNow()
        let types = Set(h.dev.receivedEvents().map(\.type))
        XCTAssertTrue(types.contains("gateway.device.connected"))
        XCTAssertTrue(types.contains("gateway.device.revocation_enforced"))
        XCTAssertTrue(revokedSnap.activity.contains { $0.title == "Device access revoked" })
        await restarted.shutdown()
    }

    func testRejectedRequest() async throws {
        let h = try Harness()
        defer { Task { await h.tearDown() } }
        try await h.start()
        let client = try h.client()
        let r = try await client.enroll(code: try await h.pair(), capabilities: [Capability.presence])
        try h.dev.reject(enrollmentId: try await h.centralEnrollmentId(for: r.requestId), reason: "Unknown device")
        await h.engine.syncNow()
        let s = try await client.status()
        XCTAssertEqual(s.state, .rejected)
        XCTAssertEqual(s.reason, "Unknown device")
        XCTAssertNil(s.deviceId)
        let snap = await h.snapshot()
        XCTAssertTrue(snap.devices.isEmpty)
        XCTAssertEqual(snap.requests.first?.steps.first { $0.id == "decision" }?.result, .failed)
    }

    func testExpiredInvitationIsRefused() async throws {
        let h = try Harness()
        defer { Task { await h.tearDown() } }
        try await h.start()
        await h.engine.updateSettings { $0.invitationTTLSeconds = 60 }
        let code = try await h.pair()
        h.clock.advance(61)
        await h.engine.tick()
        let client = try h.client()
        // The client refuses an expired code itself (its own clock)…
        let payload = try InvitationCode.decode(code)
        XCTAssertThrowsError(try InvitationCode.validate(payload, now: Date().addingTimeInterval(61)))
        // …and the gateway refuses it regardless of the client's clock.
        let body = Wire.encode(EnrollRequestBody(invitationId: payload.invitationId, gatewayFingerprint: payload.gatewayFingerprint,
                                                 device: client.descriptor, requestedCapabilities: [Capability.presence]))
        let req = try client.prepare(path: OriginPath.enroll, body: body, address: payload.address,
                                     transport: payload.transport, tlsFingerprint: payload.tlsFingerprint,
                                     invitation: (payload.invitationId, payload.secret), now: h.clock.now())
        let resp = try await client.send(req, pinnedFingerprint: payload.gatewayFingerprint)
        XCTAssertEqual(resp.status, 410)
        XCTAssertEqual(try Wire.decoder().decode(ErrorBody.self, from: resp.body).error.code, OriginErrorCode.invitationExpired)
        let snap = await h.snapshot()
        XCTAssertNil(snap.activeInvitation)
        XCTAssertTrue(snap.requests.isEmpty)
    }

    func testReplayAndInvitationReuseAreRefused() async throws {
        let h = try Harness()
        defer { Task { await h.tearDown() } }
        try await h.start()
        let code = try await h.pair()
        let payload = try InvitationCode.decode(code)
        let client = try h.client()
        let body = Wire.encode(EnrollRequestBody(invitationId: payload.invitationId, gatewayFingerprint: payload.gatewayFingerprint,
                                                 device: client.descriptor, requestedCapabilities: [Capability.presence]))
        let req = try client.prepare(path: OriginPath.enroll, body: body, address: payload.address,
                                     transport: payload.transport, tlsFingerprint: payload.tlsFingerprint,
                                     invitation: (payload.invitationId, payload.secret))
        let first = try await client.send(req, pinnedFingerprint: payload.gatewayFingerprint)
        XCTAssertEqual(first.status, 202)
        // Exact replay of a captured request.
        let replay = try await client.send(req, pinnedFingerprint: payload.gatewayFingerprint)
        XCTAssertEqual(replay.status, 401)
        XCTAssertEqual(try Wire.decoder().decode(ErrorBody.self, from: replay.body).error.code, OriginErrorCode.replayedRequest)
        // A fresh request from another device reusing the same invitation.
        let other = try h.client("Other")
        await assertGatewayError(OriginErrorCode.invitationUsed) { _ = try await other.enroll(code: code, capabilities: [Capability.presence]) }
        let snap = await h.snapshot()
        XCTAssertEqual(snap.requests.count, 1)
        XCTAssertTrue(snap.activity.contains { $0.title == "Replayed request rejected" })
    }

    func testWrongSecretCancelsInvitationAfterFiveAttempts() async throws {
        let h = try Harness()
        defer { Task { await h.tearDown() } }
        try await h.start()
        var payload = try InvitationCode.decode(try await h.pair())
        payload.secret = InvitationCode.newSecret()
        let forged = try InvitationCode.encode(payload)
        let attacker = try h.client("Attacker")
        for _ in 0..<5 {
            await assertGatewayError(OriginErrorCode.invalidInvitationProof) { _ = try await attacker.enroll(code: forged, capabilities: [Capability.presence]) }
        }
        await assertGatewayError(OriginErrorCode.invitationCancelled) { _ = try await attacker.enroll(code: forged, capabilities: [Capability.presence]) }
        let snap = await h.snapshot()
        XCTAssertNil(snap.activeInvitation)
        XCTAssertTrue(snap.requests.isEmpty)
    }

    func testDuplicateEnrollment() async throws {
        let h = try Harness()
        defer { Task { await h.tearDown() } }
        try await h.start()
        let client = try h.client()
        let r = try await client.enroll(code: try await h.pair(), capabilities: [Capability.presence])
        // Same device while pending.
        await assertGatewayError(OriginErrorCode.enrollmentPending) { _ = try await client.enroll(code: try await h.pair(), capabilities: [Capability.presence]) }
        try h.dev.approve(enrollmentId: try await h.centralEnrollmentId(for: r.requestId))
        await h.engine.syncNow()
        _ = try await client.status()
        // Same device after approval.
        await assertGatewayError(OriginErrorCode.alreadyEnrolled) { _ = try await client.enroll(code: try await h.pair(), capabilities: [Capability.presence]) }
        let snap = await h.snapshot()
        XCTAssertEqual(snap.devices.count, 1)
    }

    func testExecutionIsNeverGranted() async throws {
        let h = try Harness()
        defer { Task { await h.tearDown() } }
        try await h.start()
        let client = try h.client()
        let r = try await client.enroll(code: try await h.pair(), capabilities: [Capability.presence, Capability.execution])
        XCTAssertEqual(r.forwardedCapabilities, [Capability.presence])
        XCTAssertEqual(r.refusedCapabilities.map(\.capability), [Capability.execution])
        let id = try await h.centralEnrollmentId(for: r.requestId)
        XCTAssertThrowsError(try h.dev.approve(enrollmentId: id, capabilities: [Capability.presence, Capability.execution]))
        try h.dev.approve(enrollmentId: id)
        await h.engine.syncNow()
        let s = try await client.status()
        XCTAssertEqual(s.grant?.capabilities, [Capability.presence])
        XCTAssertEqual(s.grant?.executionAuthorized, false)
    }

    func testCentralOutageKeepsRequestPendingAndRecovers() async throws {
        let h = try Harness()
        defer { Task { await h.tearDown() } }
        try await h.start()
        let code = try await h.pair()
        h.dev.setOutage(true)
        let client = try h.client()
        let r = try await client.enroll(code: code, capabilities: [Capability.presence])
        await h.engine.syncNow()
        var snap = await h.snapshot()
        guard case .unreachable = snap.central.reachability else { return XCTFail("expected unreachable, got \(snap.central.reachability)") }
        if case .available = snap.pairing { XCTFail("pairing must be unavailable while central is down") }
        XCTAssertEqual(snap.requests.first?.state, .received)
        let pending = try await client.status()
        XCTAssertEqual(pending.state, .received)

        h.dev.setOutage(false)
        h.clock.advance(70) // past the retry back-off
        await h.engine.syncNow()
        snap = await h.snapshot()
        guard case .reachable = snap.central.reachability else { return XCTFail("expected reachable") }
        XCTAssertEqual(snap.requests.first?.state, .awaitingDecision)
        try h.dev.approve(enrollmentId: try XCTUnwrap(snap.requests.first?.centralEnrollmentId))
        await h.engine.syncNow()
        let s = try await client.status()
        XCTAssertEqual(s.state, .approved)
        _ = r
    }

    func testDisconnectAndReconnect() async throws {
        let h = try Harness()
        defer { Task { await h.tearDown() } }
        try await h.start()
        let client = try h.client()
        let r = try await client.enroll(code: try await h.pair(), capabilities: [Capability.presence, Capability.statusReport])
        try h.dev.approve(enrollmentId: try await h.centralEnrollmentId(for: r.requestId))
        await h.engine.syncNow()
        _ = try await client.status()
        _ = try await client.heartbeat(report: ConnectorTestClient.localStatusReport())
        var snap = await h.snapshot()
        XCTAssertEqual(snap.devices.first?.connection, .connected)
        XCTAssertNotNil(snap.devices.first?.record.lastReport)

        h.clock.advance(TimeInterval(snap.settings.disconnectAfterSeconds + 5))
        await h.engine.tick()
        snap = await h.snapshot()
        XCTAssertEqual(snap.devices.first?.connection, .disconnected)
        XCTAssertTrue(snap.activity.contains { $0.title == "Device disconnected" })

        _ = try await client.heartbeat()
        snap = await h.snapshot()
        XCTAssertEqual(snap.devices.first?.connection, .connected)
        XCTAssertTrue(snap.activity.contains { $0.title == "Device reconnected" })
    }

    func testLocalBlockIsEnforcedAndReported() async throws {
        let h = try Harness()
        defer { Task { await h.tearDown() } }
        try await h.start()
        let client = try h.client()
        let r = try await client.enroll(code: try await h.pair(), capabilities: [Capability.presence])
        try h.dev.approve(enrollmentId: try await h.centralEnrollmentId(for: r.requestId))
        await h.engine.syncNow()
        let s = try await client.status()
        await h.engine.blockDeviceLocally(id: s.deviceId!)
        await assertGatewayError(OriginErrorCode.deviceBlocked) { _ = try await client.heartbeat() }
        await h.engine.syncNow()
        XCTAssertTrue(h.dev.receivedEvents().contains { $0.type == "gateway.device.blocked_locally" })
        XCTAssertEqual(h.dev.deviceRecords().first?.status, .active, "a local block does not change central admission")
    }

    func testProductionIsUnavailableWithoutIssuedConfiguration() async throws {
        let h = try Harness(mode: .production)
        defer { Task { await h.tearDown() } }
        try await h.start(signIn: false)
        await h.engine.syncNow()
        let snap = await h.snapshot()
        guard case .unavailable(let reason) = snap.pairing else { return XCTFail("production pairing must be unavailable") }
        XCTAssertTrue(reason.contains("HCG Connect"))
        guard case .notConfigured(let missing) = snap.central.reachability else { return XCTFail("expected notConfigured") }
        XCTAssertEqual(missing.count, 4)
        do {
            _ = try await h.engine.startPairing()
            XCTFail("startPairing must throw")
        } catch {}
        do {
            try await h.engine.signInDevelopment(email: "x@y.z", displayName: "x")
            XCTFail("development sign-in must not work in production mode")
        } catch {}
    }

    func testRemoteRequestsRefusedWhenLocalNetworkIsOff() async throws {
        let h = try Harness()
        defer { Task { await h.tearDown() } }
        try await h.start()
        let resp = await h.engine.handle(HTTPRequest(method: "POST", path: OriginPath.enroll, remoteAddress: "192.168.1.50"))
        XCTAssertEqual(resp.status, 403)
        let unsigned = await h.engine.handle(HTTPRequest(method: "POST", path: OriginPath.enroll, body: Data("{}".utf8), remoteAddress: "127.0.0.1"))
        XCTAssertEqual(unsigned.status, 401)
        // With local-network pairing on, private addresses reach verification; public ones never do.
        await h.engine.updateSettings { $0.allowLocalNetwork = true }
        let lan = await h.engine.handle(HTTPRequest(method: "POST", path: OriginPath.enroll, remoteAddress: "192.168.1.50"))
        XCTAssertEqual(lan.status, 401, "a private-network peer is allowed to try (and fails authentication)")
        let publicPeer = await h.engine.handle(HTTPRequest(method: "POST", path: OriginPath.enroll, remoteAddress: "8.8.8.8"))
        XCTAssertEqual(publicPeer.status, 403)
    }

    func testCentralVerifiesDeviceSignatureIndependently() async throws {
        let h = try Harness()
        defer { Task { await h.tearDown() } }
        try await h.start()
        let client = try h.client()
        let r = try await client.enroll(code: try await h.pair(), capabilities: [Capability.presence])
        _ = try await h.centralEnrollmentId(for: r.requestId)
        // A gateway that tampers with the forwarded request is refused by central.
        let snap = await h.snapshot()
        var record = try XCTUnwrap(snap.requests.first)
        let reg = try XCTUnwrap(snap.registration)
        let signer = try GatewayIdentity.loadOrCreate(store: h.secrets, preferSecureEnclave: false).signer
        let central = HTTPCentralService(mode: .development, baseURL: h.dev.baseURL, signer: signer)
        let token = try XCTUnwrap(try h.secrets.read("session-token.development").flatMap { String(data: $0, encoding: .utf8) })
        record.device.name = "Renamed by gateway"
        do {
            _ = try await central.submitEnrollment(CentralEnrollmentSubmission(
                gatewayId: reg.gatewayId, localRequestId: "req_tampered", invitationId: record.invitationId, device: record.device,
                requestedCapabilities: [Capability.presence], refusedByGateway: [], deviceRequest: record.forwarded, receivedAt: Date()), token: token)
            XCTFail("tampered submission must be refused")
        } catch let e as CentralError {
            guard case .rejected(422, let code, _) = e else { return XCTFail("\(e)") }
            XCTAssertEqual(code, CentralErrorCode.deviceSignatureInvalid)
        }
    }

    func testLocalNetworkRequiresEncryption() async throws {
        let h = try Harness()
        defer { Task { await h.tearDown() } }
        try await h.start()
        await h.engine.updateSettings { $0.allowLocalNetwork = true }
        let snap = await h.snapshot()
        guard case .failed(let reason) = snap.listener else { return XCTFail("cleartext must never listen beyond this Mac: \(snap.listener)") }
        XCTAssertTrue(reason.contains("encrypted transport"), reason)
        if case .available = snap.pairing { XCTFail("pairing must be unavailable without encryption") }
    }

    func testAdmissionFreshnessFailsClosed() async throws {
        let h = try Harness()
        defer { Task { await h.tearDown() } }
        try await h.start()
        await h.engine.updateSettings { $0.admissionMaxAgeSeconds = 60 }
        let client = try h.client()
        let r = try await client.enroll(code: try await h.pair(), capabilities: [Capability.presence])
        try h.dev.approve(enrollmentId: try await h.centralEnrollmentId(for: r.requestId))
        await h.engine.syncNow()
        _ = try await client.status()
        _ = try await client.heartbeat()
        h.dev.setOutage(true)
        h.clock.advance(61)
        await h.engine.syncNow() // fails: central down, admission not re-confirmed
        await assertGatewayError(OriginErrorCode.admissionUnverified) { _ = try await client.heartbeat() }
        h.dev.setOutage(false)
        await h.engine.syncNow()
        _ = try await client.heartbeat()
    }
}
