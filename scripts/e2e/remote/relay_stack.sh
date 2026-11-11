#!/usr/bin/env bash
# Start a real, self-hosted DSH Remote stack for end-to-end tests:
#
#   ds-harness-remote apps/server (loopback, password account, Relay only)
#     <- Host: `dsh web` + the ds-harness-remote Host plugin in an isolated
#        DSH_HOME, pre-provisioned with host credentials
#
# Nothing is faked: the Server and Host are the upstream sources and the
# published plugin. The one real user `~/.dsh` is never touched: the Host gets
# its own DSH_HOME and HOME below a fresh temp directory.
#
# Usage:
#   scripts/e2e/remote/relay_stack.sh [start] [--keep]
#       Build the Server, install the plugin, start both, wait until the Host
#       is online, write <evidence>/env.json and print exactly one line:
#           RELAY_ENV {json}
#       The stack keeps running; use `stop` (or the pids in the JSON).
#
#   scripts/e2e/remote/relay_stack.sh stop [--keep]
#       Stop both processes, verify the Server port has no listener, and
#       delete the temp work dir (unless --keep).
#
#   scripts/e2e/remote/relay_stack.sh self-test [--keep]
#       Start, verify GET /health, password login and an online Host through
#       GET /api/v1/account/devices, then stop and report no leftover listener.
#
# Env:
#   EVIDENCE_DIR     where env.json / state live (default <repo>/reports/phase1-completion/T33a)
#   STATE_FILE       stack state (default $EVIDENCE_DIR/relay-stack-state.json)
#   UPSTREAM         ds-harness-remote checkout (default <repo>/.refs/...,
#                    or the main checkout's .refs when run from a worktree)
#   DSH_BIN          dsh launcher (default: dsh on PATH)
#   PLUGIN_SPEC      anything `dsh plugin add` accepts (default
#                    ds-harness-remote@0.5.23)
#   PLUGIN_OPTIONAL  default 1: install the plugin's optional dependencies
#                    (@roamhq/wrtc). Set 0 for `--no-optional`; the pnpm
#                    11.28.5 bundled with DSH 0.2.2-rc.1 rejects that with
#                    ERR_PNPM_LOCKFILE_MISSING_DEPENDENCY, so 1 is the
#                    interoperable default. Relay-only tests do not need it.
#   NODE_BIN/NPM_BIN override node/npm
#   HOST_ONLINE_TIMEOUT seconds to wait for the Host (default 120)
#   SERVER_ONLINE_TIMEOUT seconds to wait for the Server (default 30)
#   WORK_ROOT        temp parent (default $TMPDIR or /tmp)
#
# The JSON printed by `start` has this stable schema:
#   {
#     "serverUrl": "http://127.0.0.1:<port>",
#     "account": "e2e-owner@example.test",
#     "password": "<random>",
#     "dshHome": "<temp>/dsh-home",
#     "hostLog": "<temp>/host.log",
#     "serverLog": "<temp>/server.log",
#     "pids": { "server": <pid>, "host": <pid> },
#     "upstream_sha": "<40 hex>"
#   }
#
# Needs: bash 3.2+, node >= 22, npm, curl, git, dsh, network to npm.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PKG_DIR="$REPO_ROOT/packages/dsh_remote"

DSH_BIN="${DSH_BIN:-dsh}"
NODE_BIN="${NODE_BIN:-node}"
NPM_BIN="${NPM_BIN:-npm}"
PLUGIN_VERSION="${PLUGIN_VERSION:-0.5.23}"
PLUGIN_SPEC="${PLUGIN_SPEC:-ds-harness-remote@$PLUGIN_VERSION}"
PLUGIN_OPTIONAL="${PLUGIN_OPTIONAL:-1}"
HOST_ONLINE_TIMEOUT="${HOST_ONLINE_TIMEOUT:-120}"
SERVER_ONLINE_TIMEOUT="${SERVER_ONLINE_TIMEOUT:-30}"
WORK_ROOT="${WORK_ROOT:-${TMPDIR:-/tmp}}"
WORK_ROOT="${WORK_ROOT%/}"
EVIDENCE_DIR="${EVIDENCE_DIR:-$REPO_ROOT/reports/phase1-completion/T33a}"
STATE_FILE="${STATE_FILE:-$EVIDENCE_DIR/relay-stack-state.json}"
PRINT_ENV=1

