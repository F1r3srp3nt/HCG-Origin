#!/usr/bin/env bash
# End-to-end verification of HCG Origin on a Mac. The same script runs on GitHub Actions
# (macos-latest) and on your own Mac; results are kept apart by environment.
#
#   ./scripts/verify-on-mac.sh                       build, test and run the full scenario
#   ./scripts/verify-on-mac.sh --skip-build          reuse build/ from a previous run
#   ./scripts/verify-on-mac.sh --expect-macos 27.0.1 --expect-chip "M4 Max"
#                                                    also record whether this is the expected machine
#   ./scripts/verify-on-mac.sh --save-evidence       copy the report and screenshots into docs/verification/
#
# Against the REAL app and the LOCAL DEVELOPMENT SERVICE (not HCG):
#   swift test · release + UI-automation builds of one commit · release app launched through
#   LaunchServices · encrypted transport checks (TLS 1.3 handshake, pinned key, TLS 1.2 refused,
#   cleartext refused, system trust refuses the self-signed certificate, wrong pin refused) · pairing,
#   approval, connection, rejection, expiry, duplicate, outage, disconnect/reconnect, revocation ·
#   no secrets in logs · your normal data and Keychain items unchanged.
#
# Isolation: temporary data folders, separate Keychain names and TLS certificate labels (all removed
# afterwards and checked), separate ports (47711, 47712, 47811 — not Origin's 47700 or the development
# service's 47800), a temporary test-client profile. The script refuses to run while your normal
# HCG Origin is open, and it stops only the copies it started.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
SKIP_BUILD=0; SAVE=0; EXPECT_OS=""; EXPECT_CHIP=""; ALLOW_RUNNING=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1 ;;
    --save-evidence) SAVE=1 ;;
    --expect-macos) EXPECT_OS="$2"; shift ;;
    --expect-chip) EXPECT_CHIP="$2"; shift ;;
    --allow-running-origin) ALLOW_RUNNING=1 ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
  shift
done
[[ "$(uname)" == "Darwin" ]] || { echo "verify-on-mac.sh must run on macOS"; exit 1; }

