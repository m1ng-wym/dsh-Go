#!/usr/bin/env bash
# T33b: real SSH host, end to end, on the iOS Simulator with the real model.
#
# Starts the T25 throwaway unprivileged sshd (127.0.0.1, temp host/client keys,
# no ~/.ssh changes) and the T25 loopback credential broker (the opencode-go key
# is read by the broker from ~/.dsh/.credentials.yaml and is never printed), then
# boots "iPhone 17 Pro" under the shared simulator lock, uninstalls the app and
# runs app/integration_test/phase1_ssh_real_test.dart with dart-defines for:
#   * broker URL/token,
#   * SSH host/port/user, the throwaway client private key (base64) and the
#     expected host-key fingerprint,
#   * the remote `dsh web` launch command with an isolated temp HOME/DSH_HOME,
#     plus the remote workspace directory the test asserts on.
#
# The test's DSH data stays under the temp dir. dsh-app's own per-user state
# (~/.dsh-app-remote) is moved aside for the run and restored on exit, and the
# run refuses to start while a real dsh-app-managed `dsh web` is alive.
#
# Usage:
#   scripts/e2e/ios/run_ssh_real.sh             # real run (real model)
#   scripts/e2e/ios/run_ssh_real.sh --dry-run   # preflight only, nothing started
#
# Env:
#   DSH_E2E_SSHD_PORT      preferred sshd port (default 22422 -> free fallback)
#   DSH_E2E_SSH_USER       SSH login (default $USER)
#   DSH_SIM_UDID           simulator UDID (default the iPhone 17 Pro below)
#   DSH_E2E_EVIDENCE_DIR   default <repo>/reports/phase1-completion/T33b-ssh
#   DSH_BIN                remote dsh launcher (default ~/.local/bin/dsh)
#   DSH_E2E_KEEP=1         keep temp dirs (keys, remote HOME) for debugging
#   DSH_E2E_SIM_QUIET_TIMEOUT  seconds to wait for competing simulator jobs
#                              on the same UDID to finish (default 1800)
#
# Exits non-zero on every failure. No skips.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# lib.sh derives the repo root from its own location (scripts/e2e); this runner
# sits one level deeper, so pin the root before sourcing it.
export DSH_E2E_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../lib.sh
. "$SCRIPT_DIR/../lib.sh"

ROOT="$DSH_E2E_ROOT"
APP="$ROOT/app"
TEST_FILE="$APP/integration_test/phase1_ssh_real_test.dart"
SSHD_CONTROL="$ROOT/scripts/e2e/ssh/sshd_control.sh"
BROKER="$ROOT/test/fixtures/credential_broker.mjs"
BUNDLE_ID="io.github.ccch1mneyyy.dshgo"
SIM_NAME="${DSH_E2E_SIM_NAME:-iPhone 17 Pro}"
SIM_UDID_DEFAULT="1D9F8C91-5739-47B2-BDD0-0FC7207166F3"

_default_evidence="$ROOT/reports/phase1-completion/T33b-ssh"
if [ -d "$ROOT/../../../reports" ]; then
  _default_evidence="$(cd "$ROOT/../../.." && pwd)/reports/phase1-completion/T33b-ssh"
fi
EVIDENCE="${DSH_E2E_EVIDENCE_DIR:-$_default_evidence}"

MODE="real"
case "${1:-}" in
  "") ;;
  --dry-run) MODE="dry-run" ;;
  -h | --help)
    sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) printf 'usage: %s [--dry-run]\n' "$0" >&2; exit 2 ;;
esac

SSHD_WORK=""
SSHD_PORT=""
BROKER_PID=""
WORK=""
UDID=""
REMOTE_HOME=""
REMOTE_WORK=""
REMOTE_STATE=""
SHOTS_PID=""
SCREEN_SENTINEL=""
STARTED_AT="$(date +%s)"
FLUTTER=""
DSH_BIN=""

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