MODE=start
KEEP=0
for arg in "$@"; do
  case "$arg" in
    start|stop|self-test) MODE="$arg" ;;
    --keep) KEEP=1 ;;
    -h|--help) sed -n '2,56p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

WORK=""
SERVER_PID=""
HOST_PID=""
PORT=""
SERVER_URL=""
ACCOUNT="e2e-owner@example.test"
PASSWORD=""
DSH_HOME=""
SERVER_LOG=""
HOST_LOG=""
UPSTREAM_RESOLVED=""
UPSTREAM_SHA=""
STARTED_AT=""
STARTUP_ACTIVE=0
SELF_TEST_ACTIVE=0

log() { printf '[relay-stack] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage_hint() {
  echo "usage: $0 [start|stop|self-test] [--keep]" >&2
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

find_upstream() {
  local candidates=()
  if [[ -n "${UPSTREAM:-}" ]]; then
    candidates+=("$UPSTREAM")
  else
    candidates+=("$REPO_ROOT/.refs/ds-harness-remote-upstream")
    # From a linked worktree, the checkout usually lives in the main repo.
    candidates+=("$REPO_ROOT/../../../.refs/ds-harness-remote-upstream")
    candidates+=("$REPO_ROOT/../../.refs/ds-harness-remote-upstream")
    candidates+=("$REPO_ROOT/../.refs/ds-harness-remote-upstream")
  fi
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -d "$candidate/apps/server/src" && -d "$candidate/packages/protocol/src" ]]; then
      (cd "$candidate" && pwd -P)
      return 0
    fi
  done
  return 1
}

wait_for_file() { # file pattern seconds
  local file="$1" pattern="$2" seconds="$3"
  local i=0 max=$(( seconds * 4 ))
  while (( i < max )); do
    grep -q -- "$pattern" "$file" 2>/dev/null && return 0
    sleep 0.25
    i=$(( i + 1 ))
  done
  return 1
}

wait_for_http() { # url seconds
  local url="$1" seconds="$2"
  local i=0 max=$(( seconds * 4 ))
  while (( i < max )); do
    curl -fsS --max-time 2 "$url" >/dev/null 2>&1 && return 0
    sleep 0.25
    i=$(( i + 1 ))
  done
  return 1
}

with_timeout() { # seconds command...
  local seconds="$1"
  shift
  "$@" &
  local pid=$!
  ( sleep "$seconds"; kill -TERM "$pid" 2>/dev/null || true ) &
  local watchdog=$!
  local rc=0
  if wait "$pid"; then rc=0; else rc=$?; fi
  kill -TERM "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  return "$rc"
}

port_is_open() { # port -> 0 when something listens on loopback
  "$NODE_BIN" -e '
    const net = require("net");
    const socket = net.connect({ host: "127.0.0.1", port: Number(process.argv[1]) });
    let done = false;
    const finish = code => { if (done) return; done = true; socket.destroy(); process.exit(code); };
    socket.on("connect", () => finish(0));
    socket.on("error", () => finish(1));
    setTimeout(() => finish(1), 500);
  ' "$1"
}

