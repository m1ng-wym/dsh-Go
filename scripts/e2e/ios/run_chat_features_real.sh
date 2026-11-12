#!/usr/bin/env bash
# T32 · L4-Real chat-features runner: real opencode-go model, real on-device
# engine, and the chat behaviours that only a real model can prove — steer,
# queue/withdraw, stop, tool row, message actions (copy/quote/regenerate) and
# the `ask_user_question` card.
#
# It starts the T25 loopback credential broker (key from OPENCODE_GO_API_KEY or
# refs.OPENCODE_GO_API_KEY in ~/.dsh/.credentials.yaml; never printed), uses a
# simulator clone that belongs to this task only, uninstalls the app for a real
# first launch, and runs:
#
#   app/integration_test/phase1_chat_features_real_test.dart
#
# Simulator isolation: the shared base iPhone 17 Pro (1D9F8C91…) is never
# used. The default device is "T32 iPhone 17 Pro"; it is created once with
# `simctl create` (iPhone 17 Pro, iOS 26.5) when missing. Its UDID is recorded
# in the evidence `*.env.json`, and this script takes a simulator lock scoped
# to that clone (`DSH_PHASE1_SIM_LOCK`), not the shared Phase 1 lock.
#
# The test logs `SCREENSHOT_READY <name>` when a screen worth keeping is up;
# this wrapper captures it with `xcrun simctl io <udid> screenshot` while the
# test holds the screen (steer, tool and question are required). Logs and
# screenshots land under the T32 evidence dir.
#
# Usage:
#   scripts/e2e/ios/run_chat_features_real.sh            # real run
#   scripts/e2e/ios/run_chat_features_real.sh --dry-run  # preflight only
#
# Env:
#   DSH_SIM_UDID            use this simulator instead of the T32 clone
#   DSH_E2E_EVIDENCE_DIR    default .../reports/phase1-completion/T32
#   DSH_TEST_FONT_DIR       CJK fonts for widget-side text (repo .fonts)
#   CREDENTIALS_FILE        default ~/.dsh/.credentials.yaml
#
# Exits non-zero on every failure. No skips.
set -euo pipefail

# The lock is scoped to the T32 clone before lib.sh reads it: this script never
# takes the shared `/tmp/dsh-phase1-sim.lock` other tasks use.
export DSH_PHASE1_SIM_LOCK="${DSH_PHASE1_SIM_LOCK:-/tmp/dsh-t32-chatreal-sim.lock}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$SCRIPT_DIR/../lib.sh"

ROOT="$DSH_E2E_ROOT"
APP="$ROOT/app"
TEST_FILE="$APP/integration_test/phase1_chat_features_real_test.dart"
BUNDLE_ID="io.github.ccch1mneyyy.dshgo"
SHARED_BASE_UDID="1D9F8C91-5739-47B2-BDD0-0FC7207166F3"
T32_SIM_NAME="T32 iPhone 17 Pro"
T32_DEVICE_TYPE="iPhone 17 Pro"
T32_RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-26-5"
EVIDENCE="${DSH_E2E_EVIDENCE_DIR:-$ROOT/../../../reports/phase1-completion/T32}"
MODE="real"
case "${1:-}" in
  "") ;;
  --dry-run) MODE="dry-run" ;;
  -h | --help)
    sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) printf 'usage: %s [--dry-run]\n' "$0" >&2; exit 2 ;;
esac

BROKER_PID=""
BROKER_TOKEN=""
KEY=""
WORK=""
TEST_PID=""
cleanup() {
  local rc=$?
  if [ -n "$TEST_PID" ] && kill -0 "$TEST_PID" 2>/dev/null; then
    kill -INT "$TEST_PID" 2>/dev/null || true
    wait "$TEST_PID" 2>/dev/null || true
  fi
  if [ -n "$BROKER_PID" ] && kill -0 "$BROKER_PID" 2>/dev/null; then
    kill -TERM "$BROKER_PID" 2>/dev/null || true
    wait "$BROKER_PID" 2>/dev/null || true
  fi
  if [ -n "$KEY" ] && [ -f "${LOG:-}" ]; then
    scrub_secret_from_file "$LOG" "$KEY" || true
  fi
  if [ -n "$BROKER_TOKEN" ] && [ -f "${LOG:-}" ]; then
    scrub_secret_from_file "$LOG" "$BROKER_TOKEN" || true
  fi
  e2e_cleanup
  exit "$rc"
}
trap cleanup EXIT INT TERM

