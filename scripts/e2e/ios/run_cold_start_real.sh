#!/usr/bin/env bash
# T30 process-level cold-start persistence and auto-start acceptance (17 Pro).
#
# The app is driven in phases, each one a separate `flutter test` run of
# app/integration_test/phase1_cold_start_test.dart with a different
# `--dart-define=E2E_PHASE=...`. Between phases this host wrapper terminates the
# app with `xcrun simctl terminate` and proves the process is gone; the next
# phase therefore launches a new process against the same data container. The
# tests themselves never call install/start to fake a restart: every phase ends
# with a PHASE-PASS marker and keeps running until this wrapper kills the app.
#
# Phases:
#   seed          clean install, onboarding, local engine, real provider+model,
#                 one completed real-model turn that writes a workspace file,
#                 an unsent draft (text + one attachment); marks PHASE-PASS seed
#   verify        cold launch: no onboarding, session/message/title, draft text
#                 and attachment restored, auto-start reaches running, a new
#                 real-model turn succeeds; turns auto-start off
#   autostart_off cold launch with the setting off: the engine must stay
#                 installed for the observation window; turns auto-start on
#   crash         deterministic local mock provider starts a slow bash tool
#                 turn; waits until the tool is dispatched, then marks
#                 CRASH-READY-TO-KILL; this wrapper kills the app mid-turn
#   crash_verify  cold launch: unknown-result banner, workspace side effect
#                 still happens exactly once (no re-execution before/after the
#                 user's confirmation)
#
# Evidence (logs, process proofs, screenshots, timings, env JSON) goes to
# reports/phase1-completion/T30 by default.
#
# Usage:
#   scripts/e2e/ios/run_cold_start_real.sh            # real run
#   scripts/e2e/ios/run_cold_start_real.sh --dry-run  # preflight only
#
# Env:
#   DSH_SIM_UDID            simulator UDID (default iPhone 17 Pro used by T30)
#   DSH_E2E_EVIDENCE_DIR    default <repo>/reports/phase1-completion/T30
#   DSH_E2E_PHASE_TIMEOUT   per-phase test timeout in seconds (default 900)
#   OPENCODE_GO_API_KEY     used by the broker when set (never read here)
#
# No push/merge/tag. Exits non-zero on every failure. No skips.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$SCRIPT_DIR/../lib.sh"

ROOT="$DSH_E2E_ROOT"
APP="$ROOT/app"
TEST_REL="integration_test/phase1_cold_start_test.dart"
TEST_FILE="$APP/$TEST_REL"
BUNDLE_ID="io.github.ccch1mneyyy.dshgo"
UDID="${DSH_SIM_UDID:-1D9F8C91-5739-47B2-BDD0-0FC7207166F3}"
# The worktree is under DSH-Go-iOS/.worktrees/completion/<task>; acceptance
# evidence is shared in DSH-Go-iOS/reports, outside the git worktree.
OUTER="$(cd "$ROOT/../../.." 2>/dev/null && pwd || printf '%s' "$ROOT")"
[ -d "$OUTER/reports" ] || OUTER="$ROOT"
EVIDENCE="${DSH_E2E_EVIDENCE_DIR:-$OUTER/reports/phase1-completion/T30}"
FONT_DIR="${DSH_TEST_FONT_DIR:-$OUTER/.fonts}"
PHASE_TIMEOUT="${DSH_E2E_PHASE_TIMEOUT:-900}"
BROKER="$ROOT/test/fixtures/credential_broker.mjs"

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

