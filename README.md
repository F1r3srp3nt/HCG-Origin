<img width="2172" height="724" alt="image" src="https://github.com/user-attachments/assets/330c40ca-eb66-439f-bdbe-1dd47d4e4cd9" />




# HCG Origin

**HCG Origin** is the native macOS gateway of the HCG ecosystem. It receives device-connection
requests from **HCG Connector**, forwards them to central HCG for verification and admission
through **ERP**, and manages the connections that ERP permits.

> Status: development build `0.1.0`, first milestone. One complete enrollment flow works end to end
> against a clearly labelled **local development service**. Production enrollment is unavailable
> until HCG issues Origin's HCG Connect registration and implements the central Origin API
> (see [docs/CENTRAL-HANDOFF.md](docs/CENTRAL-HANDOFF.md)). Not notarized.

## Responsibilities

| Component | Role |
|---|---|
| HCG Connector | Device-side connection and enrollment |
| **HCG Origin** | macOS gateway and connection-management interface |
| HCG Connect | Identity and sign-in |
| Main HCG / ERP | Device admission, ownership, permissions, revocation |
| Nexus | User-facing workspace |
| Agent Runtime | Separately authorised task execution — **enrollment never grants command execution** |

## The first connection flow

1. You press **Start Pairing** in Origin.
2. Origin shows a short-lived (5 min), single-use invitation as a code and QR code.
3. A Connector client uses it to send a signed enrollment request.
4. Origin verifies it locally (signature, invitation proof, freshness, gateway binding), shows it
   under **Connection Requests**, and forwards it to the central service.
5. Central verifies the account and the device's own signature; the authorised person approves or rejects in ERP.
6. Origin shows the result and accepts only the granted capabilities from that device.
7. Revocation in ERP is picked up on the next sync; Origin then rejects every request from that device.

Possessing an invitation or knowing a device name is never approval.

## Quick start on your Mac (Apple silicon)

Requirements: macOS 13+, Xcode or the Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/F1r3srp3nt/HCG-Origin.git && cd HCG-Origin && git checkout claude/wonderful-galileo-ovhpbi
```

```bash
./scripts/build-macos-app.sh
```

```bash
open "build/release/HCG Origin.app"
```

To run the whole verified scenario (build, tests, real app driven end to end, screenshots):

```bash
./scripts/verify-on-mac.sh
```

Step-by-step manual testing with the development service and test client:
[docs/SETUP-AND-VERIFY.md](docs/SETUP-AND-VERIFY.md).

## Documentation

| Document | Contents |
|---|---|
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | Pairing transport decision, identities, signed messages, invitation expiry, replay protection, endpoints |
| [docs/CENTRAL-HANDOFF.md](docs/CENTRAL-HANDOFF.md) | Handoff to the main HCG project: login registration, gateway/device registration, enrollment, ownership, revocation, audit |
| [docs/SETUP-AND-VERIFY.md](docs/SETUP-AND-VERIFY.md) | Build, run, manual and scripted verification |
| [docs/STATUS.md](docs/STATUS.md) | What is implemented, verified, development-only, and still blocked |
| [docs/EXISTING-WORK.md](docs/EXISTING-WORK.md) | What was reused from HCG Server, Connect, ERP, Nexus, Terminal |

## Repository layout

```
Sources/HCGOrigin/              macOS app (SwiftUI)
Sources/HCGOriginCore/          gateway engine, persistence, Keychain/Secure Enclave identity, central client
Sources/HCGOriginProtocol/      wire contract: invitations, signed envelopes, replay guard, capabilities, central contract
Sources/HCGHTTP/                small portable HTTP/1.1 server and client
Sources/HCGCentralDevKit/       LOCAL DEVELOPMENT SERVICE (stand-in for central HCG/ERP — not HCG)
Sources/ConnectorTestKit/       DEVELOPMENT TEST CLIENT (not the HCG Connector app)
Sources/hcg-central-devservice/ command-line entry for the development service
Sources/hcg-connector-testclient/ command-line entry for the test client
Tests/                          protocol unit tests and end-to-end enrollment tests
scripts/                        build-macos-app.sh, verify-on-mac.sh
Resources/                      Info.plist template, brand assets
```