resolve_dsh() {
  local candidate="${DSH_BIN:-}"
  if [ -n "$candidate" ]; then
    [ -x "$candidate" ] || fail "DSH_BIN is not executable: $candidate"
    printf '%s\n' "$candidate"
    return 0
  fi
  if command -v dsh >/dev/null 2>&1; then
    command -v dsh
    return 0
  fi
  candidate="${HOME:-/nonexistent}/.local/bin/dsh"
  [ -x "$candidate" ] || fail "no dsh launcher (set DSH_BIN or install dsh under ~/.local/bin)"
  printf '%s\n' "$candidate"
}

preflight() {
  require_darwin
  require_cmd python3
  require_cmd node "the credential broker and dsh need Node.js"
  require_cmd xcrun "Xcode command line tools"
  [ -f "$TEST_FILE" ] || fail "missing integration test: $TEST_FILE"
  [ -f "$SSHD_CONTROL" ] || fail "missing sshd control script: $SSHD_CONTROL"
  [ -f "$BROKER" ] || fail "missing credential broker: $BROKER"
  [ -x /usr/sbin/sshd ] || fail "/usr/sbin/sshd not found"
  FLUTTER="$(resolve_flutter)"
  [ -x "$FLUTTER" ] || fail "flutter is not executable: $FLUTTER"
  DSH_BIN="$(resolve_dsh)"
  [ -f "$APP/pubspec.yaml" ] || fail "missing app pubspec: $APP/pubspec.yaml"
  if [ ! -f "$APP/.dart_tool/package_config.json" ]; then
    e2e_log "app dependencies are not resolved; running flutter pub get"
    (cd "$APP" && "$FLUTTER" pub get >/dev/null) || fail "flutter pub get failed"
  fi
  [ -r "${HOME}/.dsh/.credentials.yaml" ] ||
    fail "the credential broker reads refs.OPENCODE_GO_API_KEY from ${HOME}/.dsh/.credentials.yaml; the file is not readable"
}

resolve_udid() {
  if [ -n "${DSH_SIM_UDID:-}" ]; then
    UDID="$DSH_SIM_UDID"
  elif [ -n "$(sim_state "$SIM_UDID_DEFAULT" 2>/dev/null || true)" ]; then
    UDID="$SIM_UDID_DEFAULT"
  else
    UDID="$(resolve_sim_udid "$SIM_NAME" || true)"
  fi
  [ -n "$UDID" ] || fail "could not resolve a simulator UDID"
  local state
  state="$(sim_state "$UDID" || true)"
  [ -n "$state" ] || fail "simulator $UDID is not available (xcrun simctl list devices)"
  e2e_log "simulator: $SIM_NAME $UDID ($state)"
}

# Other acceptance jobs share this Mac and do not all take the shared lock.
# A second app launch on the same simulator force-quits ours, so wait until no
# other Flutter test / xcodebuild targets this UDID for a quiet window.
wait_simulator_quiet() {
  local timeout="${DSH_E2E_SIM_QUIET_TIMEOUT:-1800}" deadline quiet_since now busy
  deadline=$(( $(date +%s) + timeout ))
  quiet_since=0
  while :; do
    busy="$(ps ax -o command= 2>/dev/null | grep -E "flutter_tools\.snapshot test|xcodebuild|probe-launch|simctl (launch|install|uninstall|terminate)" | grep -F -- "$UDID" | grep -v "phase1_ssh_real_test" || true)"
    now="$(date +%s)"
    if [ -z "$busy" ]; then
      [ "$quiet_since" -eq 0 ] && quiet_since="$now"
      if [ $((now - quiet_since)) -ge 15 ]; then
        return 0
      fi
    else
      quiet_since=0
      e2e_log "waiting for another job on $UDID to finish:"
      printf '%s\n' "$busy" | sed -E 's/^(.{0,160}).*/  \1/' | head -3 >&2
    fi
    [ "$now" -lt "$deadline" ] || fail "simulator $UDID stayed busy for ${timeout}s (another acceptance job keeps launching apps on it)"
    sleep 3
  done
}

stop_screenshot_loop() {
  if [ -n "$SCREEN_SENTINEL" ]; then
    rm -f -- "$SCREEN_SENTINEL"
  fi
  if [ -n "$SHOTS_PID" ]; then
    kill "$SHOTS_PID" 2>/dev/null || true
    wait "$SHOTS_PID" 2>/dev/null || true
    SHOTS_PID=""
  fi
}

