# HCG Origin pairing and enrollment protocol — `hcg-origin/1`

Status: **implemented in Origin and the development test client; PROPOSED for HCG Connector.**
Source of truth: `Sources/HCGOriginProtocol/` (Swift). This document is the contract the
Connector team implements against.

## 1. Roles

| Party | Responsibility in this protocol |
|---|---|
| **HCG Connector** (device) | Owns a device key. Uses an invitation to *request* enrollment. Connects later only with what was granted. |
| **HCG Origin** (this app, macOS gateway) | Issues invitations when the owner explicitly starts pairing. Verifies requests locally, forwards them to central, enforces the decision. |
| **HCG Connect** | Authenticates the person who owns the gateway (production). |
| **Main HCG / ERP** | Verifies the account and the device request; an authorised person approves or rejects; holds ownership, permissions and revocation. |
| **Agent Runtime** | Task/command execution. **Never authorised by enrollment.** |

Discovery or knowing a device name is never approval. An invitation lets a device *submit*
a request; only an ERP decision admits it.

## 2. Transport (milestone 1) — decision

**HTTP/1.1, Connector → Origin, direct, with message-level authentication.**

* Origin listens on `127.0.0.1:47700` by default (this Mac only). Accepting devices on the
  local network (`0.0.0.0:47700`, private addresses only) is an explicit setting.
* Every request and every response is signed (§4). Confidentiality of the transport is **not**
  provided in milestone 1: device name, platform and requested capabilities are visible to an
  observer on the same network. No secret ever crosses the wire: the invitation secret is
  proven with an HMAC, keys are public, tokens never reach the Connector.
* Why: it works identically for a Connector on the same Mac and on the local network, needs no
  certificate infrastructure on the device, and lets central verify the device's own signature
  end to end. HCG Server Device Link's pinned mutual-TLS model is the intended next step
  (`hcg-origin/2`), adding confidentiality; the signing layer stays.
* Not in milestone 1: Bonjour discovery, remote relaying, Bluetooth, mutual TLS.

## 3. Identities

| Identity | Key | Stored | Identifier |
|---|---|---|---|
| Gateway (Origin) | ECDSA P-256 | Secure Enclave on Apple silicon (Keychain holds the wrapped reference); otherwise a software key in the login Keychain | Fingerprint = SHA-256 of the SubjectPublicKeyInfo DER, hex (same definition as HCG Server). `proposedGatewayId` = `origin-gw-<first 16 hex>`; the **gatewayId is issued by central** |
| Device (Connector) | ECDSA P-256 | Platform keystore (Secure Enclave / Keychain / Android Keystore). The test client uses a 0600 file and says so | Fingerprint as above. `proposedDeviceId` is self-chosen; the **deviceId is issued by central** on approval |

A device record is bound to its key fingerprint. A new key is a new device.

## 4. Signed messages

Headers (requests):

| Header | Value |
|---|---|
| `X-HCG-Protocol` | `hcg-origin/1` |
| `X-HCG-Key-Fingerprint` | signer fingerprint (64 hex) |
| `X-HCG-Timestamp` | Unix seconds |
| `X-HCG-Nonce` | 16 random bytes, base64url (16–64 chars `[A-Za-z0-9_-]`) |
| `X-HCG-Signature` | base64url DER ECDSA-P256-SHA256 signature of the signing input |
| `X-HCG-Invitation-Proof` | enrollment only, §5 |

Request signing input (UTF-8, `\n`-separated):

```
HCG-ORIGIN-REQUEST-V1
<METHOD>
<path>
<timestamp>
<nonce>
<signer fingerprint>
<hex SHA-256 of the exact body bytes>
```

Responses carry `X-HCG-Protocol`, `X-HCG-Key-Fingerprint`, `X-HCG-Timestamp`,
`X-HCG-Request-Nonce` (echo), `X-HCG-Public-Key` (gateway SPKI, base64url) and
`X-HCG-Signature` over:

```
HCG-ORIGIN-RESPONSE-V1
<HTTP status>
<request nonce>
<timestamp>
<gateway fingerprint>
<hex SHA-256 of the exact body bytes>
```

The Connector accepts a response only if `SHA-256(X-HCG-Public-Key)` equals the fingerprint
pinned by the invitation (or stored at enrollment), the nonce echoes its request and the
signature verifies. Error responses are signed too.

### Replay protection

* Timestamps outside ±120 s are rejected (`401 stale_request`).
* `(key fingerprint, nonce)` pairs are remembered for 300 s; a repeat is rejected
  (`401 replayed_request`).
* The signature covers method, path and body, so a signature cannot be moved to another
  endpoint or body. Responses are bound to the request nonce.
* Central re-verifies the device's original signed enrollment request (§7) and applies its
  own replay window to gateway requests.

## 5. Invitation

Created only when the owner presses **Start Pairing**. One active invitation at a time.

```
hcgo1-<base64url(JSON)>
{"v":1,"id":"inv_<18 hex>","s":"<32 random bytes, base64url>","gfp":"<gateway fingerprint>",
 "gn":"<gateway name>","addr":"<host:port>","exp":<unix seconds>,"env":"development|production"}
```

