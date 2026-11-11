#!/usr/bin/env bash
# Real workspace/files acceptance runner for Phase 1 (T25).
#
# Starts a real `dsh web` with an isolated HOME/DSH_HOME, reads the launch URL
# (with its one-time token) from stdout, and runs
# app/test/files/workspace_live_test.dart against it. All 5 live tests must
# pass; a skip is a failure. The token is scrubbed from every log and is never
# written to the evidence JSON.
#
# Usage:
#   scripts/e2e/run_workspace_live.sh              # real run
#   scripts/e2e/run_workspace_live.sh --dry-run    # preflight only
#   scripts/e2e/run_workspace_live.sh --self-test  # harness checks (no dsh web)
#
# Env:
#   DSH_BIN              dsh launcher (default: dsh on PATH, else ~/.local/bin/dsh)
#   DSH_E2E_EVIDENCE_DIR default <repo>/reports/phase1-completion/T25
#
# Exits non-zero on every failure. No skips.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

ROOT="$DSH_E2E_ROOT"
APP="$ROOT/app"
TEST_FILE="$APP/test/files/workspace_live_test.dart"
EVIDENCE="${DSH_E2E_EVIDENCE_DIR:-$ROOT/reports/phase1-completion/T25}"
MODE="real"
case "${1:-}" in
  "") ;;
  --dry-run) MODE="dry-run" ;;
  --self-test) MODE="self-test" ;;
  -h | --help)
    sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) printf 'usage: %s [--dry-run|--self-test]\n' "$0" >&2; exit 2 ;;
esac

