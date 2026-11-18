import Foundation
import HCGCentralDevKit

// hcg-central-devservice — LOCAL DEVELOPMENT stand-in for central HCG / ERP.
// Not HCG. Implements the PROPOSED HCG Origin central contract on 127.0.0.1 only.

var args = Array(CommandLine.arguments.dropFirst())
func take(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
if args.contains("--help") || args.contains("-h") {
    print("""
    hcg-central-devservice [--port 47800] [--state <file>] [--admin-token-file <file>] [--enrollment-ttl <seconds>]

    LOCAL DEVELOPMENT SERVICE — NOT HCG, NOT ERP.
    Open http://127.0.0.1:<port>/ to approve, reject or revoke as the development approver.
    """)
    exit(0)
}
let port = UInt16(take("--port") ?? "47800") ?? 47_800
let defaultState: URL = {
    #if os(macOS)
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return base.appendingPathComponent("HCG Origin Development Service/state.json")
    #else
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/hcg-origin-devservice/state.json")
    #endif
}()
let stateURL = take("--state").map { URL(fileURLWithPath: $0) } ?? defaultState
let tokenFile = take("--admin-token-file")
let ttl = take("--enrollment-ttl").flatMap(Double.init)

let service = DevCentralService(port: port, stateURL: stateURL)
if let ttl { service.enrollmentTTL = ttl }
do {
    let bound = try service.start()
    if let tokenFile {
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: tokenFile).deletingLastPathComponent(), withIntermediateDirectories: true)
        try service.adminToken.write(toFile: tokenFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile)
    }
    print("""
    ================================================================
     LOCAL DEVELOPMENT SERVICE — NOT HCG, NOT ERP
     Stand-in for central HCG so HCG Origin can be tested on this Mac.
     Its decisions are development results, not HCG verification.
    ================================================================
     Approver page:  http://127.0.0.1:\(bound)/
     API base:       http://127.0.0.1:\(bound)/api/public/origin/v1   (proposed contract)
     State file:     \(stateURL.path)
     Admin token:    \(tokenFile.map { "written to \($0)" } ?? "embedded in the approver page (loopback only)")
     Stop with Ctrl-C.
    """)
    fflush(stdout)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler { service.stop(); print("stopped"); exit(0) }
    s.resume()
    return s
}
_ = sources
dispatchMain()
