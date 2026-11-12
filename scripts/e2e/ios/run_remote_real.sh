#!/usr/bin/env bash
# T33b — real self-hosted DSH Remote from the iOS app, end to end, with the
# real opencode-go model.
#
# Starts:
#   * scripts/e2e/remote/relay_stack.sh start  (real upstream Server + `dsh web`
#     Host in an isolated DSH_HOME; prints RELAY_ENV and writes env.json),
#   * the T25 loopback credential broker with the real opencode-go key,
#   * a loopback control endpoint that restarts only the Host process (same
#     DSH_HOME) for the reconnect half of the test.
#
# Then it uninstalls the app from the iPhone 17 Pro simulator, runs
# integration_test/phase1_remote_real_test.dart with the broker + relay
# defines (via a mode-600 dart-define file, so no secret is on the command
# line), captures the full log and screenshots of each test step, checks the
# remote-ok.md the model wrote on the Mac side, and finally stops the relay
# stack and the broker.
#
# Usage:
#   scripts/e2e/ios/run_remote_real.sh [--device NAME|UDID] [--keep]
#
#   --device   simulator name or UDID (default: iPhone 17 Pro
#              1D9F8C91-5739-47B2-BDD0-0FC7207166F3)
#   --keep     leave the relay stack running and its temp work dir in place
#              after a result (default: stop everything)
#
# Env:
#   DSH_E2E_EVIDENCE_DIR   default <main checkout>/reports/phase1-completion/T33b-relay
#   DSH_SIM_UDID           simulator override (same as --device with a UDID)
#   DSH_E2E_KEEP=1         keep temp dirs created by lib.sh
#   DSH_PHASE1_SIM_LOCK    global simulator lock (default /tmp/dsh-phase1-sim.lock)
#
# Exit codes: 0 pass, 1 any failure (test, file check, harness), 4 (never used:
# skips are not allowed for this acceptance check).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../lib.sh
. "$ROOT/scripts/e2e/lib.sh"

BUNDLE_ID="io.github.ccch1mneyyy.dshgo"
DEFAULT_UDID="1D9F8C91-5739-47B2-BDD0-0FC7207166F3"
DEFAULT_DEVICE="$DEFAULT_UDID"
TEST_FILE="$ROOT/app/integration_test/phase1_remote_real_test.dart"
BROKER="$ROOT/test/fixtures/credential_broker.mjs"
RELAY_STACK="$ROOT/scripts/e2e/remote/relay_stack.sh"
REMOTE_FILE_NAME="remote-ok.md"
REMOTE_FILE_LINE="remote real model ok"

TARGET="${DSH_SIM_UDID:-$DEFAULT_DEVICE}"
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --device) TARGET="${2:?--device needs a value}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h | --help)
      sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf 'unknown argument: %s (try --help)\n' "$1" >&2
      exit 2
      ;;
  esac
done

# Finder git path is the main checkout even from a linked worktree; evidence
# lives next to the other Phase 1 reports there (never committed).
GIT_COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [ -n "$GIT_COMMON" ]; then MAIN_ROOT="$(dirname "$GIT_COMMON")"; else MAIN_ROOT="$ROOT"; fi
EVIDENCE="${DSH_E2E_EVIDENCE_DIR:-$MAIN_ROOT/reports/phase1-completion/T33b-relay}"
EVIDENCE="${EVIDENCE%/}"
GREEN="$EVIDENCE/green"
RED="$EVIDENCE/red"
SHOTS="$GREEN/shots"

FLUTTER="$(resolve_flutter)"
DSH_BIN="$(command -v dsh || true)"
[ -n "$DSH_BIN" ] || fail "dsh launcher not found on PATH"

RELAY_STARTED=0
BROKER_PID=""
CONTROL_PID=""
SERVER_URL=""
ACCOUNT=""
PASSWORD=""
DSH_HOME=""
HOST_WORKSPACE=""
WORK_DIR=""
TEST_RC=1
FILE_OK=0
STARTED_AT="$(date -u +%FT%TZ)"
TEST_LOG=""
RELAY_LOG=""

