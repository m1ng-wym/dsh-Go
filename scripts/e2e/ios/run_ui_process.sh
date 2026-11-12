#!/usr/bin/env bash
# T34b · process-level UI acceptance flows for Phase 1 v1.1.
#
# Builds the real Runner.app for the simulator, installs it on a fresh app
# container, and drives the app through the Phase1UITests XCUITest bundle:
#
#   cold_autostart       A2/B5  fresh install → local engine → cold relaunch →
#                               auto-start off/on in Settings
#   logs                 B7    engine logs page: no credential values, copy works
#   failure_diagnostics  B6    a renamed runtime file → readable failure, log,
#                               retry, no crash (the wrapper corrupts/restores it)
#   install_resume       B2    kill the app mid-install → relaunch → install
#                               resumes (Retry reuses the installer journal) and
#                               completes
#   photos               D6/D8 simctl addmedia → Photos picker → tray → send →
#                               attachment bubble + canonical mock model reply
#   dark                 G1    cold launch with the system in dark appearance
#   english              G2    Chinese baseline → AppleLanguages en-US → cold
#                               launch with English labels → restore
#   se3                  SE3   repeat the dark cold launch on the iPhone SE3
#
# Every test runs in its own xcodebuild invocation. Logs, result bundles,
# screenshots and attachments go under
# reports/phase1-completion/T34b/<tag>/<flow>/ (tag: red or green).
#
# Usage:
#   scripts/e2e/ios/run_ui_process.sh [--tag red|green] [--only flow,flow]
#                                     [--no-build] [--dry-run] [--keep-app]
#
# Environment:
#   DSH_SIM_UDID            override the iPhone 17 Pro UDID
#   DSH_E2E_EVIDENCE_DIR    override the evidence root
#   DSH_E2E_KEEP=1          keep temp dirs
#   DSH_FLUTTER_BIN         flutter executable
#
# Exits non-zero if any flow fails; never treats a missing dependency as a skip.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$SCRIPT_DIR/../lib.sh"

ROOT="$DSH_E2E_ROOT"
APP="$ROOT/app"
BUNDLE_ID="io.github.ccch1mneyyy.dshgo"
DEFAULT_UDID="1D9F8C91-5739-47B2-BDD0-0FC7207166F3"
SE3_UDID="D9C6C518-0452-4AFE-9F8C-59EBE495BD47"
EVIDENCE="${DSH_E2E_EVIDENCE_DIR:-$ROOT/../../../reports/phase1-completion/T34b}"
TAG="green"
ONLY=""
BUILD=1
DRY_RUN=0
KEEP_APP=0
FLOWS=(cold_autostart logs failure_diagnostics install_resume photos dark english se3)

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) [ $# -ge 2 ] || { printf 'usage: %s --tag red|green\n' "$0" >&2; exit 2; }; TAG="$2"; shift 2 ;;
    --only) [ $# -ge 2 ] || { printf 'usage: %s --only flow,flow\n' "$0" >&2; exit 2; }; ONLY="$2"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --keep-app) KEEP_APP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'usage: %s [--tag red|green] [--only flow,flow] [--no-build] [--dry-run]\n' "$0" >&2; exit 2 ;;
  esac
done
case "$TAG" in red|green) ;; *) fail "--tag must be red or green" ;; esac

if [ -n "$ONLY" ]; then
  IFS=',' read -r -a REQUESTED <<< "$ONLY"
  SELECTED=()
  for flow in "${REQUESTED[@]}"; do
    found=0
    for known in "${FLOWS[@]}"; do [ "$flow" = "$known" ] && found=1; done
    [ "$found" = 1 ] || fail "unknown flow: $flow (known: ${FLOWS[*]})"
    SELECTED+=("$flow")
  done
  FLOWS=("${SELECTED[@]}")
fi

WORK=""
MOCK_PID=""
FAILURE_BIN=""
FAILURE_BIN_BAK=""
APP_PID=""
LANGUAGE_CHANGED=0
ORIGINAL_LANGUAGES=""
ORIGINAL_LOCALE=""
ORIGINAL_APPEARANCE=""
declare -a RESULT_FLOWS=()
declare -a RESULT_STATUS=()

