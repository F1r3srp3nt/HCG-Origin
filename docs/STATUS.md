# HCG Origin — status (milestone 1)

Date: 18 Nov 2026 · version 0.1.0

## Evidence

| Where | What ran | Result |
|---|---|---|
| Linux container (development) and GitHub Actions `ubuntu-latest` | `swift test`: 9 protocol tests + 13 end-to-end enrollment tests over real loopback sockets (gateway engine ↔ local development service ↔ Connector test client) | PASS |
| GitHub Actions `macos-latest` (Apple silicon) | `scripts/verify-on-mac.sh`: build release + UI-automation app, `swift test`, LaunchServices launch of the release app, full scenario driven through the real app, screenshots | **PASS** — run [44390315988](https://github.com/F1r3srp3nt/HCG-Origin/actions/runs/44390315988), commit `bc5d0be7e9ff` (build 9; earlier pass: run 44388967092), macOS 26.7.2 on Apple M1 (virtual), Xcode 26.6 / Swift 6.3.3. all 24 checks passed ([report](screenshots/VERIFICATION-REPORT.md)); 14 [screenshots](screenshots/) of the actual app |
| Your MacBook Pro | `scripts/verify-on-mac.sh` and the manual walk-through in SETUP-AND-VERIFY.md | **NOT RUN** — no Mac was attached to this session |

Mac run details (what was exercised in the real app): release app launched through LaunchServices and
started its gateway; production pairing shown as unavailable with the missing items; development sign-in
and a centrally issued gateway ID; Start Pairing → test-client enrollment with matching check code and
`agent.execute` refused → approval (presence + status report) → client learns the grant with execution not
authorised → connected; rejection; expired invitation; duplicate enrollment (`already_enrolled`); central
outage (pairing disabled, requests kept) and recovery; disconnect after the timeout and reconnect; ERP
revocation reflected and the next connection refused (`device_revoked`); background setting with menu bar
status; no invitation secret or session token in Origin's data folder or log.

Every enrollment result above came from the **local development service, not HCG**. Production HCG
verification has **not** been exercised by anyone: nothing has been issued (see CENTRAL-HANDOFF.md).

## Implemented

| Area | State |
|---|---|
| macOS app: Overview, Connection Requests, Devices, Activity, Account & Settings | Implemented; real state only (no simulated devices); development results labelled everywhere |
| Pairing: explicit Start Pairing, single-use invitation, 5 min default (1–15), code + QR + countdown | Implemented, tested |
| Transport `hcg-origin/1`: HTTP, loopback by default, LAN opt-in, signed requests and responses | Implemented, tested (LAN mode not exercised with a second physical device) |
| Device identity (P-256, fingerprint = SHA-256 SPKI), gateway identity (Secure Enclave when available, else Keychain) | Implemented; the CI Apple-silicon VM created the gateway key in the **Secure Enclave** (shown in Settings) |
| Replay protection (±120 s, nonce memory, method/path/body binding, response bound to request nonce) | Implemented, tested |
| Invitation proof by HMAC (secret never sent, hash-only storage, 5 failures cancel) | Implemented, tested |
| Forwarding to central, retries with back-off during outages | Implemented, tested against the development service |
| Decision retrieval, approval with capability subset, rejection, expiry | Implemented, tested (development service) |
| Duplicate enrollment (pending / already enrolled) | Implemented, tested |
| Permitted connection (heartbeat), disconnect after 35 s, reconnect | Implemented, tested |
| Revocation (central) and local block, enforced per request, audit events to central | Implemented, tested (development service) |
| Execution never granted by enrollment (refused at Origin, refused by central, stripped from grants) | Implemented, tested |
| Secrets in Keychain; no codes/secrets/tokens in logs or state | Implemented; checked by the Mac verification script |
| Background operation (explicit setting, menu bar status), open at login (SMAppService) | Implemented; open-at-login not exercised (needs the app in /Applications) |
| HCG Connect PKCE sign-in | Implemented but **unavailable**: no client ID, redirect or central API issued |
| Development service (`hcg-central-devservice`) with approver page | Implemented, labelled "not HCG, not ERP" |
| Connector development test client (`hcg-connector-testclient`) | Implemented, labelled "not the HCG Connector app" |

## Blockers and remaining work

1. **Production enrollment** — blocked on D-O1…D-O6 (CENTRAL-HANDOFF.md §9): product ID, HCG Connect client
   (production + development), central Origin API, ERP decision workflow, tables, revocation.
2. **HCG Connector app** — no repository or specification found; Connector must implement docs/PROTOCOL.md §9.
3. **On your Mac** — run `scripts/verify-on-mac.sh`; check Secure Enclave key storage, Keychain prompts,
   Gatekeeper on a downloaded build, VoiceOver/keyboard navigation, LAN pairing with a second device.
4. **Transport confidentiality** — milestone 1 signs but does not encrypt; `hcg-origin/2` should add pinned mutual TLS
   (HCG Server Device Link model).
5. **Distribution** — Developer ID signing and notarization not set up.
6. **Repository visibility** — `F1r3srp3nt/HCG-Origin` is currently **public**; the request was to keep it private.
   Changing visibility is a repository-settings action this session cannot perform.
7. **Official icon** — the app icon and wordmark are derived from the approved HCG mark; no official Origin icon exists.
