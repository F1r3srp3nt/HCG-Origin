# Setup and verification

Everything here runs as your normal user. Nothing is installed system-wide.

## 1. Build

Requirements: macOS 13 or later, Xcode or the Command Line Tools (`xcode-select --install`).
First target: Apple silicon (`arm64`). For a universal build set `HCG_ORIGIN_ARCHS="arm64 x86_64"`.

```bash
./scripts/build-macos-app.sh
```

Produces:

* `build/release/HCG Origin.app` — version, build number and source commit are in its Info.plist
  (`CFBundleShortVersionString`, `CFBundleVersion`, `HCGSourceCommit`) and in **Account & Settings → About this build**.
* `build/release/HCG-Origin-<version>-<commit>-macOS.zip` and `BUILD-INFO.txt`.
* `build/tools/hcg-central-devservice` and `build/tools/hcg-connector-testclient` (development tools, not part of the app).

The build is signed ad hoc. A zip downloaded from GitHub carries the quarantine flag; macOS will
refuse to open it until you allow it: right-click the app → **Open**, or
System Settings → Privacy & Security → **Open Anyway**.

## 2. Scripted end-to-end verification (recommended)

```bash
./scripts/verify-on-mac.sh
```

It runs `swift test`, builds the release app and a UI-automation build of the same commit,
launches the release app through LaunchServices, then drives the automation build through the
full scenario: production unavailable → development sign-in → Start Pairing → test-client
enrollment (execution refused) → approval → connection → rejection → expired invitation →
duplicate enrollment → central outage → disconnect/reconnect → revocation → background setting
→ check that no invitation secret or token reaches Origin's data folder or log.

It uses a temporary data folder, a separate Keychain service name (deleted afterwards) and
ports 47811/47711, so your normal Origin data and Keychain items are untouched. It takes about
3–4 minutes, including two deliberate waits (invitation expiry and disconnect).
Results: `build/verification/report.md`, `build/verification/screenshots/`, `build/verification/logs/`.

macOS may ask once whether Terminal may record the screen (for `screencapture`). If you decline,
the script still saves the app's own window renderings (`*-rendered.png`).

## 3. Manual walk-through

**Terminal 1 — the local development service (NOT HCG):**

```bash
build/tools/hcg-central-devservice
```

Open the printed approver page, `http://127.0.0.1:47800/`. It is clearly labelled *Local development
service — not HCG, not ERP*.

**Origin:**

```bash
open "build/release/HCG Origin.app"
```

1. Overview shows **Production HCG not configured**: production pairing is disabled because nothing has been issued.
2. **Account & Settings** → Central service → **Local development service (not HCG)**. A yellow banner now stays on every screen.
3. Enter any email (for example `you@dev.local`) → **Sign In to Development Service**. The gateway registers and receives a `hcgdev_gw_…` ID.
4. **Start Pairing**. The invitation sheet shows the QR code, code and countdown. Click **Copy Code**.

**Terminal 2 — the development test client (not the Connector app):**

```bash
pbpaste | build/tools/hcg-connector-testclient enroll --code - --name "My test device" --wait
```

5. The client prints a **CHECK CODE**. Origin → Connection Requests shows the same code and the verification steps.
6. On the approver page, compare the check code and press **Approve** (or **Reject**).
7. The client prints the decision and the granted capabilities (`execution authorised: no`).

```bash
build/tools/hcg-connector-testclient connect
```

8. Origin → Devices shows the device **Connected**. Stop the client (Ctrl-C); after 35 s it shows **Disconnected**; start it again → **Reconnected** in Activity.
9. On the approver page, **Revoke** the device. Origin marks it revoked within seconds and the client prints `connection refused … device_revoked`.

Other cases to try: wait 5 minutes before using an invitation (expired), use one invitation twice
(used), enroll the same profile again (already enrolled), add `--request-execution` (refused by
the gateway), toggle **Simulated central outage** on the approver page (requests stay pending,
pairing is disabled, everything resumes afterwards).

Reset the test client with `build/tools/hcg-connector-testclient forget`; reset Origin by quitting it
and deleting `~/Library/Application Support/HCG Origin` and the Keychain items named `HCG Origin`.

## 4. Background operation

Off by default: closing the window quits Origin and stops the gateway. **Account & Settings →
Background operation → Keep the gateway running when the window is closed** keeps it running and
shows a menu bar icon with its status; quit from that menu. **Open HCG Origin when I log in** uses
`SMAppService` and shows its current status (move the app to /Applications first).

## 5. Where things are stored

| What | Where |
|---|---|
| Gateway key | Secure Enclave (Apple silicon) with its reference in the login Keychain, service `HCG Origin`; otherwise a P-256 key in the Keychain |
| Session tokens | Login Keychain, service `HCG Origin` |
| Settings, requests, devices (no secrets) | `~/Library/Application Support/HCG Origin/settings.json`, `state.json` |
| Activity log (no secrets) | `~/Library/Application Support/HCG Origin/activity.jsonl` |
| Diagnostic log | Unified log, subsystem `com.hakmicapitalgroup.hcgorigin` (never contains codes, secrets or tokens) |

After rebuilding, macOS may ask whether the new build may use the existing `HCG Origin` Keychain
items, because each ad-hoc build has a different signature. Choose **Always Allow**.

## 6. Linux (developers only)

The protocol, engine, development service and test client also build and test on Linux
(`swift test`), which CI runs on every push. The app itself is macOS only.
