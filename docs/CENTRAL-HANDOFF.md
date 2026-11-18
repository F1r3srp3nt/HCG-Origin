# HCG Origin × main HCG (HCG Connect + ERP) — integration handoff

From: HCG Origin (`F1r3srp3nt/HCG-Origin`, branch `claude/wonderful-galileo-ovhpbi`), 18 Nov 2026.
For: the main HCG / Lovable project (`F1r3srp3nt/hakmicapitalgroup`).
No secrets, tokens or credentials are in this document or in Origin's build.

Labels (same as `docs/hcg-server/device-link-handoff.md`):
**VERIFIED-LIVE** · **SOURCE-VERIFIED** (read in main-site source/docs) · **IMPLEMENTED-DEV** (works against
Origin's local development service only) · **PROPOSED** (not issued, not implemented centrally) ·
**BLOCKED** (needs a named decision).

## 0. Summary

| Item | Status |
|---|---|
| Origin macOS app, pairing protocol, development test client | IMPLEMENTED-DEV (see `docs/STATUS.md`) |
| Origin HCG Connect client (production login) | **BLOCKED (D-O1, D-O2)** — not issued; Origin ships with empty values and production enrollment disabled |
| Product registry entry for Origin | **BLOCKED (D-O1)** — none exists; no product ID invented |
| Central Origin API (gateway registration, enrollment submission, decisions, device list, events) | **PROPOSED** — no such routes exist on the main site (SOURCE-VERIFIED: no device/gateway/enrollment table or route in migrations or `src/routes`) |
| ERP device admission (approve/reject), ownership, scoped permissions, revocation | **PROPOSED** (§5) |
| Audit events | **PROPOSED** (§6); existing `POST /ecosystem/v1/audit` is SOURCE-VERIFIED but app-key based |
| Command execution | Never part of enrollment. Agent Runtime authorises execution separately |

## 1. Responsibilities

| Component | Owns |
|---|---|
| HCG Connector (device) | Device key, invitation entry, signed enrollment request, connection with granted capabilities |
| HCG Origin (macOS) | Gateway key, invitations, local verification, forwarding, enforcing decisions, connection management UI |
| HCG Connect | Identity of the person signed in to Origin |
| Main HCG / ERP | Account verification, device admission, ownership, scoped permissions, revocation, audit |
| Nexus | User-facing workspace (may read admitted devices later; not part of this flow) |
| Agent Runtime | Separately authorised task execution |

Origin never decides admission. Signing in on a Mac never makes it a gateway by itself (central registration does), and enrolling a device never authorises execution.

## 2. Origin production login registration (HCG Connect) — BLOCKED

Registration path (SOURCE-VERIFIED, `docs/hcg-connect/shared-product-access-handoff.md` §registration):
Owner → ERP → App Integrations → *exact product* → Dedicated app login registration → Register or reuse.

Values Origin requests (all **PROPOSED** until the Owner issues them):

| Field | Production | Development |
|---|---|---|
| Product ID | see D-O1 (`hcg.origin` proposed, or `hcg.server` if Origin joins Device Link) | same product |
| Integration key | `hcg-origin-macos-production` | `hcg-origin-macos-dev` |
| Consent name | HCG Origin | HCG Origin (development) |
| Platform / environment | `macos` / `production` | `macos` / `development` |
| Bundle ID | `com.hakmicapitalgroup.hcgorigin` (proposed; follows `com.hakmicapitalgroup.hcgnexus.app`) | `com.hakmicapitalgroup.hcgorigin.dev` |
| Callback (exactly one) | `com.hakmicapitalgroup.hcgorigin://auth/callback` | `com.hakmicapitalgroup.hcgorigin.dev://auth/callback` |
| Client type | Public, `token_endpoint_auth_method: none`, authorization_code + refresh_token, **PKCE S256 only** | same, separate client |
| Scopes | `openid email profile` (no custom scopes exist — SOURCE-VERIFIED) | same |
| Access-token audience | `authenticated` with signed `client_id` claim (SOURCE-VERIFIED convention) | same |

Origin's implementation (`Sources/HCGOriginCore/Central.swift` `HCGConnectPKCE`, `Sources/HCGOrigin/AppModel.swift`):
discovery from the configured issuer (`/.well-known/openid-configuration`), issuer equality check, S256 required,
`ASWebAuthenticationSession` (system browser, not an embedded web view), state check, code exchange, tokens in the login
Keychain. No revocation/end-session endpoint is advertised (SOURCE-VERIFIED), so sign-out clears local tokens only and
access ends at the next central check.

What Origin needs back, and where it goes (`Resources/Info.plist`; all four empty today):

| Key | Value source |
|---|---|
| `HCGConnectClientID` | Issued client ID |
| `HCGConnectRedirectURI` | The registered callback, exactly; Origin then adds the matching `CFBundleURLTypes` scheme |
| `HCGConnectIssuer` | Canonical direct issuer from discovery (SOURCE-VERIFIED value in `docs/hcg-connect/ai-native-public-config.json`) — copied from configuration, not hardcoded in code |
| `HCGCentralOriginAPIBase` | Base URL of the central Origin API once implemented (§3); must be https |

The registration stays `configured_untested` until the acceptance tests in §8 pass with a real account.

## 3. Central Origin API — PROPOSED contract

Reference implementation: Origin's local development service (`Sources/HCGCentralDevKit/DevCentralService.swift`),
wire types in `Sources/HCGOriginProtocol/CentralContract.swift`. Proposed base, following existing public route layout:
`https://beta.hakmicapitalgroup.com/api/public/origin/v1` — **not implemented; Origin does not assume it.**

Authentication on every route except `health`:
1. `Authorization: Bearer <HCG Connect access token>` of the person signed in to Origin, validated as today (`auth.getUser`).
2. Gateway signature headers (`docs/PROTOCOL.md` §4) by the gateway key registered to that account. Central must verify the
   signature over method, path, timestamp, nonce and body digest, keep a ±120 s window and reject repeated
   `(fingerprint, nonce)` pairs.
Errors use the existing envelope `{"error":{"code","message"},"api_version":"v1"}`; all responses `cache-control: no-store`.
Origin fails closed on anything but the documented 2xx shapes.

| Method & path | Purpose | Response |
|---|---|---|
| `GET health` | Liveness + environment check | `{service, environment:"production", apiVersion, time}` — Origin refuses a mismatched environment |
| `GET account` | Who is signed in, and whether they may own gateways | `{accountId, email, displayName, verified, mayOwnGateways, environment}` |
| `POST gateways` | Register this Mac's gateway key to the account (idempotent per key) | `201/200 {gatewayId, gatewayFingerprint, ownerAccountId, status, registeredAt, environment}`; `409 gateway_owned_elsewhere`; `403 account_not_permitted` |
| `POST enrollments` | Submit a device request received by Origin | `201 {enrollmentId, localRequestId, state:"pending_review", verification:{account, deviceSignature, gatewaySignature}, …}`; idempotent on `(gatewayId, localRequestId)`; `409 duplicate_enrollment`; `422 device_signature_invalid` |
| `GET enrollments/{enrollmentId}` | Decision retrieval (polled every few seconds) | state `pending_review | approved | rejected | expired`; on approval `deviceId` (issued) and `grant {capabilities, executionAuthorized:false, grantedAt, expiresAt?, decidedBy:"hcg-erp"}` |
| `GET gateways/{gatewayId}/devices` | Admission state of every device on this gateway (revocation, narrowed grants) | `{gatewayId, devices:[{deviceId, fingerprint, name, status: active|revoked, grant, ownerAccountId, revokedAt?, revocationReason?}]}` |
| `POST gateways/{gatewayId}/events` | Gateway audit events (§6), batched, idempotent by `eventId` | `202 {accepted}` |

`POST enrollments` body (`CentralEnrollmentSubmission`): `gatewayId, localRequestId, invitationId, device{publicKey (SPKI
base64url), proposedDeviceId, name, platform, model, softwareVersion, clientKind}, requestedCapabilities,
refusedByGateway[], deviceRequest{method, path, timestamp, nonce, keyFingerprint, body (base64url, exact bytes),
signature}, receivedAt`.

Central **must** verify the device itself — recompute the request signing input from `deviceRequest`, verify the
signature with `device.publicKey`, check `SHA-256(publicKey) == keyFingerprint`, decode `body` and confirm it names
the same device, invitation and the registered gateway's fingerprint, and that `requestedCapabilities` ⊆ the device's
original request. It must not trust Origin's summary. The development service does exactly this and refuses a
tampered submission (test `testCentralVerifiesDeviceSignatureIndependently`).

Identifiers: `gatewayId`, `enrollmentId`, `deviceId` are **issued by central** and opaque to Origin. Origin shows its own
`proposedGatewayId`/`proposedDeviceId` only as "proposed". The development service issues `hcgdev_…` IDs so they can
never be mistaken for production ones.

## 4. Enrollment decision in ERP — PROPOSED

* Each submission becomes an ERP request (proposed: reuse `erp_requests` / `erp_request_events` with type
  `device_enrollment`, decided through `erp_decide_request`), showing: device name/platform/client kind, device key
  fingerprint, **check code** (`PairingCheckCode`, `docs/PROTOCOL.md` §5 — the approver compares it with the device),
  account, gateway name/ID, requested and gateway-refused capabilities, verification results.
* Authorised person: the gateway owner (or an org admin of the owning organisation) — **D-O3**.
* The approver may grant a subset of requested capabilities; never execution-like ones.
* Undecided requests expire (Origin expires them locally after 30 min; central should use the same or shorter).

## 5. Ownership and scoped permissions — PROPOSED

Proposed tables (names indicative; follow `eco_*`/`erp_*` conventions and RLS as the project prefers):

| Table | Key columns |
|---|---|
| `origin_gateways` | `gateway_id`, `owner_user_id`, `org_id?`, `public_key_spki`, `fingerprint` (unique), `name`, `platform`, `status active|suspended`, `environment`, timestamps |
| `origin_enrollments` | `enrollment_id`, `gateway_id`, `local_request_id` (unique per gateway), `device_fingerprint`, `device_descriptor jsonb`, `requested_capabilities`, `refused_by_gateway`, `forwarded_request jsonb`, `verification jsonb`, `state`, `erp_request_id`, `decided_by`, `decided_at`, `reason`, `expires_at` |
| `origin_devices` | `device_id`, `gateway_id`, `owner_user_id`, `org_id?`, `fingerprint` (unique per gateway while active), `name`, `status active|revoked`, `revoked_at`, `revocation_reason`, `enrollment_id` |
| `origin_device_grants` | `device_id`, `capability`, `granted_by`, `granted_at`, `expires_at?`, `revoked_at?` |
| `origin_gateway_events` | `event_id` (unique), `gateway_id`, `type`, `occurred_at`, `device_id?`, `local_request_id?`, `detail` |

Rules: a device belongs to the gateway owner's account (or org); capabilities come from an allow-list
(`connection.presence`, `device.status.report`); `agent.*`/execution-like capabilities are rejected by a check
constraint and by the API. If Origin features are gated by the ecosystem evaluator, use `eco_check_access` with a
product per D-O1 (e.g. features `origin.gateway.register`, `origin.enrollment.submit`, `origin.devices.read`), treat only
`allowed === true` as allowed (SOURCE-VERIFIED rule) and never cache a yes.

## 6. Revocation and audit — PROPOSED

* Revocation is an ERP action on `origin_devices` (and on grants). It must be visible in `GET gateways/{id}/devices`
  immediately. Origin polls every few seconds while running, enforces on the next sync, and reports
  `gateway.device.revocation_enforced`.
* Suspending a gateway or ending the owner's account access should make every gateway call return 401/403; Origin then
  stops pairing and shows the error.
* Gateway events Origin sends: `gateway.device.connected`, `gateway.device.reconnected`, `gateway.device.disconnected`,
  `gateway.device.revocation_enforced`, `gateway.device.blocked_locally`, `gateway.device.unblocked_locally`,
  `gateway.enrollment.expired_locally`. They contain IDs, types, times and short text only — never invitation codes,
  secrets or tokens. Proposed: store in `origin_gateway_events` and mirror to `eco_audit` with source `app:hcg-origin`.
* Central-side audit for decisions: submission received, verification results, approve/reject (who, when, reason,
  granted capabilities), revoke (who, when, reason).

## 7. Missing contracts (explicit)

1. Product registry entry and HCG Connect client for Origin (D-O1, D-O2).
2. The entire central Origin API (§3) and its tables (§5).
3. ERP UI/workflow for device enrollment decisions and revocation (§4, §6).
4. A push channel for revocation (polling is used now).
5. Organisation scope for gateways (D-O4); ordinary customers have no organisation today (SOURCE-VERIFIED).
6. Relationship to HCG Server Device Link (`hcg.server` / `devicelink.*`, PROPOSED there) — D-O1.
7. HCG Connector app: not found in any accessible repository. Origin ships a development test client only.
8. Agent Runtime authorisation contract: not defined (its repository has only a README).

## 8. Acceptance tests (central side) — NOT RUN

| # | Test | Expected |
|---|---|---|
| C1 | Sign in to Origin with HCG Connect (PKCE) | Account shown; client stays `configured_untested` until C1–C9 pass |
| C2 | Gateway registration | `gatewayId` issued; second call idempotent; another account → 409 |
| C3 | Enrollment from a real Connector | ERP shows request with the same check code as the device |
| C4 | Tampered forwarded request | 422 `device_signature_invalid` |
| C5 | Approve with subset | Origin shows only the granted capabilities; execution never granted |
| C6 | Reject | Origin and Connector show rejected with reason |
| C7 | Revoke in ERP | Origin rejects the device within one sync; event recorded |
| C8 | Expired token / ended session | 401 → Origin asks to sign in again, pairing disabled |
| C9 | Central outage | Origin keeps requests pending and resumes |
Record PASS/FAIL/NOT RUN with date, build (Origin version + commit) and account — never tokens.

## 9. Decisions needed

* **D-O1** Product: register `hcg.origin` (proposed) or place Origin under `hcg.server` Device Link.
* **D-O2** Approve bundle IDs and callbacks in §2; Owner issues production and development clients.
* **D-O3** Who may approve a device: gateway owner only, or org admins too.
* **D-O4** Account vs organisation scope for gateways and devices.
* **D-O5** Approve the central API shape (§3) and tables (§5), or propose changes.
* **D-O6** Revocation latency target (polling interval) and whether to add push later.
