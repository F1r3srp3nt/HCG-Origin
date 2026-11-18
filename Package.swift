// swift-tools-version:5.9
// HCG Origin — macOS gateway for HCG Connector device enrollment.
//
//   HCGOrigin                  macOS app (SwiftUI). macOS only.
//   HCGOriginProtocol          wire contract: invitations, signed envelopes, replay
//                              protection, capability catalogue, proposed central contract.
//   HCGHTTP                    small portable HTTP/1.1 server + client helpers.
//   HCGOriginCore              gateway engine, persistence, secrets, central client.
//   HCGCentralDevKit           LOCAL DEVELOPMENT stand-in for central HCG/ERP (not HCG).
//   ConnectorTestKit           DEVELOPMENT TEST CLIENT for the protocol (not the Connector app).
//
// On macOS everything uses Apple's CryptoKit and has no third-party dependencies.
// On Linux (used only for fast development checks of the non-UI code) the
// API-compatible swift-crypto package stands in for CryptoKit.
import PackageDescription

var packageDependencies: [Package.Dependency] = []
var cryptoDependency: [Target.Dependency] = []
#if os(Linux)
packageDependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0"))
cryptoDependency.append(.product(name: "Crypto", package: "swift-crypto"))
#endif

var products: [Product] = [
    .executable(name: "hcg-central-devservice", targets: ["hcg-central-devservice"]),
    .executable(name: "hcg-connector-testclient", targets: ["hcg-connector-testclient"]),
]

var targets: [Target] = [
    .target(name: "HCGOriginProtocol", dependencies: cryptoDependency, path: "Sources/HCGOriginProtocol"),
    .target(name: "HCGHTTP", path: "Sources/HCGHTTP"),
    .target(name: "HCGOriginCore", dependencies: ["HCGOriginProtocol", "HCGHTTP"], path: "Sources/HCGOriginCore"),
    .target(name: "HCGCentralDevKit", dependencies: ["HCGOriginProtocol", "HCGHTTP"], path: "Sources/HCGCentralDevKit"),
    .target(name: "ConnectorTestKit", dependencies: ["HCGOriginProtocol", "HCGHTTP"], path: "Sources/ConnectorTestKit"),
    .executableTarget(name: "hcg-central-devservice", dependencies: ["HCGCentralDevKit"], path: "Sources/hcg-central-devservice"),
    .executableTarget(name: "hcg-connector-testclient", dependencies: ["ConnectorTestKit"], path: "Sources/hcg-connector-testclient"),
    .testTarget(name: "HCGOriginProtocolTests", dependencies: ["HCGOriginProtocol"], path: "Tests/HCGOriginProtocolTests"),
    .testTarget(
        name: "HCGOriginCoreTests",
        dependencies: ["HCGOriginCore", "HCGCentralDevKit", "ConnectorTestKit", "HCGHTTP"],
        path: "Tests/HCGOriginCoreTests"
    ),
]

#if os(macOS)
products.insert(.executable(name: "HCGOrigin", targets: ["HCGOrigin"]), at: 0)
targets.append(.executableTarget(
    name: "HCGOrigin",
    dependencies: ["HCGOriginCore"],
    path: "Sources/HCGOrigin"
    // Brand images are copied into Contents/Resources by scripts/build-macos-app.sh
    // (SwiftPM resource bundles do not belong at the root of a signed .app).
    // The UI-automation hooks used for CI screenshots exist only in builds made with
    // -Xswiftc -DHCG_UI_AUTOMATION; release builds never contain them.
))
#endif

let package = Package(
    name: "HCGOrigin",
    platforms: [.macOS(.v13)],
    products: products,
    dependencies: packageDependencies,
    targets: targets
)
