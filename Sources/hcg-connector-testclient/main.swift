import Foundation
import ConnectorTestKit
import HCGOriginProtocol

// hcg-connector-testclient — DEVELOPMENT TEST CLIENT for the HCG Origin protocol.
// Not the HCG Connector app.

let usage = """
\(ConnectorTestClient.banner)

Usage:
  hcg-connector-testclient enroll (--code <code> | --code-file <path> | --code -) [--name <device name>]
                                  [--request-execution] [--no-status-report] [--wait] [--profile <name>]
  hcg-connector-testclient status  [--wait] [--profile <name>]
  hcg-connector-testclient connect [--count <n>] [--interval <seconds>] [--profile <name>]
  hcg-connector-testclient show    [--profile <name>]
  hcg-connector-testclient forget  [--profile <name>]

Exit codes: 0 success · 1 error · 2 rejected/expired/refused · 3 revoked or blocked
Prefer --code-file or --code - over --code: command-line arguments are visible to other processes.
"""

var args = Array(CommandLine.arguments.dropFirst())
func take(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
func flag(_ f: String) -> Bool {
    guard let i = args.firstIndex(of: f) else { return false }
    args.remove(at: i)
    return true
}
func out(_ s: String) { print(s); fflush(stdout) }
func fail(_ s: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("error: " + s + "\n").utf8))
    exit(code)
}

guard let command = args.first else { out(usage); exit(1) }
args.removeFirst()
let profileName = take("--profile") ?? "default"
let profileDir: URL = {
    if let explicit = ProcessInfo.processInfo.environment["HCG_CONNECTOR_TESTCLIENT_DIR"], !explicit.isEmpty {
        return URL(fileURLWithPath: explicit).appendingPathComponent(profileName)
    }
    return ConnectorTestClient.defaultProfileDirectory(name: profileName)
}()

func exitCode(for error: Error) -> Int32 {
    if let e = error as? ConnectorTestClient.ClientError, let code = e.code {
        switch code {
        case OriginErrorCode.deviceRevoked, OriginErrorCode.deviceBlocked: return 3
        case OriginErrorCode.invitationExpired, OriginErrorCode.invitationUsed, OriginErrorCode.invitationCancelled,
             OriginErrorCode.alreadyEnrolled, OriginErrorCode.enrollmentPending, OriginErrorCode.invitationUnknown,
             OriginErrorCode.invalidInvitationProof:
            return 2
        default: return 1
        }
    }
    if case ConnectorTestClient.ClientError.invitation = error { return 2 }
    return 1
}

