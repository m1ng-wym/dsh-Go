#!/usr/bin/env bash
# Real SSH acceptance runner for Phase 1 (T25).
#
# Starts the throwaway loopback sshd (scripts/e2e/ssh/sshd_control.sh), then
# runs app/test/remote/live_ssh_test.dart with DSH_APP_LIVE_SSH=1 so the real
# dartssh2 -> sshd -> remote `dsh web` path is exercised. All 7 live tests must
# pass; a skip is a failure. The remote side gets a temporary HOME/DSH_HOME and
# a PATH (DSH_APP_LIVE_SSH_PATH), so no real ~/.dsh is touched and the remote
# `dsh` binary is found.
#
# Usage:
#   scripts/e2e/run_live_ssh.sh              # real run (starts sshd, runs flutter test)
#   scripts/e2e/run_live_ssh.sh --dry-run    # preflight only, no ssh/flutter run
#   scripts/e2e/run_live_ssh.sh --self-test  # harness self-tests (sshd start/ssh/stop), no suite
#
# Env:
#   DSH_E2E_SSHD_PORT      preferred sshd port (default 22422 -> free fallback)
#   DSH_APP_LIVE_SSH_PATH  remote PATH (default /usr/local/bin:/opt/homebrew/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin)
#   DSH_E2E_EVIDENCE_DIR   default <repo>/reports/phase1-completion/T25
#
# Exits non-zero on every failure. No skips.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

ROOT="$DSH_E2E_ROOT"
APP="$ROOT/app"
TEST_FILE="$APP/test/remote/live_ssh_test.dart"
SSHD_CONTROL="$SCRIPT_DIR/ssh/sshd_control.sh"
EVIDENCE="${DSH_E2E_EVIDENCE_DIR:-$ROOT/reports/phase1-completion/T25}"
REMOTE_PATH="${DSH_APP_LIVE_SSH_PATH:-/usr/local/bin:/opt/homebrew/bin:${HOME}/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"
MODE="real"
case "${1:-}" in
  "") ;;
  --dry-run) MODE="dry-run" ;;
  --self-test) MODE="self-test" ;;
  -h | --help)
    sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) printf 'usage: %s [--dry-run|--self-test]\n' "$0" >&2; exit 2 ;;
esac

SSHD_WORK=""
cleanup() {
  local rc=$?
  if [ -n "$SSHD_WORK" ]; then
    if ! bash "$SSHD_CONTROL" stop "$SSHD_WORK" >/dev/null 2>&1; then
      e2e_log "ERROR: sshd cleanup failed for $SSHD_WORK"
      rc=1
    fi
  fi
  e2e_cleanup
  exit "$rc"
}
trap cleanup EXIT INT TERM

preflight() {
  require_darwin
  require_cmd python3
  [ -f "$TEST_FILE" ] || fail "missing live SSH test: $TEST_FILE"
  [ -x "$SSHD_CONTROL" ] || [ -f "$SSHD_CONTROL" ] || fail "missing sshd control script: $SSHD_CONTROL"
  FLUTTER="$(resolve_flutter)"
  [ -x "$FLUTTER" ] || fail "flutter is not executable: $FLUTTER"
  [ -f "$APP/pubspec.yaml" ] || fail "missing app pubspec: $APP/pubspec.yaml"
  [ -x /usr/sbin/sshd ] || fail "/usr/sbin/sshd not found"
  if [ ! -f "$APP/.dart_tool/package_config.json" ]; then
    e2e_log "app dependencies are not resolved; running flutter pub get"
    (cd "$APP" && "$FLUTTER" pub get >/dev/null) || fail "flutter pub get failed"
  fi
}

run_sshd_self_test() {
  e2e_log "sshd harness self-test (start -> ssh -> stop)"
  bash "$SSHD_CONTROL" --self-test
}