cleanup() {
  local rc=$?
  if [ -n "${MOCK_PID:-}" ] && kill -0 "$MOCK_PID" 2>/dev/null; then
    kill -TERM "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  if [ -n "${FAILURE_BIN_BAK:-}" ] && [ -f "${FAILURE_BIN_BAK:-}" ] && [ -n "${FAILURE_BIN:-}" ]; then
    mv -f "$FAILURE_BIN_BAK" "$FAILURE_BIN" 2>/dev/null || true
  fi
  if [ "${LANGUAGE_CHANGED:-0}" = 1 ] && [ -n "${ORIGINAL_LANGUAGES:-}" ] && [ -n "${UDID:-}" ]; then
    restore_language || true
  fi
  if [ -n "${ORIGINAL_APPEARANCE:-}" ] && [ -n "${UDID:-}" ]; then
    xcrun simctl ui "$UDID" appearance "$ORIGINAL_APPEARANCE" >/dev/null 2>&1 || true
  fi
  if [ -n "${WORK:-}" ]; then e2e_cleanup; else release_sim_lock; fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

preflight() {
  require_darwin
  require_cmd xcrun "Xcode command line tools"
  require_cmd python3
  require_cmd node "canonical mock model server"
  [ -f "$APP/pubspec.yaml" ] || fail "missing app pubspec: $APP/pubspec.yaml"
  FLUTTER="$(resolve_flutter)"
  if [ ! -f "$APP/ios/Engine/.ready" ]; then
    e2e_log "app/ios/Engine is not prepared; running tooling/ios/prepare-engine.sh"
    local py=""
    py="$(python3 -c 'import sys; print(sys.executable if sys.version_info >= (3,11) else "")')" || true
    if [ -z "$py" ]; then
      for candidate in /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.13 python3.12 python3.13; do
        if command -v "$candidate" >/dev/null 2>&1; then py="$(command -v "$candidate")"; break; fi
      done
    fi
    [ -n "$py" ] || fail "prepare-engine needs python3 >= 3.11 (set PYTHON)"
    (cd "$ROOT" && PATH="$(dirname "$py"):$PATH" PYTHON="$py" ./tooling/ios/prepare-engine.sh) >&2 ||
      fail "tooling/ios/prepare-engine.sh failed"
  fi
}

resolve_target_udid() {
  if [ -n "${DSH_SIM_UDID:-}" ]; then printf '%s\n' "$DSH_SIM_UDID"; return 0; fi
  if xcrun simctl list devices available -j 2>/dev/null | grep -q "$DEFAULT_UDID"; then
    printf '%s\n' "$DEFAULT_UDID"
    return 0
  fi
  resolve_sim_udid "iPhone 17 Pro"
}

build_app() {
  if [ "$BUILD" = 0 ] && [ -d "$APP/build/ios/iphonesimulator/Runner.app" ]; then
    e2e_log "--no-build: reusing app/build/ios/iphonesimulator/Runner.app"
    return 0
  fi
  e2e_log "flutter pub get"
  (cd "$APP" && "$FLUTTER" pub get) >"$WORK/pub-get.log" 2>&1 || fail "flutter pub get failed"
  e2e_log "flutter build ios --simulator --debug (DSH_IOS_GUEST_BUILD=0)"
  (cd "$APP" && DSH_IOS_GUEST_BUILD=0 "$FLUTTER" build ios --simulator --debug) >"$WORK/build.log" 2>&1 ||
    fail "flutter build ios failed; see $WORK/build.log"
  local bundle="$APP/build/ios/iphonesimulator/Runner.app"
  [ -d "$bundle" ] || fail "Runner.app was not built"
  [ -f "$bundle/dsh-runtime/runtime.zip" ] ||
    fail "Runner.app has no dsh-runtime/runtime.zip (app/ios/Engine was not ready at build time)"
}

start_mock() {
  local log="$EVIDENCE/$TAG/mock-model.jsonl"
  mkdir -p "$EVIDENCE/$TAG"
  : > "$log"
  MOCK_MODEL_LOG="$log" node "$ROOT/test/fixtures/mock_model_server.mjs" --port 3901 >"$WORK/mock.out" 2>"$WORK/mock.err" &
  MOCK_PID=$!
  for _ in $(seq 1 100); do
    if python3 - <<'PROBE' >/dev/null 2>&1
import socket
s = socket.socket()
s.settimeout(0.3)
try:
    s.connect(("127.0.0.1", 3901))
except OSError:
    raise SystemExit(1)
finally:
    s.close()
PROBE
    then
      e2e_log "canonical mock model is up on 127.0.0.1:3901"
      return 0
    fi
    kill -0 "$MOCK_PID" 2>/dev/null || { cat "$WORK/mock.err" >&2 || true; fail "mock model server exited"; }
    sleep 0.2
  done
  fail "mock model server did not open 127.0.0.1:3901"
}

make_photo() {
  local png="$WORK/t34b-photo.png"
  python3 - "$png" <<'PY'
import struct, sys, zlib
w = h = 96
rows = b''.join(b'\x00' + bytes([220, 56, 56]) * w for _ in range(h))
def chunk(t, d):
    return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
png = (b'\x89PNG\r\n\x1a\n' +
       chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
       chunk(b'IDAT', zlib.compress(rows)) +
       chunk(b'IEND', b''))
open(sys.argv[1], 'wb').write(png)
PY
  PHOTO="$png"
}

add_photo_to_simulator() {
  local udid="$1"
  [ -n "${PHOTO:-}" ] || make_photo
  e2e_log "adding $PHOTO to the simulator photo library"
  xcrun simctl addmedia "$udid" "$PHOTO" >"$WORK/addmedia.log" 2>&1 &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge 150 ]; then
      e2e_log "simctl addmedia did not return in 150s; stopping it (the photo may be present)"
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      break
    fi
    sleep 2
    waited=$((waited + 2))
  done
}

