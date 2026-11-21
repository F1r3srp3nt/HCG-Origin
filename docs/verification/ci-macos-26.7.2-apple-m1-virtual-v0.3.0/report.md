# HCG Origin — Mac verification report

**Environment: GitHub Actions hosted runner (CI) — NOT your Mac.**

| | |
|---|---|
| macOS | 26.7.2 (25G332) |
| Chip / model / memory | Apple M1 (Virtual) / VirtualMac2,1 / 7 GB |
| Architecture | arm64 |
| Commit | 33490f0ed4bf |
| Date (UTC) | 2026-11-21T20:25:01Z |
| CI run | 44943555051 |

**Central service in every enrollment below: the LOCAL DEVELOPMENT SERVICE (not HCG, not ERP).**
Production HCG verification was not exercised: no HCG Connect client or central API has been issued.

### Environment
- PASS: results folder: build/verification/ci-macos-26.7.2-apple-m1-virtual-run44943555051-20261121T202501Z

### Your normal HCG Origin data and Keychain (before)
- PASS: recorded fingerprints of 8 normal items (hashes only, no secret values)

### Swift tests
- PASS: Executed 50 tests, with 1 test skipped and 0 failures (0 unexpected) in 9.849 (9.864) seconds
- PASS: TLS transport tests ran (pinned TLS 1.3 end to end, wrong pin refused, cleartext refused, unpinned trust refused)

### Build
- PASS: release app: 0.3.0 (24) commit 33490f0ed4bf, arm64
- PASS: release app signature verifies (ad hoc)

### Release app launches through LaunchServices
- PASS: release app started through LaunchServices and its gateway started
- PASS: release app listens with TLS 1.3 and a pinned certificate (no cleartext listener)

### Local development service (NOT HCG)
- PASS: development service on 127.0.0.1:47811

### Launch the UI-automation build of the same commit
- PASS: app running (pid 6340): Version 0.3.0 (24) · commit 33490f0ed4bf · UI-automation build

### Gateway port conflict: identified and recovered
- PASS: Origin reports the port conflict and names the owner: Port 47711 is already used by “Python” (process 6329, /opt/homebrew/Cellar/python@3.15/3.15.2/Frameworks/Python.framework/Versions/3.15/Resources/Python.app/Contents/MacOS/Python).
- PASS: the listener recovered automatically once the port was free (no restart, nothing else stopped)
- PASS: gateway self-test passed: a real pinned TLS 1.3 request to 127.0.0.1:47711 returned a correctly signed answer

### Production HCG is unavailable (nothing issued)
- PASS: pairing unavailable in production: unavailable: Production enrollment is unavailable: HCG Origin is not yet registered with HCG Connect and the central HCG Origin API does not…

### Development sign-in and gateway registration (LOCAL DEVELOPMENT SERVICE)
- PASS: signed in to the development service; gateway ID issued centrally: hcgdev_gw_d461dff60e5dcf08b2

### Encrypted transport (hcg-origin/2)
- PASS: TLS 1.3 handshake succeeds (TLSv1.3); the served key matches the fingerprint Origin puts in invitations
- PASS: TLS 1.2 is refused
- PASS: cleartext HTTP to the gateway port gets no HTTP answer
- PASS: system trust refuses the self-signed gateway certificate (curl exit 60): there is no accept-any path
- PASS: an invitation with the wrong TLS pin is refused by the client before any request reaches Origin

### Pairing → enrollment request → approval → connection
- PASS: test client enrolled with check code 669 137; agent.execute refused by the gateway
- PASS: Origin shows the request awaiting decision with the same check code
- PASS: approved hcgdev_enr_8005f8fbdf4272b986 on the development approver page API (presence + status report)
- PASS: test client learned the approval; execution authorised: no
- PASS: device connected: hcgdev_dev_2396fa54bf8620d543=active/connected

### Rejected request
- PASS: rejection reached Origin and the test client (exit 2)

### Expired invitation and duplicate enrollment
- PASS: expired invitation refused: error: The invitation has expired. Ask for a new one in HCG Origin.
- PASS: duplicate enrollment refused (already_enrolled); invitation consumed

### Central outage
- PASS: outage shown; pairing unavailable while central is down
- PASS: central reachable again

### Disconnect and reconnect
- PASS: device shown as disconnected
- PASS: device reconnected

### Revocation
- PASS: revocation reflected in Origin; the device's next connection is refused (device_revoked)

### Background operation setting
- PASS: background operation toggled on (menu bar status shown) and off

### Secrets stay out of logs and state
- PASS: no invitation secret or session token in Origin's data folder or log

### Clean-up and preservation (after)
- PASS: all test Keychain items and TLS certificates were removed
- PASS: your normal HCG Origin data, test-client and development-service folders and Keychain items are unchanged
ALL CHECKS PASSED
