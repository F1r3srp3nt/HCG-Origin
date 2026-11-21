# HCG Origin Connector protocol — `hcg-origin/2`

Part of **contract revision `hcg-origin-contract/2`**. The same revision is used by
[CENTRAL-HANDOFF.md](CENTRAL-HANDOFF.md) (Origin ↔ main HCG). Machine-readable values:
[contract/hcg-origin-contract-2.json](contract/hcg-origin-contract-2.json) — a test fails if the code drifts from it.

| Contract part | Version | Between | Status |
|---|---|---|---|
| Connector protocol | `hcg-origin/2` | HCG Connector ↔ HCG Origin | Implemented in Origin and the development test client; Connector app not built yet |
| Central API | `hcg-origin-central/1` | HCG Origin ↔ main HCG / ERP | **PROPOSED**; implemented only by the local development service |
| Capability catalogue | `hcg-origin-capabilities/1` | all three | Implemented |
| Invitation format | `hcgo2-…`, version 2 | Origin → Connector (out of band) | Implemented |

Changes from `hcg-origin/1` (0.1.0): TLS 1.3 with a pinned gateway certificate is required for every
connection the app offers; invitations carry the transport and TLS pin; signed responses repeat the TLS
fingerprint; devices connect only while their admission was confirmed with central in the last 15 minutes;
the central API reports its version. `hcgo1-` invitations are no longer accepted.

## 1. Roles

| Party | In this protocol |
|---|---|
| HCG Connector (device) | Owns a device key. Uses an invitation to *request* enrollment. Connects later only with what was granted. |
| HCG Origin (macOS gateway) | Issues invitations when the owner presses Start Pairing. Verifies requests, forwards them to central, enforces decisions. |
| HCG Connect | Signs in the person who owns the gateway (production). |
| Main HCG / ERP | Verifies account and device; an authorised person approves or rejects; ownership, permissions, revocation. |
| Agent Runtime | Task/command execution — **never authorised by enrollment**. |

Discovery or a device name is never approval. An invitation lets a device submit a request; only an ERP decision admits it.

## 2. Transport

**HTTPS with TLS 1.3 only, directly from Connector to Origin.** Same trust model as HCG Server Device Link:
the server certificate is self-signed and is authenticated by **pinning the SHA-256 of its SubjectPublicKeyInfo**,
which the Connector receives in the invitation. No certificate authority, hostname check or system trust store is
involved, and there is **no fallback**: a mismatching key aborts the handshake before any request is sent.

* Origin listens on `127.0.0.1:47700` by default. "Accept devices on the local network" binds all IPv4 interfaces
  and admits only loopback and private (RFC 1918) peers. Local-network mode **refuses to start without TLS**.
* The gateway's TLS key is a P-256 key in the macOS login Keychain with a 10-year self-signed certificate
  (X.509 v3, `CA:false`, `digitalSignature`, `serverAuth`). It is separate from the gateway *identity* key
  (Secure Enclave on Apple silicon), which signs messages and is registered with central.
* **Channel binding:** every signed response body includes `tlsFingerprint`. Because the body is signed by the pinned
  gateway identity key, the Connector learns that the identity key vouches for the TLS key it is talking to.
* **No client certificate.** Every request is signed with the device key (§4), which binds requests to the device
  as strongly as mutual TLS would and lets central verify the device's own signature.
* TLS 1.2 and earlier are refused (verified with OpenSSL in `scripts/verify-on-mac.sh`).
* `cleartext-loopback-dev` exists only for the Linux development test harness (no TLS stack there). It is
  accepted only for `127.x` addresses in the `development` environment; the macOS app never issues it and a
  Connector must refuse it otherwise.
* Rotating the TLS key requires re-pairing in this revision (devices keep their enrollment; the new pin comes from
  a new invitation). A signed rotation notice is a candidate for revision 3.

## 3. Identities

| Identity | Key | Identifier |
|---|---|---|
| Gateway identity | ECDSA P-256 (Secure Enclave when available, else Keychain) | Fingerprint = lowercase hex SHA-256 of SPKI DER. `proposedGatewayId` = `origin-gw-<first 16 hex>`; **`gatewayId` is issued by central** |
| Gateway TLS key | ECDSA P-256 in the login Keychain | TLS fingerprint, same definition |
| Device (Connector) | ECDSA P-256 in the platform keystore (Secure Enclave / Keychain / Android Keystore). The test client uses a 0600 file and says so | Fingerprint, same definition. `proposedDeviceId` is self-chosen; **`deviceId` is issued by central** |

