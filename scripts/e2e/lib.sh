#!/usr/bin/env bash
# Shared helpers for the Phase 1 real-acceptance E2E scripts (T25).
#
# Source this file from a script that already set `set -euo pipefail`:
#
#   . "$(dirname "$0")/lib.sh"
#
# It locates the repo/worktree, resolves the SDK tools (flutter, simulators),
# provides a process-safe simulator lock, temp dirs that clean up via trap,
# port waits, credential loading that never echoes the key, and evidence JSON
# writing. Every failure path exits non-zero; there is no "skip" escape hatch.
#
# Test it with:  bash scripts/e2e/lib.sh --self-test
#
# Bash 3.2 compatible (macOS /bin/bash).

# lib.sh intentionally does not change the caller's shell options.

E2E_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DSH_E2E_ROOT="${DSH_E2E_ROOT:-$(cd "$E2E_LIB_DIR/../.." && pwd)}"
export DSH_E2E_ROOT
E2E_SIM_LOCK_DEFAULT="/tmp/dsh-phase1-sim.lock"
E2E_SIM_LOCK="${DSH_PHASE1_SIM_LOCK:-$E2E_SIM_LOCK_DEFAULT}"
E2E_TEMP_DIRS=()
E2E_CLEANED=0
E2E_SIM_LOCK_HELD=0

# --------------------------------------------------------------------------- logging

e2e_log() {
  printf '[e2e] %s\n' "$*" >&2
}

# Fatal error: always a non-zero exit (never a silent skip).
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# A required precondition is missing. The acceptance rules forbid treating
# that as a skip, so the wording is explicit and the exit is non-zero.
skip_not_allowed() {
  printf 'FAIL (skip not allowed): %s\n' "$*" >&2
  printf 'This E2E check must pass with real dependencies; fix the environment and rerun.\n' >&2
  exit 1
}

require_cmd() {
  local cmd="$1" hint="${2:-}"
  command -v "$cmd" >/dev/null 2>&1 || fail "missing required command: $cmd${hint:+ ($hint)}"
}

require_env() {
  local name="$1"
  [ -n "${!name:-}" ] || fail "required environment variable is empty: $name"
}

require_darwin() {
  [ "$(uname -s)" = "Darwin" ] || fail "this E2E check needs macOS with Xcode ($(uname -s) found)"
}

repo_commit() {
  git -C "$DSH_E2E_ROOT" rev-parse --short HEAD 2>/dev/null || printf 'unknown'
}

# --------------------------------------------------------------------------- toolchain

# Prints the flutter executable: $DSH_FLUTTER_BIN, then PATH, then the
# maintainer toolchain location. Fails instead of silently continuing.
resolve_flutter() {
  if [ -n "${DSH_FLUTTER_BIN:-}" ]; then
    [ -x "$DSH_FLUTTER_BIN" ] || fail "DSH_FLUTTER_BIN is not executable: $DSH_FLUTTER_BIN"
    printf '%s\n' "$DSH_FLUTTER_BIN"
    return 0
  fi
  if command -v flutter >/dev/null 2>&1; then
    command -v flutter
    return 0
  fi
  if [ -x "${HOME:-/nonexistent}/tools/flutter/bin/flutter" ]; then
    printf '%s\n' "${HOME}/tools/flutter/bin/flutter"
    return 0
  fi
  fail "flutter not found (add it to PATH or install it under \$HOME/tools/flutter)"
}

# Prints the UDID of an available iOS simulator with this exact name.
# Prefers a booted device when several share the name. DSH_SIM_UDID overrides.
resolve_sim_udid() {
  local name="${1:?simulator name required}"
  if [ -n "${DSH_SIM_UDID:-}" ]; then
    printf '%s\n' "$DSH_SIM_UDID"
    return 0
  fi
  require_cmd xcrun "Xcode command line tools"
  local udid
  udid="$(xcrun simctl list devices available -j 2>/dev/null | python3 -c '
import json, sys
name = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
matches = []
for runtime, rows in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for row in rows:
        if row.get("name") == name and row.get("isAvailable", True):
            matches.append(row)
if not matches:
    sys.exit(1)
booted = [r for r in matches if r.get("state") == "Booted"]
print((booted or matches)[0].get("udid", ""))
' "$name")" || fail "no available iOS simulator named '$name'"
  [ -n "$udid" ] || fail "no available iOS simulator named '$name'"
  printf '%s\n' "$udid"
}

