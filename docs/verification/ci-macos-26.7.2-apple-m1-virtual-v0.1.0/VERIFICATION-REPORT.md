# HCG Origin — Mac verification report

Date: 2026-11-18T20:31:50Z · macOS 26.7.2 · arm64 · Apple M1 (Virtual)
Commit: bc5d0be7e9ff
CI: true (GitHub Actions run 44390315988)

**Central service in every enrollment below: the LOCAL DEVELOPMENT SERVICE (not HCG, not ERP).**
Production HCG verification was not exercised: no HCG Connect client or central API has been issued.

### Swift tests
- PASS: Executed 22 tests, with 0 failures (0 unexpected) in 1.913 (1.921) seconds

### Build
- PASS: release app: 0.1.0 (9) commit bc5d0be7e9ff, arm64
- PASS: release app signature verifies (ad hoc)

### Release app launches through LaunchServices
- PASS: release app started, created its state and stayed running
- PASS: release app gateway started

### Local development service (NOT HCG)
- PASS: development service on 127.0.0.1:47811

### Launch the UI-automation build of the same commit
- PASS: app running (pid 5043): Version 0.1.0 (9) · commit bc5d0be7e9ff · UI-automation build

### Production HCG is unavailable (nothing issued)
- PASS: pairing unavailable in production: unavailable: Production enrollment is unavailable: HCG Origin is not yet registered with HCG Connect and the central HCG Origin API does not…

### Development sign-in and gateway registration (LOCAL DEVELOPMENT SERVICE)
- PASS: signed in to the development service; gateway ID issued centrally: hcgdev_gw_edf37d76cc889f55e0

### Pairing → enrollment request → approval → connection
- PASS: test client enrolled with check code 471 640; agent.execute refused by the gateway
- PASS: Origin shows the request awaiting decision with the same check code
- PASS: approved hcgdev_enr_d1e39b7ccaa0b7aeb4 on the development approver page API (presence + status report)
- PASS: test client learned the approval; execution authorised: no
- PASS: device connected: hcgdev_dev_8a0a164c15e5bf3173=active/connected

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
ALL CHECKS PASSED