fresh_install() {
  local udid="$1"
  if [ "$KEEP_APP" != 1 ]; then
    xcrun simctl uninstall "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  fi
  xcrun simctl install "$udid" "$APP/build/ios/iphonesimulator/Runner.app" ||
    fail "cannot install Runner.app on $udid"
  local bundle
  bundle="$(xcrun simctl get_app_container "$udid" "$BUNDLE_ID" app 2>/dev/null || true)"
  [ -n "$bundle" ] || fail "Runner.app is not installed on $udid"
  [ -f "$bundle/dsh-runtime/runtime.zip" ] || fail "installed Runner.app has no engine payload"
}

run_test() {
  local flow="$1" test="$2" udid="$3" fresh="$4"
  local dir="$EVIDENCE/$TAG/$flow"
  mkdir -p "$dir/screenshots"
  if [ "$fresh" = fresh ]; then fresh_install "$udid"; fi
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  rm -rf "$dir/result.xcresult" "$dir/attachments"
  local started rc=0
  started=$(date +%s)
  e2e_log "$flow: xcodebuild test -only-testing Phase1UITests/$test on $udid"
  set +e
  xcodebuild test \
    -workspace "$APP/ios/Runner.xcworkspace" \
    -scheme Phase1UITests \
    -destination "platform=iOS Simulator,id=$udid" \
    -derivedDataPath "$WORK/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    -only-testing:"Phase1UITests/Phase1UITests/$test" \
    -resultBundlePath "$dir/result.xcresult" \
    >"$dir/xcodebuild.log" 2>&1 &
  local test_pid=$!
  local waited=0 rc=0
  local limit="${DSH_UI_TEST_TIMEOUT:-900}"
  while kill -0 "$test_pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
      e2e_log "$flow: xcodebuild exceeded ${limit}s; stopping it"
      kill "$test_pid" 2>/dev/null || true
      sleep 2
      kill -9 "$test_pid" 2>/dev/null || true
      rc=124
      break
    fi
    sleep 2
    waited=$((waited + 2))
  done
  if [ "$rc" -eq 0 ]; then
    wait "$test_pid"
    rc=$?
  fi
  set -e
  local seconds=$(( $(date +%s) - started ))
  if [ -d "$dir/result.xcresult" ]; then
    xcrun xcresulttool export attachments --path "$dir/result.xcresult" --output-path "$dir/attachments" \
      >"$dir/export.log" 2>&1 || e2e_log "$flow: could not export xcresult attachments"
  fi
  export_screenshots "$flow" "$dir"
  xcrun simctl io "$udid" screenshot "$dir/screenshots/final-screen.png" >/dev/null 2>&1 || true
  if [ "$rc" -eq 0 ]; then
    RESULT_FLOWS+=("$flow"); RESULT_STATUS+=("pass")
    e2e_log "$flow: PASS (${seconds}s)"
  else
    RESULT_FLOWS+=("$flow"); RESULT_STATUS+=("fail")
    e2e_log "$flow: FAIL (${seconds}s); see $dir/xcodebuild.log"
    tail -40 "$dir/xcodebuild.log" >&2 || true
  fi
  env_json_write "$dir/result.env.json" \
    "flow=$flow" "test=$test" "result=$([ "$rc" -eq 0 ] && echo pass || echo fail)" \
    "udid=$udid" "seconds=$seconds" "commit=$(repo_commit)" "log=$dir/xcodebuild.log" \
    "result_bundle=$dir/result.xcresult" >/dev/null 2>&1 || true
  return 0
}