# Boots the simulator when needed (no-op when already booted).
boot_sim() {
  local udid="${1:?udid required}"
  require_cmd xcrun "Xcode command line tools"
  if [ "$(sim_state "$udid")" = "Booted" ]; then
    return 0
  fi
  xcrun simctl boot "$udid" >/dev/null 2>&1 || {
    [ "$(sim_state "$udid")" = "Booted" ] || fail "cannot boot simulator $udid"
  }
  wait_sim_booted "$udid" 180
}

sim_state() {
  local udid="${1:?udid required}"
  xcrun simctl list devices -j 2>/dev/null | python3 -c '
import json, sys
udid = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for rows in data.get("devices", {}).values():
    for row in rows:
        if row.get("udid") == udid:
            print(row.get("state", "Unknown"))
            raise SystemExit(0)
raise SystemExit(1)
' "$udid"
}

wait_sim_booted() {
  local udid="${1:?udid required}" timeout="${2:-180}" deadline state
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    state="$(sim_state "$udid" || true)"
    [ "$state" = "Booted" ] && return 0
    [ "$(date +%s)" -lt "$deadline" ] || fail "simulator $udid did not boot within ${timeout}s (state: ${state:-unknown})"
    sleep 2
  done
}

# --------------------------------------------------------------------------- simulator lock

# Serializes simulator use across concurrent acceptance jobs. mkdir is atomic;
# no flock on macOS. Waits up to $1 seconds (default 900), then fails.
acquire_sim_lock() {
  local timeout="${1:-900}" deadline pid started
  [ "$E2E_SIM_LOCK_HELD" = 1 ] && return 0
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    if mkdir "$E2E_SIM_LOCK" 2>/dev/null; then
      printf '%s\n' "$$" > "$E2E_SIM_LOCK/pid" 2>/dev/null || true
      E2E_SIM_LOCK_HELD=1
      e2e_log "simulator lock acquired: $E2E_SIM_LOCK (pid $$)"
      return 0
    fi
    pid="$(cat "$E2E_SIM_LOCK/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      # Holder is gone. Drop the lock only when it is clearly stale, so a
      # racing process cannot steal it mid-acquire.
      started="$(stat -f %m "$E2E_SIM_LOCK" 2>/dev/null || stat -c %Y "$E2E_SIM_LOCK" 2>/dev/null || echo 0)"
      if [ "$started" -gt 0 ] && [ $(( $(date +%s) - started )) -gt 120 ]; then
        e2e_log "removing stale simulator lock (pid $pid is gone)"
        rm -rf "$E2E_SIM_LOCK"
        continue
      fi
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      fail "timed out waiting for simulator lock $E2E_SIM_LOCK (held by pid ${pid:-unknown})"
    fi
    e2e_log "waiting for simulator lock (held by pid ${pid:-unknown})"
    sleep 1
  done
}

release_sim_lock() {
  [ "$E2E_SIM_LOCK_HELD" = 1 ] || return 0
  E2E_SIM_LOCK_HELD=0
  rm -rf "$E2E_SIM_LOCK"
  e2e_log "simulator lock released"
}

# --------------------------------------------------------------------------- temp dirs / cleanup