if [ "$MODE" = "self-test" ]; then
  preflight
  run_sshd_self_test
  # Prove the live suite is wired to the same 7 tests and opt-in switch.
  local_count="$(grep -c "^  test(" "$TEST_FILE" || true)"
  e2e_log "live SSH test file declares $local_count test( entries"
  [ "$local_count" -ge 7 ] || fail "expected >=7 live SSH tests, found $local_count"
  if ! grep -q "DSH_APP_LIVE_SSH" "$TEST_FILE"; then
    fail "live_ssh_test.dart is not gated on DSH_APP_LIVE_SSH"
  fi
  printf 'self-test: PASS (live SSH harness)\n'
  exit 0
fi

if [ "$MODE" = "dry-run" ]; then
  preflight
  e2e_log "dry-run: flutter=$FLUTTER"
  e2e_log "dry-run: sshd=/usr/sbin/sshd preferred_port=${DSH_E2E_SSHD_PORT:-22422}"
  e2e_log "dry-run: remote PATH=$REMOTE_PATH"
  e2e_log "dry-run: would run: cd $APP && flutter test --no-pub test/remote/live_ssh_test.dart -r expanded"
  printf 'dry-run: PASS (no sshd started, no test run)\n'
  exit 0
fi

preflight
mkdir -p "$EVIDENCE/green"
WORK="$(make_temp_dir dsh-e2e-live-ssh)"
e2e_track_temp "$WORK"

e2e_log "starting temporary sshd on 127.0.0.1 (preferred port ${DSH_E2E_SSHD_PORT:-22422})"
START_OUT="$WORK/sshd-start.out"
if ! bash "$SSHD_CONTROL" start >"$START_OUT" 2>"$WORK/sshd-start.err"; then
  cat "$WORK/sshd-start.err" >&2 || true
  fail "temporary sshd did not start"
fi
SSHD_LINE="$(grep -m 1 '^SSHD ' "$START_OUT" || true)"
[ -n "$SSHD_LINE" ] || fail "sshd did not print its state"
SSHD_JSON="${SSHD_LINE#SSHD }"
SSHD_WORK="$(printf '%s' "$SSHD_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["work"])')"
SSHD_PORT="$(printf '%s' "$SSHD_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["port"])')"
SSHD_USER="$(printf '%s' "$SSHD_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["user"])')"
SSHD_KEY="$(printf '%s' "$SSHD_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["client_key"])')"
SSHD_HOST_PUB="$(printf '%s' "$SSHD_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["host_pub"])')"
[ -n "$SSHD_WORK" ] && [ -n "$SSHD_PORT" ] && [ -n "$SSHD_KEY" ] || fail "could not parse sshd state"
e2e_log "sshd ready on 127.0.0.1:$SSHD_PORT (user $SSHD_USER)"

LOG="$EVIDENCE/green/live_ssh.log"
: >"$LOG"
chmod 600 "$LOG" 2>/dev/null || true

e2e_log "running flutter test test/remote/live_ssh_test.dart"
TEST_OUT="$WORK/live-ssh-test.out"
set +e
(
  cd "$APP"
  DSH_APP_LIVE_SSH=1 \
    DSH_APP_LIVE_SSH_HOST=127.0.0.1 \
    DSH_APP_LIVE_SSH_PORT="$SSHD_PORT" \
    DSH_APP_LIVE_SSH_USER="$SSHD_USER" \
    DSH_APP_LIVE_SSH_KEY="$SSHD_KEY" \
    DSH_APP_LIVE_SSH_HOST_PUB="$SSHD_HOST_PUB" \
    DSH_APP_LIVE_SSH_PATH="$REMOTE_PATH" \
    "$FLUTTER" test --no-pub test/remote/live_ssh_test.dart -r expanded
) >"$TEST_OUT" 2>&1
TEST_RC=$?
set -e
tee "$LOG" <"$TEST_OUT" >/dev/null
if [ "$TEST_RC" -ne 0 ]; then
  tail -60 "$LOG" >&2 || true
  fail "live SSH suite failed (exit $TEST_RC); see $LOG"
fi
grep -q 'All tests passed!' "$LOG" || fail "live SSH suite did not report 'All tests passed!'"
if grep -Eq '~[0-9]+:|Some tests failed|: Skip' "$LOG"; then
  fail "live SSH suite contains a skipped or failed test (see $LOG)"
fi
PASSED="$(python3 - "$LOG" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8', errors='replace').read()
nums = [int(n) for n in re.findall(r'\+(\d+)', text)]
print(max(nums) if nums else 0)
PY
)"
[ "$PASSED" -ge 7 ] || fail "expected 7 passing live SSH tests, saw $PASSED"

env_json_write "$EVIDENCE/green/live_ssh.env.json" \
  "run=live_ssh" "tests=$PASSED" "result=pass" "port=$SSHD_PORT" "user=$SSHD_USER" \
  "remote_path=$REMOTE_PATH" "commit=$(repo_commit)" "log=$LOG"

printf 'live SSH suite: PASS (%s tests, port %s)\n' "$PASSED" "$SSHD_PORT"
