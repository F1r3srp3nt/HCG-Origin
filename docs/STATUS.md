# HCG Origin — status

Version **0.2.0** · contract revision `hcg-origin-contract/2` (Connector protocol `hcg-origin/2`,
central API `hcg-origin-central/1` PROPOSED) · 21 Nov 2026.

## Evidence, by environment (kept separate)

| Environment | What ran | Result |
|---|---|---|
| Linux container + GitHub `ubuntu-latest` | `swift test`: protocol, contract-drift, and end-to-end enrollment tests over loopback (cleartext development transport — Linux has no TLS server) | PASS — 31 tests |
| **CI: GitHub `macos-latest`** (macOS 26.7.2, Apple M1 virtual, Xcode 26.6) | `scripts/verify-on-mac.sh`: `swift test` incl. real TLS 1.3 tests; release + UI-automation builds; release app via LaunchServices; TLS checks with OpenSSL; full scenario through the real app; preservation and clean-up checks | **PASS** — run [44933222822](https://github.com/F1r3srp3nt/HCG-Origin/actions/runs/44933222822), commit `98b6711dded2`, build 16: 36 tests (incl. 5 real-TLS tests) and every scenario check; [evidence](verification/ci-macos-26.7.2-apple-m1-virtual-v0.2.0/) |
| **Your MacBook Pro M4 Max, macOS 27.0.1** | `./scripts/verify-on-mac.sh --expect-macos 27.0.1 --expect-chip "M4 Max"` | **NOT RUN** — no Mac was attached to this session; macOS 27 is not available on GitHub runners |
| Earlier: CI, 0.1.0 (`hcg-origin/1`) | see `docs/verification/ci-macos-26.7.2-apple-m1-virtual-v0.1.0/` | PASS (superseded) |

Every enrollment decision in any of these runs came from the **local development service, not HCG**.
Production HCG verification has not been exercised by anyone: nothing has been issued (see CENTRAL-HANDOFF.md).

## Encrypted transport (new in 0.2.0)

| Requirement | State |
|---|---|
| TLS 1.3 only, Connector → Origin | Implemented (Network.framework server; URLSession client); TLS 1.2 refused |
| Gateway authenticated by the pairing fingerprint | Invitation `tfp` pins SHA-256 of the certificate SPKI; client accepts nothing else |
| No accept-any fallback | Pin mismatch aborts before any request; unpinned clients fail system trust; Linux client refuses pinned TLS instead of skipping it |
| Signed messages, invitation expiry, replay protection | Retained unchanged; signed responses also carry the TLS fingerprint (channel binding) |
| Local-network pairing | Refuses to start without TLS; admits loopback and private addresses only. Not yet exercised with a second physical device |
| Gateway TLS key | P-256 in the login Keychain, self-signed 10-year certificate; identity key stays in the Secure Enclave |

**Found and fixed by CI:** the first macOS run (44932308046) timed out on the app's TLS port while the TLS unit
tests passed. The verification script's two app instances used Keychain labels where one was a prefix of the other,
and the identity lookup could return the other build's key, whose use stalls on a Keychain access prompt.
Origin now uses an identity only if its certificate subject equals the label exactly, and the script's labels are
distinct; the next run passed.

## Implemented (unchanged from 0.1.0 unless noted)

App sections (Overview, Connection Requests, Devices, Activity, Account & Settings) · explicit Start Pairing,
single-use 5-minute invitations with QR · enrollment forwarding with retries · approval, rejection, expiry,
duplicate handling · heartbeat connection, disconnect/reconnect · revocation and local block · **admission
freshness (new): connections refused when central has not confirmed admission for 15 minutes and after restart** ·
execution never granted · secrets only in the Keychain · background operation with menu bar status · HCG Connect
PKCE code present but unavailable · labelled development service and test client · **contract file with drift test (new)**.

## Blockers and remaining work

1. **Production enrollment** — blocked on D-O1…D-O6 (CENTRAL-HANDOFF.md §11 with recommendations): product ID,
   HCG Connect clients, the central API, ERP workflow, tables, revocation. The development service is not a substitute.
2. **HCG Connector app** — not found; it must implement PROTOCOL.md §9, including TLS pinning.
3. **Your Mac** — run the verification above; LAN pairing with a second device; Gatekeeper on a downloaded build;
   Keychain prompts after rebuilding (one for the session items, one for the TLS key — choose Always Allow).
4. **TLS key rotation** requires re-pairing in this revision.
5. **Distribution** — Developer ID signing and notarization not set up.
6. **Repository visibility** — still public; the request was private (GitHub → Settings).
7. **Official icon** — derived placeholder.
8. Command execution stays disabled at this milestone.