A device record is bound to its key fingerprint. A new key is a new device.

## 4. Signed messages

Request headers: `X-HCG-Protocol: hcg-origin/2`, `X-HCG-Key-Fingerprint`, `X-HCG-Timestamp` (Unix seconds),
`X-HCG-Nonce` (16 random bytes, base64url), `X-HCG-Signature` (base64url DER ECDSA-P256-SHA256), and on
enrollment `X-HCG-Invitation-Proof`.

Request signing input (UTF-8, `\n`-separated; the label is unchanged from revision 1):

```
HCG-ORIGIN-REQUEST-V1
<METHOD>
<path>
<timestamp>
<nonce>
<signer fingerprint>
<hex SHA-256 of the exact body bytes>
```

Responses carry `X-HCG-Protocol`, `X-HCG-Key-Fingerprint`, `X-HCG-Timestamp`, `X-HCG-Request-Nonce` (echo),
`X-HCG-Public-Key` (gateway identity SPKI, base64url) and `X-HCG-Signature` over:

```
HCG-ORIGIN-RESPONSE-V1
<HTTP status>
<request nonce>
<timestamp>
<gateway identity fingerprint>
<hex SHA-256 of the exact body bytes>
```

The Connector accepts a response only if (1) the TLS pin held, (2) SHA-256 of `X-HCG-Public-Key` equals the
gateway fingerprint from the invitation, (3) the nonce echoes its request, (4) the signature verifies, and (5) the
body's `tlsFingerprint` equals the pin. Error responses are signed too.

### Replay protection (unchanged)

* Timestamps outside ±120 s → `401 stale_request`.
* `(key fingerprint, nonce)` remembered 300 s → `401 replayed_request`.
* Signatures cover method, path and body; responses are bound to the request nonce.
* Central re-verifies the device's original signed enrollment request and applies its own window to gateway requests.

## 5. Invitation (version 2)

Created only when the owner presses **Start Pairing**. One active invitation at a time.

```
hcgo2-<base64url(JSON)>
{"v":2,"id":"inv_<18 hex>","s":"<32 random bytes, base64url>","gfp":"<gateway identity fingerprint>",
 "gn":"<gateway name>","addr":"<IPv4>:<port>","exp":<unix seconds>,"env":"development|production",
 "t":"tls13-pinned","tfp":"<gateway TLS fingerprint>"}
```

* Lifetime 5 min by default (1–15 min). Expired → `410 invitation_expired`.
* Single use: consumed by the first request whose signature and proof verify, whatever the outcome
  (`410 invitation_used`). Cancelled on restart, on connection-setting changes and after 5 invalid proofs
  (`410 invitation_cancelled`).
* Origin stores only `SHA-256("hcg-origin-invitation-secret-v1:" + secret)`; the secret stays in memory.
* The Connector never sends the secret: `X-HCG-Invitation-Proof = base64url(HMAC-SHA256(K, request signing input))`,
  `K = HKDF-SHA256(ikm = secret (UTF-8), salt = "hcg-origin-invitation-proof-v1", info = invitation id, 32 bytes)`.
* Decoding rules: `v` must be 2; `t = tls13-pinned` requires a valid `tfp`; `t = cleartext-loopback-dev` requires a
  `127.x` address, `env = development` and no `tfp`; any other `t` is refused.
* The Connector must show the gateway name, `env` and the short fingerprints, and must refuse silently proceeding
  with a `development` invitation in a production build.
* Shown as text and QR code.

**Check code:** both sides (and the approver in ERP) display
`first 4 bytes of SHA-256("hcg-origin-check-v1|<gateway fp>|<device fp>|<invitation id>") mod 10^6` as `123 456`.

## 6. Endpoints (Connector → Origin)

All `POST`, JSON, signed, over the pinned TLS connection.

### `POST /origin/v1/enroll`

