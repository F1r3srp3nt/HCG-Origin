import XCTest
@testable import HCGOriginProtocol

final class ProtocolTests: XCTestCase {
    let gateway = SoftwareSigner()
    let device = SoftwareSigner()

    func payload(expiresIn: TimeInterval = 300) -> InvitationPayload {
        InvitationPayload(invitationId: "inv_test", secret: InvitationCode.newSecret(), gatewayFingerprint: gateway.fingerprint,
                          gatewayName: "Test Gateway", address: "127.0.0.1:47700",
                          expiresAt: Int64(Date().addingTimeInterval(expiresIn).timeIntervalSince1970), environment: "development")
    }

    func testInvitationRoundTripAndWhitespaceTolerance() throws {
        let p = payload()
        let code = try InvitationCode.encode(p)
        XCTAssertTrue(code.hasPrefix("hcgo1-"))
        let wrapped = String(code.prefix(20)) + "\n  " + String(code.dropFirst(20))
        XCTAssertEqual(try InvitationCode.decode(wrapped), p)
        XCTAssertNoThrow(try InvitationCode.validate(p))
    }

    func testInvitationRejectsWrongPrefixCorruptionAndExpiry() throws {
        XCTAssertThrowsError(try InvitationCode.decode("hcg1-abc")) { XCTAssertEqual($0 as? InvitationError, .wrongPrefix) }
        XCTAssertThrowsError(try InvitationCode.decode("hcgo1-!!!")) { XCTAssertEqual($0 as? InvitationError, .corrupted) }
        var bad = payload()
        bad.gatewayFingerprint = "abc"
        XCTAssertThrowsError(try InvitationCode.decode(try InvitationCode.encode(bad))) { XCTAssertEqual($0 as? InvitationError, .incomplete) }
        XCTAssertThrowsError(try InvitationCode.validate(payload(expiresIn: -1))) { XCTAssertEqual($0 as? InvitationError, .expired) }
    }

    func testSecretIsStoredOnlyAsHashAndProofBindsRequest() {
        let secret = InvitationCode.newSecret()
        XCTAssertFalse(InvitationCode.hashSecret(secret).contains(secret))
        let input = Data("request-1".utf8)
        let proof = InvitationCode.proof(secret: secret, invitationId: "inv_a", signingInput: input)
        XCTAssertTrue(InvitationCode.verifyProof(proof, secret: secret, invitationId: "inv_a", signingInput: input))
        XCTAssertFalse(InvitationCode.verifyProof(proof, secret: secret, invitationId: "inv_b", signingInput: input))
        XCTAssertFalse(InvitationCode.verifyProof(proof, secret: secret, invitationId: "inv_a", signingInput: Data("request-2".utf8)))
        XCTAssertFalse(InvitationCode.verifyProof(proof, secret: InvitationCode.newSecret(), invitationId: "inv_a", signingInput: input))
    }

    func testRequestSignatureCoversMethodPathAndBody() throws {
        let body = Data("{\"a\":1}".utf8)
        let headers = try SignedEnvelope.signRequest(method: "POST", path: OriginPath.heartbeat, body: body, signer: device)
        let auth = try XCTUnwrap(SignedEnvelope.parseRequestAuth(headers: headers))
        func verifies(_ path: String, _ body: Data) -> Bool {
            let input = RequestSigningInput(method: "POST", path: path, timestamp: auth.timestamp, nonce: auth.nonce,
                                            keyFingerprint: auth.keyFingerprint, body: body)
            return SignatureVerifier.verify(signatureDER: auth.signature, message: input.bytes, publicKeyDER: device.publicKeyDER)
        }
        XCTAssertTrue(verifies(OriginPath.heartbeat, body))
        XCTAssertFalse(verifies(OriginPath.enroll, body))
        XCTAssertFalse(verifies(OriginPath.heartbeat, Data("{\"a\":2}".utf8)))
        let other = SoftwareSigner()
        let input = RequestSigningInput(method: "POST", path: OriginPath.heartbeat, timestamp: auth.timestamp, nonce: auth.nonce,
                                        keyFingerprint: auth.keyFingerprint, body: body)
        XCTAssertFalse(SignatureVerifier.verify(signatureDER: auth.signature, message: input.bytes, publicKeyDER: other.publicKeyDER))
    }

