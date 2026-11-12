#!/usr/bin/env bash
# Temporary, unprivileged sshd for Phase 1 real-SSH acceptance (T25).
#
# Creates a throwaway sshd in a temp dir (own host key, client key,
# authorized_keys, config) and listens on 127.0.0.1 only. Nothing in ~/.ssh or
# the system sshd configuration is read or modified. The account is the current
# desktop user; there is no root login and no password auth.
#
# Usage:
#   scripts/e2e/ssh/sshd_control.sh start [--env]    # prints SSHD {...} (+ SSHD_ENV)
#   scripts/e2e/ssh/sshd_control.sh stop <workdir>   # idempotent
#   scripts/e2e/ssh/sshd_control.sh status <workdir>
#   scripts/e2e/ssh/sshd_control.sh --self-test      # start -> ssh -> stop proof
#
# Env:
#   DSH_E2E_SSHD_PORT   preferred port (default 22422; falls back to a free one)
#   DSH_E2E_SSH_USER    login name (default $USER; root is refused)
#   DSH_E2E_SSHD_BIN    default /usr/sbin/sshd
#   DSH_E2E_KEEP=1      keep the temp dir on stop (default removes it)
#
# Every failure exits non-zero. No skips.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$SCRIPT_DIR/../lib.sh"

START_WORK=""
START_FAILED=1
SSHD_BIN="${DSH_E2E_SSHD_BIN:-/usr/sbin/sshd}"
SSH_BIN="${DSH_E2E_SSH_BIN:-/usr/bin/ssh}"
SSH_KEYGEN="${DSH_E2E_SSH_KEYGEN:-/usr/bin/ssh-keygen}"

json_quote() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

port_open() {
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

port_free() {
  python3 - "$1" <<'PY'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
    s.close()
    sys.exit(0)
except OSError:
    s.close()
    sys.exit(1)
PY
}

wait_port_closed() {
  local port="$1" timeout="${2:-10}" deadline
  deadline=$(( $(date +%s) + timeout ))
  while port_open "$port"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.2
  done
  return 0
}

write_config() {
  local work="$1" port="$2"
  cat >"$work/sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $work/host_ed25519
PidFile $work/sshd.pid
AuthorizedKeysFile $work/authorized_keys
UsePAM no
StrictModes no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin no
AllowTcpForwarding yes
X11Forwarding no
AllowAgentForwarding no
LogLevel ERROR
EOF
  if [ -n "$SSHD_SETENV_LINES" ]; then
    printf '%s\n' "$SSHD_SETENV_LINES" >>"$work/sshd_config"
  fi
  chmod 600 "$work/sshd_config"
}

# Validates DSH_E2E_SSHD_SETENV and turns it into SetEnv config lines. The
# value may not contain whitespace or shell metacharacters of its own: each
# entry arrives as one whitespace-separated NAME=value token.
build_setenv_lines() {
  SSHD_SETENV_LINES=""
  local kv name value
  for kv in ${DSH_E2E_SSHD_SETENV:-}; do
    case "$kv" in
      *=*) ;;
      *) fail "DSH_E2E_SSHD_SETENV expects NAME=value, got: $kv" ;;
    esac
    name="${kv%%=*}"
    value="${kv#*=}"
    case "$name" in
      [A-Za-z_]*) ;;
      *) fail "invalid DSH_E2E_SSHD_SETENV name: $name" ;;
    esac
    case "$name" in
      *[!A-Za-z0-9_]*) fail "invalid DSH_E2E_SSHD_SETENV name: $name" ;;
    esac
    case "$value" in
      *[[:space:]]*) fail "DSH_E2E_SSHD_SETENV value may not contain whitespace: $kv" ;;
    esac
    if [ -n "$SSHD_SETENV_LINES" ]; then
      SSHD_SETENV_LINES="$SSHD_SETENV_LINES
SetEnv $kv"
    else
      SSHD_SETENV_LINES="SetEnv $kv"
    fi
  done
}