find_t32_udid() {
  xcrun simctl list devices available -j 2>/dev/null | python3 -c '
import json, sys
name = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for runtime, rows in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for row in rows:
        if row.get("name") == name and row.get("isAvailable", True):
            print(row.get("udid", ""))
            raise SystemExit(0)
raise SystemExit(1)
' "$T32_SIM_NAME"
}

create_t32_udid() {
  local runtime="$T32_RUNTIME"
  if ! xcrun simctl list runtimes -j 2>/dev/null | grep -q "$runtime"; then
    runtime="$(xcrun simctl list runtimes available -j 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
for row in data.get("runtimes", []):
    if row.get("isAvailable", True) and str(row.get("version", "")).startswith("26.5"):
        print(row.get("identifier", ""))
        raise SystemExit(0)
raise SystemExit(1)
')" || fail "no available iOS 26.5 runtime for the T32 simulator clone"
  fi
  xcrun simctl create "$T32_SIM_NAME" "$T32_DEVICE_TYPE" "$runtime"
}

resolve_t32_clone() {
  if [ -n "${DSH_SIM_UDID:-}" ]; then
    [ "$DSH_SIM_UDID" = "$SHARED_BASE_UDID" ] &&
      fail "refusing the shared base simulator $SHARED_BASE_UDID; give the T32 clone its own UDID"
    printf '%s\n' "$DSH_SIM_UDID"
    return 0
  fi
  local udid
  udid="$(find_t32_udid || true)"
  if [ -z "$udid" ]; then
    e2e_log "creating the T32 simulator clone ($T32_SIM_NAME, $T32_DEVICE_TYPE, iOS 26.5)"
    udid="$(create_t32_udid)" || fail "could not create the T32 simulator clone"
  fi
  [ -n "$udid" ] || fail "the T32 simulator clone has no UDID"
  [ "$udid" = "$SHARED_BASE_UDID" ] && fail "resolved the shared base simulator; refusing"
  printf '%s\n' "$udid"
}

preflight() {
  require_darwin
  require_cmd node "credential broker"
  require_cmd python3
  require_cmd xcrun "Xcode command line tools"
  [ -f "$TEST_FILE" ] || fail "missing real chat-features test: $TEST_FILE"
  FLUTTER="$(resolve_flutter)"
  [ -f "$APP/pubspec.yaml" ] || fail "missing app pubspec: $APP/pubspec.yaml"
  if [ ! -f "$APP/.dart_tool/package_config.json" ]; then
    e2e_log "app dependencies are not resolved; running flutter pub get"
    (cd "$APP" && "$FLUTTER" pub get >/dev/null) || fail "flutter pub get failed"
  fi
  if [ ! -f "$APP/ios/Engine/.ready" ]; then
    e2e_log "app/ios/Engine is not prepared; running tooling/ios/prepare-engine.sh"
    local py
    py="$(python3 -c 'import sys; print(sys.executable if sys.version_info >= (3, 11) else "")')" || true
    if [ -z "$py" ]; then
      local candidate
      for candidate in /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.13 python3.12 python3.13; do
        if command -v "$candidate" >/dev/null 2>&1; then py="$(command -v "$candidate")"; break; fi
      done
    fi
    [ -n "$py" ] || fail "prepare-engine needs python3 >= 3.11 (set PYTHON)"
    (cd "$ROOT" && PATH="$(dirname "$py"):$PATH" PYTHON="$py" ./tooling/ios/prepare-engine.sh) >&2 ||
      fail "tooling/ios/prepare-engine.sh failed"
  fi
}