export_screenshots() {
  local flow="$1" dir="$2" manifest="$dir/attachments/manifest.json"
  [ -f "$manifest" ] || return 0
  python3 - "$manifest" "$dir" "$flow" <<'PY'
import json, os, shutil, subprocess, sys
manifest, outdir, flow = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(manifest))
shots = os.path.join(outdir, 'screenshots')
os.makedirs(shots, exist_ok=True)
for test in data:
    for att in test.get('attachments', []):
        name = att.get('suggestedHumanReadableName', '')
        exported = att.get('exportedFileName')
        if not name.endswith(('.png', '.jpg', '.jpeg')) or not exported:
            continue
        src = os.path.join(os.path.dirname(manifest), exported)
        if not os.path.exists(src):
            continue
        safe = ''.join(c if c.isalnum() or c in '-_.' else '-' for c in name)[:120]
        shutil.copyfile(src, os.path.join(shots, safe))
PY
}

prepare_failure() {
  local udid="$1"
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  local container
  container="$(xcrun simctl get_app_container "$udid" "$BUNDLE_ID" data 2>/dev/null || true)"
  [ -n "$container" ] || fail "no app data container for the failure test"
  FAILURE_BIN="$container/Library/Application Support/dsh-runtime/tree/node_modules/@deepseek-ai/dsh/lib/bin.js"
  [ -f "$FAILURE_BIN" ] || fail "the installed runtime entry is missing: $FAILURE_BIN"
  FAILURE_BIN_BAK="$FAILURE_BIN.t34b-bak"
  mv -f "$FAILURE_BIN" "$FAILURE_BIN_BAK"
  e2e_log "failure test: renamed $(basename "$FAILURE_BIN") in the app container"
}

restore_failure() {
  if [ -n "${FAILURE_BIN_BAK:-}" ] && [ -f "${FAILURE_BIN_BAK:-}" ] && [ -n "${FAILURE_BIN:-}" ]; then
    mv -f "$FAILURE_BIN_BAK" "$FAILURE_BIN"
    e2e_log "failure test: restored the runtime entry"
    FAILURE_BIN_BAK=""
  fi
}

set_language() {
  local udid="$1" lang="$2" locale="$3"
  xcrun simctl spawn "$udid" defaults write NSGlobalDomain AppleLanguages -array "$lang" >/dev/null
  xcrun simctl spawn "$udid" defaults write NSGlobalDomain AppleLocale -string "$locale" >/dev/null
  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  wait_sim_booted "$udid" 180
}

restore_language() {
  if [ -n "${ORIGINAL_LANGUAGES:-}" ]; then
    local lang
    lang="$(printf '%s' "$ORIGINAL_LANGUAGES" | tr -d '()" ' | cut -d, -f1)"
    [ -n "$lang" ] || lang="en-US"
    e2e_log "restoring simulator language to $lang"
    set_language "$UDID" "$lang" "${ORIGINAL_LOCALE:-en_US}"
  fi
  LANGUAGE_CHANGED=0
}