# Stops the `dsh web` this run started, proving the pid is ours first. The app
# keeps the remote server alive after its SSH link closes, so the runner is the
# one that must stop it.
stop_remote_dsh() {
  [ -n "$REMOTE_STATE" ] || return 0
  [ -f "$REMOTE_STATE/web.pid" ] || return 0
  local pid args i recorded_start live_start
  pid="$(cat "$REMOTE_STATE/web.pid" 2>/dev/null || true)"
  case "$pid" in '' | *[!0-9]*) return 0 ;; esac
  kill -0 "$pid" 2>/dev/null || return 0
  # The pid file lives under this run's private temp HOME (the pifile path is
  # unique), and RemoteDshBootstrap recorded the process start time in web.st.
  # Matching it rules out a recycled pid without needing the env in argv.
  args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
  case "$args" in
    *dsh*web*) ;;
    *)
      e2e_log "not stopping pid $pid: its command line is not a dsh web process ($args)"
      return 0
      ;;
  esac
  if [ -f "$REMOTE_STATE/web.st" ]; then
    recorded_start="$(cat "$REMOTE_STATE/web.st" 2>/dev/null || true)"
    live_start="$(ps -p "$pid" -o lstart= 2>/dev/null || true)"
    if [ -n "$recorded_start" ] && [ -n "$live_start" ] && [ "$recorded_start" != "$live_start" ]; then
      e2e_log "not stopping pid $pid: start time does not match the bootstrap record (pid reused)"
      return 0
    fi
  fi
  e2e_log "stopping remote dsh web pid $pid"
  pkill -TERM -P "$pid" 2>/dev/null || true
  kill -TERM "$pid" 2>/dev/null || true
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    sleep 0.2
  fi
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  stop_screenshot_loop

  if [ "$rc" -ne 0 ] && [ -n "$UDID" ]; then
    mkdir -p "$EVIDENCE/green" 2>/dev/null || true
    xcrun simctl io "$UDID" screenshot "$EVIDENCE/green/failure-screen.png" >/dev/null 2>&1 || true
  fi

  # Capture the remote logs before the state dir is removed/restored.
  if [ -n "$REMOTE_STATE" ] && [ -d "$REMOTE_STATE" ]; then
    stop_remote_dsh
    if [ -f "$REMOTE_STATE/web.log" ]; then
      local token
      token="$(python3 - "$REMOTE_STATE/web.log" <<'PY'
import re, sys
try:
    text = open(sys.argv[1], encoding='utf-8', errors='replace').read()
except OSError:
    sys.exit(0)
match = re.search(r'[?&]token=(\S+)', text)
print(match.group(1) if match else '')
PY
)"
      [ -n "$token" ] && scrub_secret_from_file "$REMOTE_STATE/web.log" "$token" || true
      mkdir -p "$EVIDENCE/green" 2>/dev/null || true
      cp "$REMOTE_STATE/web.log" "$EVIDENCE/green/remote-dsh-web.log" 2>/dev/null || true
    fi
    rm -rf -- "$REMOTE_STATE"
  fi
  # A Flutter tool that lost its connection leaves the test app running; do not
  # leave it on the shared simulator.
  if [ -n "$UDID" ]; then
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  fi

  if [ -n "$BROKER_PID" ] && kill -0 "$BROKER_PID" 2>/dev/null; then
    kill "$BROKER_PID" 2>/dev/null || true
    wait "$BROKER_PID" 2>/dev/null || true
  fi
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

# --------------------------------------------------------------------------- dry run

