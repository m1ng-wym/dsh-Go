#!/usr/bin/env bash
# T27 · L4-Real approval run: clean install, real opencode-go model, allow/deny.
#
# Starts the T25 loopback credential broker with the real key from
# ~/.dsh/.credentials.yaml (or OPENCODE_GO_API_KEY), uninstalls the app for a
# clean install, runs app/integration_test/phase1_real_approval_test.dart on
# the iPhone 17 Pro simulator, and stops the broker on exit.
#
# Screenshots are taken while the test holds the approval card on screen: the
# test writes `dsh-t27-<name>.ready` into the app's temporary directory, this
# script runs `xcrun simctl io ... screenshot`, then writes the matching
# `.shot` marker back so the test continues.
#
# Usage:
#   scripts/e2e/ios/run_approval_real.sh                # GREEN evidence
#   scripts/e2e/ios/run_approval_real.sh --tag red --allow-failure
#   scripts/e2e/ios/run_approval_real.sh --self-test    # offline preflight
#
# Env:
#   DSH_SIM_UDID              default 1D9F8C91-5739-47B2-BDD0-0FC7207166F3
#   DSH_E2E_EVIDENCE_DIR      default <repo>/reports/phase1-completion/T27
#   DSH_E2E_BROKER_CREDENTIALS default ~/.dsh/.credentials.yaml
#   DSH_E2E_PROVIDER_BASE_URL default https://opencode.ai/inference/go/v1
#   DSH_E2E_MODEL              default deepseek-v4.1-flash
#
# Exits non-zero on every failure. No skips.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$SCRIPT_DIR/../lib.sh"

ROOT="$DSH_E2E_ROOT"
APP="$ROOT/app"
MAIN_REPO="$(cd "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)/.." && pwd -P)"
BROKER="$ROOT/test/fixtures/credential_broker.mjs"
TEST_FILE="integration_test/phase1_real_approval_test.dart"
BUNDLE_ID="io.github.ccch1mneyyy.dshgo"
UDID="${DSH_SIM_UDID:-1D9F8C91-5739-47B2-BDD0-0FC7207166F3}"
EVIDENCE="${DSH_E2E_EVIDENCE_DIR:-$(dirname "$MAIN_REPO")/reports/phase1-completion/T27}"
BASE_URL="${DSH_E2E_PROVIDER_BASE_URL:-https://opencode.ai/inference/go/v1}"
MODEL="${DSH_E2E_MODEL:-deepseek-v4.1-flash}"
CREDENTIALS="${DSH_E2E_BROKER_CREDENTIALS:-${HOME:-/nonexistent}/.dsh/.credentials.yaml}"

TAG="green"
ALLOW_FAILURE=0
MODE="real"
case "${1:-}" in
  "") ;;
  --tag)
    TAG="${2:?--tag needs red or green}"
    [ "$TAG" = "red" ] || [ "$TAG" = "green" ] || fail "--tag must be red or green"
    shift 2
    ;;
  --self-test) MODE="self-test"; shift ;;
  -h | --help)
    sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) fail "usage: $0 [--tag red|green] [--allow-failure] [--self-test]" ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --allow-failure) ALLOW_FAILURE=1; shift ;;
    *) fail "unknown option: $1" ;;
  esac
done

BROKER_PID=""
TEST_PID=""
WORK=""
LOG=""
cleanup() {
  local rc=$?
  if [ -n "$TEST_PID" ] && kill -0 "$TEST_PID" 2>/dev/null; then
    kill "$TEST_PID" 2>/dev/null || true
    wait "$TEST_PID" 2>/dev/null || true
  fi
  if [ -n "$BROKER_PID" ] && kill -0 "$BROKER_PID" 2>/dev/null; then
    kill "$BROKER_PID" 2>/dev/null || true
    wait "$BROKER_PID" 2>/dev/null || true
  fi
  e2e_cleanup
  exit "$rc"
}
trap cleanup EXIT INT TERM