# Starts sshd and prints one machine-readable SSHD {...} line on stdout.
start_sshd() {
  local want_json="${1:-}"
  [ -x "$SSHD_BIN" ] || fail "sshd not found or not executable: $SSHD_BIN"
  [ -x "$SSH_BIN" ] || fail "ssh not found: $SSH_BIN"
  [ -x "$SSH_KEYGEN" ] || fail "ssh-keygen not found: $SSH_KEYGEN"

  local ssh_user="${DSH_E2E_SSH_USER:-${USER:-$(id -un)}}"
  [ "$ssh_user" != "root" ] || fail "refusing to test SSH as root (PermitRootLogin no)"

  build_setenv_lines

  local work
  work="$(mktemp -d "${TMPDIR:-/tmp}/dsh-e2e-sshd.XXXXXX")" || fail "cannot create the sshd temp dir"
  chmod 700 "$work"
  START_WORK="$work"
  START_FAILED=1

  "$SSH_KEYGEN" -q -t ed25519 -N '' -C dsh-e2e-host -f "$work/host_ed25519" || fail "cannot create the host key"
  "$SSH_KEYGEN" -q -t ed25519 -N '' -C dsh-e2e-client -f "$work/client_ed25519" || fail "cannot create the client key"
  cp "$work/client_ed25519.pub" "$work/authorized_keys"
  chmod 600 "$work/authorized_keys" "$work/client_ed25519" "$work/host_ed25519"

  local port="${DSH_E2E_SSHD_PORT:-22422}"
  if ! port_free "$port"; then
    port="$(e2e_free_port)"
    e2e_log "port ${DSH_E2E_SSHD_PORT:-22422} is busy; using free port $port"
  fi
  write_config "$work" "$port"

  nohup "$SSHD_BIN" -D -e -f "$work/sshd_config" >>"$work/sshd.log" 2>&1 &
  local launcher_pid=$!
  printf '%s\n' "$launcher_pid" >"$work/launcher.pid"

  if ! wait_port 127.0.0.1 "$port" 20; then
    tail -30 "$work/sshd.log" >&2 || true
    stop_sshd "$work" >/dev/null 2>&1 || true
    fail "sshd did not listen on 127.0.0.1:$port"
  fi

  # Prove the real SSH path before handing the details to the test runner.
  local ssh_out ssh_err
  ssh_err="$work/ssh.err"
  if ! ssh_out="$("$SSH_BIN" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o IdentitiesOnly=yes -o ConnectTimeout=10 -o LogLevel=ERROR \
    -i "$work/client_ed25519" -p "$port" "${ssh_user}@127.0.0.1" 'echo SSH_OK' 2>"$ssh_err")"; then
    cat "$ssh_err" >&2 || true
    tail -30 "$work/sshd.log" >&2 || true
    stop_sshd "$work" || true
    fail "ssh could not log in to the temporary sshd on port $port"
  fi
  if [ "$ssh_out" != "SSH_OK" ]; then
    stop_sshd "$work" || true
    fail "ssh login returned '$ssh_out' instead of SSH_OK"
  fi

  local fingerprint
  fingerprint="$("$SSH_KEYGEN" -lf "$work/host_ed25519.pub" | awk '{print $2}')"
  if [ -z "$fingerprint" ]; then
    stop_sshd "$work" >/dev/null 2>&1 || true
    fail "could not read the host key fingerprint"
  fi

  cat >"$work/state.json" <<EOF
{"port":$port,"user":$(json_quote "$ssh_user"),"client_key":$(json_quote "$work/client_ed25519"),"host_pub":$(json_quote "$work/host_ed25519.pub"),"fingerprint":$(json_quote "$fingerprint"),"work":$(json_quote "$work"),"pid":$launcher_pid,"ssh_log":$(json_quote "$work/sshd.log")}
EOF
  chmod 600 "$work/state.json"
  cat >"$work/env.sh" <<EOF
SSHD_PORT=$port
SSHD_USER=$(json_quote "$ssh_user")
SSHD_KEY=$(json_quote "$work/client_ed25519")
SSHD_HOST_PUB=$(json_quote "$work/host_ed25519.pub")
SSHD_FINGERPRINT=$(json_quote "$fingerprint")
SSHD_WORK=$(json_quote "$work")
SSHD_PID=$launcher_pid
EOF
  chmod 600 "$work/env.sh"
  START_FAILED=0
  printf 'SSHD %s\n' "$(cat "$work/state.json")"
  if [ "$want_json" = "--env" ]; then
    printf 'SSHD_ENV %s\n' "$work/env.sh"
  fi
}