func waitForDecision(_ client: ConnectorTestClient) async -> Int32 {
    var last = ""
    while true {
        do {
            let s = try await client.status()
            let line = "state: \(s.state.rawValue)" + (s.centralState.map { " (central: \($0))" } ?? "") + " — \(s.message)"
            if line != last { out(line); last = line }
            switch s.state {
            case .approved:
                out("issued device ID: \(s.deviceId ?? "?")")
                out("granted: \(s.grant?.capabilities.joined(separator: ", ") ?? "nothing") · execution authorised: \(s.grant?.executionAuthorized == true ? "yes" : "no")")
                if s.environment == "development" { out("NOTE: decided by the LOCAL DEVELOPMENT SERVICE, not by HCG.") }
                return 0
            case .rejected, .expired, .failed: return 2
            default: break
            }
        } catch {
            out("status unavailable: \(error)")
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }
}

func readCode() -> String {
    if let file = take("--code-file") {
        guard let s = try? String(contentsOfFile: file, encoding: .utf8) else { fail("cannot read \(file)") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let c = take("--code") {
        if c == "-" { return (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces) }
        return c
    }
    fail("enroll needs --code, --code-file or --code -")
}

let semaphore = DispatchSemaphore(value: 0)
var finalStatus: Int32 = 0
Task {
    defer { semaphore.signal() }
    do {
        switch command {
        case "enroll":
            let code = readCode()
            let name = take("--name")
            var caps = [Capability.presence]
            if !flag("--no-status-report") { caps.append(Capability.statusReport) }
            if flag("--request-execution") { caps.append(Capability.execution) }
            let wait = flag("--wait")
            out(ConnectorTestClient.banner)
            let client = try ConnectorTestClient(profileDirectory: profileDir, name: name)
            out("device key: \(KeyFingerprint.short(client.fingerprint))  (profile \(profileName))")
            let r = try await client.enroll(code: code, capabilities: caps)
            out("gateway: \(r.gatewayName)  key \(KeyFingerprint.short(r.gatewayFingerprint))  environment \(r.environment)")
            out("request: \(r.requestId)  state \(r.state.rawValue)")
            out("CHECK CODE: \(r.checkCode)   ← must match the code shown in HCG Origin")
            out("forwarded for decision: \(r.forwardedCapabilities.joined(separator: ", "))")
            for refusal in r.refusedCapabilities { out("refused by gateway: \(refusal.capability) — \(refusal.message)") }
            out(r.message)
            if wait { finalStatus = await waitForDecision(client) }
        case "status":
            let client = try ConnectorTestClient(profileDirectory: profileDir)
            if flag("--wait") { finalStatus = await waitForDecision(client) }
            else {
                let s = try await client.status()
                out("state: \(s.state.rawValue) — \(s.message)")
                if let id = s.deviceId { out("device ID: \(id)") }
                if [.rejected, .expired, .failed].contains(s.state) { finalStatus = 2 }
            }
        case "connect":
            let count = Int(take("--count") ?? "0") ?? 0
            let interval = Double(take("--interval") ?? "") ?? 0
            let client = try ConnectorTestClient(profileDirectory: profileDir)
            out(ConnectorTestClient.banner)
            var sent = 0
            while count == 0 || sent < count {
                do {
                    let wantsReport = client.profile.grant?.allows(Capability.statusReport) == true
                    let r = try await client.heartbeat(report: wantsReport ? ConnectorTestClient.localStatusReport() : nil)
                    sent += 1
                    out("[\(sent)] \(r.state) · granted \(r.grant.capabilities.joined(separator: ", ")) · next in \(interval > 0 ? interval : Double(r.intervalSeconds)) s")
                    if count != 0 && sent >= count { break }
                    try? await Task.sleep(nanoseconds: UInt64((interval > 0 ? interval : Double(r.intervalSeconds)) * 1_000_000_000))
                } catch let e as ConnectorTestClient.ClientError {
                    let code = exitCode(for: e)
                    if code == 3 || e.code == OriginErrorCode.unknownDevice || e.code == OriginErrorCode.capabilityNotGranted {
                        out("connection refused: \(e)")
                        finalStatus = code == 3 ? 3 : 2
                        return
                    }
                    out("connection failed (will retry): \(e)")
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        case "show":
            let client = try ConnectorTestClient(profileDirectory: profileDir)
            let p = client.profile
            out(ConnectorTestClient.banner)
            out("profile: \(profileDir.path)")
            out("device key: \(client.fingerprint)")
            out("name: \(p.name)")
            out("gateway: \(p.gateway.map { "\($0.name) at \($0.address) (\($0.environment)) key \(KeyFingerprint.short($0.fingerprint))" } ?? "none")")
            out("request: \(p.requestId ?? "none")  check code: \(p.checkCode ?? "-")")
            out("device ID: \(p.deviceId ?? "not issued")  granted: \(p.grant?.capabilities.joined(separator: ", ") ?? "-")")
        case "forget":
            let client = try ConnectorTestClient(profileDirectory: profileDir)
            try client.forget()
            out("Removed the test client profile at \(profileDir.path).")
        default:
            out(usage)
            finalStatus = 1
        }
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        finalStatus = exitCode(for: error)
    }
}
semaphore.wait()
exit(finalStatus)
