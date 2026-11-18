# Existing HCG work reviewed for Origin (18 Nov 2026)

| Repository / document | What it contains | Reused in Origin |
|---|---|---|
| `F1r3srp3nt/HCG-Server` (`docs/SECURITY.md`, `internal/pairing`, `contracts/v1`, `macos/HCGServerApp`) | Device Link pairing: P-256 device keys in Keychain, SHA-256-of-SPKI fingerprints, single-use expiring invitation codes (`hcg1-…`, hash-only storage, 5 failed secrets cancel), owner fingerprint approval, pinned mutual TLS, per-request revocation; SwiftUI shell; macOS CI on `macos-latest` with launch smoke tests | Fingerprint definition, invitation model (single use, hash-only, failure limit, expiry), "discovery is not trust", verification-level wording, theme palette, CI approach. Origin adds central (ERP) admission instead of local owner approval, an HMAC proof instead of sending the secret, and message signatures instead of mTLS for milestone 1 |
| `hakmicapitalgroup` `docs/hcg-server/device-link-handoff.md`, `registry-review.sql`, `src/lib/devicelink-contract.ts` | Device Link product mapping `hcg.server` / `devicelink.*` (PROPOSED there), `/check` semantics, `actions.request` permanently disabled | Fail-closed handling, "execution never via enrollment", labels and decision format of the handoff |
| `hakmicapitalgroup` `docs/hcg-connect/*` (shared-product-access, ai-native-login-handoff, public config) | HCG Connect: public PKCE S256 clients, scopes `openid email profile`, audience `authenticated`, Owner registration through ERP → App Integrations, `configured_untested` until verified, no revocation endpoint, never invent client IDs | PKCE flow, configuration keys in Info.plist, empty values until issued, registration request in the handoff |
| `hakmicapitalgroup` ecosystem API (`/api/public/ecosystem/v1/me`, `/check`, `/access`, `/audit`) | Account, organisations, three-layer access evaluator, app audit endpoint | Referenced for ownership/permission design; not called by Origin yet (no Origin client issued) |
| `hakmicapitalgroup` ERP (`erp_requests`, `erp_decide_request`, App Access, `eco_*`) | Approval workflow and licence/permission tables; **no device, gateway or enrollment tables** | Proposed `device_enrollment` ERP request type and new tables in the handoff |
| `HCG-Nexus` | iOS command panel / workspace; docs say HCG Connect and ERP are the authority | Responsibility split; no pairing code to reuse in the local clone (a Device Link client exists only on an unmerged Nexus branch referenced by HCG Repo) |
| `HCG-Terminal` | SSH-based remote links; HCG Connect not integrated | Theme colours only |
| `HCG-Repo` `branding/` | Approved "HCG REPO" icon master (chrome HCG letters, cyan octagon) | Chrome "HCG" letters cropped for Origin's wordmark and placeholder icon |
| `Agent-Runtime` | README only | Nothing to reuse; execution stays out of enrollment |

**Not found anywhere accessible:** an HCG Connector repository or specification, a "Device Link"
document beyond the HCG Server handoff, any mention of "HCG Origin". Origin therefore defines the
Connector-facing protocol (`docs/PROTOCOL.md`) and ships only a labelled development test client.