# Stops sshd for a work dir; idempotent. Fails if the process/listener survives.
stop_sshd() {
  local work="${1:?sshd work dir required}"
  [ -d "$work" ] || return 0
  local pid="" port=""
  [ -f "$work/launcher.pid" ] && pid="$(cat "$work/launcher.pid" 2>/dev/null || true)"
  [ -f "$work/sshd.pid" ] && pid="${pid:-$(cat "$work/sshd.pid" 2>/dev/null || true)}"
  [ -f "$work/state.json" ] && port="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("port",""))' "$work/state.json" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    local i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
      sleep 0.2
    fi
  fi
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    fail "sshd process $pid survived SIGTERM/SIGKILL"
  fi
  if [ -n "$port" ] && ! wait_port_closed "$port" 10; then
    fail "sshd listener on 127.0.0.1:$port survived shutdown"
  fi
  if [ "${DSH_E2E_KEEP:-0}" = 1 ]; then
    e2e_log "kept sshd work dir: $work"
  else
    rm -rf -- "$work"
  fi
  return 0
}

status_sshd() {
  local work="${1:?sshd work dir required}"
  [ -f "$work/state.json" ] || fail "no sshd state under $work"
  local pid port
  pid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pid",""))' "$work/state.json")"
  port="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("port",""))' "$work/state.json")"
  kill -0 "$pid" 2>/dev/null || fail "sshd pid $pid is not running"
  port_open "$port" || fail "sshd is not listening on 127.0.0.1:$port"
  cat "$work/state.json"
}

# --------------------------------------------------------------------------- self-test

