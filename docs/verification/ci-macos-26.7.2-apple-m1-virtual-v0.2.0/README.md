# CI evidence — HCG Origin 0.2.0 (`hcg-origin/2`, TLS 1.3 pinned)

**GitHub Actions hosted runner, not your Mac.** macOS 26.7.2 (25G332), Apple M1 (virtual), Xcode 26.6 / Swift 6.3.3.
Run [44933222822](https://github.com/F1r3srp3nt/HCG-Origin/actions/runs/44933222822), commit `98b6711dded2`, build 16.
All checks passed — see [report.md](report.md). Every enrollment decision came from the **local development service,
not HCG**. `preservation-before.txt` / `-after.txt` are the hashes the script compared (identical). On a fresh CI runner no
normal HCG Origin data or Keychain items exist, so here the check only shows nothing was created or left behind;
on your Mac it compares your real data and Keychain items.

Results from your MacBook Pro M4 Max (macOS 27.0.1) belong in a separate `personal-…` folder, written by
`./scripts/verify-on-mac.sh --expect-macos 27.0.1 --expect-chip "M4 Max" --save-evidence`.