DSH_PID=""
WORK=""
DSH_WORK=""
cleanup() {
  local rc=$?
  if [ -n "$DSH_PID" ] && kill -0 "$DSH_PID" 2>/dev/null; then
    kill -TERM "$DSH_PID" 2>/dev/null || true
    local i=0
    while kill -0 "$DSH_PID" 2>/dev/null && [ "$i" -lt 150 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    if kill -0 "$DSH_PID" 2>/dev/null; then
      kill -KILL "$DSH_PID" 2>/dev/null || true
      sleep 0.2
      if kill -0 "$DSH_PID" 2>/dev/null; then
        e2e_log "ERROR: dsh web process $DSH_PID survived shutdown"
        rc=1
      fi
    fi
  fi
  if [ -n "${LAUNCH_PORT:-}" ]; then
    local j=0
    while port_reachable "$LAUNCH_PORT" && [ "$j" -lt 100 ]; do
      sleep 0.1
      j=$((j + 1))
    done
    if port_reachable "$LAUNCH_PORT"; then
      e2e_log "ERROR: dsh web is still listening on 127.0.0.1:$LAUNCH_PORT after shutdown"
      rc=1
    fi
  fi
  if [ -n "$DSH_WORK" ] && [ -d "$DSH_WORK" ]; then
    # Never keep or leak the one-time launch token in a log.
    if [ -f "$DSH_WORK/web.log" ] && [ -n "${LAUNCH_TOKEN:-}" ]; then
      scrub_secret_from_file "$DSH_WORK/web.log" "$LAUNCH_TOKEN" || true
    fi
    if [ "${DSH_E2E_KEEP:-0}" = 1 ]; then
      e2e_log "kept dsh work dir (token scrubbed): $DSH_WORK"
    else
      rm -rf -- "$DSH_WORK"
    fi
  fi
  e2e_cleanup
  exit "$rc"
}
trap cleanup EXIT INT TERM

resolve_dsh() {
  if [ -n "${DSH_BIN:-}" ]; then
    [ -x "$DSH_BIN" ] || fail "DSH_BIN is not executable: $DSH_BIN"
    printf '%s\n' "$DSH_BIN"
    return 0
  fi
  if command -v dsh >/dev/null 2>&1; then
    command -v dsh
    return 0
  fi
  if [ -x "${HOME:-/nonexistent}/.local/bin/dsh" ]; then
    printf '%s\n' "${HOME}/.local/bin/dsh"
    return 0
  fi
  fail "dsh not found (put it on PATH or set DSH_BIN)"
}

port_reachable() {
  python3 - "$1" <<'PY'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(0.3)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
    s.close()
    sys.exit(0)
except OSError:
    s.close()
    sys.exit(1)
PY
}

parse_launch_url() {
  local log="$1"
  python3 - "$log" <<'PY'
import re, sys
try:
    text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
except OSError:
    sys.exit(1)
match = re.search(r"https?://127\.0\.0\.1:\d+/\?token=\S+", text)
if not match:
    sys.exit(1)
print(match.group(0))
PY
}

preflight() {
  require_darwin
  require_cmd python3
  [ -f "$TEST_FILE" ] || fail "missing workspace live test: $TEST_FILE"
  FLUTTER="$(resolve_flutter)"
  DSH="$(resolve_dsh)"
  [ -f "$APP/pubspec.yaml" ] || fail "missing app pubspec: $APP/pubspec.yaml"
  if [ ! -f "$APP/.dart_tool/package_config.json" ]; then
    e2e_log "app dependencies are not resolved; running flutter pub get"
    (cd "$APP" && "$FLUTTER" pub get >/dev/null) || fail "flutter pub get failed"
  fi
}

test_count() {
  grep -c '^    test(' "$TEST_FILE" || true
}

check_launch_parser() {
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/dsh-e2e-url.XXXXXX")"
  printf 'noise\ndsh web: http://127.0.0.1:59321/?token=abc123DEF\n' >"$tmp"
  local parsed
  parsed="$(parse_launch_url "$tmp" || true)"
  rm -f "$tmp"
  [ "$parsed" = "http://127.0.0.1:59321/?token=abc123DEF" ] || fail "launch URL parser failed"
}

if [ "$MODE" = "self-test" ]; then
  preflight
  check_launch_parser
  local_count="$(test_count)"
  [ "$local_count" -ge 5 ] || fail "expected >=5 workspace live tests, found $local_count"
  "$DSH" --version >/dev/null 2>&1 || fail "dsh --version failed ($DSH)"
  e2e_log "dsh launcher: $DSH ($("$DSH" --version 2>/dev/null | head -1))"
  e2e_log "workspace live test file declares $local_count test( entries"
  printf 'self-test: PASS (workspace live harness)\n'
  exit 0
fi

if [ "$MODE" = "dry-run" ]; then
  preflight
  e2e_log "dry-run: flutter=$FLUTTER"
  e2e_log "dry-run: dsh=$DSH ($("$DSH" --version 2>/dev/null | head -1))"
  e2e_log "dry-run: would start: env HOME=<tmp> DSH_HOME=<tmp>/.dsh $DSH web --host 127.0.0.1 --port 0 --no-open"
  e2e_log "dry-run: would run: cd $APP && flutter test --no-pub test/files/workspace_live_test.dart -r expanded"
  printf 'dry-run: PASS (no dsh web started, no test run)\n'
  exit 0
fi

preflight
mkdir -p "$EVIDENCE/green"
WORK="$(make_temp_dir dsh-e2e-workspace)"
e2e_track_temp "$WORK"
DSH_WORK="$WORK/dsh-home"
mkdir -p "$DSH_WORK/.dsh" "$WORK/workspace"

e2e_log "starting dsh web with an isolated HOME/DSH_HOME"
env HOME="$DSH_WORK" DSH_HOME="$DSH_WORK/.dsh" \
  "$DSH" web --host 127.0.0.1 --port 0 --no-open >"$DSH_WORK/web.log" 2>&1 &
DSH_PID=$!

LAUNCH_URL=""
for _ in $(seq 1 1200); do
  LAUNCH_URL="$(parse_launch_url "$DSH_WORK/web.log" 2>/dev/null || true)"
  [ -n "$LAUNCH_URL" ] && break
  kill -0 "$DSH_PID" 2>/dev/null || {
    sed -E 's/token=[^ ]+/token=<redacted>/g' "$DSH_WORK/web.log" | tail -30 >&2 || true
    fail "dsh web exited before printing a launch URL"
  }
  sleep 0.1
done
[ -n "$LAUNCH_URL" ] || fail "dsh web did not print a launch URL within 120s"
LAUNCH_TOKEN="${LAUNCH_URL##*token=}"
LAUNCH_PORT="$(printf '%s' "$LAUNCH_URL" | python3 -c 'import sys,urllib.parse; print(urllib.parse.urlparse(sys.stdin.read().strip()).port)')"
[ -n "$LAUNCH_PORT" ] || fail "could not read the dsh web port"
wait_port 127.0.0.1 "$LAUNCH_PORT" 30

e2e_log "dsh web is up on 127.0.0.1:$LAUNCH_PORT (token hidden)"
LOG="$EVIDENCE/green/workspace_live.log"
: >"$LOG"
chmod 600 "$LOG" 2>/dev/null || true

e2e_log "running flutter test test/files/workspace_live_test.dart"
TEST_OUT="$WORK/workspace-test.out"
set +e
(
  cd "$APP"
  DSH_LIVE_URL="$LAUNCH_URL" DSH_LIVE_CWD="$WORK/workspace" \
    "$FLUTTER" test --no-pub test/files/workspace_live_test.dart -r expanded
) >"$TEST_OUT" 2>&1
TEST_RC=$?
set -e
# The test output should never contain the token; scrub defensively anyway.
scrub_secret_from_file "$TEST_OUT" "$LAUNCH_TOKEN" || true
tee "$LOG" <"$TEST_OUT" >/dev/null

if [ "$TEST_RC" -ne 0 ]; then
  tail -60 "$LOG" >&2 || true
  fail "workspace live suite failed (exit $TEST_RC); see $LOG"
fi
grep -q 'All tests passed!' "$LOG" || fail "workspace live suite did not report 'All tests passed!'"
if grep -Eq '~[0-9]+:|Some tests failed|: Skip' "$LOG"; then
  fail "workspace live suite contains a skipped or failed test (see $LOG)"
fi
PASSED="$(python3 - "$LOG" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8', errors='replace').read()
nums = [int(n) for n in re.findall(r'\+(\d+)', text)]
print(max(nums) if nums else 0)
PY
)"
[ "$PASSED" -ge 5 ] || fail "expected 5 passing workspace live tests, saw $PASSED"

env_json_write "$EVIDENCE/green/workspace_live.env.json" \
  "run=workspace_live" "tests=$PASSED" "result=pass" "port=$LAUNCH_PORT" \
  "cwd=$WORK/workspace" "commit=$(repo_commit)" "log=$LOG"

printf 'workspace live suite: PASS (%s tests, dsh web port %s)\n' "$PASSED" "$LAUNCH_PORT"