log() { printf '[t33b] %s\n' "$*" >&2; }

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  set +e
  if [ -n "$CONTROL_PID" ] && kill -0 "$CONTROL_PID" 2>/dev/null; then
    kill -TERM "$CONTROL_PID" 2>/dev/null
    wait "$CONTROL_PID" 2>/dev/null
  fi
  if [ -n "$BROKER_PID" ] && kill -0 "$BROKER_PID" 2>/dev/null; then
    kill -TERM "$BROKER_PID" 2>/dev/null
    wait "$BROKER_PID" 2>/dev/null
  fi
  if [ -n "$WORK_DIR" ] && [ -d "$GREEN" ]; then copy_logs; fi
  if [ "$RELAY_STARTED" = 1 ]; then
    if [ "$KEEP" = 1 ]; then
      log "leaving the relay stack running (--keep); stop it with:"
      log "  EVIDENCE_DIR=$EVIDENCE STATE_FILE=$EVIDENCE/relay-stack-state.json $RELAY_STACK stop"
    else
      log "stopping the relay stack and broker"
      EVIDENCE_DIR="$EVIDENCE" STATE_FILE="$EVIDENCE/relay-stack-state.json" \
        "$RELAY_STACK" stop >>"$GREEN/03-relay-stop.log" 2>&1 || rc=1
    fi
  fi
  e2e_cleanup
  if [ -n "$EVIDENCE" ] && [ -d "$EVIDENCE" ]; then
    env_json_write "$EVIDENCE/summary.json" \
      "run=remote_real" \
      "result=$([ "$rc" -eq 0 ] && echo pass || echo fail)" \
      "test_exit=$TEST_RC" \
      "remote_file_ok=$FILE_OK" \
      "server_url=$SERVER_URL" \
      "host_workspace=$HOST_WORKSPACE" \
      "commit=$(repo_commit)" \
      "started_at=$STARTED_AT" \
      "finished_at=$(date -u +%FT%TZ)" \
      "test_log=$TEST_LOG" >/dev/null
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

redact_copy() { # source destination
  local src="$1" dst="$2"
  [ -f "$src" ] || return 0
  python3 - "$src" "$dst" "${PASSWORD:-}" <<'PY'
import re, sys

src, dst, password = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src, encoding="utf-8", errors="replace").read()
text = re.sub(r"([?&]token=)[^&\s]+", r"\1<redacted>", text)
text = re.sub(r"(Bearer )[A-Za-z0-9._~-]+", r"\1<redacted>", text)
if password:
    text = text.replace(password, "<redacted>")
open(dst, "w", encoding="utf-8").write(text)
PY
  chmod 600 "$dst" 2>/dev/null || true
}

json_field() { # json key
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$2"
}

parse_line_json() { # line prefix
  python3 -c '
import json, sys
line = sys.stdin.read().strip()
prefix = sys.argv[1]
if not line.startswith(prefix):
    raise SystemExit(3)
print(line[len(prefix):])
' "$1"
}

preflight() {
  require_darwin
  require_cmd python3
  require_cmd node
  require_cmd curl
  require_cmd git
  [ -f "$RELAY_STACK" ] || fail "missing relay stack script: $RELAY_STACK"
  [ -f "$BROKER" ] || fail "missing credential broker: $BROKER"
  [ -f "$TEST_FILE" ] || fail "missing integration test: $TEST_FILE"
  if [ ! -f "$ROOT/app/.dart_tool/package_config.json" ]; then
    e2e_log "app dependencies are not resolved; running flutter pub get"
    (cd "$ROOT/app" && "$FLUTTER" pub get >/dev/null) || fail "flutter pub get failed"
  fi
  [ -r "${OPENCODE_GO_API_KEY_FILE:-$HOME/.dsh/.credentials.yaml}" ] || [ -n "${OPENCODE_GO_API_KEY:-}" ] \
    || fail "no opencode-go key: set OPENCODE_GO_API_KEY or provide ~/.dsh/.credentials.yaml"
  mkdir -p "$GREEN" "$RED" "$SHOTS"
}