WORK=""
BROKER_PID=""
FLUTTER_PID=""
PHASE_STARTED=0
cleanup() {
  local rc=$?
  if [ -n "$FLUTTER_PID" ] && kill -0 "$FLUTTER_PID" 2>/dev/null; then
    kill "$FLUTTER_PID" 2>/dev/null || true
    wait "$FLUTTER_PID" 2>/dev/null || true
  fi
  FLUTTER_PID=""
  if [ -n "$BROKER_PID" ] && kill -0 "$BROKER_PID" 2>/dev/null; then
    kill "$BROKER_PID" 2>/dev/null || true
    wait "$BROKER_PID" 2>/dev/null || true
  fi
  BROKER_PID=""
  e2e_cleanup
  exit "$rc"
}
trap cleanup EXIT INT TERM

preflight() {
  require_darwin
  require_cmd python3
  require_cmd xcrun
  require_cmd node
  [ -f "$BROKER" ] || fail "missing credential broker: $BROKER"
  [ -f "$TEST_FILE" ] || fail "missing cold-start test: $TEST_FILE (RED before implementation; this is expected before the test exists)"
  FLUTTER="$(resolve_flutter)"
  [ -f "$APP/pubspec.yaml" ] || fail "missing app pubspec: $APP/pubspec.yaml"
  if [ ! -f "$APP/.dart_tool/package_config.json" ]; then
    e2e_log "app dependencies are not resolved; running flutter pub get"
    (cd "$APP" && "$FLUTTER" pub get >/dev/null) || fail "flutter pub get failed"
  fi
  [ -f "$APP/ios/Engine/runtime.zip" ] && [ -f "$APP/ios/Engine/.ready" ] ||
    fail "local engine is not prepared in this worktree: run tooling/ios/prepare-engine.sh (app/ios/Engine is not in git)"
  # The key is never printed: the broker reads it itself. Failing here keeps a
  # missing key from looking like a test failure 15 minutes later.
  read_credentials_key >/dev/null || fail "no opencode-go key (OPENCODE_GO_API_KEY or ~/.dsh/.credentials.yaml refs.OPENCODE_GO_API_KEY)"
  [ -n "$(repo_commit)" ] || fail "could not read the repository commit"
}

# --------------------------------------------------------------------------- proof helpers

app_pids() {
  # The simulator app is a real host process. Match this device's bundle path so
  # another simulator's Runner cannot make the proof look alive.
  ps -axo pid=,etime=,command= 2>/dev/null |
    grep -F "Devices/$UDID/" |
    grep -F "Runner.app/Runner" |
    grep -v grep || true
}

app_label() {
  xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -F "$BUNDLE_ID" || true
}

record_processes() {
  local label="${1:?label required}" out="$EVIDENCE/process-$1.txt"
  {
    printf 'label: %s\n' "$label"
    printf 'recorded_at: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'udid: %s\n' "$UDID"
    printf 'bundle: %s\n' "$BUNDLE_ID"
    printf '\nps (host):\n'
    app_pids
    printf '\nlaunchctl (simulator):\n'
    app_label
  } >"$out"
  e2e_log "process evidence: $out"
}

app_container() {
  xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null || true
}

