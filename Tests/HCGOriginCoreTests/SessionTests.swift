import XCTest
import HCGOriginProtocol
import HCGHTTP
@testable import HCGOriginCore

/// HCG Connect session lifecycle against a local mock token endpoint (refresh_token grant).
/// The real HCG Connect client for Origin is not issued yet, so this exercises Origin's logic, not HCG.
final class SessionTests: XCTestCase {
    final class TokenEndpoint: @unchecked Sendable {
        let lock = NSLock()
        var validRefresh = "rt-1"
        var issued = 0
        var server: HTTPServer!
        func respond(_ form: String) -> HTTPResponse {
            lock.lock(); defer { lock.unlock() }
            guard form.contains("grant_type=refresh_token"), form.contains("client_id=test-client"),
                  form.contains("refresh_token=\(validRefresh)") else {
                return HTTPResponse.json(400, Data(#"{"error":"invalid_grant"}"#.utf8))
            }
            issued += 1
            validRefresh = "rt-\(issued + 1)" // rotation: the old refresh token stops working
            return HTTPResponse.json(200, Data(#"{"access_token":"at-\#(issued)","refresh_token":"\#(validRefresh)","expires_in":3600,"token_type":"bearer"}"#.utf8))
        }
        func start() throws -> URL {
            server = HTTPServer(host: "127.0.0.1", port: 0) { [unowned self] req in
                self.respond(String(decoding: req.body, as: UTF8.self).removingPercentEncoding ?? "")
            }
            let port = try server.start()
            return URL(string: "http://127.0.0.1:\(port)/token")!
        }
    }

    override func setUp() { HCGConnectPKCE.allowLoopbackHTTPForTesting = true }
    override func tearDown() { HCGConnectPKCE.allowLoopbackHTTPForTesting = false }

    func testRenewalRotatesAndStoresTheSessionAtomically() async throws {
        let endpoint = TokenEndpoint()
        let url = try endpoint.start()
        let h = try Harness()
        defer { Task { await h.tearDown() } }
        try await h.start()
        try await h.engine.storeSession(ConnectSession(accessToken: "at-0", refreshToken: "rt-1", expiresAt: h.clock.now().addingTimeInterval(60),
                                                       tokenEndpoint: url.absoluteString, clientID: "test-client"), env: "development")
        await h.engine.renewSessionIfNeeded()
        let s1 = await h.engine.currentSession()
        XCTAssertEqual(s1?.accessToken, "at-1")
        XCTAssertEqual(s1?.refreshToken, "rt-2", "the rotated refresh token must replace the old one")
        // Stored in the secret store as one item, readable after a restart.
        let raw = try XCTUnwrap(try h.secrets.read("session-token.development"))
        XCTAssertEqual(ConnectSession.decode(raw)?.refreshToken, "rt-2")
        // Not due yet: no renewal.
        await h.engine.renewSessionIfNeeded()
        let s2 = await h.engine.currentSession()
        XCTAssertEqual(s2?.accessToken, "at-1")
        // Nothing token-like in the activity log.
        let snap = await h.snapshot()
        XCTAssertFalse(snap.activity.contains { $0.detail.contains("rt-") || $0.detail.contains("at-1") })
        endpoint.server.stop()
    }

    func testRefusedRenewalEndsTheSessionCleanly() async throws {
        let endpoint = TokenEndpoint()
        let url = try endpoint.start()
        let h = try Harness()
        defer { Task { await h.tearDown() } }
        try await h.start()
        try await h.engine.storeSession(ConnectSession(accessToken: "at-0", refreshToken: "rt-revoked", expiresAt: h.clock.now().addingTimeInterval(30),
                                                       tokenEndpoint: url.absoluteString, clientID: "test-client"), env: "development")
        await h.engine.renewSessionIfNeeded()
        let s = await h.engine.currentSession()
        XCTAssertNil(s, "a refused renewal must clear the session")
        XCTAssertNil(try h.secrets.read("session-token.development"))
        let snap = await h.snapshot()
        XCTAssertNil(snap.account)
        XCTAssertTrue(snap.activity.contains { $0.title == "HCG session ended" })
        let d = await h.engine.checkPermission(.devicesEnroll)
        XCTAssertEqual(d.reason, "not_signed_in")
        endpoint.server.stop()
    }

    func testOutageDuringRenewalKeepsTheCurrentToken() async throws {
        let h = try Harness()
        defer { Task { await h.tearDown() } }
        try await h.start()
        try await h.engine.storeSession(ConnectSession(accessToken: "at-0", refreshToken: "rt-1", expiresAt: h.clock.now().addingTimeInterval(30),
                                                       tokenEndpoint: "http://127.0.0.1:9/token", clientID: "test-client"), env: "development")
        await h.engine.renewSessionIfNeeded()
        let s = await h.engine.currentSession()
        XCTAssertEqual(s?.accessToken, "at-0")
        let snap = await h.snapshot()
        XCTAssertTrue(snap.activity.contains { $0.title == "HCG session renewal postponed" })
    }

    func testLegacyBareTokenStillLoads() {
        XCTAssertEqual(ConnectSession.decode(Data("hcgdev_tok_abc".utf8))?.accessToken, "hcgdev_tok_abc")
        XCTAssertNil(ConnectSession.decode(Data()))
    }

    func testProductionTokenEndpointMustBeHTTPS() async {
        HCGConnectPKCE.allowLoopbackHTTPForTesting = false
        do {
            _ = try await HCGConnectPKCE.refresh(refreshToken: "x", tokenEndpoint: "http://127.0.0.1:1/token", clientID: "c")
            XCTFail("non-https token endpoint must be refused")
        } catch {}
    }
}