preflight() {
  require_cmd node
  require_cmd python3
  require_cmd xcrun "Xcode command line tools"
  require_darwin
  [ -f "$BROKER" ] || fail "missing credential broker: $BROKER"
  [ -f "$APP/$TEST_FILE" ] || fail "missing integration test: $APP/$TEST_FILE"
  [ -f "$APP/ios/Engine/.ready" ] || fail "the iOS engine is not prepared; run tooling/ios/prepare-engine.sh first"
  [ -r "$CREDENTIALS" ] || [ -n "${OPENCODE_GO_API_KEY:-}" ] || fail "no key: $CREDENTIALS is unreadable and OPENCODE_GO_API_KEY is empty"
  xcrun simctl list devices available -j | python3 -c '
import json, sys
udid = sys.argv[1]
data = json.load(sys.stdin)
for rows in data.get("devices", {}).values():
    for row in rows:
        if row.get("udid") == udid:
            raise SystemExit(0)
raise SystemExit(1)
' "$UDID" || fail "simulator $UDID is not available"
  # The test's compile-time defines must not leak through the wrapper's shell:
  # the broker prints its own token, which is passed only on flutter's argv.
  if [ -n "${E2E_BROKER_TOKEN:-}" ] || [ -n "${E2E_BROKER_URL:-}" ]; then
    fail "E2E_BROKER_* are set in the environment; unset them (the wrapper starts its own broker)"
  fi
}

section() { printf '\n== %s\n' "$*" >&2; }

self_test() {
  section "preflight"
  preflight
  section "test file present"
  [ -f "$APP/$TEST_FILE" ] || fail "missing $TEST_FILE"
  section "broker self-test"
  node "$BROKER" --self-test
  section "lib self-test"
  bash "$SCRIPT_DIR/../lib.sh" --self-test
  printf 'self-test: PASS (approval real harness preflight)\n'
}

if [ "$MODE" = "self-test" ]; then
  self_test
  exit 0
fi

preflight
mkdir -p "$EVIDENCE/$TAG"
LOG="$EVIDENCE/$TAG/run-$TAG.log"
: >"$LOG"
chmod 600 "$LOG" 2>/dev/null || true
WORK="$(make_temp_dir dsh-e2e-approval)"
e2e_track_temp "$WORK"

section "simulator lock and boot"
acquire_sim_lock 3600
boot_sim "$UDID"

section "clean install: uninstall $BUNDLE_ID"
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
if xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data >/dev/null 2>&1; then
  fail "the app data container still exists after uninstall; the run would not be a clean install"
fi

section "credential broker"
node "$BROKER" --credentials "$CREDENTIALS" >"$WORK/broker.out" 2>"$WORK/broker.err" &
BROKER_PID=$!
BROKER_LINE=""
for _ in $(seq 1 300); do
  BROKER_LINE="$(grep -m 1 '^BROKER ' "$WORK/broker.out" 2>/dev/null || true)"
  [ -n "$BROKER_LINE" ] && break
  kill -0 "$BROKER_PID" 2>/dev/null || {
    cat "$WORK/broker.err" >&2 || true
    fail "credential broker exited before announcing its port"
  }
  sleep 0.1
done
[ -n "$BROKER_LINE" ] || fail "credential broker did not announce a port"
BROKER_PORT="$(printf '%s\n' "$BROKER_LINE" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read().strip()[len("BROKER "):])["port"])')"
BROKER_TOKEN="$(printf '%s\n' "$BROKER_LINE" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read().strip()[len("BROKER "):])["token"])')"
[ -n "$BROKER_PORT" ] && [ -n "$BROKER_TOKEN" ] || fail "could not parse the broker announcement"
wait_port 127.0.0.1 "$BROKER_PORT" 10
e2e_log "credential broker ready on 127.0.0.1:$BROKER_PORT (token redacted)"

FLUTTER="$(resolve_flutter)"

section "run $TEST_FILE (real model; evidence $EVIDENCE/$TAG)"
export DSH_IOS_GUEST_BUILD=0
export DSH_TEST_FONT_DIR="${DSH_TEST_FONT_DIR:-$(dirname "$MAIN_REPO")/.fonts}"
(
  cd "$APP"
  "$FLUTTER" test --no-pub -r expanded -d "$UDID" "$TEST_FILE" \
    --dart-define=E2E_BROKER_URL="http://127.0.0.1:$BROKER_PORT" \
    --dart-define=E2E_BROKER_TOKEN="$BROKER_TOKEN" \
    --dart-define=E2E_PROVIDER_BASE_URL="$BASE_URL" \
    --dart-define=E2E_MODEL="$MODEL"
) >>"$LOG" 2>&1 &
TEST_PID=$!