# Registers a directory so `e2e_cleanup` (call it from an EXIT trap) removes it.
# Set DSH_E2E_KEEP=1 to keep temp dirs for debugging.
e2e_track_temp() {
  local dir="${1:?temp dir required}"
  E2E_TEMP_DIRS[${#E2E_TEMP_DIRS[@]}]="$dir"
}

# Creates a temp dir and prints it. The caller must register it itself, since
# command substitution runs in a subshell:
#   WORK="$(mktemp -d "${TMPDIR:-/tmp}/dsh-e2e-x.XXXXXX")"; e2e_track_temp "$WORK"
make_temp_dir() {
  local prefix="${1:?prefix required}" dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX")" || fail "cannot create a temp dir for $prefix"
  printf '%s\n' "$dir"
}

# Idempotent: call from a single EXIT trap. Scripts with their own resources
# should define `cleanup() { ...; e2e_cleanup; }` and trap that.
e2e_cleanup() {
  [ "$E2E_CLEANED" = 1 ] && return 0
  E2E_CLEANED=1
  local dir
  if [ "${#E2E_TEMP_DIRS[@]}" -gt 0 ]; then
    for dir in "${E2E_TEMP_DIRS[@]}"; do
      [ -n "$dir" ] || continue
      if [ "${DSH_E2E_KEEP:-0}" = 1 ]; then
        e2e_log "kept temp dir: $dir"
      else
        rm -rf -- "$dir"
      fi
    done
  fi
  release_sim_lock
}

# --------------------------------------------------------------------------- network

# Fails unless host:port accepts a TCP connection within the timeout.
wait_port() {
  local host="${1:?host required}" port="${2:?port required}" timeout="${3:-30}"
  if ! python3 - "$host" "$port" "$timeout" <<'PY'
import socket, sys, time
host, port, timeout = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
deadline = time.time() + timeout
while time.time() < deadline:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(0.5)
    try:
        s.connect((host, port))
        s.close()
        sys.exit(0)
    except OSError:
        s.close()
        time.sleep(0.15)
sys.exit(1)
PY
  then
    fail "nothing is listening on $host:$port after ${timeout}s"
  fi
}

# Prints an unused loopback port (bind + close; small race window is fine for
# starting a listener immediately afterwards).
e2e_free_port() {
  python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

# --------------------------------------------------------------------------- credentials

# Prints the opencode-go key from OPENCODE_GO_API_KEY or the credentials YAML
# (`refs.OPENCODE_GO_API_KEY`). Never logs the value; callers must capture it:
#   KEY="$(read_credentials_key)" || exit 1
# and must not pass it on a command line that shows up in `ps`.
read_credentials_key() {
  local file="${1:-${CREDENTIALS_FILE:-${HOME:-/nonexistent}/.dsh/.credentials.yaml}}"
  if [ -n "${OPENCODE_GO_API_KEY:-}" ]; then
    printf '%s\n' "$OPENCODE_GO_API_KEY"
    return 0
  fi
  [ -r "$file" ] || fail "no OPENCODE_GO_API_KEY in the environment and the credentials file is unreadable: $file"
  local key
  key="$(python3 - "$file" <<'PY'
import sys

def scalar(raw):
    value = raw.strip()
    if value.startswith('"'):
        out, i = [], 1
        while i < len(value):
            ch = value[i]
            if ch == '\\' and i + 1 < len(value):
                i += 1
                out.append({'n': '\n', 't': '\t'}.get(value[i], value[i]))
            elif ch == '"':
                return ''.join(out)
            else:
                out.append(ch)
            i += 1
        return ''.join(out)
    if value.startswith("'"):
        out, i = [], 1
        while i < len(value):
            if value[i] == "'" and i + 1 < len(value) and value[i + 1] == "'":
                out.append("'")
                i += 2
                continue
            if value[i] == "'":
                return ''.join(out)
            out.append(value[i])
            i += 1
        return ''.join(out)
    comment = value.find(' #')
    if comment >= 0:
        value = value[:comment]
    return value.strip()

path = sys.argv[1]
refs_indent = -1
try:
    lines = open(path, encoding='utf-8').read().splitlines()
except OSError:
    sys.exit(2)
for line in lines:
    if not line.strip() or line.lstrip().startswith('#'):
        continue
    indent = len(line) - len(line.lstrip())
    if refs_indent < 0:
        if indent == 0 and line.strip().rstrip() == 'refs:':
            refs_indent = 0
        continue
    if indent == 0:
        break
    stripped = line.strip()
    if stripped.startswith('OPENCODE_GO_API_KEY:'):
        key = scalar(stripped.split(':', 1)[1])
        if key:
            print(key)
            sys.exit(0)
sys.exit(1)
PY
  )" || fail "could not read refs.OPENCODE_GO_API_KEY from $file (the file must be readable and contain that ref)"
  [ -n "$key" ] || fail "could not read refs.OPENCODE_GO_API_KEY from $file"
  printf '%s\n' "$key"
}

# --------------------------------------------------------------------------- evidence

# Writes key=value pairs to a JSON evidence file (mode 600). Values for keys
# that look secret (key/token/secret/password/authorization) are redacted so a
# dropped evidence file cannot leak a credential. Creates parent directories.
env_json_write() {
  local file="${1:?output path required}"
  shift
  python3 - "$file" "$@" <<'PY'
import json, os, re, sys, time

path, pairs = sys.argv[1], sys.argv[2:]
data = {"generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
secretish = re.compile(r"key|token|secret|password|authorization", re.I)
for pair in pairs:
    if "=" not in pair:
        raise SystemExit("env_json_write expects key=value, got: " + pair)
    name, value = pair.split("=", 1)
    data[name] = "<redacted>" if secretish.search(name) and value else value
parent = os.path.dirname(os.path.abspath(path))
if parent:
    os.makedirs(parent, exist_ok=True)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2, sort_keys=True)
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY
}

# Fails when a file contains the given secret (defense against accidental logs).
assert_no_secret_in_file() {
  local file="${1:?file required}" secret="${2:-}"
  [ -n "$secret" ] || return 0
  [ -f "$file" ] || return 0
  if python3 - "$file" "$secret" <<'PY'
import sys
needle = sys.argv[2].encode()
with open(sys.argv[1], 'rb') as f:
    sys.exit(0 if needle in f.read() else 1)
PY
  then
    fail "the credential appears in $file"
  fi
}

# Replaces the secret in a file with <redacted> (idempotent).
scrub_secret_from_file() {
  local file="${1:?file required}" secret="${2:-}"
  [ -n "$secret" ] || return 0
  [ -f "$file" ] || return 0
  python3 - "$file" "$secret" <<'PY'
import sys
path, needle = sys.argv[1], sys.argv[2].encode()
with open(path, 'rb') as f:
    data = f.read()
data = data.replace(needle, b'<redacted>')
with open(path, 'wb') as f:
    f.write(data)
PY
}

# --------------------------------------------------------------------------- self-test

e2e_self_test() {
  local pass=0 failn=0
  st_ok() { pass=$((pass + 1)); printf 'PASS self-test: %s\n' "$1"; }
  st_bad() { failn=$((failn + 1)); printf 'FAIL self-test: %s\n' "$1" >&2; }

  # 1. Root/worktree detection.
  if [ -f "$DSH_E2E_ROOT/app/pubspec.yaml" ] && [ -f "$DSH_E2E_ROOT/scripts/e2e/lib.sh" ]; then
    st_ok "repo root detected: $DSH_E2E_ROOT"
  else
    st_bad "repo root detection ($DSH_E2E_ROOT)"
  fi
  if [ "$E2E_SIM_LOCK_DEFAULT" = "/tmp/dsh-phase1-sim.lock" ]; then
    st_ok "default simulator lock is /tmp/dsh-phase1-sim.lock"
  else
    st_bad "default simulator lock path"
  fi

  # 2. flutter resolution: PATH, then \$HOME/tools/flutter/bin/flutter, then failure.
  local real_flutter
  if real_flutter="$(resolve_flutter 2>/dev/null)"; then
    if [ -x "$real_flutter" ]; then st_ok "resolve_flutter finds an executable: $real_flutter"; else st_bad "resolve_flutter returned a non-executable"; fi
  else
    st_bad "resolve_flutter failed on this machine (PATH or \$HOME/tools/flutter)"
  fi
  local fakehome
  fakehome="$(mktemp -d "${TMPDIR:-/tmp}/dsh-e2e-fakehome.XXXXXX")"
  mkdir -p "$fakehome/tools/flutter/bin"
  printf '#!/bin/sh\necho flutter-stub\n' > "$fakehome/tools/flutter/bin/flutter"
  chmod +x "$fakehome/tools/flutter/bin/flutter"
  local got
  got="$(env -u DSH_FLUTTER_BIN PATH=/usr/bin:/bin HOME="$fakehome" bash -c '. "$1"; resolve_flutter' _ "$DSH_E2E_ROOT/scripts/e2e/lib.sh" 2>/dev/null)" || true
  if [ "$got" = "$fakehome/tools/flutter/bin/flutter" ]; then
    st_ok "resolve_flutter falls back to \$HOME/tools/flutter/bin/flutter"
  else
    st_bad "resolve_flutter fallback (got: ${got:-<empty>})"
  fi
  if ( env -u DSH_FLUTTER_BIN PATH=/usr/bin:/bin HOME="$fakehome/nowhere" bash -c '. "$1"; resolve_flutter' _ "$DSH_E2E_ROOT/scripts/e2e/lib.sh" >/dev/null 2>&1 ); then
    st_bad "resolve_flutter must fail when flutter is absent"
  else
    st_ok "resolve_flutter fails (non-zero) when flutter is absent"
  fi
  rm -rf "$fakehome"

  # 3. Simulator resolution + boot wait (a booted iPhone 17 Pro is enough).
  if command -v xcrun >/dev/null 2>&1; then
    local udid
    if udid="$(resolve_sim_udid "iPhone 17 Pro" 2>/dev/null)" && [[ "$udid" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
      st_ok "resolve_sim_udid returns a UDID for 'iPhone 17 Pro'"
      if wait_sim_booted "$udid" 30 2>/dev/null; then
        st_ok "wait_sim_booted sees a booted simulator"
      else
        st_bad "wait_sim_booted on a booted simulator"
      fi
      if ( resolve_sim_udid "No Such Simulator T25" >/dev/null 2>&1 ); then
        st_bad "resolve_sim_udid must fail for an unknown name"
      else
        st_ok "resolve_sim_udid fails for an unknown name"
      fi
    else
      st_bad "resolve_sim_udid for 'iPhone 17 Pro' (is Xcode installed?)"
    fi
  else
    st_bad "xcrun missing; cannot self-test simulator helpers"
  fi

  # 4. Simulator lock: exclusive, timeout fails, release/acquire works.
  local lockdir="$E2E_SIM_LOCK_DEFAULT-$$"
  local oldlock="$E2E_SIM_LOCK"
  export DSH_PHASE1_SIM_LOCK="$lockdir"
  E2E_SIM_LOCK="$lockdir"
  if acquire_sim_lock 5 2>/dev/null; then
    st_ok "acquire_sim_lock takes the lock"
    # A second *process* must not get the lock; same-process reentry is allowed.
    if ( bash -c '. "$1"; acquire_sim_lock 1' _ "$DSH_E2E_ROOT/scripts/e2e/lib.sh" >/dev/null 2>&1 ); then
      st_bad "a second process must time out on the lock (exclusivity broken)"
    else
      st_ok "a second process times out on the lock (exclusive)"
    fi
    release_sim_lock
    if [ ! -d "$lockdir" ]; then st_ok "release_sim_lock removes the lock dir"; else st_bad "release_sim_lock left the lock dir"; fi
    if acquire_sim_lock 1 2>/dev/null; then st_ok "lock can be re-acquired after release"; release_sim_lock; else st_bad "lock cannot be re-acquired after release"; fi
  else
    st_bad "acquire_sim_lock failed on a free lock"
  fi
  if [ -n "$oldlock" ]; then
    DSH_PHASE1_SIM_LOCK="$oldlock"
    E2E_SIM_LOCK="$oldlock"
  else
    unset DSH_PHASE1_SIM_LOCK || true
    E2E_SIM_LOCK="$E2E_SIM_LOCK_DEFAULT"
  fi
  rm -rf "$lockdir"

  # 5. Temp dir tracking + cleanup (and DSH_E2E_KEEP).
  local tdir
  tdir="$(mktemp -d "${TMPDIR:-/tmp}/dsh-e2e-track.XXXXXX")"
  e2e_track_temp "$tdir"
  e2e_cleanup
  if [ ! -d "$tdir" ]; then st_ok "e2e_cleanup removes tracked temp dirs"; else st_bad "e2e_cleanup left a tracked temp dir"; fi
  E2E_CLEANED=0
  E2E_TEMP_DIRS=()
  local kept
  kept="$(mktemp -d "${TMPDIR:-/tmp}/dsh-e2e-keep.XXXXXX")"
  if ( E2E_CLEANED=0; E2E_TEMP_DIRS=(); e2e_track_temp "$kept"; DSH_E2E_KEEP=1; e2e_cleanup >/dev/null 2>&1; [ -d "$kept" ] ); then
    st_ok "DSH_E2E_KEEP=1 keeps temp dirs"
  else
    st_bad "DSH_E2E_KEEP=1 did not keep the temp dir"
  fi
  rm -rf "$kept"
  E2E_CLEANED=0
  E2E_TEMP_DIRS=()

  # 6. wait_port: open port passes, closed port fails non-zero.
  local port closed
  port="$(e2e_free_port)"
  python3 - "$port" <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(5)
time.sleep(25)
PY
  local listener=$!
  if wait_port 127.0.0.1 "$port" 10 2>/dev/null; then
    st_ok "wait_port sees an open listener"
  else
    st_bad "wait_port missed an open listener"
  fi
  kill "$listener" 2>/dev/null || true
  wait "$listener" 2>/dev/null || true
  closed="$(e2e_free_port)"
  if ( wait_port 127.0.0.1 "$closed" 1 >/dev/null 2>&1 ); then
    st_bad "wait_port must fail on a closed port"
  else
    st_ok "wait_port fails (non-zero) on a closed port"
  fi

  # 7. Credential reading: env wins, YAML parses, missing file fails, key never on stderr.
  local ckey="sk-t25-lib-selftest-000000000000"
  local gotkey errfile
  errfile="$(mktemp "${TMPDIR:-/tmp}/dsh-e2e-stderr.XXXXXX")"
  if gotkey="$(OPENCODE_GO_API_KEY="$ckey" read_credentials_key 2>"$errfile")" && [ "$gotkey" = "$ckey" ] && [ ! -s "$errfile" ]; then
    st_ok "read_credentials_key prefers OPENCODE_GO_API_KEY and is quiet"
  else
    st_bad "read_credentials_key env path"
  fi
  local creds
  creds="$(mktemp "${TMPDIR:-/tmp}/dsh-e2e-creds.XXXXXX")"
  printf 'version: 1\nrefs:\n  OPENCODE_GO_API_KEY: "%s"\n' "$ckey" > "$creds"
  if gotkey="$(env -u OPENCODE_GO_API_KEY bash -c '. "$1"; read_credentials_key "$2"' _ "$DSH_E2E_ROOT/scripts/e2e/lib.sh" "$creds" 2>/dev/null)" && [ "$gotkey" = "$ckey" ]; then
    st_ok "read_credentials_key parses refs.OPENCODE_GO_API_KEY from YAML"
  else
    st_bad "read_credentials_key YAML path"
  fi
  if ( env -u OPENCODE_GO_API_KEY bash -c '. "$1"; read_credentials_key "$2"' _ "$DSH_E2E_ROOT/scripts/e2e/lib.sh" "$creds.missing" >/dev/null 2>"$errfile" ); then
    st_bad "read_credentials_key must fail for a missing file"
  else
    st_ok "read_credentials_key fails (non-zero) for a missing file"
  fi
  if grep -Fq -- "$ckey" "$errfile" 2>/dev/null; then st_bad "read_credentials_key leaked the key on stderr"; else st_ok "read_credentials_key never writes the key to stderr"; fi
  rm -f "$creds" "$errfile"

  # 8. env_json_write: valid JSON, 600, redacts secret-looking fields.
  local evaldir evidence
  evaldir="$(mktemp -d "${TMPDIR:-/tmp}/dsh-e2e-evidence.XXXXXX")"
  evidence="$evaldir/nested dir/env.json"
  if env_json_write "$evidence" plain=ok api_key=sk-should-be-redacted token=abc 2>/dev/null; then
    if python3 - "$evidence" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["plain"] == "ok", data
assert data["api_key"] == "<redacted>", data
assert data["token"] == "<redacted>", data
PY
    then
      st_ok "env_json_write writes valid JSON and redacts secrets"
    else
      st_bad "env_json_write JSON/redaction"
    fi
    if [ "$(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$evidence")" = "0o600" ]; then
      st_ok "env_json_write stores evidence as mode 600"
    else
      st_bad "env_json_write file mode"
    fi
  else
    st_bad "env_json_write failed"
  fi
  if printf 'secret=%s\n' "$ckey" > "$evaldir/log.txt" && ( assert_no_secret_in_file "$evaldir/log.txt" "$ckey" >/dev/null 2>&1 ); then
    st_bad "assert_no_secret_in_file missed the secret"
  else
    st_ok "assert_no_secret_in_file rejects a leaked secret"
  fi
  scrub_secret_from_file "$evaldir/log.txt" "$ckey"
  if ! grep -Fq -- "$ckey" "$evaldir/log.txt"; then st_ok "scrub_secret_from_file removes the secret"; else st_bad "scrub_secret_from_file left the secret"; fi
  rm -rf "$evaldir"

  # 9. failure semantics: both are non-zero and never look like a pass.
  local out rc
  if out="$( ( fail "selftest expected failure" ) 2>&1 )"; then rc=0; else rc=$?; fi
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '^FAIL:'; then st_ok "fail() exits non-zero with a FAIL line"; else st_bad "fail() semantics"; fi
  if out="$( ( skip_not_allowed "selftest expected skip refusal" ) 2>&1 )"; then rc=0; else rc=$?; fi
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'skip not allowed'; then st_ok "skip_not_allowed() refuses to skip"; else st_bad "skip_not_allowed() semantics"; fi

  printf '\nself-test: %d passed, %d failed\n' "$pass" "$failn"
  [ "$failn" -eq 0 ]
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --self-test)
      set -euo pipefail
      e2e_self_test
      ;;
    *)
      printf 'usage: bash scripts/e2e/lib.sh --self-test (source it from E2E scripts)\n' >&2
      exit 2
      ;;
  esac
fi
