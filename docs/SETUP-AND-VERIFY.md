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

## 1a. First: find out why your current copy says “Gateway listener failed”

Before installing 0.3.0, while the copy that shows the failure is still running:

```bash
./scripts/diagnose-gateway.sh > ~/Desktop/origin-diagnosis.txt
```

Read-only: it lists running copies of HCG Origin, which process owns the gateway port, whether that port answers
with Origin's TLS certificate, the Keychain certificate, recent gateway errors and whether that copy has production
values. It prints a short conclusion. Send the file back if the conclusion is not clear; it contains no tokens.
[GATEWAY-LISTENER.md](GATEWAY-LISTENER.md) explains each finding and what 0.3.0 does about it.

## 2. Scripted end-to-end verification on your MacBook Pro (M4 Max, macOS 27.0.1)

Quit HCG Origin first (the script refuses to run while it is open), then:

```bash
./scripts/verify-on-mac.sh --expect-macos 27.0.1 --expect-chip "M4 Max"
```

What it does — against the real app and the **local development service, not HCG**:

1. Records fingerprints of your normal data (`~/Library/Application Support/HCG Origin`, the test-client and
   development-service folders) and your normal Keychain items named `HCG Origin` and `HCG Origin TLS (HCG Origin)`.
   Only hashes and presence are recorded — never secret values.
2. `swift test` — includes real TLS 1.3 tests that create and delete a certificate labelled `HCG Origin TEST <uuid>`.
3. Builds the release app and a UI-automation build of the same commit; launches the release app through
   LaunchServices on port 47712 and checks it listens with TLS 1.3.
4. Drives the automation build on port 47711 with a development service on 47811 (not Origin's 47700 or the
   service's 47800): production unavailable, development sign-in, TLS checks (OpenSSL TLS 1.3 handshake with the
   pinned key, TLS 1.2 refused, cleartext refused, system trust refuses the self-signed certificate, wrong pin
   refused before any request), pairing, approval, connection, rejection, expiry, duplicate, outage, disconnect and
   reconnect, revocation, background setting, no secrets in logs.
5. Removes every test Keychain item and certificate it created, checks none are left, and compares your normal data
   and Keychain fingerprints with step 1. Any difference fails the run.

Takes about 5 minutes (two deliberate waits). Results go to
`build/verification/personal-macos-<version>-<chip>-<timestamp>/` (`build/verification/latest` points to it):
`report.md`, `environment.json`, `screenshots/`, `logs/` (including `preservation-before.txt` / `-after.txt`).
CI results are written under `ci-…` names and are never mixed with yours. `--expect-macos` / `--expect-chip` only
record whether the Mac matches; a mismatch is noted in the report, not hidden.

To keep the evidence in the repository: `--save-evidence` copies the report and screenshots to
`docs/verification/personal-macos-27.0.1-apple-m4-max/` for you to review and commit.

macOS may ask once whether Terminal may record the screen (for screenshots); declining only affects screenshots.
macOS 27.0.1 has not been tested by CI (GitHub runners use macOS 26.7.2); your run is the only evidence for it.

### 2a. Optional: the same run against a real HCG Server agent (Device Link)

Needs Go and a checkout of `F1r3srp3nt/hcg-server` on branch `claude/devicelink-testdevice`:

```bash
./scripts/verify-on-mac.sh --expect-macos 27.0.1 --expect-chip "M4 Max" --hcg-server ~/src/hcg-server
```

It builds HCG Server's Device Link fixture (a real agent with **mock** HCG identities, in a temporary folder — your
own HCG Server data and Keychain items are not touched) and its scriptable test device, connects the app to the
fixture, creates an invitation in the app, pairs the test device, approves it in the app, checks it comes online,
checks that a remote action is refused (`action_execution_disabled`), revokes it in the app and checks the device is
refused (`device_revoked`). Screenshots `14-hcg-server-request` and `15-hcg-server-devices`.

### 2b. Connecting your own HCG Server

In **Account & Settings → HCG Server**: *Connect to HCG Server on This Mac* reads the owner token from HCG Server's
own Keychain item (macOS asks once whether HCG Origin may read it), or paste the link printed by
`hcg-agent admin-url`. Only loopback addresses are accepted. Requires the central permission `origin.server.connect`.

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
   All of this travels over TLS 1.3 to the certificate pinned in the invitation; the client refuses any other key.

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