# Removes simulator data/app-group containers that still belong to this bundle.
# Paths are validated before rm: only this device's container directories, and
# only when their CoreSimulator metadata names this bundle/group.
reset_app_containers() {
  local base="/Users/$(whoami)/Library/Developer/CoreSimulator/Devices/$UDID/data/Containers"
  local dir id removed=0
  # The bundle's data containers (including orphaned ones from app updates).
  for dir in "$base/Data/Application"/*; do
    [ -d "$dir" ] || continue
    id="$(plutil -extract MCMMetadataIdentifier raw "$dir/.com.apple.mobile_container_manager.metadata.plist" 2>/dev/null || true)"
    if [ "$id" = "$BUNDLE_ID" ]; then
      case "$dir" in
        "$base/Data/Application/"*) rm -rf -- "$dir" && removed=$((removed + 1)) ;;
        *) fail "refusing to remove unexpected container path: $dir" ;;
      esac
    fi
  done
  # The app group container (extension + any suite preferences).
  for dir in "$base/Shared/AppGroup"/*; do
    [ -d "$dir" ] || continue
    id="$(plutil -extract MCMMetadataIdentifier raw "$dir/.com.apple.mobile_container_manager.metadata.plist" 2>/dev/null || true)"
    if [ "$id" = "group.$BUNDLE_ID" ]; then
      case "$dir" in
        "$base/Shared/AppGroup/"*) rm -rf -- "$dir" && removed=$((removed + 1)) ;;
        *) fail "refusing to remove unexpected container path: $dir" ;;
      esac
    fi
  done
  e2e_log "removed $removed leftover simulator container(s) for $BUNDLE_ID"
}

screenshot() {
  local name="${1:?name required}"
  xcrun simctl io "$UDID" screenshot "$EVIDENCE/$name.png" >/dev/null 2>&1 || true
  e2e_log "screenshot: $EVIDENCE/$name.png"
}

wait_app_process() {
  local timeout="${1:-900}" log="${2:?log required}" deadline now rc
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    if [ -n "$(app_pids)" ]; then return 0; fi
    if [ -n "$FLUTTER_PID" ] && ! kill -0 "$FLUTTER_PID" 2>/dev/null; then
      set +e
      wait "$FLUTTER_PID" 2>/dev/null
      rc=$?
      set -e
      FLUTTER_PID=""
      tail -40 "$log" >&2 || true
      fail "flutter test exited before the app process appeared (exit $rc); see $log"
    fi
    now=$(date +%s)
    [ "$now" -lt "$deadline" ] || break
    sleep 0.25
  done
  fail "the app process did not appear within ${timeout}s; see $log"
}

wait_marker() {
  local log="${1:?log required}" marker="${2:?marker required}" timeout="${3:-900}" deadline now
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    if grep -Fq -- "$marker" "$log" 2>/dev/null; then return 0; fi
    if [ -n "$FLUTTER_PID" ] && ! kill -0 "$FLUTTER_PID" 2>/dev/null; then
      FLUTTER_PID=""
      fail "phase exited before $marker; see $log"
    fi
    now=$(date +%s)
    [ "$now" -lt "$deadline" ] || break
    sleep 0.5
  done
  fail "timed out after ${timeout}s waiting for '$marker' in $log"
}

terminate_app_and_prove() {
  local label="${1:?label required}" pid_before pid_after clock=0
  record_processes "before-terminate-$label"
  pid_before="$(app_pids)"
  [ -n "$pid_before" ] || fail "no app process to terminate at $label (the phase must keep the app alive until the host kills it)"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  while [ "$clock" -lt 60 ]; do
    pid_after="$(app_pids)"
    [ -z "$pid_after" ] && break
    sleep 0.25
    clock=$((clock + 1))
  done
  pid_after="$(app_pids)"
  if [ -n "$pid_after" ]; then
    e2e_log "process still alive after simctl terminate; refusing to continue"
    record_processes "after-terminate-$label"
    fail "the app process survived simctl terminate at $label"
  fi
  record_processes "after-terminate-$label"
  screenshot "$label-after-terminate"
  e2e_log "process proof: $label had pid(s) $(printf '%s' "$pid_before" | awk '{print $1}' | tr '\n' ' ') before terminate, none after"
}

wait_flutter_exit() {
  local timeout="${1:-120}" deadline now pid="$FLUTTER_PID"
  [ -n "$pid" ] || return 0
  deadline=$(( $(date +%s) + timeout ))
  while kill -0 "$pid" 2>/dev/null; do
    now=$(date +%s)
    [ "$now" -lt "$deadline" ] || break
    sleep 0.5
  done
  if kill -0 "$pid" 2>/dev/null; then
    e2e_log "flutter test process $pid did not exit after the app died; terminating it"
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
  FLUTTER_PID=""
}

# --------------------------------------------------------------------------- phases

start_phase() {
  local phase="${1:?phase required}" autostart="${2:-on}" log="$EVIDENCE/$phase.log"
  PHASE_STARTED="$(date +%s)"
  : >"$log"
  chmod 600 "$log" 2>/dev/null || true
  e2e_log "phase $phase: flutter test ($log)"
  (
    cd "$APP"
    DSH_IOS_GUEST_BUILD=0 \
      DSH_TEST_FONT_DIR="$FONT_DIR" \
      "$FLUTTER" test --no-pub -r expanded --no-uninstall \
      --dart-define=E2E_PHASE="$phase" \
      --dart-define=E2E_AUTOSTART="$autostart" \
      --dart-define=E2E_BROKER_URL="http://127.0.0.1:$BROKER_PORT" \
      --dart-define=E2E_BROKER_TOKEN="$BROKER_TOKEN" \
      "$TEST_REL" -d "$UDID"
  ) >>"$log" 2>&1 &
  FLUTTER_PID=$!
}

finish_phase() {
  local phase="${1:?phase required}" elapsed
  elapsed=$(( $(date +%s) - PHASE_STARTED ))
  e2e_log "phase $phase passed in ${elapsed}s; terminating the app to start the next process"
  screenshot "$phase-screen"
  terminate_app_and_prove "$phase"
  wait_flutter_exit 180
  # The app was killed on purpose, so flutter test ends non-zero. A phase only
  # passes when its assertions already printed PHASE-PASS (wait_marker).
  env_json_write "$EVIDENCE/phase-$phase.env.json" \
    "run=cold_start" "phase=$phase" "result=pass" "seconds=$elapsed" \
    "commit=$(repo_commit)" "log=$EVIDENCE/$phase.log"
}

run_phase() {
  local phase="${1:?phase required}" autostart="${2:-on}"
  start_phase "$phase" "$autostart"
  wait_app_process 900 "$EVIDENCE/$phase.log"
  screenshot "$phase-cold-launch"
  record_processes "cold-launch-$phase"
  sleep 2
  screenshot "$phase-first-screen"
  wait_marker "$EVIDENCE/$phase.log" "[cold-start-e2e] PHASE-PASS $phase" "$PHASE_TIMEOUT"
  finish_phase "$phase"
  sleep 1
}

run_crash_phase() {
  local phase="crash"
  start_phase "$phase" "on"
  wait_app_process 900 "$EVIDENCE/$phase.log"
  screenshot "crash-cold-launch"
  record_processes "cold-launch-$phase"
  wait_marker "$EVIDENCE/$phase.log" "[cold-start-e2e] CRASH-READY-TO-KILL" "$PHASE_TIMEOUT"
  local elapsed=$(( $(date +%s) - PHASE_STARTED ))
  screenshot "crash-mid-turn"
  e2e_log "crash phase dispatched a slow tool after ${elapsed}s; killing the app mid-turn"
  terminate_app_and_prove "crash-mid-turn"
  wait_flutter_exit 180
  env_json_write "$EVIDENCE/phase-crash.env.json" \
    "run=cold_start" "phase=crash" "result=pass" "seconds=$elapsed" \
    "commit=$(repo_commit)" "log=$EVIDENCE/$phase.log"
  sleep 1
}

# --------------------------------------------------------------------------- main

preflight
if [ "$MODE" = "dry-run" ]; then
  e2e_log "dry-run: flutter=$FLUTTER simulator=$UDID evidence=$EVIDENCE"
  e2e_log "dry-run: would run phases seed, verify, autostart_off, crash, crash_verify"
  printf 'dry-run: PASS (no simulator or test run)\n'
  exit 0
fi

mkdir -p "$EVIDENCE"
WORK="$(make_temp_dir dsh-e2e-cold-start)"
e2e_track_temp "$WORK"

acquire_sim_lock 1800
boot_sim "$UDID"

e2e_log "starting credential broker"
node "$BROKER" >"$WORK/broker.out" 2>"$WORK/broker.err" &
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
e2e_log "broker up on 127.0.0.1:$BROKER_PORT (bearer token hidden)"

wrap_start="$(date +%s)"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
record_processes "after-uninstall"
# CoreSimulator may keep a previous app data container after simctl uninstall
# and hand it to the next install (a real app update path, but not a clean
# first run). Remove every container that still belongs to this bundle so the
# seed phase really starts at the welcome page with no runtime.
reset_app_containers
CONTAINER_BEFORE="$(app_container)"
[ -z "$CONTAINER_BEFORE" ] ||
  fail "clean-install precondition failed: the app data container survived uninstall: $CONTAINER_BEFORE"

PHASE_ONLY="${DSH_E2E_ONLY_PHASE:-}"
if [ "$PHASE_ONLY" = "verify" ]; then
  run_phase verify on
  env_json_write "$EVIDENCE/run.env.json" \
    "run=cold_start" "result=pass" "phases=verify" "seconds=$(( $(date +%s) - wrap_start ))" \
    "udid=$UDID" "bundle=$BUNDLE_ID" "commit=$(repo_commit)" "evidence=$EVIDENCE" "only=$PHASE_ONLY"
  printf 'cold-start real suite: PASS (verify only, udid %s)\n' "$UDID"
  exit 0
fi
if [ "$PHASE_ONLY" = "autostart_off" ]; then
  run_phase autostart_off off
  env_json_write "$EVIDENCE/run.env.json" \
    "run=cold_start" "result=pass" "phases=autostart_off" "seconds=$(( $(date +%s) - wrap_start ))" \
    "udid=$UDID" "bundle=$BUNDLE_ID" "commit=$(repo_commit)" "evidence=$EVIDENCE" "only=$PHASE_ONLY"
  printf 'cold-start real suite: PASS (autostart_off only, udid %s)\n' "$UDID"
  exit 0
fi
if [ "$PHASE_ONLY" = "crash" ]; then
  run_crash_phase
  env_json_write "$EVIDENCE/run.env.json" \
    "run=cold_start" "result=pass" "phases=crash" "seconds=$(( $(date +%s) - wrap_start ))" \
    "udid=$UDID" "bundle=$BUNDLE_ID" "commit=$(repo_commit)" "evidence=$EVIDENCE" "only=$PHASE_ONLY"
  printf 'cold-start real suite: PASS (crash only, udid %s)\n' "$UDID"
  exit 0
fi
if [ "$PHASE_ONLY" = "crash_verify" ]; then
  run_phase crash_verify on
  env_json_write "$EVIDENCE/run.env.json" \
    "run=cold_start" "result=pass" "phases=crash_verify" "seconds=$(( $(date +%s) - wrap_start ))" \
    "udid=$UDID" "bundle=$BUNDLE_ID" "commit=$(repo_commit)" "evidence=$EVIDENCE" "only=$PHASE_ONLY"
  printf 'cold-start real suite: PASS (crash_verify only, udid %s)\n' "$UDID"
  exit 0
fi

# ---- seed (clean install + onboarding + real model + draft) ------------------
run_phase seed on
CONTAINER_SEED="$(app_container)"
[ -n "$CONTAINER_SEED" ] || fail "no app data container after the seed phase"
printf '%s\n' "$CONTAINER_SEED" >"$EVIDENCE/app-container.txt"
{
  printf 'container: %s\n' "$CONTAINER_SEED"
  printf '\ndraft attachment files:\n'
  find "$CONTAINER_SEED" -type f -path '*draft-attachments*' 2>/dev/null || true
  printf '\npreference markers:\n'
  for plist in "$CONTAINER_SEED"/Library/Preferences/*.plist; do
    [ -f "$plist" ] || continue
    printf '%s\n' "$(basename "$plist")"
    plutil -p "$plist" 2>/dev/null | grep -E 't30_cold_start|chat_drafts_v1|auto_start_local|last_session' || true
  done
} >"$EVIDENCE/app-container-seed.txt"

# Fast diagnosis path: set up the app with the seed phase, then only crash.
if [ "${DSH_E2E_DEBUG_CRASH:-0}" = "1" ]; then
  run_crash_phase
  run_phase crash_verify on
  env_json_write "$EVIDENCE/run.env.json" \
    "run=cold_start" "result=pass" "phases=seed,crash,crash_verify" "seconds=$(( $(date +%s) - wrap_start ))" \
    "udid=$UDID" "bundle=$BUNDLE_ID" "container=$CONTAINER_SEED" \
    "commit=$(repo_commit)" "evidence=$EVIDENCE" "debug=crash"
  printf 'cold-start real suite: PASS (debug seed+crash+crash_verify, udid %s)\n' "$UDID"
  exit 0
fi

if [ "$PHASE_ONLY" = "seed" ]; then
  env_json_write "$EVIDENCE/run.env.json" \
    "run=cold_start" "result=pass" "phases=seed" "seconds=$(( $(date +%s) - wrap_start ))" \
    "udid=$UDID" "bundle=$BUNDLE_ID" "container=$CONTAINER_SEED" \
    "commit=$(repo_commit)" "evidence=$EVIDENCE" "only=$PHASE_ONLY"
  printf 'cold-start real suite: PASS (seed only, udid %s)\n' "$UDID"
  exit 0
fi

# ---- verify (cold launch: persistence + auto-start on + new real turn) ------
run_phase verify on
CONTAINER_VERIFY="$(app_container)"
CONTAINER_CHANGED=0
if [ "$CONTAINER_VERIFY" != "$CONTAINER_SEED" ]; then
  # The Simulator can reissue an app data container when the bundle is
  # reinstalled; iOS migrates its contents and the app's storage relocation
  # handles the new root. Continuity is proven inside the verify phase by the
  # seed record, session, messages, draft and workspace file, not by the UUID.
  CONTAINER_CHANGED=1
  e2e_log "data container was reissued across the seed/verify boundary: $CONTAINER_SEED -> $CONTAINER_VERIFY"
else
  e2e_log "same data container across the seed/verify process boundary: $CONTAINER_VERIFY"
fi
{
  printf 'seed_container: %s\nverify_container: %s\nchanged: %s\n' \
    "$CONTAINER_SEED" "$CONTAINER_VERIFY" "$CONTAINER_CHANGED"
  printf '\nverify draft attachment files:\n'
  find "$CONTAINER_VERIFY" -type f -path '*draft-attachments*' 2>/dev/null || true
  printf '\nverify preference markers:\n'
  for plist in "$CONTAINER_VERIFY"/Library/Preferences/*.plist; do
    [ -f "$plist" ] || continue
    printf '%s\n' "$(basename "$plist")"
    plutil -p "$plist" 2>/dev/null | grep -E 't30_cold_start|chat_drafts_v1|auto_start_local|last_session' || true
  done
} >"$EVIDENCE/app-container-verify.txt"

# ---- autostart off (cold launch must not start the engine) ------------------
run_phase autostart_off off

# ---- unknown result: kill mid-tool, then relaunch ---------------------------
run_crash_phase
run_phase crash_verify on

elapsed=$(( $(date +%s) - wrap_start ))
for log in "$EVIDENCE"/*.log; do
  [ -f "$log" ] || continue
  scrub_secret_from_file "$log" "$BROKER_TOKEN" || true
done
env_json_write "$EVIDENCE/run.env.json" \
  "run=cold_start" "result=pass" "phases=seed,verify,autostart_off,crash,crash_verify" \
  "seconds=$elapsed" "udid=$UDID" "bundle=$BUNDLE_ID" "container=$CONTAINER_SEED" \
  "commit=$(repo_commit)" "evidence=$EVIDENCE"

printf 'cold-start real suite: PASS (%ss, 5 phases, udid %s)\n' "$elapsed" "$UDID"