```json
{"type":"hcg.origin.enroll/1","invitationId":"inv_…","gatewayFingerprint":"<from invitation>",
 "device":{"publicKey":"<SPKI base64url>","proposedDeviceId":"dev-…","name":"…","platform":"…",
           "model":"…","softwareVersion":"…","clientKind":"connector|connector-test-client"},
 "requestedCapabilities":["connection.presence","device.status.report"]}
```

Origin checks, in order: body and key well-formed → device signature with the enclosed key, header fingerprint
matches → freshness and nonce → `gatewayFingerprint` is this gateway → invitation exists, active, unexpired →
invitation proof → invitation marked used → duplicates → capability screening.

`202 {"requestId","state":"received","checkCode","gatewayName","gatewayFingerprint","gatewayPublicKey",
"environment","forwardedCapabilities","refusedCapabilities","message","transport","tlsFingerprint"}`.

Errors: `400 bad_request|wrong_gateway`, `401 invalid_signature|stale_request|replayed_request|invalid_invitation_proof`,
`404 invitation_unknown`, `410 invitation_expired|invitation_used|invitation_cancelled`,
`409 already_enrolled|enrollment_pending`, `403 device_blocked_locally|local_network_disabled|address_not_allowed`.

### `POST /origin/v1/enrollment-status`

`{"type":"hcg.origin.enrollment-status/1","requestId":"req_…"}` →
`200 {"requestId","state","centralState","reason","deviceId","grant","environment","message","tlsFingerprint"}`.
`state ∈ received | awaiting_decision | approved | rejected | expired | failed`. `grant` and `deviceId` appear only on
approval and never for a device revoked since.

### `POST /origin/v1/heartbeat` — the permitted connection

`{"type":"hcg.origin.heartbeat/1","deviceId":"<issued>","sequence":n,"report":{…}|null}` →
`200 {"state":"connected","grant":{…},"intervalSeconds":10,"serverTime":"…","tlsFingerprint":"…"}`.

* Requires `connection.presence`; a `report` requires `device.status.report` (`403 capability_not_granted`).
* Revoked → `403 device_revoked`; blocked on this gateway → `403 device_blocked_locally`; unknown key →
  `401 unknown_device`; enrolled in the other environment → `403 environment_inactive`.
* **Admission freshness (new):** Origin answers `503 admission_unverified` unless it confirmed the device list
  with central within the last 15 minutes (in memory; a restarted Origin must sync first). The Connector retries.
* No contact for 35 s → shown as disconnected; the next valid heartbeat reconnects.

## 7. Capabilities (`hcg-origin-capabilities/1`)

| Capability | Meaning | Enrollable |
|---|---|---|
| `connection.presence` | Authenticated connection; appears online | yes |
| `device.status.report` | OS version, battery, uptime | yes |
| `agent.execute` (and anything `agent.*`, `*exec*`, `*command*`, `*shell*`) | Command/task execution | **never** — Agent Runtime only |

Origin refuses execution-like and unknown capabilities before forwarding; central must refuse to grant them; Origin
strips them from any grant and always sets `executionAuthorized: false`. Command execution is disabled at this milestone.

## 8. Revocation

ERP revokes → central lists the device `revoked` → Origin's next sync (every few seconds while running) marks it
revoked, reports `gateway.device.revocation_enforced` and rejects every request from that key. A device missing from
central's list is treated as no longer admitted. If Origin cannot reach central for 15 minutes, all devices are refused
until it can (fail closed). "Block on this gateway" stops a device here only and is reported to central.

## 9. What the Connector must implement

1. Device key in the platform keystore; never exported.
2. Parse `hcgo2-` codes (text or QR); apply §5 decoding rules; check expiry; show gateway name, environment and short fingerprints.
3. Connect with **TLS 1.3 only**, accept the server only if SHA-256(leaf SPKI) equals `tfp`; no CA trust, no hostname
   check, no fallback, no user override.
4. Sign every request (§4) with a fresh nonce; add the invitation proof to `enroll`.
5. Verify every response (§4 points 1–5); ignore anything that fails.
6. Show the check code; poll `enrollment-status`; store the gateway identity key, the TLS pin, the issued `deviceId` and the grant.
7. Heartbeat at `intervalSeconds` with granted capabilities only; retry on `admission_unverified`; stop on `device_revoked`.
8. Never treat enrollment as permission to execute anything.
