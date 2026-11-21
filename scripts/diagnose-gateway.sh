#!/usr/bin/env bash
# Read-only diagnosis of the HCG Origin gateway on this Mac. Changes nothing, stops nothing,
# prints no secrets (no tokens, invitation codes or private keys).
#
#   ./scripts/diagnose-gateway.sh            (or: bash diagnose-gateway.sh from anywhere)
#   ./scripts/diagnose-gateway.sh > origin-diagnosis.txt
set -uo pipefail
[[ "$(uname)" == "Darwin" ]] || { echo "Run this on the Mac where HCG Origin runs."; exit 1; }
DATA="${HCG_ORIGIN_DATA_DIR:-$HOME/Library/Application Support/HCG Origin}"
with_timeout() { local t="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$t" "$@"; }
hr() { echo; echo "== $*"; }
CONCLUSIONS=()
conclude() { CONCLUSIONS+=("$*"); }

echo "HCG Origin gateway diagnosis — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)) · $(sysctl -n machdep.cpu.brand_string 2>/dev/null) · $(uname -m)"

hr "1. Running copies of HCG Origin"
PIDS=$(pgrep -x HCGOrigin || true)
if [[ -z "$PIDS" ]]; then
  echo "none running"
  conclude "HCG Origin is not running, so nothing is listening for it right now."
else
  for pid in $PIDS; do
    exe=$(ps -o comm= -p "$pid" 2>/dev/null)
    app="${exe%/Contents/MacOS/HCGOrigin}"
    ver=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist" 2>/dev/null || echo "?")
    build=$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist" 2>/dev/null || echo "?")
    commit=$(plutil -extract HCGSourceCommit raw "$app/Contents/Info.plist" 2>/dev/null || echo "?")
    echo "pid $pid · $app · version $ver ($build) · commit $commit · started $(ps -o lstart= -p "$pid")"
  done
  n=$(echo "$PIDS" | wc -w | tr -d ' ')
  [[ "$n" -gt 1 ]] && conclude "$n copies of HCG Origin are running. Only one can own the gateway port and data folder; quit the others."
fi

hr "2. Origin settings (non-secret)"
PORT=47700; LAN=false; MODE="?"
if [[ -f "$DATA/settings.json" ]]; then
  read -r PORT LAN MODE < <(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(s.get("listenPort",47700), str(s.get("allowLocalNetwork",False)).lower(), s.get("centralMode","?"))' "$DATA/settings.json")
  echo "data folder: $DATA"
  echo "listen port: $PORT · local network: $LAN · central mode: $MODE"
else
  echo "no settings.json in $DATA (defaults apply: port 47700, this Mac only)"
fi
if [[ -f "$DATA/gateway.lock" ]]; then
  lp=$(cat "$DATA/gateway.lock" 2>/dev/null | tr -d '\n')
  if [[ -n "$lp" ]] && kill -0 "$lp" 2>/dev/null; then echo "data-folder lock: held by running process $lp"
  else echo "data-folder lock: free (last holder $lp is not running)"; fi
fi

hr "3. Who listens on port $PORT"
OWN=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null)
if [[ -z "$OWN" ]]; then
  echo "nothing listens on TCP $PORT"
  [[ -n "$PIDS" ]] && conclude "Origin is running but nothing listens on port $PORT: the listener failed to start (see sections 5 and 6)."
else
  echo "$OWN"
  owner_pids=$(echo "$OWN" | awk 'NR>1{print $2}' | sort -u)
  for op in $owner_pids; do
    cmd=$(ps -o comm= -p "$op" 2>/dev/null)
    if [[ "$cmd" == */HCGOrigin ]]; then
      echo "→ port $PORT is held by HCG Origin (pid $op)"
    else
      echo "→ port $PORT is held by another program: $cmd (pid $op)"
      conclude "Port $PORT is used by another program ($cmd, pid $op). Quit it, or in Origin choose Settings → Gateway diagnostics → Use a Free Port. This script does not stop it."
    fi
  done
  echo "$OWN" | awk 'NR>1{print $9}' | grep -qv '^127\.0\.0\.1:' && [[ "$LAN" != "true" ]] && conclude "Something listens on port $PORT beyond 127.0.0.1 although local-network pairing is off — check the program in section 3."
