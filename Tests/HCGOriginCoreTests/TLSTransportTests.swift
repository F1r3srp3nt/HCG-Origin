#if os(macOS)
import XCTest
import Security
import HCGOriginProtocol
import HCGHTTP
@testable import HCGOriginCore
@testable import HCGCentralDevKit
@testable import ConnectorTestKit

/// hcg-origin/2 over real TLS 1.3 (Network.framework server, URLSession client with pinning).
/// Uses a uniquely labelled certificate in the login Keychain that is deleted afterwards.
final class TLSTransportTests: XCTestCase {
    var label = ""

    override func setUp() {
        label = "HCG Origin TEST \(UUID().uuidString)"
    }

    override func tearDown() {
        GatewayTLSIdentity.delete(label: label)
        XCTAssertNil(try? GatewayTLSIdentity.find(label: label), "test certificate must be removed")
    }

    func makeHarness() throws -> Harness {
        try Harness(transport: .tls(label: label))
    }

    func testIdentityIsStableAndMatchesItsCertificate() throws {
        let a = try GatewayTLSIdentity.loadOrCreate(label: label)
        let b = try GatewayTLSIdentity.loadOrCreate(label: label)
        XCTAssertEqual(a.fingerprint, b.fingerprint, "the TLS key must persist")
        let cert = try XCTUnwrap(SecCertificateCreateWithData(nil, a.certificateDER as CFData))
        XCTAssertEqual(GatewayTLSIdentity.fingerprint(of: cert), a.fingerprint)
    }

    func testEnrollApproveConnectOverPinnedTLS() async throws {
        let h = try makeHarness()
        defer { Task { await h.tearDown() } }
        try await h.start()
        let snap = await h.snapshot()
        guard case .tls13Pinned(let fp, _) = snap.transport else { return XCTFail("expected TLS, got \(String(describing: snap.transport))") }
        let code = try await h.pair()
        let invitation = try InvitationCode.decode(code)
        XCTAssertEqual(invitation.transport, InvitationTransport.tls13Pinned)
        XCTAssertEqual(invitation.tlsFingerprint, fp)

        let client = try h.client("TLS Device")
        let r = try await client.enroll(code: code, capabilities: [Capability.presence])
        XCTAssertEqual(r.tlsFingerprint, fp)
        try h.dev.approve(enrollmentId: try await h.centralEnrollmentId(for: r.requestId))
        await h.engine.syncNow()
        let status = try await client.status()
        XCTAssertEqual(status.state, .approved)
        let hb = try await client.heartbeat()
        XCTAssertEqual(hb.tlsFingerprint, fp)
        let after = await h.snapshot()
        XCTAssertEqual(after.devices.first?.connection, .connected)
    }

    func testWrongPinIsRefusedBeforeAnyRequestIsSent() async throws {
        let h = try makeHarness()
        defer { Task { await h.tearDown() } }
        try await h.start()
        var invitation = try InvitationCode.decode(try await h.pair())
        invitation.tlsFingerprint = SoftwareSigner().fingerprint // an attacker's certificate would not match either
        let forged = try InvitationCode.encode(invitation)
        let client = try h.client()
        do {
            _ = try await client.enroll(code: forged, capabilities: [Capability.presence])
            XCTFail("a pin mismatch must abort the connection")
        } catch let e as ConnectorTestClient.ClientError {
            guard case .transport(let message) = e else { return XCTFail("\(e)") }
            XCTAssertTrue(message.contains("does not match the pinned"), message)
        }
        let snap = await h.snapshot()
        XCTAssertTrue(snap.requests.isEmpty, "nothing may reach the gateway over an unauthenticated channel")
        XCTAssertNotNil(snap.activeInvitation, "the invitation was not consumed")
    }

    func testCleartextToTheTLSPortIsRefused() async throws {
        let h = try makeHarness()
        defer { Task { await h.tearDown() } }
        try await h.start()
        let snap = await h.snapshot()
        guard case .listening(let address, _) = snap.listener else { return XCTFail("not listening") }
        let url = try XCTUnwrap(URL(string: "http://\(address)\(OriginPath.enroll)"))
        do {
            let r = try await HTTPClient(timeout: 5).send(method: "POST", url: url, body: Data("{}".utf8))
            XCTAssertNotEqual(r.status, 202, "a cleartext request must never be processed")
        } catch {
            // Expected: the TLS server does not speak cleartext HTTP.
        }
        let after = await h.snapshot()
        XCTAssertTrue(after.requests.isEmpty)
    }

    func testUnpinnedClientCannotBeUsedForGatewayTraffic() async throws {
        // System trust (no pin) must reject the self-signed gateway certificate: there is no accept-any path.
        let h = try makeHarness()
        defer { Task { await h.tearDown() } }
        try await h.start()
        let snap = await h.snapshot()
        guard case .listening(let address, _) = snap.listener else { return XCTFail("not listening") }
        let url = try XCTUnwrap(URL(string: "https://\(address)\(OriginPath.enroll)"))
        do {
            _ = try await HTTPClient(timeout: 5).send(method: "POST", url: url, body: Data("{}".utf8))
            XCTFail("an unpinned client must not trust the self-signed gateway certificate")
        } catch {}
    }
}
#endif