start_relay() {
  RELAY_LOG="$GREEN/00-relay-start.log"
  log "starting the real self-hosted relay stack"
  local clock
  clock=$(date +%s)
  if ! EVIDENCE_DIR="$EVIDENCE" STATE_FILE="$EVIDENCE/relay-stack-state.json" \
    "$RELAY_STACK" start >"$RELAY_LOG" 2>&1; then
    tail -30 "$RELAY_LOG" >&2 || true
    fail "relay_stack.sh start failed (log: $RELAY_LOG)"
  fi
  RELAY_STARTED=1
  local line
  line="$(grep -m 1 '^RELAY_ENV ' "$RELAY_LOG" || true)"
  [ -n "$line" ] || fail "relay_stack.sh printed no RELAY_ENV line"
  local json
  json="$(printf '%s\n' "$line" | parse_line_json 'RELAY_ENV ')" || fail "unparseable RELAY_ENV line"
  SERVER_URL="$(json_field "$json" serverUrl)"
  ACCOUNT="$(json_field "$json" account)"
  PASSWORD="$(json_field "$json" password)"
  DSH_HOME="$(json_field "$json" dshHome)"
  local host_log server_log host_pid
  host_log="$(json_field "$json" hostLog)"
  server_log="$(json_field "$json" serverLog)"
  host_pid="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pids"]["host"])')"
  WORK_DIR="$(dirname "$host_log")"
  HOST_WORKSPACE="$DSH_HOME/workspace"
  mkdir -p "$HOST_WORKSPACE"
  # The RELAY_ENV line carries the Server password. Keep the evidence log free
  # of it; the mode-600 env.json the stack writes is the only copy.
  redact_copy "$RELAY_LOG" "$RELAY_LOG.redacted"
  mv "$RELAY_LOG.redacted" "$RELAY_LOG"
  chmod 600 "$RELAY_LOG" 2>/dev/null || true
  log "relay stack up in $(( $(date +%s) - clock ))s: $SERVER_URL (host pid $host_pid)"
  log "host workspace for the session: $HOST_WORKSPACE"
  HOST_PID="$host_pid"
  HOST_LOG="$host_log"
  SERVER_LOG="$server_log"
}

start_broker() {
  log "starting the loopback credential broker"
  node "$BROKER" >"$WORK_DIR/broker.out" 2>"$WORK_DIR/broker.err" &
  BROKER_PID=$!
  local line=""
  for _ in $(seq 1 300); do
    line="$(grep -m 1 '^BROKER ' "$WORK_DIR/broker.out" 2>/dev/null || true)"
    [ -n "$line" ] && break
    kill -0 "$BROKER_PID" 2>/dev/null || {
      cat "$WORK_DIR/broker.err" >&2 || true
      fail "credential broker exited before announcing its port"
    }
    sleep 0.1
  done
  [ -n "$line" ] || fail "credential broker did not announce a port"
  local json
  json="$(printf '%s\n' "$line" | parse_line_json 'BROKER ')"
  BROKER_PORT="$(json_field "$json" port)"
  BROKER_TOKEN="$(json_field "$json" token)"
  wait_port 127.0.0.1 "$BROKER_PORT" 10
  log "credential broker on 127.0.0.1:$BROKER_PORT (key never printed)"
}

