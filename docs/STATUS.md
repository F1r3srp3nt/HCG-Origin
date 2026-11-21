# HCG Origin — status

Version **0.3.0** · contract revision `hcg-origin-contract/3` (Connector protocol `hcg-origin/2` unchanged,
central API `hcg-origin-central/1` PROPOSED, Origin feature keys PROPOSED) · 21 Nov 2026.

## What 0.3.0 adds

| Area | State | Details |
|---|---|---|
| “Gateway listener failed” | **Fixed in code; cause on your Mac not observed** (no Mac attached) | Single-instance lock, port owner named, `.waiting` tolerated, automatic retry, *Use a Free Port*, self-test over pinned TLS, diagnostics panel, read-only `scripts/diagnose-gateway.sh`. [GATEWAY-LISTENER.md](GATEWAY-LISTENER.md) |
| Central feature registration (`hcg.origin`) | **PROPOSED, not applied** | 10 operational feature keys, `origin.actions.approve` disabled; reviewable SQL + proposal in the main-site repo, draft PR F1r3srp3nt/hakmicapitalgroup#1. [CENTRAL-HANDOFF.md §13](CENTRAL-HANDOFF.md) |
| Central permission enforcement | IMPLEMENTED-DEV | Every sensitive action calls `/check` for its feature; only `allowed:true` allows; fail closed; execution blocked in the build regardless of central answers |
| HCG Connect production | **Not exercised** — no Origin client exists centrally | Session renewal with refresh tokens, Keychain-only storage, sign-out; production values all empty in this build (5 keys) |
| HCG Server Device Link | **IMPLEMENTED; verified against a real agent with mock identities** | Connect (loopback owner API), invitations, review with fingerprint confirmation, attributed approval, rejection, inventory, revocation, reachability, audit. [Linux record](verification/linux-hcg-server-integration/) |

## Evidence, by environment (kept separate)

| Environment | What ran | Result |
|---|---|---|
| Linux container | `swift test` — 45 tests incl. listener conflict/recovery/self-test, permissions, session renewal, and the 13-step flow against a **real HCG Server agent** (mock identities) | PASS — [record](verification/linux-hcg-server-integration/) |
| **CI: GitHub `macos-latest`** (macOS 26.7.2, Apple M1 virtual) | `scripts/verify-on-mac.sh` incl. a port-conflict step against the real app | 0.3.0: see the latest run on PR F1r3srp3nt/HCG-Origin#1. 0.2.0: PASS, [evidence](verification/ci-macos-26.7.2-apple-m1-virtual-v0.2.0/) |
| CI with HCG Server | — | **NOT RUN**: CI cannot check out the HCG Server repository; `--hcg-server` is for your Mac |
| **Your MacBook Pro M4 Max, macOS 27.0.1** | `diagnose-gateway.sh`, then `verify-on-mac.sh --expect-macos 27.0.1 --expect-chip "M4 Max" [--hcg-server …]` | **NOT RUN** — no Mac attached to this session |

Every enrollment and permission decision in these runs came from the **local development service or HCG Server's
mock identities, not HCG**. Production HCG verification has not been exercised by anyone.

## Encrypted transport (0.2.0)

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

1. **Your Mac** — run `scripts/diagnose-gateway.sh` with the copy that shows the failure (identifies the actual
   cause), then install 0.3.0 and run the verification. The “production configuration is present” you saw does not
   match any build from this repository (all production values are empty); the diagnosis prints what your copy has.
2. **Central registration (Owner)** — apply or adapt `hcg.origin` + the ten features (main-site draft PR); grant
   yourself the features to test; issue the development HCG Connect client (D-O2). Origin has invented none of these.
3. **HCG Connect acceptance** (C2, C11–C13) — needs the development client; until then sign-in, renewal and `/check`
   are verified only against the development service.
4. **`/check` without an organisation** (D-O4) — personal accounts have no `org_id`; central must decide.
5. **Central API `hcg-origin-central/1`** (D-O5) and ERP workflow — unchanged from revision 2.
6. **Origin as a Device Link installation** of HCG Server — needs HCG Server to allow `hcg.origin` and the Origin
   client; today Origin manages the agent on the same Mac through its owner API.
7. **HCG Connector app** — not found; PROTOCOL.md §9 is its checklist.
8. **Distribution** — Developer ID signing and notarization not set up.
9. **Repository visibility** — still public; the request was private (GitHub → Settings).
10. Command execution and remote actions stay disabled (`origin.actions.approve` disabled centrally and in the build;
    HCG Server's action registry empty).