# Screenshots are taken by a background poller, not one blocking waiter per
# marker: the test holds each card for at most 20 s, and a slow app-container
# lookup for one marker must not delay the next one. Each marker becomes a
# `.shot` only after the screenshot was written.
SHOT_PID=""
capture_markers() {
  local spec name file app_data ready shot
  while kill -0 "$TEST_PID" 2>/dev/null; do
    app_data="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null || true)"
    if [ -n "$app_data" ] && [ -d "$app_data" ]; then
      for spec in         card-allow:03-approval-allow-card.png         card-deny:04-approval-deny-card.png         done-a:05-allow-result.png         done-b:06-deny-result.png         done:07-final.png; do
        name="${spec%%:*}"
        file="${spec#*:}"
        # The engine points TMPDIR at <app>/Library/Caches/dsh-runtime/ohos-process,
        # not <app>/tmp; find the marker wherever the app wrote it.
        ready="$(find "$app_data" -maxdepth 6 -name "dsh-t27-$name.ready" -print -quit 2>/dev/null || true)"
        [ -n "$ready" ] || continue
        shot="${ready%.ready}.shot"
        [ -f "$shot" ] && continue
        if xcrun simctl io "$UDID" screenshot "$EVIDENCE/$TAG/$file" >/dev/null 2>&1; then
          printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$shot" 2>/dev/null || true
          e2e_log "screenshot: $EVIDENCE/$TAG/$file"
        else
          e2e_log "screenshot failed: $file"
        fi
      done
    fi
    sleep 0.2
  done
}
capture_markers &
SHOT_PID=$!

set +e
wait "$TEST_PID"
TEST_RC=$?
set -e
if [ -n "$SHOT_PID" ]; then
  kill "$SHOT_PID" 2>/dev/null || true
  wait "$SHOT_PID" 2>/dev/null || true
  SHOT_PID=""
fi
TEST_PID=""

# Never leave the key in the evidence: assert, then scrub defensively.
KEY="$(read_credentials_key "$CREDENTIALS")" || true
if [ -n "${KEY:-}" ]; then
  assert_no_secret_in_file "$LOG" "$KEY"
  scrub_secret_from_file "$LOG" "$KEY"
fi
scrub_secret_from_file "$LOG" "$BROKER_TOKEN"

LINES="$(wc -l <"$LOG" | tr -d ' ')"
e2e_log "flutter test exit $TEST_RC; log: $LOG ($LINES lines)"
if [ "$TEST_RC" -ne 0 ] && [ "$ALLOW_FAILURE" -ne 1 ]; then
  tail -n 80 "$LOG" >&2 || true
  fail "real approval test failed (exit $TEST_RC); see $LOG"
fi
if [ "$TEST_RC" -eq 0 ]; then
  grep -q 'T27 PASS' "$LOG" || fail "test exited 0 without the T27 PASS marker"
  for shot in 03-approval-allow-card.png 04-approval-deny-card.png; do
    [ -s "$EVIDENCE/$TAG/$shot" ] || fail "missing screenshot: $EVIDENCE/$TAG/$shot"
  done
fi

env_json_write "$EVIDENCE/$TAG/run-$TAG.env.json" \
  "run=t27_real_approval" "tag=$TAG" "test=$TEST_FILE" "udid=$UDID" \
  "base_url=$BASE_URL" "model=$MODEL" "result=$([ "$TEST_RC" -eq 0 ] && printf pass || printf fail)" \
  "test_exit=$TEST_RC" "log=$LOG" "commit=$(repo_commit)"

if [ "$TEST_RC" -eq 0 ]; then
  printf 'real approval %s: PASS (see %s)\n' "$TAG" "$EVIDENCE/$TAG"
else
  printf 'real approval %s: FAIL/recorded (exit %s, see %s)\n' "$TAG" "$TEST_RC" "$EVIDENCE/$TAG"
  [ "$ALLOW_FAILURE" -eq 1 ] || exit "$TEST_RC"
fi