safe_remove_work() { # dir
  local dir="${1:-}"
  [[ -n "$dir" ]] || return 0
  [[ -d "$dir" ]] || return 0
  if [[ ! -f "$dir/.relay-stack-marker" ]]; then
    log "refusing to remove $dir: marker missing"
    return 1
  fi
  case "$dir" in
    "$WORK_ROOT"/dsh-relay-stack.*|/tmp/dsh-relay-stack.*|/private/tmp/dsh-relay-stack.*|/var/folders/*/dsh-relay-stack.*) ;;
    *)
      log "refusing to remove $dir: outside the work root"
      return 1
      ;;
  esac
  rm -rf "$dir"
}

stop_processes() {
  [[ -n "$HOST_PID" ]] && kill -TERM "$HOST_PID" 2>/dev/null || true
  [[ -n "$SERVER_PID" ]] && kill -TERM "$SERVER_PID" 2>/dev/null || true

  local i=0 alive=0
  while (( i < 40 )); do
    alive=0
    if [[ -n "$HOST_PID" ]] && kill -0 "$HOST_PID" 2>/dev/null; then alive=1; fi
    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then alive=1; fi
    (( alive == 0 )) && break
    sleep 0.25
    i=$(( i + 1 ))
  done
  [[ -n "$HOST_PID" ]] && kill -KILL "$HOST_PID" 2>/dev/null || true
  [[ -n "$SERVER_PID" ]] && kill -KILL "$SERVER_PID" 2>/dev/null || true

  if [[ -n "$HOST_PID" ]] && kill -0 "$HOST_PID" 2>/dev/null; then
    log "host process $HOST_PID is still alive"
    return 1
  fi
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    log "server process $SERVER_PID is still alive"
    return 1
  fi
  if [[ -n "$PORT" ]] && port_is_open "$PORT"; then
    log "port $PORT still has a listener"
    return 1
  fi
  return 0
}

write_state() { # status
  local status="$1"
  local stopped_at=""
  [[ "$status" == stopped ]] && stopped_at="$(date -u +%FT%TZ)"
  RS_STATE_STATUS="$status" \
  RS_STATE_WORK="$WORK" \
  RS_STATE_SERVER_PID="$SERVER_PID" \
  RS_STATE_HOST_PID="$HOST_PID" \
  RS_STATE_PORT="$PORT" \
  RS_STATE_SERVER_URL="$SERVER_URL" \
  RS_STATE_ACCOUNT="$ACCOUNT" \
  RS_STATE_DSH_HOME="$DSH_HOME" \
  RS_STATE_SERVER_LOG="$SERVER_LOG" \
  RS_STATE_HOST_LOG="$HOST_LOG" \
  RS_STATE_UPSTREAM_SHA="$UPSTREAM_SHA" \
  RS_STATE_STARTED_AT="$STARTED_AT" \
  RS_STATE_STOPPED_AT="$stopped_at" \
  "$NODE_BIN" -e '
    const e = process.env;
    process.stdout.write(JSON.stringify({
      status: e.RS_STATE_STATUS,
      work: e.RS_STATE_WORK,
      serverPid: Number(e.RS_STATE_SERVER_PID || 0),
      hostPid: Number(e.RS_STATE_HOST_PID || 0),
      serverPort: Number(e.RS_STATE_PORT || 0),
      serverUrl: e.RS_STATE_SERVER_URL,
      account: e.RS_STATE_ACCOUNT,
      dshHome: e.RS_STATE_DSH_HOME,
      serverLog: e.RS_STATE_SERVER_LOG,
      hostLog: e.RS_STATE_HOST_LOG,
      upstreamSha: e.RS_STATE_UPSTREAM_SHA,
      startedAt: e.RS_STATE_STARTED_AT,
      stoppedAt: e.RS_STATE_STOPPED_AT || null,
    }, null, 2) + "\n");
  ' > "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

relay_env_json() {
  RS_SERVER_URL="$SERVER_URL" \
  RS_ACCOUNT="$ACCOUNT" \
  RS_PASSWORD="$PASSWORD" \
  RS_DSH_HOME="$DSH_HOME" \
  RS_HOST_LOG="$HOST_LOG" \
  RS_SERVER_LOG="$SERVER_LOG" \
  RS_SERVER_PID="$SERVER_PID" \
  RS_HOST_PID="$HOST_PID" \
  RS_UPSTREAM_SHA="$UPSTREAM_SHA" \
  "$NODE_BIN" -e '
    const e = process.env;
    process.stdout.write(JSON.stringify({
      serverUrl: e.RS_SERVER_URL,
      account: e.RS_ACCOUNT,
      password: e.RS_PASSWORD,
      dshHome: e.RS_DSH_HOME,
      hostLog: e.RS_HOST_LOG,
      serverLog: e.RS_SERVER_LOG,
      pids: { server: Number(e.RS_SERVER_PID), host: Number(e.RS_HOST_PID) },
      upstream_sha: e.RS_UPSTREAM_SHA,
    }));
  '
}

write_env_json() {
  mkdir -p "$EVIDENCE_DIR"
  local json
  json="$(relay_env_json)"
  printf '%s\n' "$json" > "$EVIDENCE_DIR/env.json"
  chmod 600 "$EVIDENCE_DIR/env.json"
  printf '%s' "$json"
}

install_plugin() {
  if [[ "${PLUGIN_OPTIONAL:-0}" == 1 ]]; then
    ( cd "$WORK" && exec "$DSH_BIN" plugin --profile web add -w "$PLUGIN_SPEC" )
  else
    ( cd "$WORK" && exec "$DSH_BIN" plugin --profile web add -w --no-optional "$PLUGIN_SPEC" )
  fi
}

build_server() {
  cd "$WORK/server"
  "$NPM_BIN" install --silent --no-audit --no-fund ws@8.21.3 zod@4.6.7 esbuild@0.24.2
  ./node_modules/.bin/esbuild src/server/main.ts --bundle --platform=node --format=esm \
    --target=node22 --alias:@dsh-remote/protocol=./src/protocol/index.ts \
    --outfile=dist/main.js --log-level=warning \
    --banner:js="import { createRequire } from 'module'; const require = createRequire(import.meta.url);"
}

start_server_process() {
  (
    cd "$WORK/server" || exit 1
    exec nohup env \
      DSH_SERVER_ACCOUNT="$ACCOUNT" \
      DSH_SERVER_PASSWORD="$PASSWORD" \
      DSH_SERVER_PUBLIC_URL="$SERVER_URL" \
      DSH_SERVER_PORT="$PORT" \
      DSH_SERVER_HOST=127.0.0.1 \
      DSH_SERVER_DATA_FILE="$WORK/server-data/state.json" \
      "$NODE_BIN" dist/main.js
  ) >"$SERVER_LOG" 2>&1 </dev/null &
  SERVER_PID=$!
}

start_host_process() {
  (
    cd "$WORK/work" || exit 1
    exec nohup env -u DEEPSEEK_API_KEY \
      HOME="$WORK/home" \
      DSH_HOME="$DSH_HOME" \
      XDG_CACHE_HOME="$WORK/home/.cache" \
      XDG_CONFIG_HOME="$WORK/home/.config" \
      XDG_DATA_HOME="$WORK/home/.local/share" \
      "$DSH_BIN" web --host 127.0.0.1 --port 0 --no-open
  ) >"$HOST_LOG" 2>&1 </dev/null &
  HOST_PID=$!
}

cleanup_on_exit() {
  local rc=$?
  trap - EXIT
  if (( STARTUP_ACTIVE == 1 )); then
    log "startup failed; stopping processes that did start"
    stop_processes || true
    if [[ "$KEEP" == 1 && -n "$WORK" ]]; then
      log "kept work dir: $WORK"
    elif [[ -n "$WORK" ]]; then
      safe_remove_work "$WORK" || true
    fi
  fi
  exit "$rc"
}
trap cleanup_on_exit EXIT

self_test_cleanup() {
  local rc=$?
  trap - EXIT
  if (( SELF_TEST_ACTIVE == 1 )); then
    SELF_TEST_ACTIVE=0
    log "self-test: stopping the stack"
    if ! stop_processes; then
      log "self-test: cleanup left a process or listener"
      (( rc == 0 )) && rc=1
    fi
    write_state stopped || true
    if [[ "$KEEP" == 1 ]]; then
      log "kept work dir: $WORK"
    else
      safe_remove_work "$WORK" || true
    fi
  fi
  exit "$rc"
}

start_stack() {
  need_cmd "$NODE_BIN"
  need_cmd "$NPM_BIN"
  need_cmd curl
  need_cmd git
  command -v "$DSH_BIN" >/dev/null 2>&1 || die "dsh launcher not found: $DSH_BIN (set DSH_BIN)"
  [[ -f "$PKG_DIR/tool/e2e/provision-host.mjs" ]] || die "missing $PKG_DIR/tool/e2e/provision-host.mjs"
  UPSTREAM_RESOLVED="$(find_upstream)" || die "no ds-harness-remote checkout with apps/server and packages/protocol (set UPSTREAM)"
  UPSTREAM_SHA="$(git -C "$UPSTREAM_RESOLVED" rev-parse HEAD 2>/dev/null)" || die "cannot read the upstream commit: $UPSTREAM_RESOLVED"
  if [[ -n "$(git -C "$UPSTREAM_RESOLVED" status --porcelain 2>/dev/null)" ]]; then
    log "warning: upstream checkout has local modifications; recording HEAD only"
  fi
  mkdir -p "$EVIDENCE_DIR"

  if [[ -f "$STATE_FILE" ]]; then
    local old_status old_server old_host
    old_status="$("$NODE_BIN" -p 'require(process.argv[1]).status' "$STATE_FILE" 2>/dev/null || true)"
    old_server="$("$NODE_BIN" -p 'require(process.argv[1]).serverPid' "$STATE_FILE" 2>/dev/null || true)"
    old_host="$("$NODE_BIN" -p 'require(process.argv[1]).hostPid' "$STATE_FILE" 2>/dev/null || true)"
    if [[ "$old_status" == running ]] && { { [[ -n "$old_server" ]] && kill -0 "$old_server" 2>/dev/null; } || { [[ -n "$old_host" ]] && kill -0 "$old_host" 2>/dev/null; }; }; then
      die "a stack is already running (state: $STATE_FILE); run '$0 stop' first"
    fi
  fi

  WORK="$(mktemp -d "$WORK_ROOT/dsh-relay-stack.XXXXXX")"
  printf 'dsh-relay-stack\n' >"$WORK/.relay-stack-marker"
  STARTUP_ACTIVE=1
  STARTED_AT="$(date -u +%FT%TZ)"
  SERVER_LOG="$WORK/server.log"
  HOST_LOG="$WORK/host.log"
  DSH_HOME="$WORK/dsh-home"
  mkdir -p "$WORK/server/src/server" "$WORK/server/src/protocol" \
    "$WORK/home" "$WORK/dsh-home" "$WORK/work" "$WORK/server-data"
  mkdir -p "$WORK/home/.cache" "$WORK/home/.config" "$WORK/home/.local/share"

  log "upstream: $UPSTREAM_RESOLVED @ $UPSTREAM_SHA"
  log "work dir: $WORK"
  log "building the self-hosted Server (esbuild)"
  cp "$UPSTREAM_RESOLVED"/apps/server/src/*.ts "$WORK/server/src/server/"
  cp "$UPSTREAM_RESOLVED"/packages/protocol/src/*.ts "$WORK/server/src/protocol/"
  printf '%s\n' '{"name":"e2e-server","private":true,"type":"module"}' >"$WORK/server/package.json"
  export npm_config_cache="$WORK/npm-cache"
  export npm_config_registry="${NPM_REGISTRY:-https://registry.npmjs.org/}"
  if ! with_timeout 300 build_server >"$WORK/server-build.log" 2>&1; then
    tail -30 "$WORK/server-build.log" >&2 || true
    die "Server build failed (log: $WORK/server-build.log)"
  fi

  PORT="$("$NODE_BIN" -e 'const s = require("net").createServer(); s.listen(0, "127.0.0.1", () => { console.log(s.address().port); s.close(); });')"
  SERVER_URL="http://127.0.0.1:$PORT"
  PASSWORD="e2e-$("$NODE_BIN" -e 'console.log(require("crypto").randomBytes(18).toString("base64url"))')"

  log "starting the Server on $SERVER_URL"
  start_server_process
  if ! wait_for_file "$SERVER_LOG" "listening" "$SERVER_ONLINE_TIMEOUT"; then
    tail -20 "$SERVER_LOG" >&2 || true
    die "Server did not report listening (log: $SERVER_LOG)"
  fi
  if ! wait_for_http "$SERVER_URL/health" 15; then
    tail -20 "$SERVER_LOG" >&2 || true
    die "Server health check failed at $SERVER_URL/health"
  fi

  export HOME="$WORK/home"
  export DSH_HOME
  log "installing $PLUGIN_SPEC into isolated DSH_HOME"
  if ! with_timeout 600 install_plugin >"$WORK/plugin-install.log" 2>&1; then
    tail -30 "$WORK/plugin-install.log" >&2 || true
    die "plugin install failed (log: $WORK/plugin-install.log)"
  fi
  [[ -d "$DSH_HOME/profiles/web" ]] || die "plugin install did not create $DSH_HOME/profiles/web"

  cat >"$DSH_HOME/profiles/web/cordis.patch.yml" <<EOF
- id: ds-harness-remote
  config:
    enabled: true
    role: host
    serverUrl: $SERVER_URL
    deviceName: E2E Host
    terminal: { enabled: false }
    codex: { enabled: false }
    cursor: { enabled: false }
    acp: { enabled: false }
EOF

  log "pre-provisioning Host credentials"
  if ! "$NODE_BIN" "$PKG_DIR/tool/e2e/provision-host.mjs" \
    "$SERVER_URL" "$ACCOUNT" "$PASSWORD" "$DSH_HOME" "E2E Host" \
    >"$WORK/host-provision.json" 2>"$WORK/host-provision.err"; then
    cat "$WORK/host-provision.err" >&2 || true
    die "Host credential provisioning failed"
  fi

  log "starting the Host (dsh web) and waiting for the Server control connection"
  start_host_process
  local i=0 max=$(( HOST_ONLINE_TIMEOUT * 4 ))
  local online=0
  while (( i < max )); do
    if grep -q "server control connection online" "$HOST_LOG" 2>/dev/null; then online=1; break; fi
    if ! kill -0 "$HOST_PID" 2>/dev/null; then
      log "Host exited before coming online (log: $HOST_LOG)"
      die "Host did not come online"
    fi
    sleep 0.25
    i=$(( i + 1 ))
  done
  (( online == 1 )) || {
    grep -iE 'error|failed|fatal' "$HOST_LOG" 2>/dev/null | tail -10 | sed -E 's/[A-Za-z0-9_-]{32,}/<redacted>/g' >&2 || true
    die "timed out waiting for the Host (log: $HOST_LOG)"
  }

  write_state running
  local json
  json="$(write_env_json)"
  STARTUP_ACTIVE=0
  trap - EXIT
  log "stack up: server pid $SERVER_PID, host pid $HOST_PID"
  if [[ "$KEEP" == 1 ]]; then log "kept work dir: $WORK"; fi
  if [[ "$PRINT_ENV" == 1 ]]; then
    printf 'RELAY_ENV %s\n' "$json"
  fi
}

load_state() {
  [[ -f "$STATE_FILE" ]] || die "no stack state at $STATE_FILE"
  local line
  line="$("$NODE_BIN" -e '
    const s = require(process.argv[1]);
    console.log([
      s.status || "unknown",
      s.work || "",
      s.serverPid || "",
      s.hostPid || "",
      s.serverPort || "",
      s.upstreamSha || "",
    ].join("\x1f"));
  ' "$STATE_FILE")" || die "cannot read $STATE_FILE"
  IFS=$'\x1f' read -r STATE_STATUS WORK SERVER_PID HOST_PID PORT UPSTREAM_SHA <<<"$line"
  SERVER_URL="$("$NODE_BIN" -p 'require(process.argv[1]).serverUrl || ""' "$STATE_FILE" 2>/dev/null || true)"
  DSH_HOME="$("$NODE_BIN" -p 'require(process.argv[1]).dshHome || ""' "$STATE_FILE" 2>/dev/null || true)"
  SERVER_LOG="$("$NODE_BIN" -p 'require(process.argv[1]).serverLog || ""' "$STATE_FILE" 2>/dev/null || true)"
  HOST_LOG="$("$NODE_BIN" -p 'require(process.argv[1]).hostLog || ""' "$STATE_FILE" 2>/dev/null || true)"
  STARTED_AT="$("$NODE_BIN" -p 'require(process.argv[1]).startedAt || ""' "$STATE_FILE" 2>/dev/null || true)"
  ACCOUNT="$("$NODE_BIN" -p 'require(process.argv[1]).account || ""' "$STATE_FILE" 2>/dev/null || true)"
}

stop_stack() {
  load_state
  if [[ "$STATE_STATUS" == stopped ]]; then
    log "stack is already stopped"
    if [[ "$KEEP" == 1 && -n "$WORK" ]]; then
      log "work dir: $WORK"
    elif [[ -n "$WORK" ]]; then
      safe_remove_work "$WORK" || true
    fi
    return 0
  fi
  log "stopping Server pid ${SERVER_PID:-?} and Host pid ${HOST_PID:-?}"
  if ! stop_processes; then
    die "could not stop the stack cleanly; state kept at $STATE_FILE"
  fi
  write_state stopped
  log "no listener left on port ${PORT:-?}"
  if [[ "$KEEP" == 1 ]]; then
    log "kept work dir: $WORK"
  else
    safe_remove_work "$WORK" || die "could not remove the work dir: $WORK"
    log "removed work dir: $WORK"
  fi
  log "stopped"
}

redact_log() { # file: keep evidence free of local UI / bearer tokens
  sed -E 's/([?&]token=)[A-Za-z0-9._~-]+/\1<redacted>/g; s/(Bearer )[A-Za-z0-9._~-]+/\1<redacted>/g' "$1"
}

self_test() {
  PRINT_ENV=0
  start_stack
  STARTUP_ACTIVE=0
  SELF_TEST_ACTIVE=1
  trap self_test_cleanup EXIT

  log "self-test: GET $SERVER_URL/health"
  local health
  health="$(curl -fsS --max-time 5 "$SERVER_URL/health")" || die "self-test: /health request failed"
  [[ "$health" == *'"status":"ok"'* ]] || die "self-test: unexpected /health body"
  printf '%s\n' "$health" >"$EVIDENCE_DIR/self-test-health.txt"

  log "self-test: password login"
  local login_body="$WORK/login.json" auth_file="$WORK/auth-header"
  local login_json token devices_file
  printf '{"email":"%s","password":"%s"}' "$ACCOUNT" "$PASSWORD" >"$login_body"
  login_json="$(curl -fsS --max-time 5 -H 'content-type: application/json' --data-binary "@$login_body" "$SERVER_URL/api/v1/auth/login")" \
    || die "self-test: password login failed"
  token="$(printf '%s' "$login_json" | "$NODE_BIN" -e 'let s=""; process.stdin.on("data", d => s += d).on("end", () => { const t = JSON.parse(s).token; if (!t) process.exit(2); process.stdout.write(t); });')" \
    || die "self-test: login response had no token"
  [[ -n "$token" ]] || die "self-test: empty login token"
  rm -f "$login_body"

  log "self-test: GET /api/v1/account/devices (Host online)"
  devices_file="$WORK/account-devices.json"
  printf 'authorization: Bearer %s\n' "$token" >"$auth_file"
  curl -fsS --max-time 5 -H "@$auth_file" "$SERVER_URL/api/v1/account/devices" >"$devices_file" \
    || die "self-test: /api/v1/account/devices failed"
  rm -f "$auth_file"
  local host_id
  host_id="$("$NODE_BIN" -e '
    const fs = require("fs");
    const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const hosts = (j.items || []).filter(d => d && d.role === "host");
    const online = hosts.filter(d => d.online === true);
    if (!Array.isArray(j.items)) { console.error("missing items"); process.exit(2); }
    if (!hosts.length) { console.error("no host registered"); process.exit(3); }
    if (!online.length) { console.error("host registered but not online"); process.exit(4); }
    const summary = {
      serverUrl: j.serverUrl,
      transport: j.transport,
      hosts: hosts.map(h => ({
        deviceId: h.deviceId,
        name: h.name,
        role: h.role,
        online: h.online,
        platform: h.platform,
        harnessVersion: h.harnessVersion || null,
        lastSeenAt: h.lastSeenAt,
      })),
    };
    fs.writeFileSync(process.argv[2], JSON.stringify(summary, null, 2) + "\n");
    process.stdout.write(online[0].deviceId);
  ' "$devices_file" "$EVIDENCE_DIR/self-test-host.json")" || die "self-test: no online Host through the Server REST API"
  chmod 600 "$EVIDENCE_DIR/self-test-host.json" 2>/dev/null || true

  redact_log "$SERVER_LOG" >"$EVIDENCE_DIR/self-test-server.log"
  redact_log "$HOST_LOG" >"$EVIDENCE_DIR/self-test-host.log"
  chmod 600 "$EVIDENCE_DIR/self-test-server.log" "$EVIDENCE_DIR/self-test-host.log" 2>/dev/null || true

  log "self-test: stopping the stack and checking for leftovers"
  SELF_TEST_ACTIVE=0
  trap - EXIT
  if ! stop_stack_internal; then
    log "SELF-TEST FAIL: cleanup left a process or listener"
    exit 1
  fi
  printf 'SELF-TEST PASS hostId=%s online=true leftoverListener=false\n' "$host_id"
}

stop_stack_internal() {
  if ! stop_processes; then
    write_state stopped || true
    return 1
  fi
  write_state stopped
  if [[ "$KEEP" == 1 ]]; then
    log "kept work dir: $WORK"
  else
    safe_remove_work "$WORK" || return 1
  fi
  return 0
}

case "$MODE" in
  start)
    start_stack
    ;;
  stop)
    stop_stack
    ;;
  self-test)
    self_test
    ;;
  *)
    usage_hint
    exit 2
    ;;
esac