* Lifetime 5 min by default, 1–15 min configurable. Expired → `410 invitation_expired`.
* Single use: consumed by the first request whose signature and proof verify, whatever the
  outcome (`410 invitation_used` afterwards). Cancelled on restart, on settings changes and
  after 5 invalid proofs (`410 invitation_cancelled`).
* Origin stores only `SHA-256("hcg-origin-invitation-secret-v1:" + secret)`; the secret lives
  in memory until used/expired.
* The Connector never sends the secret. It sends
  `X-HCG-Invitation-Proof = base64url(HMAC-SHA256(K, request signing input))` with
  `K = HKDF-SHA256(ikm = secret (UTF-8), salt = "hcg-origin-invitation-proof-v1", info = invitation id, 32 bytes)`.
* Shown as text and QR code. The Connector must show `env` and refuse to proceed silently
  if it is `development` in a production build.

### Check code

Both sides display `PairingCheckCode = first 4 bytes of SHA-256("hcg-origin-check-v1|<gateway fp>|<device fp>|<invitation id>") mod 10^6`
as `123 456`. The development approver page shows it too. The person compares them.

## 6. Endpoints (Connector → Origin)

All `POST`, JSON bodies, signed. Bodies are versioned by `type`.

### `POST /origin/v1/enroll`

Signed by the device key, plus invitation proof.

```json
{"type":"hcg.origin.enroll/1","invitationId":"inv_…","gatewayFingerprint":"<from invitation>",
 "device":{"publicKey":"<SPKI base64url>","proposedDeviceId":"dev-…","name":"…","platform":"…",
           "model":"…","softwareVersion":"…","clientKind":"connector|connector-test-client"},
 "requestedCapabilities":["connection.presence","device.status.report"]}
```

Origin checks, in order: well-formed body and key → device signature with the enclosed key,
fingerprint header matches → freshness/nonce → `gatewayFingerprint` is this gateway →
invitation exists, active, not expired → invitation proof → marks the invitation used →
duplicates → capability screening.

`202` → `{"requestId","state":"received","checkCode","gatewayName","gatewayFingerprint",
"gatewayPublicKey","environment","forwardedCapabilities","refusedCapabilities","message"}`.

Errors: `400 bad_request|wrong_gateway`, `401 invalid_signature|stale_request|replayed_request|invalid_invitation_proof`,
`404 invitation_unknown`, `410 invitation_expired|invitation_used|invitation_cancelled`,
`409 already_enrolled|enrollment_pending`, `403 device_blocked_locally|local_network_disabled`.

### `POST /origin/v1/enrollment-status`

Signed by the same device key. `{"type":"hcg.origin.enrollment-status/1","requestId":"req_…"}` →
`200 {"requestId","state","centralState","reason","deviceId","grant","environment","message"}`.
`state ∈ received | awaiting_decision | approved | rejected | expired | failed`.
`grant` and `deviceId` appear only on approval and never for a device revoked since.

### `POST /origin/v1/heartbeat` — the permitted connection

Signed by the enrolled device key.
`{"type":"hcg.origin.heartbeat/1","deviceId":"<issued>","sequence":n,"report":{…}|null}` →
`200 {"state":"connected","grant":{…},"intervalSeconds":10,"serverTime":"…"}`.

Requires `connection.presence`. A `report` requires `device.status.report`
(`403 capability_not_granted` otherwise). Revoked → `403 device_revoked`; blocked on this
gateway → `403 device_blocked_locally`; unknown key → `401 unknown_device`.
No contact for 35 s → Origin shows the device as disconnected; the next valid heartbeat
reconnects it.

## 7. Capabilities

| Capability | Meaning | Enrollable |
|---|---|---|
| `connection.presence` | Authenticated connection; appears online | yes |
| `device.status.report` | OS version, battery, uptime | yes |
| `agent.execute` (and anything `agent.*`, `*exec*`, `*command*`, `*shell*`) | Command/task execution | **never** — Agent Runtime, separately authorised |

Origin refuses execution-like and unknown capabilities before forwarding; central must refuse
to grant them; Origin strips them from any grant it receives and sets `executionAuthorized:false`.

## 8. Revocation

ERP revokes → central lists the device as `revoked` → Origin's next sync (every few seconds)
marks it revoked, reports `gateway.device.revocation_enforced`, and rejects every request from
that key. A device missing from central's list is treated as no longer admitted. A local
"block on this gateway" stops it here only and is reported as an audit event; it does not
change ERP admission.

## 9. What the Connector must implement

1. Device key in the platform keystore; never exported.
2. Parse `hcgo1-` codes (text or QR); check expiry; show gateway name, environment and short fingerprint.
3. Sign every request (§4) with a fresh nonce; add the invitation proof to `enroll`.
4. Verify every response against the pinned fingerprint; ignore anything that fails.
5. Show the check code; poll `enrollment-status`; store the gateway key, issued `deviceId` and grant.
6. Heartbeat at `intervalSeconds` using only granted capabilities; stop on `device_revoked`.
7. Never treat enrollment as permission to execute anything.
