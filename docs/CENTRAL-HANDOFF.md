# HCG Origin × main HCG (HCG Connect + ERP) — integration handoff, contract revision 3

**From:** HCG Origin (`F1r3srp3nt/HCG-Origin`, branch `claude/wonderful-galileo-ovhpbi`), 21 Nov 2026.
**For:** the main HCG / Lovable project (`F1r3srp3nt/hakmicapitalgroup`).
**Supersedes:** revision 2 (21 Nov, same day) and revision 1 (18 Nov). **What changed in revision 3:** §13.
No secrets, tokens, client IDs or credentials are in this document or in Origin's build.
When sent on its own, this file travels with `hcg-origin-contract-3.json` (the machine-readable contract) and
Origin's `docs/PROTOCOL.md` is available in the Origin repository.

Labels (as in `docs/hcg-server/device-link-handoff.md`): **SOURCE-VERIFIED** (read in main-site source/docs) ·
**IMPLEMENTED-DEV** (works against Origin's local development service only) · **PROPOSED** (not issued, not
implemented centrally) · **BLOCKED** (needs a decision below) · **RECOMMENDED** (Origin's suggested choice).

## 0. Contract versions (identical in docs/PROTOCOL.md)

| Contract part | Version | Between | Status |
|---|---|---|---|
| Contract revision | `hcg-origin-contract/3` | everyone | this document + PROTOCOL.md + `contract/hcg-origin-contract-3.json` |
| Central API | `hcg-origin-central/1` | Origin ↔ main HCG | **PROPOSED** — to be implemented by main HCG |
| Connector protocol | `hcg-origin/2` | Connector ↔ Origin | implemented in Origin; main HCG verifies one message of it (§4.3) |
| Capability catalogue | `hcg-origin-capabilities/1` | everyone | implemented |

Versioning rules: `GET health` must return `apiVersion: "hcg-origin-central/1"` exactly — Origin refuses any other
value and sends nothing. Additive optional fields are allowed within a version; anything else needs
`hcg-origin-central/2` and a new contract revision. The machine-readable file
[`contract/hcg-origin-contract-3.json`](contract/hcg-origin-contract-3.json) lists every path, field set, state,
error code and event type; Origin's tests fail if Origin drifts from it.

## 1. Summary

| Item | Status |
|---|---|
| Origin macOS app, `hcg-origin/2` (TLS 1.3 pinned + signed messages), development test client | IMPLEMENTED-DEV; verified on macOS CI (see `docs/STATUS.md`) |
| Origin HCG Connect client (production + development) | **BLOCKED — D-O1, D-O2.** Not issued. Origin ships with empty values and production enrollment disabled |
| Product registry entry for Origin | **BLOCKED — D-O1.** None exists; Origin has not invented one |
| Central Origin API (`hcg-origin-central/1`, §4) | **PROPOSED.** No device, gateway or enrollment route or table exists on the main site (SOURCE-VERIFIED) |
| ERP device-enrollment decision, ownership, scoped permissions, revocation | **PROPOSED** (§5–§7) |
| Command execution | Not part of enrollment, never grantable here. Agent Runtime authorises execution separately |

**Production stays off until this is built.** Origin's production mode requires four issued values (§3) and a
reachable `hcg-origin-central/1` service. Origin's local development service is a test stand-in on 127.0.0.1 only;
it is not a substitute, must not be deployed, and Origin refuses to use it as "production" (it reports
`environment: development` and Origin only accepts it in development mode).

## 2. Responsibilities

| Component | Owns |
|---|---|
| HCG Connector (device) | Device key, invitation entry, signed enrollment request, connection with granted capabilities |
| HCG Origin (macOS) | Gateway identity and TLS keys, invitations, local verification, forwarding, enforcing decisions, connection UI |
| HCG Connect | Identity of the person signed in to Origin |
| **Main HCG / ERP** | **Account verification, independent device-signature verification, admission decision, ownership, scoped permissions, revocation, audit** |
| Nexus | User-facing workspace (may list admitted devices later; not in this flow) |
| Agent Runtime | Separately authorised task execution |

## 3. HCG Connect registration for Origin — BLOCKED (D-O1, D-O2)

Path (SOURCE-VERIFIED, `docs/hcg-connect/shared-product-access-handoff.md`): Owner → ERP → App Integrations →
*product* → Dedicated app login registration → Register or reuse → read back. Keep `configured_untested` until the
acceptance tests in §10 pass.

| Field | Production (RECOMMENDED values) | Development (RECOMMENDED values) |
|---|---|---|
| Product ID | `hcg.origin` (D-O1) | `hcg.origin` |
| Integration key | `hcg-origin-macos-production` | `hcg-origin-macos-dev` |
| Consent name | HCG Origin | HCG Origin (development) |
| Platform / environment | `macos` / `production` | `macos` / `development` |
| Bundle ID | `com.hakmicapitalgroup.hcgorigin` | `com.hakmicapitalgroup.hcgorigin.dev` |
| Callback (exactly one) | `com.hakmicapitalgroup.hcgorigin://auth/callback` | `com.hakmicapitalgroup.hcgorigin.dev://auth/callback` |
| Client type | public, `token_endpoint_auth_method: none`, authorization_code + refresh_token, **PKCE S256 only** | separate client, same type |
| Scopes / audience | `openid email profile` (no custom scopes exist — SOURCE-VERIFIED) / `authenticated` | same |

Origin's side (implemented, unused until configured): discovery from the configured issuer, issuer equality check,
S256 required, system browser via `ASWebAuthenticationSession`, `state` check, code exchange, tokens in the login
Keychain, sign-out clears local tokens only (no revocation endpoint is advertised — SOURCE-VERIFIED).

**Send back to Origin** (goes into the app's `Info.plist`; all five are empty today):

| Key | Value |
|---|---|
| `HCGConnectClientID` | issued client ID (production build; the development build gets the development client) |
| `HCGConnectRedirectURI` | the registered callback, exactly — Origin then adds the matching URL scheme |
| `HCGConnectIssuer` | canonical direct issuer from discovery (Origin copies it from configuration, never hardcodes it in code) |
| `HCGCentralOriginAPIBase` | https base URL of `hcg-origin-central/1` once deployed (RECOMMENDED: `https://<site>/api/public/origin/v1`) |
| `HCGEcosystemAPIBase` | https base of the existing ecosystem API (`…/api/public/ecosystem/v1`) — Origin calls `POST check` there for its feature keys (§13.1). New in revision 3 |

## 4. Central API `hcg-origin-central/1` — PROPOSED

Reference implementation: `Sources/HCGCentralDevKit/DevCentralService.swift`; wire types:
`Sources/HCGOriginProtocol/CentralContract.swift`. All paths are relative to `HCGCentralOriginAPIBase`.
Bodies are JSON, dates ISO 8601 UTC with seconds (`2026-11-21T10:00:00Z`), all responses `cache-control: no-store`.
Errors may use the existing main-site envelope `{"error":{"code","message"},"api_version":"v1"}`; Origin reads
`error.code` and `error.message` and fails closed on anything not documented here.

### 4.1 Authentication of every route except `health`

1. `Authorization: Bearer <HCG Connect access token>` of the person signed in to Origin, validated as today
   (`auth.getUser`). 401 → Origin discards its token and asks the person to sign in again.
2. Gateway signature headers by the gateway identity key registered to that account:
   `X-HCG-Protocol: hcg-origin/2`, `X-HCG-Key-Fingerprint`, `X-HCG-Timestamp`, `X-HCG-Nonce`, `X-HCG-Signature`
   over `HCG-ORIGIN-REQUEST-V1\n<METHOD>\n<path>\n<timestamp>\n<nonce>\n<fingerprint>\n<hex SHA-256 of body>`
   where `<path>` is the full URL path (e.g. `/api/public/origin/v1/enrollments`). Central must verify the signature
   (ECDSA P-256 / SHA-256, DER), keep a ±120 s window, reject a repeated `(fingerprint, nonce)` for 300 s, and
   check the fingerprint belongs to a gateway owned by the token's account. For `POST gateways` the key is in the body.

### 4.2 Routes

| Method & path | Request | Success | Errors |
|---|---|---|---|
| `GET health` | — (no auth) | `200 {service, environment:"production", apiVersion:"hcg-origin-central/1", time}` | 503 `service_unavailable` |
| `GET account` | — | `200 {accountId, email, displayName, verified, mayOwnGateways, environment}` | 401 |
| `POST gateways` | `{gatewayPublicKey, proposedGatewayId, name, platform, originVersion, protocolVersion, transportFingerprint?}` | `201` (new) / `200` (same key, same account): `{gatewayId, gatewayFingerprint, ownerAccountId, status:"registered", registeredAt, environment}` | 401, 403 `account_not_permitted`, 409 `gateway_owned_elsewhere`, 400 `invalid_input`, 401 `gateway_signature_invalid` |
| `POST enrollments` | `CentralEnrollmentSubmission` (§4.3) | `201 CentralEnrollmentRecord` with `state:"pending_review"`; `200` with the existing record for a retry of the same `(gatewayId, localRequestId)` | 409 `duplicate_enrollment`, 422 `device_signature_invalid`, 422 `invalid_input` (execution requested), 403 |
| `GET enrollments/{enrollmentId}` | — | `200 CentralEnrollmentRecord` | 404 `not_found` (also for another gateway's enrollment) |
| `GET gateways/{gatewayId}/devices` | — | `200 {gatewayId, devices:[{deviceId, fingerprint, name, status:"active"|"revoked", grant, ownerAccountId, revokedAt?, revocationReason?}]}` | 403 (not this gateway) |
| `POST gateways/{gatewayId}/events` | `{events:[{eventId, type, occurredAt, deviceId?, localRequestId?, detail}]}` | `202 {accepted:n}`; idempotent by `eventId` | 400 `invalid_input` |

`CentralEnrollmentRecord` = `{enrollmentId, localRequestId, state:"pending_review"|"approved"|"rejected"|"expired",
verification:{account:"verified"|"unverified"|"not_permitted", deviceSignature:"valid"|"invalid",
gatewaySignature:"valid"|"invalid"}, reason?, decidedAt?, deviceId? (on approval), grant? (on approval),
environment}`; `grant = {capabilities:[…], executionAuthorized:false, grantedAt, expiresAt?, decidedBy:"hcg-erp"}`.

`gatewayId`, `enrollmentId` and `deviceId` are **issued by central** and opaque to Origin. Origin shows its own
`proposedGatewayId` / `proposedDeviceId` only as "proposed".

### 4.3 What central must verify on `POST enrollments`

The submission is `{gatewayId, localRequestId, invitationId, device:{publicKey, proposedDeviceId, name, platform,
model?, softwareVersion, clientKind}, requestedCapabilities, refusedByGateway:[{capability, reason, message}],
deviceRequest:{protocolVersion:"hcg-origin/2", method, path, timestamp, nonce, keyFingerprint, body, signature},
receivedAt}` (`body` and `signature` base64url).

Central must **not** trust Origin's summary. It must:
1. require `deviceRequest.protocolVersion == "hcg-origin/2"`, `method == "POST"`, `path == "/origin/v1/enroll"`;
2. check `SHA-256(device.publicKey SPKI) == keyFingerprint`;
3. rebuild the request signing input (§4.1 format, with the device's `path`, `timestamp`, `nonce`,
   `keyFingerprint` and SHA-256 of the decoded `body`) and verify `signature` with `device.publicKey`;
4. decode `body` and confirm it names the same `device`, the same `invitationId`, the registered gateway's identity
   fingerprint (`gatewayFingerprint`), and that `requestedCapabilities` ⊆ the device's original list;
5. refuse any execution-like capability (`agent.*`, anything containing `exec`, `command` or `shell`);
6. refuse a key that is already admitted (active) on this gateway, or already pending;
7. verify the account (`verified`, allowed to own gateways — D-O4) and record the results in `verification`.

Origin's development service does exactly this and refuses a tampered submission (test
`testCentralVerifiesDeviceSignatureIndependently`).

## 5. ERP decision — PROPOSED

* Each submission becomes an ERP request (RECOMMENDED: reuse `erp_requests` / `erp_request_events`, type
  `device_enrollment`, decided through `erp_decide_request`).
* The approver sees: device name, platform, client kind, key fingerprint (short), **check code**
  (`hcg-origin-check-v1`, PROTOCOL.md §5 — compared with the device's screen), account, gateway name and ID,
  requested and gateway-refused capabilities, verification results, transport (`tls13-pinned`).
* The approver may grant a subset of the requested enrollable capabilities; never execution.
* Undecided requests expire after at most 30 minutes (Origin expires them locally at 30 minutes).
* Approver: see D-O3.

## 6. Ownership and scoped permissions — PROPOSED

| Table | Key columns |
|---|---|
| `origin_gateways` | `gateway_id`, `owner_user_id`, `org_id` (nullable, D-O4), `public_key_spki`, `fingerprint` (unique), `transport_fingerprint`, `name`, `platform`, `protocol_version`, `status active\|suspended`, `environment`, timestamps |
| `origin_enrollments` | `enrollment_id`, `gateway_id`, `local_request_id` (unique per gateway), `device_fingerprint`, `device_descriptor jsonb`, `requested_capabilities`, `refused_by_gateway`, `forwarded_request jsonb`, `verification jsonb`, `state`, `erp_request_id`, `decided_by`, `decided_at`, `reason`, `expires_at` |
| `origin_devices` | `device_id`, `gateway_id`, `owner_user_id`, `org_id?`, `fingerprint` (unique per gateway while active), `name`, `status active\|revoked`, `revoked_at`, `revocation_reason`, `enrollment_id` |
| `origin_device_grants` | `device_id`, `capability` (check constraint: allow-list `connection.presence`, `device.status.report`), `granted_by`, `granted_at`, `expires_at?`, `revoked_at?` |
| `origin_gateway_events` | `event_id` (unique), `gateway_id`, `type`, `occurred_at`, `device_id?`, `local_request_id?`, `detail` |

Rules: a device belongs to the gateway owner's account (org later); Origin never decides licensing or ownership;
gating of Origin features through `eco_check_access` follows the existing rule — only `allowed === true` allows,
never cache a yes (SOURCE-VERIFIED).

## 7. Revocation, admission freshness and audit — PROPOSED

* ERP revocation sets `origin_devices.status = revoked` (and grant rows); it must appear in
  `GET gateways/{id}/devices` immediately.
* Origin polls that list every 4 s while running, enforces revocation on the next request, and reports
  `gateway.device.revocation_enforced`. A device missing from the list is treated as no longer admitted.
* **Admission freshness (new in revision 2):** Origin refuses all device connections
  (`503 admission_unverified`) when it has not fetched the device list successfully in the last 15 minutes, and after
  every restart until the first successful fetch. Central outages therefore stop connections after 15 minutes instead
  of letting revoked devices keep connecting.
* Gateway suspension or ended account access → 401/403 on every gateway call → Origin stops pairing and shows why.
* Gateway events Origin sends (`gatewayEventTypes` in the contract file): `gateway.device.connected`,
  `gateway.device.reconnected`, `gateway.device.disconnected`, `gateway.device.revocation_enforced`,
  `gateway.device.blocked_locally`, `gateway.device.unblocked_locally`, `gateway.enrollment.expired_locally`.
  IDs, types, times and short text only — never invitation codes, secrets or tokens. RECOMMENDED: store in
  `origin_gateway_events` and mirror to `eco_audit` with source `app:hcg-origin`.
* Central-side audit: submission received, verification results, approve/reject (who, when, reason, granted
  capabilities), revoke (who, when, reason).

## 8. Security requirements for main HCG (summary)

1. Never trust Origin-supplied account, organisation, ownership or `allowed` values — derive them from the bearer token.
2. Verify the gateway signature on every call and the device signature on every enrollment (§4.1, §4.3).
3. Fail closed: any evaluation error is a refusal, not an approval.
4. Execution-like capabilities cannot be requested, stored or granted.
5. Issued identifiers are random and opaque; do not derive them from keys or names.
6. No secrets in events, logs or responses.
7. Return `environment:"production"` and `apiVersion:"hcg-origin-central/1"` from `health`.

## 9. Missing contracts (explicit)

1. Product registry entry and HCG Connect clients for Origin (D-O1, D-O2).
2. The whole `hcg-origin-central/1` API (§4) and its tables (§6).
3. ERP UI/workflow for enrollment decisions and revocation (§5, §7).
4. Organisation scope (D-O4); ordinary customers have no organisation today (SOURCE-VERIFIED).
5. Push channel for revocation (polling now; revision 3 candidate).
6. HCG Connector app: not found in any accessible repository; PROTOCOL.md §9 is its checklist.
7. Agent Runtime authorisation contract: not defined (its repository has only a README).
8. Relationship to HCG Server Device Link (`hcg.server` / `devicelink.*`, PROPOSED there) — D-O1.

## 10. Acceptance tests (central side) — NOT RUN

| # | Test | Expected |
|---|---|---|
| C1 | `GET health` on the deployed base | `environment:"production"`, `apiVersion:"hcg-origin-central/1"` |
| C2 | Sign in to Origin with HCG Connect (PKCE) | Account shown in Origin; client stays `configured_untested` until C2–C10 pass |
| C3 | Gateway registration | `gatewayId` issued; repeat call returns the same; another account → 409 |
| C4 | Enrollment from a real Connector over `hcg-origin/2` | ERP shows the request with the same check code as the device |
| C5 | Tampered forwarded request (changed name or capability) | 422 `device_signature_invalid` |
| C6 | Approve with a subset | Origin and Connector show only those capabilities; `executionAuthorized:false` |
| C7 | Reject with a reason | Origin and Connector show rejected with the reason |
| C8 | Revoke in ERP | Origin refuses the device within one sync (≈ 4 s); event recorded |
| C9 | Expired token / ended session | 401 → Origin asks to sign in again; pairing disabled |
| C10 | Central unavailable for > 15 min | Origin keeps requests pending, refuses device connections (`admission_unverified`), resumes afterwards |

Record PASS/FAIL/NOT RUN with date, Origin version + commit, and account — never tokens.

## 11. Decisions needed — with Origin's recommendations

| # | Decision | **Recommended** | Why | Alternative |
|---|---|---|---|---|
| **D-O1** | Product for Origin | **Register `hcg.origin`** as its own product (status `planned` until C1–C10 pass) with the ten operational features in §13.1 (`origin.actions.approve` disabled) | Origin has its own app, client, consent screen and lifecycle; HCG Server Device Link (`hcg.server`) governs host agents and storage. Separate products keep licences and revocation independent. Device capabilities stay in Origin's own allow-list, not as ecosystem features | Place Origin under `hcg.server` as more `devicelink.*` features |
| **D-O2** | Bundle IDs and callbacks | **Approve §3 values**; issue a production and a separate development public PKCE client; keep both `configured_untested` | Follows the existing `<bundle-id>://auth/callback` convention (Nexus, Sentinel) and the "one client per app and environment" rule | Different scheme, e.g. `hcg-origin://auth/callback` (LifeOS style) |
| **D-O3** | Who approves a device | **The gateway owner** (the account that registered the gateway). Owner/Founder may **revoke** any device for security, but not approve on someone's behalf | Admission is about the owner's own machine and device; keeps approval with the person who can compare the check code | Org admins of the owning organisation (after D-O4) |
| **D-O4** | Account or organisation scope | **Account scope now**, nullable `org_id` for later; whether an account may own gateways is an explicit per-account grant managed in ERP App Access, returned as `mayOwnGateways` | Ordinary customers have no organisation today, so `/check` cannot evaluate them; an explicit grant avoids "membership alone" access | Wait for the shared customer-organisation work (Store D4) and use org scope from the start |
| **D-O5** | Central API shape | **Approve `hcg-origin-central/1` as in §4**, deployed under `/api/public/origin/v1`, with the exact `health` version string and the verification steps in §4.3 | Already exercised end to end against Origin's reference implementation; fail-closed by construction | Propose changes as `hcg-origin-central/2` before implementation |
| **D-O6** | Revocation latency and outage behaviour | **Polling every 4 s while Origin runs; fail closed after 15 minutes without a successful admission check and after every restart** (implemented in Origin); a push channel in revision 3 | Revocation effective within seconds while Origin runs, and never silently stale for more than 15 minutes | Longer window (e.g. 24 h) for better offline tolerance, at the cost of slower revocation during outages |

## 12. What happens on Origin's side once values are issued

1. Put the five issued values into the production build's `Info.plist`; add the URL scheme for the callback.
2. Build, then run the acceptance tests in §10 with a real account and a real Connector (or the development test client
   pointed at the real gateway, clearly recorded as such).
3. Only then is production pairing available in Origin. Until then the app shows exactly which values are missing.

## 13. Revision 3 additions (21 Nov 2026)

### 13.1 Origin feature keys — PROPOSED (not registered, not approved)

Prepared for the Owner as an unapplied, reviewable change in the main-site repository:
`docs/hcg-origin/registration-proposal.md` and `docs/hcg-origin/registry-review.sql` (branch
`claude/hcg-origin-registration`, draft PR F1r3srp3nt/hakmicapitalgroup#1). Product `hcg.origin`, `app_type desktop`,
platforms `macos`, lifecycle `development` / release `planned`. All features `access_class = operational`, not
licensable: **only an explicit, revocable per-member grant allows** — membership or a licence alone never does.

| Feature key | Purpose | Enabled at registration |
|---|---|---|
| `origin.app.access` | View Origin's state while signed in | yes |
| `origin.gateway.manage` | Port, network exposure, start/stop, local block | yes |
| `origin.devices.enroll` | Create invitations (Connector and HCG Server Device Link) | yes |
| `origin.requests.review` | Approve / reject connection requests | yes |
| `origin.devices.read` | Device inventory | yes |
| `origin.gateway.diagnostics` | Diagnostics (no secrets) | yes |
| `origin.server.connect` | Connect Origin to HCG Server | yes |
| `origin.audit.read` | Origin and gateway audit events | yes |
| `origin.settings.admin` | Central environment, background operation | yes |
| `origin.actions.approve` | Remote action approval — **execution-related** | **no (disabled)** |

How Origin uses them (IMPLEMENTED-DEV, against the development service's `POST /api/public/ecosystem/v1/check`):
`POST {HCGEcosystemAPIBase}/check {org_id, product_id:"hcg.origin", feature_key}` with the signed-in person's
token. Only `allowed: true` allows. Allows are cached ≤ 60 s, denials ≤ 10 s; a 401 clears the cache. A central
outage refuses everything except access-reducing actions (reject, revoke, block). Every refusal is logged in Origin's
Activity with the central reason.

**Founder and execution.** `eco_check_access` checks `enabled` before the Founder short-circuit, so a disabled
feature is refused for the Founder too (SOURCE-VERIFIED, migration 0083). Origin additionally refuses
execution-related features in this build (`ExecutionPolicy.enabledInThisBuild = false`) without asking central; both
must change before any remote action can be approved, and the target device's owner still approves locally.

**Organisation for `/check` (D-O4 follow-up).** `/check` requires an `org_id`. Personal accounts have none today, so
Origin sends the zero UUID and expects central to evaluate the account-level grant, or to return
`user_not_permitted`. Central must decide how a personal owner's Origin grants are evaluated before production.

### 13.2 HCG Connect session lifecycle — IMPLEMENTED-DEV, not exercised against HCG Connect

Origin stores one session item (access token, refresh token, expiry, token endpoint, client ID) in the login
Keychain — never in files or logs. It renews with `grant_type=refresh_token` before expiry (serialized; one renewal
at a time); a refused renewal (400/401) ends the session and asks the person to sign in again. Sign-out deletes the
item and the permission cache; no revocation endpoint is advertised, so tokens expire naturally (SOURCE-VERIFIED).
Acceptance against the real HCG Connect requires the development client (§3, D-O2).

### 13.3 HCG Server Device Link — Origin as the owner's console (IMPLEMENTED, mock identities)

Origin connects to the **local** HCG Server agent's owner API (loopback only, admin token from HCG Server's own
Keychain item or an `hcg-agent admin-url` link) and shows its Device Link pairings and installations next to
Connector devices. Origin does **not** add a second identity, role or licence authority: HCG Server verifies the
device's signature, HCG token and ERP access (`devicelink.*`); Origin adds the owner's explicit, attributed approval,
gated by `origin.requests.review`. Events `gateway.server.*` (contract revision 3) are sent to central with the other
gateway events. Verified against a real agent with mock identities (`docs/verification/linux-hcg-server-integration/`).

Not done and needed for "Origin registers the Mac as an authorized device of HCG Server": HCG Server's allow-list of
apps that may pair would have to include `hcg.origin`, which needs the Origin HCG Connect client (D-O2) and a
decision in HCG Server's own handoff. Until then Origin uses the owner API on the same Mac only.

### 13.4 Acceptance tests added

| # | Test | Expected |
|---|---|---|
| C11 | `/check` for each Origin feature with and without a grant | granted → `allowed:true`; ungranted → `user_not_permitted`; `origin.actions.approve` → `feature_unavailable`, also for the Founder |
| C12 | Grant withdrawn in ERP while Origin runs | Next approval in Origin refused within ≤ 60 s |
| C13 | Access token expires | Origin renews with the refresh token without asking; refused renewal → sign in again |