if [ "$MODE" = "dry-run" ]; then
  preflight
  resolve_udid
  local_evidence_parent="$(dirname "$EVIDENCE")"
  [ -d "$local_evidence_parent" ] || fail "evidence parent directory does not exist: $local_evidence_parent"
  e2e_log "dry-run: flutter=$FLUTTER"
  e2e_log "dry-run: dsh=$DSH_BIN ($("$DSH_BIN" --version 2>/dev/null | head -1))"
  e2e_log "dry-run: sshd=/usr/sbin/sshd preferred_port=${DSH_E2E_SSHD_PORT:-22422}"
  e2e_log "dry-run: broker=$BROKER (key source: \$HOME/.dsh/.credentials.yaml)"
  e2e_log "dry-run: evidence=$EVIDENCE"
  e2e_log "dry-run: would uninstall $BUNDLE_ID and run:"
  e2e_log "  cd $APP && flutter test --no-pub -r expanded -d $UDID \\"
  e2e_log "    --dart-define=E2E_BROKER_URL=http://127.0.0.1:<port> --dart-define=E2E_BROKER_TOKEN=<token> \\"
  e2e_log "    --dart-define=T33B_SSH_HOST=127.0.0.1 --dart-define=T33B_SSH_PORT=<port> \\"
  e2e_log "    --dart-define=T33B_SSH_USER=\${USER} --dart-define=T33B_SSH_KEY_B64=<key> \\"
  e2e_log "    --dart-define=T33B_HOST_FINGERPRINT=<SHA256:...> \\"
  e2e_log "    --dart-define='T33B_LAUNCH_COMMAND=env HOME=<temp>/remote-home DSH_HOME=<temp>/remote-home/.dsh $DSH_BIN web' \\"
  e2e_log "    integration_test/phase1_ssh_real_test.dart"
  printf 'dry-run: PASS (nothing started)\n'
  exit 0
fi

# --------------------------------------------------------------------------- real run

preflight
resolve_udid
mkdir -p "$EVIDENCE/green"

acquire_sim_lock 1800
boot_sim "$UDID"
wait_simulator_quiet

WORK="$(make_temp_dir dsh-e2e-ios-ssh)"
e2e_track_temp "$WORK"
chmod 700 "$WORK"
REMOTE_HOME="$WORK/remote-home"
REMOTE_WORK="$REMOTE_HOME/work"
mkdir -p "$REMOTE_WORK" "$REMOTE_HOME/.dsh"
if printf '%s' "$REMOTE_HOME" | grep -q ' '; then
  fail "the temp remote HOME contains a space, which the remote launch command cannot carry: $REMOTE_HOME"
fi

# The SSH session's HOME is the temp remote HOME (sshd SetEnv below), so
# RemoteDshBootstrap keeps its web.pid/web.log under the temp dir and the real
# ~/.dsh-app-remote of a running dsh-app on this Mac is never read or written.
REMOTE_STATE="$REMOTE_HOME/.dsh-app-remote"

e2e_log "starting the throwaway unprivileged sshd on 127.0.0.1 (preferred port ${DSH_E2E_SSHD_PORT:-22422})"
SSHD_START_OUT="$WORK/sshd-start.out"
SSHD_START_ERR="$WORK/sshd-start.err"
# The login shell (and so RemoteDshBootstrap) sees the temp HOME; dsh itself
# also gets HOME/DSH_HOME from the launch command.
export DSH_E2E_SSHD_SETENV="HOME=$REMOTE_HOME"
if ! bash "$SSHD_CONTROL" start >"$SSHD_START_OUT" 2>"$SSHD_START_ERR"; then
  cat "$SSHD_START_ERR" >&2 || true
  fail "the throwaway sshd did not start"
fi
SSHD_LINE="$(grep -m 1 '^SSHD ' "$SSHD_START_OUT" || true)"
[ -n "$SSHD_LINE" ] || fail "sshd did not print its state"
SSHD_JSON="${SSHD_LINE#SSHD }"
SSHD_WORK="$(printf '%s' "$SSHD_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["work"])')"
SSHD_PORT="$(printf '%s' "$SSHD_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["port"])')"
SSHD_USER="$(printf '%s' "$SSHD_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["user"])')"
SSHD_KEY="$(printf '%s' "$SSHD_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["client_key"])')"
SSHD_FINGERPRINT="$(printf '%s' "$SSHD_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["fingerprint"])')"
[ -n "$SSHD_WORK" ] && [ -n "$SSHD_PORT" ] && [ -n "$SSHD_KEY" ] && [ -n "$SSHD_FINGERPRINT" ] ||
  fail "could not parse the sshd state"
