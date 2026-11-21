# CI verification — HCG Origin 0.3.0 on macOS 26.7.2 (Apple M1, virtual)

**GitHub Actions hosted runner — not your Mac.** Run
[44943555051](https://github.com/F1r3srp3nt/HCG-Origin/actions/runs/44943555051), commit `33490f0ed4bf`, build 24.
Every enrollment decision came from the **local development service, not HCG**.

Result: **ALL CHECKS PASSED** (`report.md`), including 50 Swift tests (one skipped: the real-HCG-Server test, which
needs HCG Server binaries that CI cannot check out; see `../linux-hcg-server-integration/`).

New in 0.3.0:

- **Gateway port conflict** (`screenshots/00b-port-conflict.png`). The script occupied the gateway port before
  launching the app. Origin named the process holding it and retried on its own. Once the port was freed it
  recovered without a restart, and the self-test passed over pinned TLS 1.3 (`03-overview-development-ready.png`
  shows *Self-test OK*).
- The HCG Server panel appears as *Not connected*. The `--hcg-server` flow is for your Mac.

An earlier run of this branch (44942679120, commit `912501a`) failed because the UI-automation build did not compile:
one engine method was not public. It was fixed in `fb9ab9c`; the release build was not affected.
