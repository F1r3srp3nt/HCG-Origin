import XCTest
@testable import HCGOriginProtocol

final class ProtocolTests: XCTestCase {
    let gateway = SoftwareSigner()
    let device = SoftwareSigner()

    func payload(expiresIn: TimeInterval = 300) -> InvitationPayload {
        InvitationPayload(invitationId: "inv_test", secret: InvitationCode.newSecret(), gatewayFingerprint: gateway.fingerprint,
                          gatewayName: "Test Gateway", address: "127.0.0.1:47700",
                          expiresAt: Int64(Date().addingTimeInterval(expiresIn).timeIntervalSince1970), environment: "development",
                          transport: InvitationTransport.tls13Pinned, tlsFingerprint: SoftwareSigner().fingerprint)
    }

    func testInvitationRoundTripAndWhitespaceTolerance() throws {
        let p = payload()
        let code = try InvitationCode.encode(p)
        XCTAssertTrue(code.hasPrefix("hcgo2-"))
        let wrapped = String(code.prefix(20)) + "\n  " + String(code.dropFirst(20))
        XCTAssertEqual(try InvitationCode.decode(wrapped), p)
        XCTAssertNoThrow(try InvitationCode.validate(p))
    }

    func testInvitationRejectsWrongPrefixCorruptionAndExpiry() throws {
        XCTAssertThrowsError(try InvitationCode.decode("hcg1-abc")) { XCTAssertEqual($0 as? InvitationError, .wrongPrefix) }
        XCTAssertThrowsError(try InvitationCode.decode("hcgo2-!!!")) { XCTAssertEqual($0 as? InvitationError, .corrupted) }
        XCTAssertThrowsError(try InvitationCode.decode("hcgo1-eyJ2IjoxfQ")) { XCTAssertEqual($0 as? InvitationError, .wrongPrefix) }
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

    // MARK: hcg-origin/2 transport rules

    func testInvitationTransportRules() throws {
        // TLS requires a valid pin.
        var noPin = payload()
        noPin.tlsFingerprint = nil
        XCTAssertThrowsError(try InvitationCode.decode(try InvitationCode.encode(noPin))) { XCTAssertEqual($0 as? InvitationError, .incomplete) }
        // Cleartext is accepted only for 127.0.0.1 in development, without a pin.
        var clear = payload()
        clear.transport = InvitationTransport.cleartextLoopbackDevelopment
        clear.tlsFingerprint = nil
        XCTAssertNoThrow(try InvitationCode.decode(try InvitationCode.encode(clear)))
        var lan = clear
        lan.address = "192.168.1.20:47700"
        XCTAssertThrowsError(try InvitationCode.decode(try InvitationCode.encode(lan))) { XCTAssertEqual($0 as? InvitationError, .insecureTransport) }
        var prod = clear
        prod.environment = "production"
        XCTAssertThrowsError(try InvitationCode.decode(try InvitationCode.encode(prod))) { XCTAssertEqual($0 as? InvitationError, .insecureTransport) }
        var unknown = payload()
        unknown.transport = "tls12"
        XCTAssertThrowsError(try InvitationCode.decode(try InvitationCode.encode(unknown))) { XCTAssertEqual($0 as? InvitationError, .insecureTransport) }
    }

    func testSelfSignedCertificateIsValidAndCarriesThePinnedKey() throws {
        let key = SoftwareSigner()
        let der = try X509SelfSigned.make(spkiDER: key.publicKeyDER, commonName: "HCG Origin TLS (test)",
                                          serial: Encoding.randomBytes(16), notBefore: Date(), notAfter: Date().addingTimeInterval(86_400)) {
            try key.sign($0)
        }
        // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
        let outer = try XCTUnwrap(DER.children(of: der))
        XCTAssertEqual(outer.count, 3)
        let tbs = outer[0]
        let sigBits = outer[2]
        XCTAssertEqual(sigBits.first, 0x03)
        let signature = Data(try XCTUnwrap(DER.content(of: sigBits)).dropFirst()) // drop "unused bits" byte
        XCTAssertTrue(SignatureVerifier.verify(signatureDER: signature, message: tbs, publicKeyDER: key.publicKeyDER),
                      "the TBSCertificate must be signed by the certified key")
        XCTAssertNotNil(der.range(of: key.publicKeyDER), "the certificate must contain the pinned SPKI")
    }
}

/// Minimal DER reader for the tests.
enum DER {
    static func header(_ d: Data, at i: Int) -> (contentStart: Int, length: Int)? {
        guard i + 1 < d.count else { return nil }
        let b = d[d.startIndex + i + 1]
        if b < 0x80 { return (i + 2, Int(b)) }
        let n = Int(b & 0x7f)
        guard n > 0, n <= 4, i + 2 + n <= d.count else { return nil }
        var len = 0
        for k in 0..<n { len = (len << 8) | Int(d[d.startIndex + i + 2 + k]) }
        return (i + 2 + n, len)
    }
    static func content(of tlv: Data) -> Data? {
        guard let h = header(tlv, at: 0) else { return nil }
        return Data(tlv[(tlv.startIndex + h.contentStart)..<(tlv.startIndex + h.contentStart + h.length)])
    }
    static func children(of tlv: Data) -> [Data]? {
        guard let body = content(of: tlv) else { return nil }
        var out: [Data] = []
        var i = 0
        while i < body.count {
            guard let h = header(body, at: i) else { return nil }
            let end = h.contentStart + h.length
            out.append(Data(body[(body.startIndex + i)..<(body.startIndex + end)]))
            i = end
        }
        return out
    }
}