case "$SSHD_FINGERPRINT" in SHA256:*) ;; *) fail "unexpected host-key fingerprint: $SSHD_FINGERPRINT" ;; esac
cp "$SSHD_START_OUT" "$EVIDENCE/green/sshd-start.log" 2>/dev/null || true
e2e_log "sshd ready on 127.0.0.1:$SSHD_PORT as $SSHD_USER (host key $SSHD_FINGERPRINT)"

# Prove the isolated session HOME before the app relies on it; a real desktop
# dsh-app's state must not be in reach.
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
SSH_OPTS+=(-o IdentitiesOnly=yes -o ConnectTimeout=10 -o LogLevel=ERROR)
SSHD_SESSION_HOME="$(ssh "${SSH_OPTS[@]}" -i "$SSHD_KEY" -p "$SSHD_PORT" "$SSHD_USER@127.0.0.1" 'printf %s "$HOME"' 2>"$WORK/ssh-home.err" || true)"
if [ "$SSHD_SESSION_HOME" != "$REMOTE_HOME" ]; then
  cat "$WORK/ssh-home.err" >&2 || true
  fail "the SSH session HOME is '$SSHD_SESSION_HOME', expected the isolated '$REMOTE_HOME' (sshd SetEnv did not apply)"
fi
[ ! -e "$REMOTE_STATE/web.pid" ] || fail "the isolated remote state already has a dsh web pid: $REMOTE_STATE/web.pid"
e2e_log "SSH session HOME is isolated: $SSHD_SESSION_HOME (bootstrap state: $REMOTE_STATE)"

e2e_log "starting the loopback credential broker (key from ~/.dsh/.credentials.yaml)"
env -u OPENCODE_GO_API_KEY node "$BROKER" >"$WORK/broker.out" 2>"$WORK/broker.err" &
BROKER_PID=$!
BROKER_LINE=""
for _ in $(seq 1 300); do
  BROKER_LINE="$(grep -m 1 '^BROKER ' "$WORK/broker.out" 2>/dev/null || true)"
  [ -n "$BROKER_LINE" ] && break
  if ! kill -0 "$BROKER_PID" 2>/dev/null; then
    cat "$WORK/broker.err" >&2 || true
    fail "the credential broker exited before announcing its port"
  fi
  sleep 0.1
done
[ -n "$BROKER_LINE" ] || fail "the credential broker did not announce its port"
BROKER_PORT="$(printf '%s\n' "$BROKER_LINE" | python3 -c 'import json,sys; line=sys.stdin.read().strip(); print(json.loads(line[len("BROKER "):])["port"])')"
BROKER_TOKEN="$(printf '%s\n' "$BROKER_LINE" | python3 -c 'import json,sys; line=sys.stdin.read().strip(); print(json.loads(line[len("BROKER "):])["token"])')"
[ -n "$BROKER_PORT" ] && [ -n "$BROKER_TOKEN" ] || fail "could not parse the broker announcement"
wait_port 127.0.0.1 "$BROKER_PORT" 10
e2e_log "broker ready on 127.0.0.1:$BROKER_PORT (token held in memory only)"

KEY_B64="$(base64 <"$SSHD_KEY" | tr -d '\n')"
[ -n "$KEY_B64" ] || fail "could not base64-encode the throwaway client key"
LAUNCH_COMMAND="env HOME=$REMOTE_HOME DSH_HOME=$REMOTE_HOME/.dsh $DSH_BIN web"
e2e_log "remote launch command: $LAUNCH_COMMAND (the app appends --host 127.0.0.1 --port 0 --no-open)"
e2e_log "remote workspace: $REMOTE_WORK"

e2e_log "uninstalling $BUNDLE_ID from $UDID (real clean first launch)"
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

mkdir -p "$EVIDENCE/green/screens"
SCREEN_SENTINEL="$WORK/screens-on"
: >"$SCREEN_SENTINEL"
(
  n=0
  while [ -f "$SCREEN_SENTINEL" ]; do
    n=$((n + 1))
    xcrun simctl io "$UDID" screenshot "$EVIDENCE/green/screens/$(printf '%03d' "$n")-t$(($(date +%s) - STARTED_AT))s.png" >/dev/null 2>&1 || true
    sleep 12
  done
) &
SHOTS_PID=$!

