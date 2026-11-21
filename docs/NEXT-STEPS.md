# Next steps: HCG Terminal, Agent Runtime and other devices (after 0.3.0)

Order matters. Each step depends on the one before. Nothing here enables command execution until step 5, and step 5
needs explicit Owner approval.

## 1. Close the local gap on your Mac (you)

1. Run `scripts/diagnose-gateway.sh` with the copy that shows “Gateway listener failed”. Then install 0.3.0 and run
   `scripts/verify-on-mac.sh --expect-macos 27.0.1 --expect-chip "M4 Max" --hcg-server <hcg-server checkout>`.
2. In 0.3.0, the Overview must show **Listening · Self-test OK** before anything else is attempted.

## 2. Central registration (Owner, main site)

1. Review and apply `hcg.origin` and its ten features (draft PR F1r3srp3nt/hakmicapitalgroup#1). Keep
   `origin.actions.approve` disabled.
2. Register the **development** HCG Connect client for Origin (callback
   `com.hakmicapitalgroup.hcgorigin.dev://auth/callback`). Grant yourself the nine enabled features.
3. Decide D-O4: how `/check` evaluates a personal owner with no organisation.
4. Origin then runs acceptance tests C2 and C11–C13 with a real account. Production values go into a production build
   only after that.

## 3. Devices that use HCG Server Device Link (HCG Terminal, iPhone/iPad apps, Sentinel)

Device Link (`hcg.devicelink/1`) already does what these devices need: pairing by invitation, a device key per
installation, pinned TLS 1.3, signed requests, replay protection, HCG token and ERP `/check`, presence, revocation.
Origin is the owner's review and inventory console for it.

* **HCG Terminal** (`hcg.terminal`): vendor the Swift `HCGDeviceLink` client (`scripts/vendor-devicelink.sh` in
  HCG Server), add a “Pair with HCG Server” screen that takes the invitation code Origin shows, and use
  `devicelink.*` presence and report-sharing capabilities only. Do **not** add a shell or command surface; Terminal's
  terminal features must stay local to the Terminal device until step 5.
* **Prerequisites on HCG Server:** merge Device Link (`claude/lucid-mendel-egzyd6`) to `main`, then the test-device
  PR (F1r3srp3nt/HCG-Server#10). Register `hcg.server` and its `devicelink.*` features centrally
  (`docs/hcg-server/registry-review.sql`, still PROPOSED). Add each app (`hcg.terminal`, `hcg.sentinel`, …) to the
  agent's allowed-app list as its HCG Connect client is issued.
* **Origin as a Device Link installation** (so the Mac itself is registered centrally through the `hcg.origin` client)
  needs `hcg.origin` in that allowed-app list and the Origin client from step 2.

## 4. Devices that use HCG Connector (`hcg-origin/2`)

The Connector app does not exist yet. `docs/PROTOCOL.md` §9 is its checklist. The development test client is the
reference. Production enrollment additionally needs the central API `hcg-origin-central/1` (D-O5) and the ERP
workflow. Decide per device family whether it should use Connector → Origin or Device Link → HCG Server; running both
for the same device is not recommended.

## 5. Agent Runtime and remote actions (needs explicit Owner approval; not started)

Execution stays disabled in four independent places:

| Place | State |
|---|---|
| Origin's build | `ExecutionPolicy.enabledInThisBuild = false` |
| Central | `origin.actions.approve` disabled |
| Device Link | action registry empty, so every action returns `action_execution_disabled` |
| Devices | no command surface |

Enabling a first action needs a written design covering:

* a named, allow-listed action (no shell, no free-form commands) with typed parameters;
* central authorization per action and per device (`origin.actions.approve` enabled for named members only, plus a
  Device Link action feature). A licence or Founder status must never be enough;
* local approval on the **target device** by its owner, every time, showing the exact action and parameters;
* a signed, single-use, short-lived action request bound to the device key, with replay protection;
* full audit centrally, on Origin and on the device, plus immediate revocation.

The Agent Runtime repository has only a README today. Its authorization contract has to be written first. Origin
will implement only its side of that contract, and only after the Owner approves.