start_broker() {
  local broker_line=""
  e2e_log "starting the credential broker"
  node "$ROOT/test/fixtures/credential_broker.mjs" >"$WORK/broker.out" 2>"$WORK/broker.err" &
  BROKER_PID=$!
  for _ in $(seq 1 300); do
    broker_line="$(grep -m 1 '^BROKER ' "$WORK/broker.out" 2>/dev/null || true)"
    [ -n "$broker_line" ] && break
    kill -0 "$BROKER_PID" 2>/dev/null || {
      cat "$WORK/broker.err" >&2 || true
      fail "credential broker exited before announcing its port"
    }
    sleep 0.1
  done
  [ -n "$broker_line" ] || fail "credential broker did not announce a port"
  BROKER_PORT="$(printf '%s\n' "$broker_line" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read().strip()[len("BROKER "):])["port"])')"
  BROKER_TOKEN="$(printf '%s\n' "$broker_line" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read().strip()[len("BROKER "):])["token"])')"
  [ -n "$BROKER_PORT" ] && [ -n "$BROKER_TOKEN" ] || fail "could not parse the broker announcement"
  wait_port 127.0.0.1 "$BROKER_PORT" 10
  e2e_log "credential broker is up on 127.0.0.1:$BROKER_PORT (token hidden)"
}

ensure_sim_booted() {
  local udid="${1:?udid required}" state
  for _ in $(seq 1 30); do
    state="$(sim_state "$udid" 2>/dev/null || true)"
    [ "$state" = "Booted" ] && return 0
    xcrun simctl boot "$udid" >/dev/null 2>&1 || true
    sleep 2
  done
  fail "simulator $udid is not booted (state: ${state:-unknown})"
}

preflight
mkdir -p "$EVIDENCE/green" "$EVIDENCE/screenshots"
WORK="$(make_temp_dir dsh-e2e-chat-real)"
e2e_track_temp "$WORK"
LOG="$EVIDENCE/green/chat_features_real.log"
: >"$LOG"
chmod 600 "$LOG" 2>/dev/null || true

if [ "$MODE" = "dry-run" ]; then
  KEY="$(read_credentials_key)" || exit 1
  [ -n "$KEY" ] || fail "credentials resolved to an empty key"
  node "$ROOT/test/fixtures/credential_broker.mjs" --self-test >/dev/null || fail "credential broker self-test failed"
  UDID="$(find_t32_udid || true)"
  e2e_log "dry-run: flutter=$FLUTTER key available (not printed) test=$TEST_FILE"
  e2e_log "dry-run: T32 clone=${UDID:-<created on the real run>} lock=$DSH_PHASE1_SIM_LOCK"
  e2e_log "dry-run: would uninstall $BUNDLE_ID and run the real L4 chat-features test"
  printf 'dry-run: PASS (no simulator run, no model request)\n'
  exit 0
fi

UDID="$(resolve_t32_clone)"
[ -n "$UDID" ] || fail "no T32 simulator available (set DSH_SIM_UDID)"
acquire_sim_lock 3600
boot_sim "$UDID"
ensure_sim_booted "$UDID"
e2e_log "T32 simulator ready: $UDID (shared base untouched)"

# The key is checked once here for the post-run leak scan; the broker reads its
# own copy and no value is ever echoed.
KEY="$(read_credentials_key)" || exit 1
[ -n "$KEY" ] || fail "credentials resolved to an empty key"

start_broker

if [ "${DSH_E2E_KEEP_APP:-0}" != 1 ]; then
  xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  e2e_log "app uninstalled from $UDID (fresh first launch)"
fi

export DSH_IOS_GUEST_BUILD=0
if [ -z "${DSH_TEST_FONT_DIR:-}" ]; then
  if [ -d "$ROOT/../../../.fonts" ]; then
    export DSH_TEST_FONT_DIR="$ROOT/../../../.fonts"
  fi
fi