TEST_OUT="$WORK/flutter-test.out"
TEST_RC=1
TEST_STARTED="$(date +%s)"
export DSH_IOS_GUEST_BUILD=0
export DSH_TEST_FONT_DIR="${DSH_TEST_FONT_DIR:-${HOME}/Documents/Zenlix/DSH-Go-iOS/.fonts}"
export PATH="$(dirname "$FLUTTER"):$PATH"
e2e_log "running flutter test integration_test/phase1_ssh_real_test.dart on $UDID"
e2e_log "the real model is called (< 20 requests budgeted); this takes several minutes"
set +e
(
  cd "$APP" || exit 90
  # --ignore-timeouts keeps a busy simulator (several agents share this Mac)
  # from failing the suite at load; the test's own waits still fail loudly.
  "$FLUTTER" test --no-pub -r expanded --ignore-timeouts -d "$UDID" \
    --dart-define=E2E_BROKER_URL="http://127.0.0.1:$BROKER_PORT" \
    --dart-define=E2E_BROKER_TOKEN="$BROKER_TOKEN" \
    --dart-define=E2E_PROVIDER_BASE_URL="https://opencode.ai/inference/go/v1" \
    --dart-define=E2E_MODEL="deepseek-v4.1-flash" \
    --dart-define=T33B_SSH_HOST="127.0.0.1" \
    --dart-define=T33B_SSH_PORT="$SSHD_PORT" \
    --dart-define=T33B_SSH_USER="$SSHD_USER" \
    --dart-define=T33B_SSH_KEY_B64="$KEY_B64" \
    --dart-define=T33B_HOST_FINGERPRINT="$SSHD_FINGERPRINT" \
    --dart-define=T33B_REMOTE_HOME="$REMOTE_HOME" \
    --dart-define=T33B_REMOTE_WORKDIR="$REMOTE_WORK" \
    --dart-define="T33B_LAUNCH_COMMAND=$LAUNCH_COMMAND" \
    integration_test/phase1_ssh_real_test.dart
) >"$TEST_OUT" 2>&1
TEST_RC=$?
set -e
TEST_FINISHED="$(date +%s)"
TEST_SECONDS=$((TEST_FINISHED - TEST_STARTED))

stop_screenshot_loop
xcrun simctl io "$UDID" screenshot "$EVIDENCE/green/final-screen.png" >/dev/null 2>&1 || true

# The broker token and any launch token must not land in evidence.
scrub_secret_from_file "$TEST_OUT" "$BROKER_TOKEN" || true
if [ -f "$REMOTE_STATE/web.log" ]; then
  launch_token="$(python3 - "$REMOTE_STATE/web.log" <<'PY'
import re, sys
try:
    text = open(sys.argv[1], encoding='utf-8', errors='replace').read()
except OSError:
    sys.exit(0)
match = re.search(r'[?&]token=(\S+)', text)
print(match.group(1) if match else '')
PY
)"
  [ -n "$launch_token" ] && scrub_secret_from_file "$TEST_OUT" "$launch_token" || true
fi
cp "$TEST_OUT" "$EVIDENCE/green/flutter-test.log"
chmod 600 "$EVIDENCE/green/flutter-test.log" 2>/dev/null || true

# The Mac-side proof that the model's bash tool wrote the file in the remote
# workspace (the test also reads it back over a second real SSH connection).
REMOTE_FILE="$REMOTE_WORK/ssh-ok.md"
FILE_STATUS="missing"
FILE_CONTENT=""
if [ -f "$REMOTE_FILE" ]; then
  FILE_STATUS="present"
  FILE_CONTENT="$(cat "$REMOTE_FILE")"
  cp "$REMOTE_FILE" "$EVIDENCE/green/ssh-ok.md"