capture_language() {
  local udid="$1"
  ORIGINAL_LANGUAGES="$(xcrun simctl spawn "$udid" defaults read -g AppleLanguages 2>/dev/null | tr -d '\n' || true)"
  ORIGINAL_LOCALE="$(xcrun simctl spawn "$udid" defaults read -g AppleLocale 2>/dev/null | tr -d '\n' || true)"
}

main() {
  preflight
  UDID="$(resolve_target_udid)"
  [ -n "$UDID" ] || fail "no simulator selected"
  WORK="$(make_temp_dir dsh-t34b-ui)"; e2e_track_temp "$WORK"
  mkdir -p "$EVIDENCE/$TAG"

  if [ "$DRY_RUN" = 1 ]; then
    e2e_log "dry-run: flutter=$FLUTTER udid=$UDID se3=$SE3_UDID evidence=$EVIDENCE/$TAG"
    e2e_log "dry-run: flows=${FLOWS[*]}"
    [ -d "$APP/build/ios/iphonesimulator/Runner.app" ] && e2e_log "dry-run: Runner.app present" || e2e_log "dry-run: Runner.app will be built"
    node "$ROOT/test/fixtures/mock_model_server.mjs" --self-test >/dev/null || fail "mock model self-test failed"
    printf 'dry-run: PASS (no build, no simulator run)\n'
    exit 0
  fi

  if [ "$BUILD" = 1 ] || [ ! -d "$APP/build/ios/iphonesimulator/Runner.app" ]; then
    build_app
  else
    e2e_log "--no-build: reusing existing Runner.app"
  fi
  [ -f "$APP/build/ios/iphonesimulator/Runner.app/dsh-runtime/runtime.zip" ] ||
    fail "Runner.app has no engine payload; rerun without --no-build"

  acquire_sim_lock 3600
  boot_sim "$UDID"
  capture_language "$UDID"
  ORIGINAL_APPEARANCE="$(xcrun simctl ui "$UDID" appearance 2>/dev/null | tr -d '\n' || true)"
  [ -n "$ORIGINAL_APPEARANCE" ] || ORIGINAL_APPEARANCE="light"

  start_mock
  add_photo_to_simulator "$UDID"
  xcrun simctl ui "$UDID" appearance light >/dev/null 2>&1 || true

  LOGS_RAN=0
  for flow in "${FLOWS[@]}"; do
    case "$flow" in
      cold_autostart) run_test cold_autostart testColdLaunchAutoStart "$UDID" fresh ;;
      logs)
        LOGS_RAN=1
        run_test logs testLogsRedactionAndCopy "$UDID" reuse
        ;;
      failure_diagnostics)
        prepare_failure "$UDID"
        run_test failure_diagnostics testFailureDiagnostics "$UDID" reuse
        restore_failure
        ;;
      install_resume) run_test install_resume testInstallResume "$UDID" fresh ;;
      photos)
        run_test photos testPhotosAttachment "$UDID" fresh
        if [ -s "$EVIDENCE/$TAG/mock-model.jsonl" ]; then
          cp "$EVIDENCE/$TAG/mock-model.jsonl" "$EVIDENCE/$TAG/photos/mock-model.jsonl"
          if python3 - "$EVIDENCE/$TAG/photos/mock-model.jsonl" <<'PYCHECK'
import json, sys
found = False
for line in open(sys.argv[1], encoding='utf-8', errors='replace'):
    try:
        entry = json.loads(line)
    except ValueError:
        continue
    last = str(entry.get('last_user', ''))
    if 'image' in last.lower() or 'attachment' in last.lower():
        found = True
        break