SEEN="$WORK/screenshots-seen"
mkdir -p "$SEEN"
STARTED_AT="$(date +%s)"
e2e_log "running integration_test/phase1_chat_features_real_test.dart on $UDID"

(
  cd "$APP"
  "$FLUTTER" test --no-pub -r expanded --timeout 2700s integration_test/phase1_chat_features_real_test.dart -d "$UDID" \
    --dart-define=E2E_BROKER_URL="http://127.0.0.1:$BROKER_PORT" \
    --dart-define=E2E_BROKER_TOKEN="$BROKER_TOKEN"
) >"$LOG" 2>&1 &
TEST_PID=$!

while kill -0 "$TEST_PID" 2>/dev/null; do
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "$name" in
      *[!a-z0-9_-]*) continue ;;
    esac
    [ -f "$SEEN/$name" ] && continue
    touch "$SEEN/$name"
    sleep 0.4
    shot="$EVIDENCE/screenshots/$name.png"
    if xcrun simctl io "$UDID" screenshot "$shot" >/dev/null 2>&1; then
      e2e_log "screenshot: $shot"
    else
      e2e_log "screenshot failed: $name"
    fi
  done < <(grep -o 'SCREENSHOT_READY [a-z0-9_-]*' "$LOG" 2>/dev/null | awk '{print $2}' | sort -u | tail -8)
  sleep 0.2
done

set +e
wait "$TEST_PID"
TEST_RC=$?
set -e
TEST_PID=""
DURATION=$(( $(date +%s) - STARTED_AT ))

# Never let the broker token or the real key survive in the evidence log.
scrub_secret_from_file "$LOG" "$BROKER_TOKEN" || true
scrub_secret_from_file "$LOG" "$KEY" || true

if [ "$TEST_RC" -ne 0 ]; then
  tail -100 "$LOG" >&2 || true
  fail "real chat-features L4 test failed (exit $TEST_RC); see $LOG"
fi
grep -q 'All tests passed!' "$LOG" || fail "the test process exited 0 without 'All tests passed!'; see $LOG"
if grep -Eq '~[0-9]+:|Some tests failed|: Skip' "$LOG"; then
  fail "the real chat-features suite contains a skipped or failed test; see $LOG"
fi
PASSED="$(python3 - "$LOG" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8', errors='replace').read()
nums = [int(n) for n in re.findall(r'\+(\d+)', text)]
print(max(nums) if nums else 0)
PY
)"
[ "${PASSED:-0}" -ge 1 ] || fail "expected the real chat-features test to pass; saw +$PASSED"
for shot in steer tool question; do
  [ -s "$EVIDENCE/screenshots/$shot.png" ] || fail "the $shot screenshot was not captured"
done
assert_no_secret_in_file "$LOG" "$KEY"
assert_no_secret_in_file "$LOG" "$BROKER_TOKEN"

ESTIMATE="$(python3 - "$LOG" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8', errors='replace').read()
match = re.findall(r'provider request estimate: .*?=\s*(\d+)', text)
print(match[-1] if match else '')
PY
)"
[ -n "$ESTIMATE" ] || fail "the test did not report its provider request estimate"
[ "$ESTIMATE" -lt 25 ] || fail "the real-model budget was exceeded: $ESTIMATE provider requests"

env_json_write "$EVIDENCE/green/chat_features_real.env.json" \
  "run=chat_features_real" "result=pass" "tests=$PASSED" "udid=$UDID" \
  "simulator=$T32_SIM_NAME" "broker_port=$BROKER_PORT" "duration_s=$DURATION" \
  "provider_requests=$ESTIMATE" "commit=$(repo_commit)" "log=$LOG" \
  "screenshot_steer=$EVIDENCE/screenshots/steer.png" \
  "screenshot_tool=$EVIDENCE/screenshots/tool.png" \
  "screenshot_question=$EVIDENCE/screenshots/question.png"

printf 'chat features real L4: PASS (%s test(s), %ss, device %s, %s provider requests)\n' \
  "$PASSED" "$DURATION" "$UDID" "$ESTIMATE"
