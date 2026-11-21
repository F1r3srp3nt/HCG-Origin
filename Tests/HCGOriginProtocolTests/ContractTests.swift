import XCTest
@testable import HCGOriginProtocol

/// docs/contract/hcg-origin-contract-2.json is what the Connector and main HCG teams implement.
/// This test fails if the code and that file drift apart.
final class ContractTests: XCTestCase {
    var contract: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/contract/hcg-origin-contract-2.json")
        let data = try Data(contentsOf: url)
        contract = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func section(_ name: String) -> [String: Any] { contract[name] as? [String: Any] ?? [:] }

    func testVersions() {
        XCTAssertEqual(contract["contract"] as? String, HCGOriginContract.revision)
        let v = section("versions")
        XCTAssertEqual(v["connectorProtocol"] as? String, OriginProtocol.version)
        XCTAssertEqual(v["centralAPI"] as? String, HCGOriginContract.centralAPI)
        XCTAssertEqual(v["capabilityCatalogue"] as? String, HCGOriginContract.capabilityCatalogue)
        XCTAssertEqual(v["invitationCodePrefix"] as? String, InvitationCode.prefix)
        XCTAssertEqual(v["invitationVersion"] as? Int, 2)
    }

    func testTransportHeadersPathsAndBodies() {
        let t = section("transport")
        XCTAssertEqual(t["tls13Pinned"] as? String, InvitationTransport.tls13Pinned)
        XCTAssertEqual(t["cleartextLoopbackDevelopment"] as? String, InvitationTransport.cleartextLoopbackDevelopment)
        let h = section("headers") as? [String: String] ?? [:]
        XCTAssertEqual(h["protocolVersion"], OriginHeader.protocolVersion)
        XCTAssertEqual(h["keyFingerprint"], OriginHeader.keyFingerprint)
        XCTAssertEqual(h["timestamp"], OriginHeader.timestamp)
        XCTAssertEqual(h["nonce"], OriginHeader.nonce)
        XCTAssertEqual(h["signature"], OriginHeader.signature)
        XCTAssertEqual(h["invitationProof"], OriginHeader.invitationProof)
        XCTAssertEqual(h["requestNonce"], OriginHeader.requestNonce)
        XCTAssertEqual(h["publicKey"], OriginHeader.publicKey)
        let p = section("connectorPaths") as? [String: String] ?? [:]
        XCTAssertEqual(p["enroll"], OriginPath.enroll)
        XCTAssertEqual(p["enrollmentStatus"], OriginPath.enrollmentStatus)
        XCTAssertEqual(p["heartbeat"], OriginPath.heartbeat)
        let b = section("bodyTypes") as? [String: String] ?? [:]
        XCTAssertEqual(b["enroll"], EnrollRequestBody.typeValue)
        XCTAssertEqual(b["enrollmentStatus"], EnrollmentStatusRequestBody.typeValue)
        XCTAssertEqual(b["heartbeat"], HeartbeatRequestBody.typeValue)
        let c = section("centralPaths") as? [String: String] ?? [:]
        XCTAssertEqual(c["health"], "GET " + CentralPath.health)
        XCTAssertEqual(c["account"], "GET " + CentralPath.account)
        XCTAssertEqual(c["registerGateway"], "POST " + CentralPath.gateways)
        XCTAssertEqual(c["submitEnrollment"], "POST " + CentralPath.enrollments)
        XCTAssertEqual(c["enrollment"], "GET " + CentralPath.enrollment("{enrollmentId}"))
        XCTAssertEqual(c["gatewayDevices"], "GET " + CentralPath.gatewayDevices("{gatewayId}"))
        XCTAssertEqual(c["gatewayEvents"], "POST " + CentralPath.gatewayEvents("{gatewayId}"))
    }

    func testSigningFormatsAndTiming() {
        let s = section("signing")
        let input = RequestSigningInput(method: "POST", path: "/p", timestamp: 1, nonce: "n", keyFingerprint: "k", body: Data())
        let text = String(decoding: input.bytes, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HCG-ORIGIN-REQUEST-V1\nPOST\n/p\n1\nn\nk\n"))
        XCTAssertTrue((s["requestInput"] as? String ?? "").hasPrefix("HCG-ORIGIN-REQUEST-V1"))
        XCTAssertEqual(s["maxClockSkewSeconds"] as? Int, Int(OriginProtocol.maxClockSkew))
        XCTAssertEqual(s["nonceRetentionSeconds"] as? Int, Int(OriginProtocol.nonceRetention))
        let t = section("timing")
        XCTAssertEqual(t["invitationDefaultSeconds"] as? Int, Int(InvitationCode.defaultTTL))
        XCTAssertEqual(t["invitationMinimumSeconds"] as? Int, Int(InvitationCode.minimumTTL))
        XCTAssertEqual(t["invitationMaximumSeconds"] as? Int, Int(InvitationCode.maximumTTL))
    }

    func testCapabilitiesStatesErrorsAndEvents() {
        let caps = section("capabilities")
        XCTAssertEqual(caps["enrollable"] as? [String], Capability.catalogue.filter(\.enrollable).map(\.id))
        XCTAssertEqual(caps["neverEnrollable"] as? [String], Capability.catalogue.filter { !$0.enrollable }.map(\.id))
        let st = section("states")
        XCTAssertEqual(st["connectorEnrollment"] as? [String], EnrollmentState.allCases.map(\.rawValue))
        XCTAssertEqual(st["centralEnrollment"] as? [String], CentralEnrollmentState.allCases.map(\.rawValue))
        XCTAssertEqual(st["centralDevice"] as? [String], CentralDeviceStatus.allCases.map(\.rawValue))
        XCTAssertEqual(Set(contract["connectorErrorCodes"] as? [String] ?? []), Set(OriginErrorCode.all))
        XCTAssertEqual(Set(contract["centralErrorCodes"] as? [String] ?? []), Set(CentralErrorCode.all))
        XCTAssertEqual(Set(contract["gatewayEventTypes"] as? [String] ?? []), Set(GatewayEventType.all))
    }

    func testEngineEmitsOnlyContractEventTypes() throws {
        let engine = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/HCGOriginCore/GatewayEngine.swift")
        let source = try String(contentsOf: engine, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: "\"(gateway\\.[a-z_.]+)\"")
        let found = Set(regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            Range($0.range(at: 1), in: source).map { String(source[$0]) }
        })
        XCTAssertFalse(found.isEmpty)
        XCTAssertTrue(found.isSubset(of: Set(GatewayEventType.all)), "undocumented event types: \(found.subtracting(GatewayEventType.all))")
    }
}