raise SystemExit(0 if found else 1)
PYCHECK
          then
            e2e_log "photos: the mock model received an image request"
          else
            e2e_log "photos: no image request reached the mock model"
            RESULT_FLOWS+=("photos-mock-image")
            RESULT_STATUS+=("fail")
          fi
        else
          e2e_log "photos: the mock model log is empty"
        fi
        ;;

      dark)
        xcrun simctl ui "$UDID" appearance dark >/dev/null 2>&1
        run_test dark testDarkColdLaunch "$UDID" fresh
        xcrun simctl ui "$UDID" appearance light >/dev/null 2>&1 || true
        ;;
      english)
        # A real switch: Chinese baseline, then English, then restore.
        set_language "$UDID" zh-Hans-CN zh_CN
        LANGUAGE_CHANGED=1
        run_test english-baseline testChineseBaseline "$UDID" fresh
        set_language "$UDID" en-US en_US
        run_test english testEnglishColdLaunch "$UDID" fresh
        restore_language
        ;;
      se3)
        boot_sim "$SE3_UDID"
        xcrun simctl ui "$SE3_UDID" appearance dark >/dev/null 2>&1
        run_test se3 testSE3ColdLaunchDark "$SE3_UDID" fresh
        xcrun simctl ui "$SE3_UDID" appearance light >/dev/null 2>&1 || true
        ;;
    esac
  done

  # The logs phase's copy is checked against the simulator clipboard, which
  # holds the whole log text after the test taps Copy all.
  if [ "${LOGS_RAN:-0}" = 1 ] && [ -f "$EVIDENCE/$TAG/logs/xcodebuild.log" ]; then
    xcrun simctl pbpaste "$UDID" >"$EVIDENCE/$TAG/logs/clipboard.txt" 2>/dev/null || true
    # The simulator and the Mac share a pasteboard; the in-test paste check is
    # the authoritative one. This is a diagnostic of what the host sees.
    if [ -s "$EVIDENCE/$TAG/logs/clipboard.txt" ]; then
      e2e_log "logs: host-visible clipboard after the run: $(wc -c <"$EVIDENCE/$TAG/logs/clipboard.txt" | tr -d ' ') bytes"
      if python3 - "$EVIDENCE/$TAG/logs/clipboard.txt" <<'PYCLIP'
import re, sys
text = open(sys.argv[1], encoding='utf-8', errors='replace').read()
if re.search(r'sk-[A-Za-z0-9_-]{12,}', text) or re.search(r'Bearer [A-Za-z0-9._~+/=-]{12,}', text) or re.search(r'token=[A-Za-z0-9._~+/=-]{8,}', text):
    raise SystemExit(2)
raise SystemExit(0 if ('[dsh-startup]' in text or 'dsh web' in text or 'Runner[' in text) else 1)
PYCLIP
      then
        e2e_log "logs: copy verified — the clipboard holds the engine log"
      else
        rc=$?
        if [ "$rc" = 2 ]; then
          e2e_log "logs: the copied log text contains a credential-shaped value"
          RESULT_FLOWS+=("logs-credentials")
        else
          e2e_log "logs: the clipboard does not hold the engine log; copy is unverified"
          RESULT_FLOWS+=("logs-copy")
        fi
        RESULT_STATUS+=("fail")
      fi
    else
      e2e_log "logs: the host-visible clipboard was empty after the run; copy is unverified"
      RESULT_FLOWS+=("logs-copy")
      RESULT_STATUS+=("fail")
    fi
  fi

  local failures=0 i
  for i in "${!RESULT_FLOWS[@]}"; do
    [ "${RESULT_STATUS[$i]}" = pass ] || failures=$((failures + 1))
  done
  {
    printf 'tag=%s\n' "$TAG"
    for i in "${!RESULT_FLOWS[@]}"; do printf '%s=%s\n' "${RESULT_FLOWS[$i]}" "${RESULT_STATUS[$i]}"; done
  } | tee "$EVIDENCE/$TAG/summary.txt"

  if [ "$failures" -ne 0 ]; then
    fail "$failures of ${#RESULT_FLOWS[@]} UI flows failed; evidence: $EVIDENCE/$TAG"
  fi
  printf 'T34b process-level UI flows: PASS (%d flows, tag %s)\n' "${#RESULT_FLOWS[@]}" "$TAG"
}

main "$@"
