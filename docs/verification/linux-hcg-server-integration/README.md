# HCG Origin ↔ real HCG Server agent — Linux integration record (0.3.0)

**What this is:** HCG Origin's engine (`HCGOriginCore`, the same code the macOS app runs) driven against a **real HCG
Server agent** over real HTTP and pinned TLS 1.3, by `HCGServerIntegrationTests` in
`Tests/HCGOriginCoreTests/PermissionAndServerTests.swift`. `transcript.txt` is the test's own output.

**What this is not:** a run against production. The agent was started by HCG Server's
`cmd/hcg-devicelink-fixture`, which uses **mock HCG Connect identities and a mock ERP `/check`** (`hcgmock`).
Origin's own central permission checks were answered by Origin's **local development service** (`HCGCentralDevKit`).
No real HCG Connect sign-in, no real ERP and no real device took part. It is also not the macOS app UI — that is
covered by `scripts/verify-on-mac.sh --hcg-server` (see below).

| | |
|---|---|
| Date | 2026-11-21 |
| Host | Linux x86_64 (session container), Swift 6.0.3, Go 1.25.4 |
| HCG Origin | 0.3.0, branch `claude/wonderful-galileo-ovhpbi` |
| HCG Server | `F1r3srp3nt/hcg-server` branch `claude/devicelink-testdevice` @ `88b977a` (= Device Link branch `claude/lucid-mendel-egzyd6` @ `a0b04eb` + the scriptable test device) |
| Device | `cmd/hcg-devicelink-testdevice` — a real Device Link client (own P-256 installation key, pinned TLS, signed requests). Labelled test device, not an HCG app |
| Result | 13/13 steps passed; full Linux suite 45 tests, 0 failures |

## Reproduce

```bash
cd hcg-server   # branch claude/devicelink-testdevice
go build -o /tmp/hcgs/fixture ./cmd/hcg-devicelink-fixture
go build -o /tmp/hcgs/testdevice ./cmd/hcg-devicelink-testdevice
```

```bash
cd HCG-Origin
HCG_SERVER_FIXTURE_BIN=/tmp/hcgs/fixture HCG_DEVICELINK_TESTDEVICE_BIN=/tmp/hcgs/testdevice swift test --filter HCGServerIntegrationTests
```

Without the two variables the test is skipped (it never pretends to have run).

## Steps and what each proves

| # | Step | Requirement covered |
|---|---|---|
| 1 | Origin connects to the agent's owner API; reads device identity, link status; confirms remote actions are **disabled** | HCG Server connectivity, health |
| 2 | Origin creates the invitation (requires `origin.devices.enroll`); a device pairs over pinned TLS 1.3 with signed requests and an HCG token; HCG Server validates | Device requests → HCG Server validates |
| 3 | Origin receives and displays the request with the account HCG Server verified | Origin receives the request |
| 4 | Approval with the wrong fingerprint is refused | Owner must compare the key |
| 5 | Central grant `origin.requests.review` withdrawn → approval refused | Central, revocable permission |
| 6 | Explicit approval, attributed to the signed-in owner (`approved by …`); device online in the inventory | Explicit, attributable approval; inventory |
| 7 | Replay → `replayed_request`; tampered signature → `bad_signature`; action → `action_execution_disabled` | Replay, invalid signatures, execution disabled |
| 8 | A different HCG account tries to pair → `wrong_account` | Unauthorized user |
| 9 | Owner rejects a request → device sees `rejected` | Denial |
| 10 | Agent paused (SIGSTOP) → unreachable; resumed → reachable again | Interruption and recovery |
| 11 | Revocation from Origin → device's next request `device_revoked` | Revoked devices |
| 12 | `gateway.server.*` audit events received centrally (dev service) | Audit |
| 13 | Origin restarts → reconnects from the stored (Keychain/secret store) connection, inventory intact | Restart and persistence |

Expired invitations are covered by HCG Server's own Device Link tests (`invitation_expired`) and, for the Connector
path, by Origin's `EnrollmentFlowTests`.