start_restart_control() {
  log "starting the Host-restart control endpoint"
  cat >"$WORK_DIR/restart_host.py" <<'PY'
import json, os, re, signal, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

work = os.environ["T33B_WORK"]
dsh_home = os.environ["T33B_DSH_HOME"]
state_file = os.environ["T33B_STATE_FILE"]
dsh_bin = os.environ["T33B_DSH_BIN"]
host_log = os.environ["T33B_HOST_LOG"]
lock = threading.Lock()
restarts = 0


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def wait_gone(pid, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if not alive(pid):
            return True
        time.sleep(0.1)
    return False


def update_state(pid):
    try:
        with open(state_file, encoding="utf-8") as f:
            state = json.load(f)
    except Exception:
        state = {}
    state["hostPid"] = pid
    tmp = state_file + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, state_file)


def restart_host():
    global restarts
    restarts += 1
    started = time.time()
    try:
        with open(state_file, encoding="utf-8") as f:
            old_pid = int(json.load(f)["hostPid"])
    except Exception:
        old_pid = 0
    if old_pid:
        try:
            os.kill(old_pid, signal.SIGTERM)
        except OSError:
            pass
        if not wait_gone(old_pid, 20):
            try:
                os.kill(old_pid, signal.SIGKILL)
            except OSError:
                pass
            if not wait_gone(old_pid, 5):
                raise RuntimeError("old Host pid %d is still alive" % old_pid)
    log_path = os.path.join(work, "host-restart-%d.log" % restarts)
    if os.path.exists(log_path):
        os.remove(log_path)
    env = dict(os.environ)
    env.pop("DEEPSEEK_API_KEY", None)
    env["HOME"] = os.path.join(work, "home")
    env["DSH_HOME"] = dsh_home
    env["XDG_CACHE_HOME"] = os.path.join(env["HOME"], ".cache")
    env["XDG_CONFIG_HOME"] = os.path.join(env["HOME"], ".config")
    env["XDG_DATA_HOME"] = os.path.join(env["HOME"], ".local/share")
    out = open(log_path, "ab", buffering=0)
    proc = subprocess.Popen(
        [dsh_bin, "web", "--host", "127.0.0.1", "--port", "0", "--no-open"],
        cwd=os.path.join(work, "work"),
        env=env,
        stdout=out,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    update_state(proc.pid)
    deadline = time.time() + 120
    online = False
    while time.time() < deadline:
        if proc.poll() is not None:
            raise RuntimeError("restarted Host exited with %s" % proc.returncode)
        try:
            with open(log_path, encoding="utf-8", errors="replace") as f:
                if "server control connection online" in f.read():
                    online = True
                    break
        except OSError:
            pass
        time.sleep(0.25)
    if not online:
        raise RuntimeError("restarted Host did not come online within 120s")
    return {
        "ok": True,
        "oldPid": old_pid,
        "newPid": proc.pid,
        "restartMs": int((time.time() - started) * 1000),
        "log": log_path,
    }


def log(message):
    print("[restart-control] " + message, file=sys.stderr, flush=True)


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/restart-host":
            self.send_error(404)
            return
        if not lock.acquire(blocking=False):
            self._json(409, {"ok": False, "error": "a restart is already running"})
            return
        try:
            result = restart_host()
            log("restarted: %s" % json.dumps({k: result[k] for k in ("oldPid", "newPid", "restartMs")}))
            self._json(200, result)
        except Exception as error:
            log("restart failed: %s" % error)
            self._json(500, {"ok": False, "error": str(error)})
        finally:
            lock.release()

    def _json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
print("CONTROL " + json.dumps({"port": server.server_address[1]}), flush=True)
log("listening on 127.0.0.1:%d" % server.server_address[1])
server.serve_forever()
PY
  T33B_WORK="$WORK_DIR" \
  T33B_DSH_HOME="$DSH_HOME" \
  T33B_STATE_FILE="$EVIDENCE/relay-stack-state.json" \
  T33B_DSH_BIN="$DSH_BIN" \
  T33B_HOST_LOG="$HOST_LOG" \
    python3 "$WORK_DIR/restart_host.py" >"$WORK_DIR/control.out" 2>"$WORK_DIR/control.err" &
  CONTROL_PID=$!
  local line=""
  for _ in $(seq 1 100); do
    line="$(grep -m 1 '^CONTROL ' "$WORK_DIR/control.out" 2>/dev/null || true)"
    [ -n "$line" ] && break
    kill -0 "$CONTROL_PID" 2>/dev/null || {
      cat "$WORK_DIR/control.err" >&2 || true
      fail "Host-restart control exited before announcing its port"
    }
    sleep 0.1
  done
  [ -n "$line" ] || fail "Host-restart control did not announce a port"
  local control_json
  control_json="$(printf '%s\n' "$line" | parse_line_json 'CONTROL ')"
  CONTROL_PORT="$(json_field "$control_json" port)"
  wait_port 127.0.0.1 "$CONTROL_PORT" 10
  log "Host-restart control on 127.0.0.1:$CONTROL_PORT"
}

write_defines() {
  local file="$WORK_DIR/e2e-defines.json"
  python3 - "$file" "$BROKER_PORT" "$BROKER_TOKEN" "$SERVER_URL" "$ACCOUNT" "$PASSWORD" \
    "$HOST_WORKSPACE" "$CONTROL_PORT" <<'PY'
import json, os, sys

path = sys.argv[1]
broker_port, broker_token, server, account, password, workdir, control_port = sys.argv[2:9]
data = {
    "E2E_BROKER_URL": "http://127.0.0.1:%s" % broker_port,
    "E2E_BROKER_TOKEN": broker_token,
    "E2E_RELAY_URL": server,
    "E2E_RELAY_ACCOUNT": account,
    "E2E_RELAY_PASSWORD": password,
    "E2E_RELAY_HOST_NAME": "E2E Host",
    "E2E_RELAY_WORKDIR": workdir,
    "E2E_HOST_RESTART_URL": "http://127.0.0.1:%s/restart-host" % control_port,
}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY
  chmod 600 "$file"
  DEFINES="$file"
}

run_test() {
  TEST_LOG="$GREEN/02-flutter-test.log"
  log "uninstalling the app from $UDID (real clean install)"
  xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  local shot_no=1
  log "running the real remote integration test on $UDID"
  set +e
  ( cd "$ROOT/app" && DSH_IOS_GUEST_BUILD=0 DSH_TEST_FONT_DIR="${DSH_TEST_FONT_DIR:-$MAIN_ROOT/.fonts}" \
      "$FLUTTER" test --no-pub -r expanded \
      --dart-define-from-file="$DEFINES" \
      integration_test/phase1_remote_real_test.dart -d "$UDID" 2>&1 ) \
    | tee "$TEST_LOG" \
    | while IFS= read -r line; do
        case "$line" in
          *"=== screenshot:"*)
            local_slug="${line##*=== screenshot:}"
            local_slug="${local_slug%%[[:space:]]*}"
            local_slug="$(printf '%s' "$local_slug" | tr -c 'A-Za-z0-9._-' '_')"
            sleep 0.8
            local_shot="$(date +%H%M%S)-$(printf '%02d' "$shot_no")-${local_slug:-step}.png"
            xcrun simctl io "$UDID" screenshot "$SHOTS/$local_shot" >/dev/null 2>&1 || true
            printf '[t33b] screenshot: %s\n' "$SHOTS/$local_shot" >&2
            shot_no=$((shot_no + 1))
            ;;
        esac
      done
  TEST_RC=${PIPESTATUS[0]}
  set -e
  chmod 600 "$TEST_LOG" 2>/dev/null || true
  return 0
}