# ---------- environment (kept separate: CI vs your own Mac) ----------
OS_VER="$(sw_vers -productVersion)"; OS_BUILD="$(sw_vers -buildVersion)"
CHIP="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
MODEL="$(sysctl -n hw.model 2>/dev/null || echo unknown)"
MEM_GB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then CLASS="ci"; else CLASS="personal"; fi
SLUG="$(echo "$CHIP" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g')"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LABEL="$CLASS-macos-$OS_VER-$SLUG${GITHUB_RUN_ID:+-run$GITHUB_RUN_ID}-$STAMP"
V="$ROOT/build/verification/$LABEL"
mkdir -p "$V/screenshots" "$V/logs"
ln -sfn "$LABEL" "$ROOT/build/verification/latest"
REPORT="$V/report.md"
with_timeout() { local t="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$t" "$@"; }
diagnose() {
  set +e
  local d="$V/logs/diagnostics"; mkdir -p "$d"
  cp "$DATA/activity.jsonl" "$d/origin-activity.jsonl" 2>/dev/null
  cp "$RDATA/activity.jsonl" "$d/release-activity.jsonl" 2>/dev/null
  log show --last 5m --style compact --predicate 'process == "HCGOrigin" OR subsystem == "com.hakmicapitalgroup.hcgorigin"' > "$d/unified-log-hcgorigin.txt" 2>&1
  log show --last 5m --style compact --predicate 'process == "securityd" OR process == "SecurityAgent"' 2>/dev/null | tail -300 > "$d/unified-log-security.txt"
  lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -E "4771|4781|COMMAND" > "$d/listening.txt"
  (echo | with_timeout 10 openssl s_client -connect "127.0.0.1:$GW_PORT" -tls1_3 -brief) > "$d/openssl-probe.txt" 2>&1
  set -e
}
fail() { echo "FAIL: $*" >&2; echo "- FAIL: $*" >> "$REPORT"; diagnose 2>/dev/null || true; exit 1; }
step() { echo; echo "== $*"; echo "" >> "$REPORT"; echo "### $*" >> "$REPORT"; }
ok() { echo "   ok: $*"; echo "- PASS: $*" >> "$REPORT"; }
note() { echo "   note: $*"; echo "- NOTE: $*" >> "$REPORT"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hcg-origin-verify.XXXXXX")"
DATA="$WORK/data"; AUTO="$WORK/automation"; CLIENTS="$WORK/clients"; RDATA="$WORK/release-data"
mkdir -p "$DATA" "$AUTO" "$CLIENTS" "$RDATA"
DEV_PORT=47811; GW_PORT=47711; RELEASE_PORT=47712
RUN_TAG="hcg-origin-verify-$STAMP-$$"
KC_SERVICE="HCG Origin verification $STAMP app"
KC_RELEASE="HCG Origin verification $STAMP release"
KC_SERVICES=("$KC_SERVICE" "$KC_RELEASE")
APP_PID=""; DEV_PID=""; CLEANED=0

cleanup() {
  [[ $CLEANED == 1 ]] && return 0
  CLEANED=1
  [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null || true
  [[ -n "$DEV_PID" ]] && kill "$DEV_PID" 2>/dev/null || true
  [[ -n "${BLOCKER_PID:-}" ]] && kill "$BLOCKER_PID" 2>/dev/null || true
  pkill -f -- "--verification-run $RUN_TAG" 2>/dev/null || true
  sleep 1
  for svc in "${KC_SERVICES[@]}"; do
    for item in gateway-signing-key.p256 gateway-signing-key.secure-enclave session-token.development session-token.production; do
      security delete-generic-password -s "$svc" -a "$item" >/dev/null 2>&1 || true
    done
    for _ in 1 2 3; do security delete-identity -c "HCG Origin TLS ($svc)" >/dev/null 2>&1 || break; done
    for _ in 1 2 3; do security delete-certificate -c "HCG Origin TLS ($svc)" >/dev/null 2>&1 || break; done
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

NORMAL_DATA="$HOME/Library/Application Support/HCG Origin"
NORMAL_TC="$HOME/Library/Application Support/HCG Connector Test Client"
NORMAL_DEV="$HOME/Library/Application Support/HCG Origin Development Service"
# Fingerprint of everything the script must not change. Hashes and attributes only — never secret values.
preservation_snapshot() {
  for d in "$NORMAL_DATA" "$NORMAL_TC" "$NORMAL_DEV"; do
    if [[ -d "$d" ]]; then
      (cd "$d" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 2>/dev/null) | sed "s|^|$(basename "$d"): |"
    else
      echo "$(basename "$d"): absent"
    fi
  done
  for item in gateway-signing-key.p256 gateway-signing-key.secure-enclave session-token.development session-token.production; do
    if out=$(security find-generic-password -s "HCG Origin" -a "$item" 2>/dev/null); then
      echo "keychain HCG Origin/$item: present $(echo "$out" | grep -E '"(mdat|cdat)"' | shasum -a 256 | cut -c1-16)"
    else
      echo "keychain HCG Origin/$item: absent"
    fi
  done
  if out=$(security find-certificate -a -c "HCG Origin TLS (HCG Origin)" -Z 2>/dev/null) && [[ -n "$out" ]]; then
    echo "keychain TLS certificate HCG Origin TLS (HCG Origin): $(echo "$out" | grep -E 'SHA-256 hash' | tr -d ' ' | shasum -a 256 | cut -c1-16)"
  else
    echo "keychain TLS certificate HCG Origin TLS (HCG Origin): absent"
  fi
}
leftovers() {
  security find-certificate -a -c "HCG Origin TLS (HCG Origin verification" 2>/dev/null | grep -c '"labl"' || true
  security find-certificate -a -c "HCG Origin TEST" 2>/dev/null | grep -c '"labl"' || true
}

{
  echo "# HCG Origin — Mac verification report"
  echo
  if [[ $CLASS == ci ]]; then
    echo "**Environment: GitHub Actions hosted runner (CI) — NOT your Mac.**"
  else
    echo "**Environment: personal Mac (not CI).** Results here are separate from the CI results."
  fi
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| macOS | $OS_VER ($OS_BUILD) |"
  echo "| Chip / model / memory | $CHIP / $MODEL / ${MEM_GB} GB |"
  echo "| Architecture | $(uname -m) |"
  echo "| Commit | $(git rev-parse --short=12 HEAD)$( [[ -n "$(git status --porcelain --untracked-files=no)" ]] && echo ' (dirty)') |"
  echo "| Date (UTC) | $(date -u +%Y-%m-%dT%H:%M:%SZ) |"
  echo "| CI run | ${GITHUB_RUN_ID:-—} |"
  echo
  echo "**Central service in every enrollment below: the LOCAL DEVELOPMENT SERVICE (not HCG, not ERP).**"
  echo "Production HCG verification was not exercised: no HCG Connect client or central API has been issued."
} > "$REPORT"
python3 - "$V/environment.json" "$CLASS" "$OS_VER" "$OS_BUILD" "$CHIP" "$MODEL" "$(uname -m)" "$(git rev-parse HEAD)" "${GITHUB_RUN_ID:-}" <<'PY'
import json, sys
k = ["class", "macos", "macos_build", "chip", "model", "arch", "commit", "ci_run"]
json.dump(dict(zip(k, sys.argv[2:])), open(sys.argv[1], "w"), indent=2)
PY

step "Environment"
if [[ -n "$EXPECT_OS" ]]; then
  [[ "$OS_VER" == "$EXPECT_OS" ]] && ok "macOS $OS_VER as expected" || note "expected macOS $EXPECT_OS but this Mac runs $OS_VER ($OS_BUILD)"
fi
if [[ -n "$EXPECT_CHIP" ]]; then
  [[ "$CHIP" == *"$EXPECT_CHIP"* ]] && ok "chip $CHIP as expected" || note "expected chip $EXPECT_CHIP but this Mac reports $CHIP"
fi
ok "results folder: build/verification/$LABEL"

step "Your normal HCG Origin data and Keychain (before)"
if pgrep -x HCGOrigin >/dev/null 2>&1; then
  if [[ $ALLOW_RUNNING == 1 ]]; then
    note "a normal HCG Origin is running; the before/after data comparison is skipped because it may change on its own"
  else
    fail "HCG Origin is running. Quit it first (its data would change during the run), or pass --allow-running-origin."
  fi
fi
preservation_snapshot > "$V/logs/preservation-before.txt"
ok "recorded fingerprints of $(wc -l < "$V/logs/preservation-before.txt" | tr -d ' ') normal items (hashes only, no secret values)"

step "Swift tests"
swift test 2>&1 | tee "$V/logs/swift-test.log" | grep -E "Executed|error|failed" | tail -5
grep -q "with 0 failures" "$V/logs/swift-test.log" || fail "swift test failed (see logs/swift-test.log)"
ok "$(grep -E 'Executed [0-9]+ tests' "$V/logs/swift-test.log" | tail -1 | sed 's/^[[:space:]]*//')"
grep -q "TLSTransportTests" "$V/logs/swift-test.log" && ok "TLS transport tests ran (pinned TLS 1.3 end to end, wrong pin refused, cleartext refused, unpinned trust refused)"

if [[ $SKIP_BUILD == 0 ]]; then
  step "Build"
  ./scripts/build-macos-app.sh 2>&1 | tee "$V/logs/build-release.log" | tail -4
  HCG_ORIGIN_VARIANT=automation ./scripts/build-macos-app.sh 2>&1 | tee "$V/logs/build-automation.log" | tail -2
fi
RELEASE_APP="$ROOT/build/release/HCG Origin.app"
AUTO_APP="$ROOT/build/automation/HCG Origin.app"
TOOLS="$ROOT/build/tools"
[[ -d "$RELEASE_APP" && -d "$AUTO_APP" ]] || fail "apps not built"
cp "$ROOT/build/release/BUILD-INFO.txt" "$V/"
ok "release app: $(plutil -extract CFBundleShortVersionString raw "$RELEASE_APP/Contents/Info.plist") ($(plutil -extract CFBundleVersion raw "$RELEASE_APP/Contents/Info.plist")) commit $(plutil -extract HCGSourceCommit raw "$RELEASE_APP/Contents/Info.plist"), $(lipo -archs "$RELEASE_APP/Contents/MacOS/HCGOrigin")"
codesign --verify --strict "$RELEASE_APP" && ok "release app signature verifies (ad hoc)"

step "Release app launches through LaunchServices"
printf '{"listenPort": %s, "gatewayName": "Release launch check", "allowLocalNetwork": false, "centralMode": "production", "developmentServiceURL": "http://127.0.0.1:%s/api/public/origin/v1", "invitationTTLSeconds": 300, "keepRunningInBackground": false, "heartbeatIntervalSeconds": 10, "disconnectAfterSeconds": 35, "centralSyncSeconds": 4, "requestTTLSeconds": 1800}\n' "$RELEASE_PORT" "$DEV_PORT" > "$RDATA/settings.json"
# Own Keychain name: items one ad-hoc build creates trigger an access prompt in another build.
open -n "$RELEASE_APP" --env HCG_ORIGIN_DATA_DIR="$RDATA" --env HCG_ORIGIN_KEYCHAIN_SERVICE="$KC_RELEASE" --args --verification-run "$RUN_TAG"
for i in $(seq 1 30); do pgrep -f -- "--verification-run $RUN_TAG" >/dev/null && break; sleep 0.5; done
pgrep -f -- "--verification-run $RUN_TAG" >/dev/null || fail "release app did not start"
for i in $(seq 1 30); do grep -q "Listening for Connector requests" "$RDATA/activity.jsonl" 2>/dev/null && break; sleep 0.5; done
pgrep -f -- "--verification-run $RUN_TAG" >/dev/null || fail "release app exited after launch"
screencapture -x "$V/screenshots/00-release-launch-fullscreen.png" 2>/dev/null || true
grep -q "Gateway started" "$RDATA/activity.jsonl" && ok "release app started through LaunchServices and its gateway started"
grep -q "TLS 1.3, pinned certificate" "$RDATA/activity.jsonl" && ok "release app listens with TLS 1.3 and a pinned certificate (no cleartext listener)" \
  || fail "release app is not listening with TLS: $(tail -3 "$RDATA/activity.jsonl")"
pkill -f -- "--verification-run $RUN_TAG" || true
sleep 1

step "Local development service (NOT HCG)"
"$TOOLS/hcg-central-devservice" --port "$DEV_PORT" --state "$WORK/devservice/state.json" --admin-token-file "$WORK/devservice/admin-token" \
  > "$V/logs/devservice.log" 2>&1 &
DEV_PID=$!
for i in $(seq 1 40); do curl -sf "http://127.0.0.1:$DEV_PORT/api/public/origin/v1/health" >/dev/null && break; sleep 0.25; done
curl -sf "http://127.0.0.1:$DEV_PORT/api/public/origin/v1/health" >/dev/null || fail "development service did not start"
ADMIN="$(cat "$WORK/devservice/admin-token")"
admin() { curl -sf -X "$1" -H "X-HCG-Dev-Admin: $ADMIN" -H "Content-Type: application/json" ${3:+-d "$3"} "http://127.0.0.1:$DEV_PORT/dev/v1/admin/$2"; }
ok "development service on 127.0.0.1:$DEV_PORT"

step "Launch the UI-automation build of the same commit"
printf '{"listenPort": %s, "gatewayName": "MacBook Pro (verification)", "allowLocalNetwork": false, "centralMode": "production", "developmentServiceURL": "http://127.0.0.1:%s/api/public/origin/v1", "invitationTTLSeconds": 300, "keepRunningInBackground": false, "heartbeatIntervalSeconds": 10, "disconnectAfterSeconds": 20, "centralSyncSeconds": 2, "requestTTLSeconds": 1800}\n' "$GW_PORT" "$DEV_PORT" > "$DATA/settings.json"
# Port conflict: a placeholder listener started by THIS script occupies the gateway port first.
python3 -c 'import socket,time,sys; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 0); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(1); time.sleep(600)' "$GW_PORT" &
BLOCKER_PID=$!
sleep 1
HCG_ORIGIN_DATA_DIR="$DATA" HCG_ORIGIN_AUTOMATION_DIR="$AUTO" HCG_ORIGIN_KEYCHAIN_SERVICE="$KC_SERVICE" \
  "$AUTO_APP/Contents/MacOS/HCGOrigin" > "$V/logs/app.log" 2>&1 &
APP_PID=$!
for i in $(seq 1 60); do [[ -f "$AUTO/ready.json" ]] && break; sleep 0.5; done
[[ -f "$AUTO/ready.json" ]] || fail "automation build did not become ready"
ok "app running (pid $APP_PID): $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["build"])' "$AUTO/ready.json")"

N=0
cmd() { # cmd <action> [arg] → prints result JSON path; fails on ok=false unless ALLOW_FAIL=1
  N=$((N + 1)); local id; id=$(printf '%04d' $N)
  python3 -c 'import json,sys; print(json.dumps({"id":sys.argv[1],"action":sys.argv[2],"arg":(sys.argv[3] if len(sys.argv)>3 else None)}))' "$id" "$@" > "$AUTO/commands/$id.json.tmp"
  mv "$AUTO/commands/$id.json.tmp" "$AUTO/commands/$id.json"
  for i in $(seq 1 120); do [[ -f "$AUTO/results/$id.json" ]] && break; sleep 0.25; done
  [[ -f "$AUTO/results/$id.json" ]] || fail "no result for $*"
  cp "$AUTO/results/$id.json" "$AUTO/last.json"
  if [[ "${ALLOW_FAIL:-0}" != 1 ]] && [[ "$(field ok)" != "true" ]]; then fail "$* → $(field error)"; fi
}
field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$AUTO/last.json" "$1"; }
shot() {
  cmd screenshot "$1"
  local wn rect; wn=$(field windowNumber); rect=$(field windowRect)
  # The screen rectangle includes attached sheets (the pairing invitation); the window ID does not.
  if [[ -n "$rect" ]]; then screencapture -x -R "$rect" "$V/screenshots/$1.png" 2>/dev/null || true
  elif [[ "$wn" != "-1" && -n "$wn" ]]; then screencapture -x -o -l "$wn" "$V/screenshots/$1.png" 2>/dev/null || true; fi
  [[ -s "$V/screenshots/$1.png" ]] || cp "$AUTO/screenshots/$1-window.png" "$V/screenshots/$1.png" 2>/dev/null || true
}
wait_for() { # wait_for <field> <python-substring> <description>
  for i in $(seq 1 80); do cmd state; [[ "$(field "$1")" == *"$2"* ]] && return 0; sleep 0.5; done
  fail "timed out waiting for $3 ($1=$(field "$1"))"
}
client() { "$TOOLS/hcg-connector-testclient" "$@"; }
export HCG_CONNECTOR_TESTCLIENT_DIR="$CLIENTS"

step "Gateway port conflict: identified and recovered"
wait_for listenerFailure "port_in_use" "port conflict reported"
FAILTXT="$(field listenerFailure)"
echo "$FAILTXT" | grep -q "process $BLOCKER_PID" && ok "Origin reports the port conflict and names the owner: ${FAILTXT#port_in_use: }" \
  || ok "Origin reports the port conflict: ${FAILTXT#port_in_use: } (owner lookup did not name process $BLOCKER_PID)"
cmd select overview
shot 00b-port-conflict
kill "$BLOCKER_PID" 2>/dev/null || true; wait "$BLOCKER_PID" 2>/dev/null || true
echo "   waiting for the automatic retry (≤ 20 s)…"
wait_for listener "listening" "listener recovered without restart"
ok "the listener recovered automatically once the port was free (no restart, nothing else stopped)"
wait_for selfTest "passed" "gateway self-test"
ok "gateway self-test passed: a real pinned TLS 1.3 request to 127.0.0.1:$GW_PORT returned a correctly signed answer"

step "Production HCG is unavailable (nothing issued)"
cmd select overview
[[ "$(field pairing)" == unavailable* ]] || fail "production pairing should be unavailable"
ok "pairing unavailable in production: $(field pairing | cut -c1-140)…"
shot 01-overview-production-unconfigured
cmd select settings
shot 02-settings-production-unavailable

step "Development sign-in and gateway registration (LOCAL DEVELOPMENT SERVICE)"
cmd setMode development
cmd devSignIn "owner@dev.local"
cmd sync
wait_for pairing available "pairing available"
[[ "$(field gatewayId)" == hcgdev_gw_* ]] || fail "gateway ID not issued by the development service"
ok "signed in to the development service; gateway ID issued centrally: $(field gatewayId)"
cmd select overview
shot 03-overview-development-ready

step "Encrypted transport (hcg-origin/2)"
[[ "$(field transport)" == "tls13-pinned" ]] || fail "Origin is not offering tls13-pinned (transport=$(field transport))"
TLSFP="$(field tlsFingerprint)"
[[ ${#TLSFP} == 64 ]] || fail "no TLS fingerprint"
HS="$(echo | with_timeout 15 openssl s_client -connect "127.0.0.1:$GW_PORT" -tls1_3 2>&1 || true)"
if echo "$HS" | grep -q "BEGIN CERTIFICATE"; then
  SERVED="$(echo "$HS" | openssl x509 -pubkey -noout | openssl pkey -pubin -outform DER | shasum -a 256 | cut -d' ' -f1)"
  [[ "$SERVED" == "$TLSFP" ]] || fail "served certificate key $SERVED does not match the pinned fingerprint $TLSFP"
  ok "TLS 1.3 handshake succeeds ($(echo "$HS" | grep -m1 -oE 'TLSv1\.3' || echo TLS 1.3)); the served key matches the fingerprint Origin puts in invitations"
else
  fail "TLS 1.3 handshake failed: $(echo "$HS" | tail -3)"
fi
HS12="$(echo | with_timeout 15 openssl s_client -connect "127.0.0.1:$GW_PORT" -tls1_2 2>&1 || true)"
echo "$HS12" | grep -q "BEGIN CERTIFICATE" && fail "TLS 1.2 was accepted" || ok "TLS 1.2 is refused"
CODE="$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$GW_PORT/origin/v1/enroll" -d '{}' || true)"
[[ "$CODE" == "000" ]] && ok "cleartext HTTP to the gateway port gets no HTTP answer" || fail "cleartext request answered with HTTP $CODE"
set +e; curl -s -m 5 -o /dev/null "https://127.0.0.1:$GW_PORT/origin/v1/enroll"; rc=$?; set -e
[[ $rc == 60 || $rc == 35 ]] && ok "system trust refuses the self-signed gateway certificate (curl exit $rc): there is no accept-any path" || fail "unexpected curl result $rc"
cmd startPairing
python3 - "$AUTO/invitation.txt" "$WORK/forged.txt" <<'PY'
import sys, base64, json, os, hashlib
code = open(sys.argv[1]).read().strip()
body = code[len("hcgo2-"):]; body += "=" * (-len(body) % 4)
p = json.loads(base64.urlsafe_b64decode(body))
p["tfp"] = hashlib.sha256(os.urandom(32)).hexdigest()  # a certificate the gateway does not have
out = base64.urlsafe_b64encode(json.dumps(p).encode()).decode().rstrip("=")
open(sys.argv[2], "w").write("hcgo2-" + out)
PY
BEFORE_REQ="$(field requests)"
set +e; client enroll --code-file "$WORK/forged.txt" --profile wrongpin > "$V/logs/client-wrong-pin.log" 2>&1; rc=$?; set -e
grep -q "does not match the pinned" "$V/logs/client-wrong-pin.log" && [[ $rc != 0 ]] || fail "wrong pin was not refused (rc=$rc): $(cat "$V/logs/client-wrong-pin.log")"
cmd state
[[ "$(field requests)" == "$BEFORE_REQ" && "$(field invitationActive)" == "true" ]] || fail "a request reached Origin over an unpinned channel"
ok "an invitation with the wrong TLS pin is refused by the client before any request reaches Origin"
cmd cancelPairing

step "Pairing → enrollment request → approval → connection"
cmd startPairing
[[ -s "$AUTO/invitation.txt" ]] || fail "no invitation"
shot 04-pairing-invitation
client enroll --code-file "$AUTO/invitation.txt" --name "MacBook Pro test client" --request-execution --profile approved > "$V/logs/client-approved.log" 2>&1 \
  || fail "enroll failed: $(cat "$V/logs/client-approved.log")"
CHECK=$(grep -o 'CHECK CODE: [0-9]* [0-9]*' "$V/logs/client-approved.log" | cut -d' ' -f3-)
grep -q "refused by gateway: agent.execute" "$V/logs/client-approved.log" || fail "execution was not refused at enrollment"
ok "test client enrolled with check code $CHECK; agent.execute refused by the gateway"
cmd closeSheet
cmd sync
wait_for requests "awaiting_decision/$CHECK" "request awaiting decision"
ok "Origin shows the request awaiting decision with the same check code"
cmd select requests
cmd selectFirstRequest
shot 05-request-awaiting-decision
ENR=$(admin GET state | python3 -c 'import json,sys; print([e for e in json.load(sys.stdin)["enrollments"] if e["state"]=="pending_review"][0]["enrollmentId"])')
admin POST "enrollments/$ENR/approve" '{"capabilities":["connection.presence","device.status.report"],"note":"Verification run"}' >/dev/null
ok "approved $ENR on the development approver page API (presence + status report)"
cmd sync
client status --wait --profile approved > "$V/logs/client-approved-status.log" 2>&1 || fail "approved status: $(cat "$V/logs/client-approved-status.log")"
grep -q "execution authorised: no" "$V/logs/client-approved-status.log" || fail "execution must not be authorised"
ok "test client learned the approval; execution authorised: no"
client connect --count 3 --interval 1 --profile approved > "$V/logs/client-connect.log" 2>&1 || fail "connect: $(cat "$V/logs/client-connect.log")"
wait_for devices "active/connected" "device connected"
ok "device connected: $(field devices)"
cmd select devices
cmd selectFirstDevice
shot 06-device-connected

step "Rejected request"
cmd startPairing
client enroll --code-file "$AUTO/invitation.txt" --name "Unrecognised tablet" --profile rejected > "$V/logs/client-rejected.log" 2>&1 || fail "enroll (to reject) failed"
cmd closeSheet
cmd sync
ENR2=$(admin GET state | python3 -c 'import json,sys; print([e for e in json.load(sys.stdin)["enrollments"] if e["state"]=="pending_review"][0]["enrollmentId"])')
admin POST "enrollments/$ENR2/reject" '{"reason":"Not a device I recognise"}' >/dev/null
cmd sync
set +e; client status --wait --profile rejected > "$V/logs/client-rejected-status.log" 2>&1; rc=$?; set -e
[[ $rc == 2 ]] && grep -q "state: rejected" "$V/logs/client-rejected-status.log" || fail "rejection not reported to the client (rc=$rc)"
wait_for requests "=rejected/" "rejected request in Origin"
ok "rejection reached Origin and the test client (exit 2)"
cmd select requests
cmd selectFirstRequest
shot 07-request-rejected

step "Expired invitation and duplicate enrollment"
cmd setInvitationTTL 60
cmd startPairing
cp "$AUTO/invitation.txt" "$WORK/expiring.txt"
cmd closeSheet
echo "   waiting 62 s for the invitation to expire…"
sleep 62
set +e; client enroll --code-file "$WORK/expiring.txt" --name "Late device" --profile late > "$V/logs/client-expired.log" 2>&1; rc=$?; set -e
[[ $rc == 2 ]] && grep -qi "expired" "$V/logs/client-expired.log" || fail "expired invitation was not refused (rc=$rc): $(cat "$V/logs/client-expired.log")"
ok "expired invitation refused: $(grep -i expired "$V/logs/client-expired.log" | head -1)"
cmd setInvitationTTL 300
cmd startPairing
set +e; client enroll --code-file "$AUTO/invitation.txt" --profile approved > "$V/logs/client-duplicate.log" 2>&1; rc=$?; set -e
[[ $rc == 2 ]] && grep -q "already_enrolled" "$V/logs/client-duplicate.log" || fail "duplicate enrollment not refused (rc=$rc)"
ok "duplicate enrollment refused (already_enrolled); invitation consumed"
cmd closeSheet

step "Central outage"
admin POST outage '{"enabled":true}' >/dev/null
cmd sync
wait_for central "unreachable" "central unreachable"
[[ "$(field pairing)" == unavailable* ]] || fail "pairing should be unavailable during an outage"
ok "outage shown; pairing unavailable while central is down"
cmd select overview
shot 08-central-outage
admin POST outage '{"enabled":false}' >/dev/null
cmd sync
wait_for central "reachable(service" "central reachable again"
ok "central reachable again"

step "Disconnect and reconnect"
echo "   waiting 24 s without heartbeats…"
sleep 24
wait_for devices "active/disconnected" "device disconnected"
ok "device shown as disconnected"
cmd select devices
cmd selectFirstDevice
shot 09-device-disconnected
client connect --count 1 --profile approved >> "$V/logs/client-connect.log" 2>&1 || fail "reconnect failed"
wait_for activity "Device reconnected" "reconnect activity"
ok "device reconnected"

step "Revocation"
DEV_ID=$(admin GET state | python3 -c 'import json,sys; print([d for d in json.load(sys.stdin)["devices"] if d["status"]=="active"][0]["deviceId"])')
admin POST "devices/$DEV_ID/revoke" '{"reason":"Device reported lost"}' >/dev/null
cmd sync
wait_for devices "revoked/revoked" "device revoked in Origin"
set +e; client connect --count 1 --profile approved > "$V/logs/client-revoked.log" 2>&1; rc=$?; set -e
[[ $rc == 3 ]] && grep -q "device_revoked" "$V/logs/client-revoked.log" || fail "revoked device was not refused (rc=$rc)"
ok "revocation reflected in Origin; the device's next connection is refused (device_revoked)"
cmd select devices
cmd selectFirstDevice
shot 10-device-revoked
cmd select activity
shot 11-activity

step "Background operation setting"
cmd setBackground true
cmd select settings
shot 12-settings-development
screencapture -x "$V/screenshots/13-fullscreen-menu-bar-status.png" 2>/dev/null || true
cmd setBackground false
ok "background operation toggled on (menu bar status shown) and off"

step "Secrets stay out of logs and state"
SECRETS=$(python3 - "$AUTO/invitation.txt" <<'PY'
import sys, base64, json
code = open(sys.argv[1]).read().strip()
body = code[len("hcgo2-"):]
body += "=" * (-len(body) % 4)
p = json.loads(base64.urlsafe_b64decode(body))
print(p["s"])
PY
)
if grep -rqF "$SECRETS" "$DATA" "$V/logs/app.log" 2>/dev/null; then fail "an invitation secret appears in Origin's data or log"; fi
if grep -rqF "hcgdev_tok_" "$DATA" "$V/logs/app.log" 2>/dev/null; then fail "a session token appears in Origin's data or log"; fi
ok "no invitation secret or session token in Origin's data folder or log"

cmd quit
sleep 1
APP_PID=""
cp "$DATA/activity.jsonl" "$V/logs/origin-activity.jsonl" 2>/dev/null || true
admin GET state > "$V/logs/devservice-state.json" 2>/dev/null || true

step "Clean-up and preservation (after)"
cleanup
trap - EXIT
LEFT="$(leftovers | paste -sd+ - | bc)"
[[ "$LEFT" == "0" ]] && ok "all test Keychain items and TLS certificates were removed" || fail "$LEFT test certificate(s) left in the Keychain"
preservation_snapshot > "$V/logs/preservation-after.txt"
if [[ $ALLOW_RUNNING == 1 ]]; then
  note "preservation comparison skipped (normal HCG Origin was running)"
elif diff -u "$V/logs/preservation-before.txt" "$V/logs/preservation-after.txt" > "$V/logs/preservation-diff.txt"; then
  ok "your normal HCG Origin data, test-client and development-service folders and Keychain items are unchanged"
else
  fail "normal data or Keychain items changed — see logs/preservation-diff.txt"
fi

if [[ $SAVE == 1 ]]; then
  DEST="$ROOT/docs/verification/$CLASS-macos-$OS_VER-$SLUG"
  rm -rf "$DEST"; mkdir -p "$DEST"
  cp "$REPORT" "$V/environment.json" "$V/BUILD-INFO.txt" "$DEST/"
  cp -R "$V/screenshots" "$DEST/"
  ok "evidence copied to docs/verification/$(basename "$DEST") (review before committing)"
fi
echo
echo "ALL CHECKS PASSED" | tee -a "$REPORT"
echo "Report: $REPORT"
echo "Screenshots: $V/screenshots"