fi
{
  printf 'remote_home=%s\n' "$REMOTE_HOME"
  printf 'remote_workdir=%s\n' "$REMOTE_WORK"
  printf 'ssh_ok_md=%s\n' "$FILE_STATUS"
  printf 'content=%s\n' "$FILE_CONTENT"
  printf 'dsh_home_files:\n'
  find "$REMOTE_HOME/.dsh" -type f 2>/dev/null | sed "s#^$REMOTE_HOME#<remote-home>#" | head -40 || true
  printf 'workspace_file_locations:\n'
  find "$REMOTE_HOME" -name 'ssh-ok.md' 2>/dev/null | sed "s#^$REMOTE_HOME#<remote-home>#" || true
} >"$EVIDENCE/green/remote-workspace.txt"
chmod 600 "$EVIDENCE/green/remote-workspace.txt" 2>/dev/null || true

# Remote dsh pid/log/token-redacted summary (the process is stopped in cleanup).
if [ -f "$REMOTE_STATE/web.pid" ]; then
  dsh_pid="$(cat "$REMOTE_STATE/web.pid" 2>/dev/null || true)"
  printf 'pid=%s\nargs=%s\n' "$dsh_pid" "$(ps -p "$dsh_pid" -o args= 2>/dev/null || true)" \
    >"$EVIDENCE/green/remote-dsh-process.txt"
  chmod 600 "$EVIDENCE/green/remote-dsh-process.txt" 2>/dev/null || true
fi

if [ "$TEST_RC" -ne 0 ]; then
  e2e_log "integration test failed (exit $TEST_RC); tail:"
  tail -80 "$TEST_OUT" >&2 || true
  env_json_write "$EVIDENCE/green/run.env.json" \
    "run=t33b_ssh_real" "result=fail" "exit=$TEST_RC" "ssh_port=$SSHD_PORT" "ssh_user=$SSHD_USER" \
    "fingerprint=$SSHD_FINGERPRINT" "remote_home=$REMOTE_HOME" "remote_workdir=$REMOTE_WORK" \
    "ssh_ok_md=$FILE_STATUS" "test_seconds=$TEST_SECONDS" "commit=$(repo_commit)" \
    "log=$EVIDENCE/green/flutter-test.log"
  fail "T33b SSH real run failed; see $EVIDENCE/green/flutter-test.log"
fi

grep -q 'All tests passed!' "$TEST_OUT" || fail "the suite did not report 'All tests passed!'"
if grep -Eq '~[0-9]+:|Some tests failed|: Skip' "$TEST_OUT"; then
  fail "the suite contains a skipped or failed test (see $EVIDENCE/green/flutter-test.log)"
fi
PASSED="$(python3 - "$TEST_OUT" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8', errors='replace').read()
nums = [int(n) for n in re.findall(r'\+(\d+)', text)]
print(max(nums) if nums else 0)
PY
)"
[ "$PASSED" -ge 1 ] || fail "the suite reported no passing test"
[ "$FILE_STATUS" = "present" ] || fail "the remote workspace file $REMOTE_FILE does not exist after the test"
printf '%s' "$FILE_CONTENT" | grep -q 'ssh real model ok' ||
  fail "the remote workspace file does not contain 'ssh real model ok': $FILE_CONTENT"

TOTAL_SECONDS=$(($(date +%s) - STARTED_AT))
env_json_write "$EVIDENCE/green/run.env.json" \
  "run=t33b_ssh_real" "result=pass" "tests=$PASSED" "ssh_port=$SSHD_PORT" "ssh_user=$SSHD_USER" \
  "fingerprint=$SSHD_FINGERPRINT" "remote_home=$REMOTE_HOME" "remote_workdir=$REMOTE_WORK" \
  "ssh_session_home=$SSHD_SESSION_HOME" "ssh_ok_md=$FILE_STATUS" "ssh_ok_content=$FILE_CONTENT" "test_seconds=$TEST_SECONDS" \
  "total_seconds=$TOTAL_SECONDS" "commit=$(repo_commit)" "log=$EVIDENCE/green/flutter-test.log" \
  "screenshots=$EVIDENCE/green/screens"

printf 'T33b SSH real: PASS (%s test, %ss total; sshd 127.0.0.1:%s user %s; remote file %s)\n' \
  "$PASSED" "$TOTAL_SECONDS" "$SSHD_PORT" "$SSHD_USER" "$FILE_STATUS"
