#!/usr/bin/env bash
# End-to-end verification of HCG Origin on a Mac (also what CI runs on macos-latest).
#
#   ./scripts/verify-on-mac.sh            build, test, and run the full enrollment scenario
#   ./scripts/verify-on-mac.sh --skip-build   reuse build/ from a previous run
#
# What it does, against the REAL app and the LOCAL DEVELOPMENT SERVICE (not HCG):
#   1. swift test (protocol + engine end-to-end tests)
#   2. builds the release app and a UI-automation build of the same commit
#   3. launches the release app through LaunchServices (as Finder does) and checks it starts
#   4. drives the automation build like a person: production state, development sign-in,
#      Start Pairing, a Connector test client enrolls, approval, connection, rejection,
#      expired invitation, duplicate enrollment, central outage, disconnect/reconnect,
#      revocation — capturing screenshots of the actual window at each step
#
# Isolation: a temporary data folder, a separate Keychain service name (removed afterwards),
# a separate development-service port. Your normal HCG Origin data and Keychain items are not touched.
# Results: build/verification/ (report.md, screenshots/, logs/).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
SKIP_BUILD=0
[[ "${1:-}" == "--skip-build" ]] && SKIP_BUILD=1
fail() { echo "FAIL: $*" >&2; echo "- FAIL: $*" >> "$REPORT"; exit 1; }
[[ "$(uname)" == "Darwin" ]] || { echo "verify-on-mac.sh must run on macOS"; exit 1; }

V="$ROOT/build/verification"
rm -rf "$V"; mkdir -p "$V/screenshots" "$V/logs"
REPORT="$V/report.md"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hcg-origin-verify.XXXXXX")"
DATA="$WORK/data"; AUTO="$WORK/automation"; CLIENTS="$WORK/clients"
mkdir -p "$DATA" "$AUTO" "$CLIENTS"
DEV_PORT="${HCG_VERIFY_DEV_PORT:-47811}"
GW_PORT="${HCG_VERIFY_GATEWAY_PORT:-47711}"
KC_SERVICE="HCG Origin verification $(date +%s)"
APP_PID=""; DEV_PID=""

cleanup() {
  [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null || true
  [[ -n "$DEV_PID" ]] && kill "$DEV_PID" 2>/dev/null || true
  pkill -f "$WORK" 2>/dev/null || true
  for svc in "$KC_SERVICE" "$KC_SERVICE release"; do
    for item in gateway-signing-key.p256 gateway-signing-key.secure-enclave session-token.development session-token.production; do
      security delete-generic-password -s "$svc" -a "$item" >/dev/null 2>&1 || true
    done
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

step() { echo; echo "== $*"; echo "" >> "$REPORT"; echo "### $*" >> "$REPORT"; }
ok() { echo "   ok: $*"; echo "- PASS: $*" >> "$REPORT"; }

{
  echo "# HCG Origin — Mac verification report"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ) · $(sw_vers -productName) $(sw_vers -productVersion) · $(uname -m) · $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo cpu?)"
  echo "Commit: $(git rev-parse --short=12 HEAD)$( [[ -n "$(git status --porcelain --untracked-files=no)" ]] && echo ' (dirty)')"
  echo "CI: ${CI:-no} ${GITHUB_RUN_ID:+(GitHub Actions run $GITHUB_RUN_ID)}"
  echo
  echo "**Central service in every enrollment below: the LOCAL DEVELOPMENT SERVICE (not HCG, not ERP).**"
  echo "Production HCG verification was not exercised: no HCG Connect client or central API has been issued."
} > "$REPORT"

step "Swift tests"
swift test 2>&1 | tee "$V/logs/swift-test.log" | grep -E "Executed|error|failed" | tail -5
grep -q "with 0 failures" "$V/logs/swift-test.log" || fail "swift test failed (see logs/swift-test.log)"
ok "$(grep -E 'Executed [0-9]+ tests' "$V/logs/swift-test.log" | tail -1 | sed 's/^[[:space:]]*//')"

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
# A separate Keychain service: items one ad-hoc build creates trigger an access prompt in another build.
open -n "$RELEASE_APP" --env HCG_ORIGIN_DATA_DIR="$WORK/release-data" --env HCG_ORIGIN_KEYCHAIN_SERVICE="$KC_SERVICE release"
for i in $(seq 1 30); do pgrep -f "$RELEASE_APP/Contents/MacOS/HCGOrigin" >/dev/null && break; sleep 0.5; done
pgrep -f "$RELEASE_APP/Contents/MacOS/HCGOrigin" >/dev/null || fail "release app did not start"
sleep 4
pgrep -f "$RELEASE_APP/Contents/MacOS/HCGOrigin" >/dev/null || fail "release app exited after launch"
screencapture -x "$V/screenshots/00-release-launch-fullscreen.png" 2>/dev/null || true
[[ -f "$WORK/release-data/state.json" ]] && ok "release app started, created its state and stayed running" || fail "release app wrote no state"
grep -q "Gateway started" "$WORK/release-data/activity.jsonl" && ok "release app gateway started"
pkill -f "$RELEASE_APP/Contents/MacOS/HCGOrigin" || true
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
  local wn; wn=$(field windowNumber)
  if [[ "$wn" != "-1" && -n "$wn" ]]; then screencapture -x -o -l "$wn" "$V/screenshots/$1.png" 2>/dev/null || true; fi
  [[ -s "$V/screenshots/$1.png" ]] || cp "$AUTO/screenshots/$1-window.png" "$V/screenshots/$1.png" 2>/dev/null || true
}
wait_for() { # wait_for <field> <python-substring> <description>
  for i in $(seq 1 80); do cmd state; [[ "$(field "$1")" == *"$2"* ]] && return 0; sleep 0.5; done
  fail "timed out waiting for $3 ($1=$(field "$1"))"
}
client() { "$TOOLS/hcg-connector-testclient" "$@"; }
export HCG_CONNECTOR_TESTCLIENT_DIR="$CLIENTS"

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
wait_for central "reachable" "central reachable again"
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
body = code[len("hcgo1-"):]
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
echo
echo "ALL CHECKS PASSED" | tee -a "$REPORT"
echo "Report: $REPORT"
echo "Screenshots: $V/screenshots"