check_remote_file() {
  local file="$HOST_WORKSPACE/$REMOTE_FILE_NAME"
  if [ -f "$file" ] && grep -q "$REMOTE_FILE_LINE" "$file"; then
    FILE_OK=1
    {
      printf 'path=%s\n' "$file"
      printf 'sha256=%s\n' "$(shasum -a 256 "$file" | awk '{print $1}')"
      printf 'size=%s\n' "$(wc -c <"$file" | tr -d ' ')"
      printf -- '--- content ---\n'
      cat "$file"
    } >"$GREEN/04-remote-file.txt"
    log "remote file verified on the Mac: $file"
  else
    FILE_OK=0
    {
      printf 'missing_or_wrong=%s\n' "$file"
      ls -la "$HOST_WORKSPACE" 2>/dev/null || true
    } >"$GREEN/04-remote-file.txt"
    log "remote file missing or wrong on the Mac: $file"
  fi
}

copy_logs() {
  redact_copy "$WORK_DIR/host.log" "$GREEN/10-host.log"
  redact_copy "$WORK_DIR/server.log" "$GREEN/11-server.log"
  redact_copy "$WORK_DIR/control.err" "$GREEN/12-restart-control.log"
  local restart
  for restart in "$WORK_DIR"/host-restart-*.log; do
    [ -f "$restart" ] || continue
    redact_copy "$restart" "$GREEN/13-$(basename "$restart")"
  done
}

preflight

if printf '%s' "$TARGET" | grep -Eq '^[0-9A-Fa-f-]{36}$'; then
  UDID="$TARGET"
else
  UDID="$(resolve_sim_udid "$TARGET")"
fi
[ -n "$UDID" ] || fail "no simulator UDID"
boot_sim "$UDID"
acquire_sim_lock 1800
log "simulator: $UDID"

start_relay
start_broker
start_restart_control
write_defines

run_test
if [ "$TEST_RC" -ne 0 ]; then
  log "integration test failed (exit $TEST_RC); see $TEST_LOG"
  copy_logs
  fail "phase1_remote_real_test.dart failed"
fi

check_remote_file
copy_logs
if [ "$FILE_OK" -ne 1 ]; then
  fail "the model did not write '$REMOTE_FILE_LINE' to $HOST_WORKSPACE/$REMOTE_FILE_NAME"
fi
log "PASS: real self-hosted relay E2E with the real model (log: $TEST_LOG)"
