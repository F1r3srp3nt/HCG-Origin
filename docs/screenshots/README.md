# Screenshots of the actual app

Captured by `scripts/verify-on-mac.sh` on GitHub Actions `macos-latest` (macOS 26.7.2, Apple M1 VM),
run 44390315988, commit `bc5d0be7e9ff`, while the script drove the real app. `00` is the release build
launched through LaunchServices; `01`–`13` are the UI-automation build of the same commit.

**Every development result shown (accounts, approvals, revocation) comes from the local development
service, not HCG.** The invitation codes visible in `04` were single-use, expired within minutes, and
belonged to a throwaway CI machine.

| File | Shows |
|---|---|
| 00-release-launch-fullscreen | Release app on first launch: gateway running, production HCG not configured |
| 01-overview-production-unconfigured | Production mode: pairing unavailable with the reason |
| 02-settings-production-unavailable | What is missing for production (nothing issued) |
| 03-overview-development-ready | Development service signed in, gateway ID issued centrally |
| 04-pairing-invitation | Pairing invitation: QR, code, countdown |
| 05-request-awaiting-decision | Request verification steps, check code, execution refused |
| 06-device-connected | Approved device connected with granted capabilities |
| 07-request-rejected | Rejected request |
| 08-central-outage | Central outage: pairing disabled, requests retried |
| 09-device-disconnected | Device disconnected after the timeout |
| 10-device-revoked | Revocation reflected |
| 11-activity | Activity log |
| 12-settings-development | Account & Settings in development mode (Secure Enclave key) |
| 13-fullscreen-menu-bar-status | Background operation on: menu bar status icon |