fi

hr "4. Encrypted transport on 127.0.0.1:$PORT"
if [[ -n "$OWN" ]]; then
  HS=$(echo | with_timeout 10 openssl s_client -connect "127.0.0.1:$PORT" -tls1_3 2>&1)
  if echo "$HS" | grep -q "BEGIN CERTIFICATE"; then
    FP=$(echo "$HS" | openssl x509 -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
    echo "TLS 1.3 handshake OK · served key fingerprint $FP"
    echo "$HS" | grep -E "subject=|Protocol" | head -3
  else
    echo "TLS 1.3 handshake FAILED:"; echo "$HS" | tail -4
    conclude "The port answers but not with Origin's TLS 1.3 listener."
  fi
fi

hr "5. Gateway TLS certificate in the login Keychain"
if security find-certificate -c "HCG Origin TLS (HCG Origin)" -p > /tmp/.hcgo-cert.$$ 2>/dev/null && [[ -s /tmp/.hcgo-cert.$$ ]]; then
  openssl x509 -in /tmp/.hcgo-cert.$$ -noout -subject -enddate 2>/dev/null
  KFP=$(openssl x509 -in /tmp/.hcgo-cert.$$ -pubkey -noout | openssl pkey -pubin -outform DER | shasum -a 256 | cut -d' ' -f1)
  echo "certificate key fingerprint $KFP"
  [[ -n "${FP:-}" && "$FP" != "$KFP" ]] && conclude "The key served on port $PORT ($FP) is not Origin's certificate ($KFP): another program holds the port."
  n=$(security find-certificate -a -c "HCG Origin TLS (HCG Origin)" 2>/dev/null | grep -c '"labl"')
  [[ "$n" -gt 1 ]] && echo "note: $n certificates with this label exist"
else
  echo "no certificate named “HCG Origin TLS (HCG Origin)” (created at first successful listener start)"
fi
rm -f /tmp/.hcgo-cert.$$
leftover=$(security find-certificate -a -c "HCG Origin TLS (HCG Origin verification" 2>/dev/null | grep -c '"labl"' || true)
[[ "$leftover" -gt 0 ]] && echo "note: $leftover leftover verification certificate(s) from an interrupted verify-on-mac.sh run"

hr "6. Origin's own record of the listener (last 15 gateway/error entries)"
if [[ -f "$DATA/activity.jsonl" ]]; then
  python3 - "$DATA/activity.jsonl" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
rows = [r for r in rows if r.get("kind") in ("gateway", "error", "security")][-15:]
for r in rows: print(f'{r["at"]}  {r["severity"]:7}  {r["title"]} — {r["detail"][:220]}')
PY
else
  echo "no activity log"
fi

hr "7. Unified log (HCG Origin subsystem, last 2 h, errors and gateway lines)"
log show --last 2h --info --style compact --predicate 'subsystem == "com.hakmicapitalgroup.hcgorigin"' 2>/dev/null \
  | grep -Ei "listener|gateway|tls|error|lock|keychain" | tail -25 || echo "(no entries)"

hr "8. Production configuration of the running copy (public values only)"
for pid in $PIDS; do
  exe=$(ps -o comm= -p "$pid" 2>/dev/null); app="${exe%/Contents/MacOS/HCGOrigin}"
  for k in HCGConnectIssuer HCGConnectClientID HCGConnectRedirectURI HCGCentralOriginAPIBase; do
    v=$(plutil -extract "$k" raw "$app/Contents/Info.plist" 2>/dev/null)
    printf '%-24s %s\n' "$k" "${v:-<empty — not issued>}"
  done
done

hr "Conclusion"
if [[ ${#CONCLUSIONS[@]} -eq 0 ]]; then
  echo "No conflict found. If Origin still reports a failure, copy Settings → Gateway diagnostics → Copy Diagnostics and share it with this output."
else
  for c in "${CONCLUSIONS[@]}"; do echo "• $c"; done
fi
