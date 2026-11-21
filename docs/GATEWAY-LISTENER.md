# Gateway listener: “Gateway listener failed” — diagnosis and fixes (0.3.0)

## What could and could not be determined

The report came from your MacBook Pro M4 Max (macOS 27.0.1). No Mac was attached to the session that wrote this, so
**the actual cause on your Mac has not been observed**. Instead of guessing, 0.3.0 makes the cause visible and
recoverable, and `scripts/diagnose-gateway.sh` (read-only) reports it in one run.

```bash
./scripts/diagnose-gateway.sh > origin-diagnosis.txt
```

It lists: running copies of HCG Origin (path, version, commit), the configured port and interface, **which process owns
the port**, whether that port answers with Origin's TLS 1.3 certificate, the gateway certificate in the Keychain,
Origin's own recent gateway/error activity, the unified log, and the production values of the running copy. It changes
nothing and stops nothing.

## Facts about 0.2.0 (from its source)

| Question | 0.2.0 behaviour |
|---|---|
| Port | `47700` (Settings → Connection), TCP |
| Interface | `127.0.0.1` only (loopback) unless “Accept devices on the local network” is on |
| Transport | TLS 1.3 (Network.framework `NWListener`) with the certificate “HCG Origin TLS (HCG Origin)” from the login Keychain |
| Single instance | **Not enforced**: two copies of the app (e.g. a downloaded build and a local build) could both try to start a gateway |
| Address reuse | `allowLocalEndpointReuse = true` |
| A listener in `.waiting` state | Treated as an immediate failure |
| Error text | One line, no owner of the port, no automatic retry |

## Causes 0.2.0 could produce, and what 0.3.0 does about each

| # | Possible cause | How you would recognise it | 0.3.0 |
|---|---|---|---|
| 1 | **Another copy of HCG Origin** (another path, or a verification run) holds port 47700 | `diagnose-gateway.sh` §1 shows two copies; §3 shows HCGOrigin owning 47700 | **Data-folder lock**: a second copy refuses to start a gateway and names the process that holds it; the UI offers *Switch to the Running Copy* |
| 2 | **Another program** uses port 47700 | §3 names a non-Origin process | Failure names the program and process ID (via `lsof`); automatic retry with back-off; *Use a Free Port* moves to 47700–47719 (loopback). Origin never stops other programs |
| 3 | The listener reported a transient `.waiting` state (e.g. while the network stack settles) and 0.2.0 gave up at once | §6/§7 show “waiting: …” | Waiting is tolerated for 5 s; only a listener that never becomes ready fails, as `not_ready` with the last system state; retried automatically |
| 4 | The TLS certificate could not be prepared (Keychain locked or access denied) | §5 shows no certificate; activity shows “TLS certificate could not be prepared” | Classified as `tls_identity` with the Keychain status; no cleartext fallback |
| 5 | Local-network pairing switched on where TLS is unavailable | “requires the encrypted transport” | Unchanged: refused by design |

Additionally: address reuse is now **off**, so a conflict is always visible instead of two processes silently sharing a
port; after every successful start, a **self-test** sends a real request to `127.0.0.1:<port>` over the pinned TLS
connection and verifies the signed answer — the UI shows “Self-test OK” only when that real round trip worked.

## Where to see it in the app

* **Overview → Gateway**: the failure in plain words, the next automatic retry, and *Retry Now* / *Use a Free Port* /
  *Switch to the Running Copy*.
* **Account & Settings → Gateway diagnostics**: listener, interface, port owner(s), encryption, self-test, startup
  errors, *Copy Diagnostics* (no tokens, codes or keys).
* **Activity**: “Gateway listener failed” once per distinct cause, “Gateway listener recovered”, “Gateway self-test
  passed/failed”.

## Verified

| Where | What |
|---|---|
| Linux tests (`EnrollmentFlowTests`) | second copy refused by the lock; port held by another socket → `port_in_use` naming this test process via `lsof`, automatic retry recovers after the port is freed; self-test passes; move to a free port |
| macOS CI (`scripts/verify-on-mac.sh`) | the script occupies the gateway port before launching the real app → Origin reports the conflict and names the process → the script frees the port → Origin recovers on its own → self-test passes over pinned TLS 1.3 |
| Your Mac | **not run** — run `diagnose-gateway.sh` with your current build, then install 0.3.0 |

Loopback-only operation is unchanged. Nothing in this work exposes the gateway beyond `127.0.0.1`.