    func testResponseIsBoundToRequestNonceAndPinnedKey() throws {
        let body = Data("{}".utf8)
        let headers = try SignedEnvelope.signResponse(status: 200, body: body, requestNonce: "nonce-aaaaaaaaaaaaaaaa", signer: gateway)
        XCTAssertTrue(SignedEnvelope.verifyResponse(status: 200, headers: headers, body: body, expectedRequestNonce: "nonce-aaaaaaaaaaaaaaaa",
                                                    pinnedFingerprint: gateway.fingerprint, publicKeyDER: gateway.publicKeyDER))
        XCTAssertFalse(SignedEnvelope.verifyResponse(status: 200, headers: headers, body: body, expectedRequestNonce: "nonce-bbbbbbbbbbbbbbbb",
                                                     pinnedFingerprint: gateway.fingerprint, publicKeyDER: gateway.publicKeyDER))
        XCTAssertFalse(SignedEnvelope.verifyResponse(status: 403, headers: headers, body: body, expectedRequestNonce: "nonce-aaaaaaaaaaaaaaaa",
                                                     pinnedFingerprint: gateway.fingerprint, publicKeyDER: gateway.publicKeyDER))
        let impostor = SoftwareSigner()
        let forged = try SignedEnvelope.signResponse(status: 200, body: body, requestNonce: "nonce-aaaaaaaaaaaaaaaa", signer: impostor)
        XCTAssertFalse(SignedEnvelope.verifyResponse(status: 200, headers: forged, body: body, expectedRequestNonce: "nonce-aaaaaaaaaaaaaaaa",
                                                     pinnedFingerprint: gateway.fingerprint, publicKeyDER: impostor.publicKeyDER))
    }

    func testReplayGuard() {
        let g = ReplayGuard()
        let now = Date()
        let ts = Int64(now.timeIntervalSince1970)
        XCTAssertEqual(g.check(keyFingerprint: "k", nonce: "n1", timestamp: ts, now: now), .fresh)
        XCTAssertEqual(g.check(keyFingerprint: "k", nonce: "n1", timestamp: ts, now: now), .replayed)
        XCTAssertEqual(g.check(keyFingerprint: "k2", nonce: "n1", timestamp: ts, now: now), .fresh)
        XCTAssertEqual(g.check(keyFingerprint: "k", nonce: "n2", timestamp: ts - 121, now: now), .stale)
        XCTAssertEqual(g.check(keyFingerprint: "k", nonce: "n3", timestamp: ts + 121, now: now), .stale)
    }

    func testExecutionIsNeverForwarded() {
        let (forward, refused) = Capability.screen([Capability.presence, Capability.execution, "agent.shell", "made.up", Capability.presence])
        XCTAssertEqual(forward, [Capability.presence])
        XCTAssertEqual(Set(refused.map(\.capability)), [Capability.execution, "agent.shell", "made.up"])
        XCTAssertEqual(refused.first { $0.capability == Capability.execution }?.reason, "execution_requires_agent_runtime")
        XCTAssertFalse(Capability.isEnrollable(Capability.execution))
    }

    func testCheckCodeIsStableSixDigits() {
        let a = PairingCheckCode.compute(gatewayFingerprint: gateway.fingerprint, deviceFingerprint: device.fingerprint, invitationId: "inv_1")
        XCTAssertEqual(a, PairingCheckCode.compute(gatewayFingerprint: gateway.fingerprint, deviceFingerprint: device.fingerprint, invitationId: "inv_1"))
        XCTAssertNotEqual(a, PairingCheckCode.compute(gatewayFingerprint: gateway.fingerprint, deviceFingerprint: device.fingerprint, invitationId: "inv_2"))
        XCTAssertNotNil(a.range(of: "^[0-9]{3} [0-9]{3}$", options: .regularExpression))
    }

    func testFingerprintIsSHA256OfSPKI() {
        XCTAssertEqual(device.fingerprint, Encoding.sha256Hex(device.publicKeyDER))
        XCTAssertTrue(KeyFingerprint.isValid(device.fingerprint))
        XCTAssertEqual(KeyFingerprint.short(device.fingerprint).count, 19)
    }
}