sshd_self_test() {
  local pass=0 failn=0
  st_ok() { pass=$((pass + 1)); printf 'PASS self-test: %s\n' "$1"; }
  st_bad() { failn=$((failn + 1)); printf 'FAIL self-test: %s\n' "$1" >&2; }

  require_darwin

  # Snapshot ~/.ssh so we can prove the harness does not touch it.
  local ssh_dir="${HOME}/.ssh"
  local before after
  before="$(python3 - "$ssh_dir" <<'PY'
import hashlib, os, sys
path = sys.argv[1]
if not os.path.isdir(path):
    print("absent")
    raise SystemExit(0)
h = hashlib.sha256()
for name in sorted(os.listdir(path)):
    full = os.path.join(path, name)
    st = os.lstat(full)
    h.update(f"{name}:{st.st_mode}:{st.st_size}:{st.st_mtime_ns}".encode())
print(h.hexdigest())
PY
)"

  local json work port user key host_pub fp start_out start_err line
  START_WORK=""
  START_FAILED=1
  start_out="$(mktemp "${TMPDIR:-/tmp}/dsh-e2e-sshd-start.XXXXXX")"
  start_err="$(mktemp "${TMPDIR:-/tmp}/dsh-e2e-sshd-err.XXXXXX")"
  if ! start_sshd >"$start_out" 2>"$start_err"; then
    cat "$start_err" >&2 || true
    rm -f "$start_out" "$start_err"
    printf '\nself-test: 0 passed, 1 failed (sshd start)\n' >&2
    return 1
  fi
  line="$(grep -m 1 '^SSHD ' "$start_out" || true)"
  rm -f "$start_out" "$start_err"
  [ -n "$line" ] || { st_bad "start_sshd did not print SSHD {...}"; printf '\nself-test: %d passed, %d failed\n' "$pass" "$failn"; return 1; }
  START_FAILED=0
  json="${line#SSHD }"
  work="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["work"])')"
  port="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["port"])')"
  user="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["user"])')"
  key="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["client_key"])')"
  host_pub="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["host_pub"])')"
  fp="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["fingerprint"])')"

  cleanup_selftest() {
    ( stop_sshd "$work" ) || true
  }
  trap cleanup_selftest EXIT INT TERM

  [ -d "$work" ] && st_ok "temp sshd work dir exists" || st_bad "temp sshd work dir missing"
  [ -f "$work/authorized_keys" ] && st_ok "independent AuthorizedKeysFile exists" || st_bad "authorized_keys missing"
  case "$work" in /tmp/* | "${TMPDIR:-/tmp}"/*) st_ok "work dir is under the system temp dir";; *) st_bad "work dir is not under temp: $work";; esac
  if grep -Fq "AuthorizedKeysFile $work/authorized_keys" "$work/sshd_config"; then
    st_ok "sshd_config uses the temp AuthorizedKeysFile"
  else
    st_bad "sshd_config does not use the temp AuthorizedKeysFile"
  fi
  [ -f "$host_pub" ] && st_ok "host public key exists" || st_bad "host public key missing"
  [ -f "$key" ] && st_ok "client private key exists" || st_bad "client key missing"
  [ -n "$fp" ] && [[ "$fp" == SHA256:* ]] && st_ok "host key fingerprint: $fp" || st_bad "bad host fingerprint: $fp"
  port_open "$port" && st_ok "sshd listens on 127.0.0.1:$port" || st_bad "sshd is not listening on $port"

  # A real ssh login, then a second one with the pinned host key.
  local out rc
  if out="$("$SSH_BIN" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o IdentitiesOnly=yes -o ConnectTimeout=10 -o LogLevel=ERROR -i "$key" -p "$port" "$user@127.0.0.1" 'echo SSH_OK' 2>/dev/null)"; then
    [ "$out" = "SSH_OK" ] && st_ok "real ssh login prints SSH_OK" || st_bad "ssh printed '$out'"
  else
    st_bad "real ssh login failed"
  fi
  if out="$("$SSH_BIN" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o IdentitiesOnly=yes -o ConnectTimeout=10 -o LogLevel=ERROR \
    -o "HostKeyAlias=dsh-e2e-selftest" -i "$key" -p "$port" "$user@127.0.0.1" 'echo SSH_OK_2' 2>/dev/null)"; then
    [ "$out" = "SSH_OK_2" ] && st_ok "a second ssh login works" || st_bad "second ssh printed '$out'"
  else
    st_bad "second ssh login failed"
  fi

  # Stop and prove nothing is left behind.
  if stop_sshd "$work" 2>/dev/null; then st_ok "stop_sshd exits 0"; else st_bad "stop_sshd failed"; fi
  trap - EXIT INT TERM
  if port_open "$port"; then st_bad "listener on $port survived stop"; else st_ok "no listener survives stop"; fi
  if [ -d "$work" ]; then st_bad "temp work dir survived stop"; else st_ok "temp work dir removed on stop"; fi
  if stop_sshd "$work" 2>/dev/null; then st_ok "stop_sshd is idempotent"; else st_bad "stop_sshd is not idempotent"; fi
  local listeners
  listeners="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
  [ -z "$listeners" ] && st_ok "lsof shows no leftover listener on $port" || st_bad "lsof still shows: $listeners"

  after="$(python3 - "$ssh_dir" <<'PY'
import hashlib, os, sys
path = sys.argv[1]
if not os.path.isdir(path):
    print("absent")
    raise SystemExit(0)
h = hashlib.sha256()
for name in sorted(os.listdir(path)):
    full = os.path.join(path, name)
    st = os.lstat(full)
    h.update(f"{name}:{st.st_mode}:{st.st_size}:{st.st_mtime_ns}".encode())
print(h.hexdigest())
PY
)"
  [ "$before" = "$after" ] && st_ok "~/.ssh was not modified" || st_bad "~/.ssh changed during the self-test"

  printf '\nself-test: %d passed, %d failed\n' "$pass" "$failn"
  [ "$failn" -eq 0 ]
}

# --------------------------------------------------------------------------- entry

case "${1:-}" in
  start | --start)
    cleanup_start() {
      if [ "$START_FAILED" = 1 ] && [ -n "$START_WORK" ]; then
        stop_sshd "$START_WORK" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup_start EXIT
    start_sshd "${2:-}"
    START_FAILED=0
    trap - EXIT
    ;;
  stop | --stop)
    stop_sshd "${2:?usage: $0 stop <workdir>}"
    ;;
  status)
    status_sshd "${2:?usage: $0 status <workdir>}"
    ;;
  --self-test)
    sshd_self_test
    ;;
  *)
    sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
