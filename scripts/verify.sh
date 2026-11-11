#!/usr/bin/env bash
# Phase 1 verification entry point.
#
# Usage:
#   scripts/verify.sh --static [--repo PATH] [--dry-run] [--allow-skip=REASON]
#   scripts/verify.sh --ci     (Linux CI: static + fast + tooling gates; no Xcode/simulator)
#   scripts/verify.sh --fast
#   scripts/verify.sh --full [--allow-skip=REASON]
#   scripts/verify.sh --list [--repo PATH]
#   scripts/verify.sh --self-test
#
# Tiers (see docs/specs/phase1/test-plan.md §6):
#   --static : L0 — flutter analyze, dart analyze, l10n/guide/skill sync checks,
#                   Node syntax checks, mock-model self-test
#   --ci     : --static + --fast + tooling gates (guest-embedding / native-loader /
#                   host-core); everything a Linux runner can do without Xcode
#   --fast   : --static + L1/L2 — flutter test on the Phase 1 dirs
#                   (test/phase1, test/chat/phase1, test/engine/phase1,
#                   test/files/phase1), dart test, node --test test/unit
#   --full   : --ci + L3 RunnerTests (deferred system-tools suite excluded) +
#                   L4 integration_test/phase1_test.dart on iPhone 17 Pro & iPhone SE3
#                   via integration_test/run_phase1_e2e.sh (canonical mock model at
#                   127.0.0.1:3901) + build (simulator + device unsigned) + official
#                   engine smoke (mock model) + archive shape check, which reports
#                   SKIP while the Phase 1 iSH guest is deferred (--allow-skip records it)
#
# Behaviour:
#   - Locates the repo from $DSH_REPO, the parent of scripts/ (normal checkout),
#     or a sibling ../repo (legacy side-by-side layout kept for migration runs).
#   - Missing prerequisites are reported as SKIP with a reason.
#   - ANY skip fails the run unless --allow-skip=REASON is given (plan §7.1:
#     no silent skips; static/ci/fast/full are all fail-on-skip).
#   - PASS == 0 in a real mode is also a failure ("no assertions ran" cannot be green).
#   - A built-in self-test (`--self-test`, also executed once per real run unless
#     VERIFY_SELFTEST=1) proves the fail-on-skip/skip-reporting behaviour itself.
#   - Command paths marked [TODO-VERIFY] must be confirmed against the merged repo by T5.
#
# Exit codes: 0 pass, 1 failed / skip-not-allowed / self-test failure, 2 bad usage.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE=""
DRY_RUN=0
ALLOW_SKIP=""
REPO_ARG=""
PASS=0
FAIL=0
SKIP=0
FAILED_STEPS=()
SKIPPED_STEPS=()

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --static) MODE="static"; shift ;;
    --ci) MODE="ci"; shift ;;
    --fast) MODE="fast"; shift ;;
    --full) MODE="full"; shift ;;
    --list) MODE="list"; shift ;;
    --self-test) MODE="self-test"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --allow-skip=*) ALLOW_SKIP="${1#--allow-skip=}"; shift ;;
    --repo=*) REPO_ARG="${1#--repo=}"; shift ;;
    --repo) shift; [ $# -gt 0 ] || { echo "verify.sh: --repo needs a path" >&2; exit 2; }; REPO_ARG="$1"; shift ;;
    -h|--help) usage ;;
    *) echo "verify.sh: unknown argument: $1" >&2; usage ;;
  esac
done
[ -n "$MODE" ] || usage

log()  { printf '%s\n' "$*"; }
info() { printf '\033[36m[verify]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[verify]\033[0m %s\n' "$*"; }
pass_info() { printf '\033[32m[verify]\033[0m %s\n' "$*"; }

resolve_repo() {
  local candidates=()
  [ -n "$REPO_ARG" ] && candidates+=("$REPO_ARG")
  [ -n "${DSH_REPO:-}" ] && candidates+=("$DSH_REPO")
  candidates+=("$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)")                    # <repo>/scripts -> repo
  candidates+=("$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd)")                # <repo> (if scripts nested)
  candidates+=("$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd)/repo")            # legacy: <root>/scripts + <root>/repo
  candidates+=("$(cd "$SCRIPT_DIR/../../.." 2>/dev/null && pwd)/repo")        # legacy: <root>/legacy/scripts + <root>/repo
  candidates+=("$PWD")
  for c in "${candidates[@]}"; do
    if [ -n "$c" ] && [ -f "$c/app/pubspec.yaml" ] && [ -d "$c/.github" ]; then
      printf '%s' "$(cd "$c" && pwd)"; return 0
    fi
  done
  return 1
}

have() { command -v "$1" >/dev/null 2>&1; }

run_step() {
  # run_step <tier> <name> <guard-path-or-empty> <command-string>
  local tier="$1" name="$2" guard="$3" cmd="$4"
  if [ "$MODE" = "list" ]; then
    log "[$tier] $name :: $cmd"
    return 0
  fi
  if [ -n "$guard" ] && [ ! -e "$REPO/$guard" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      warn "[dry-run] [$tier] $name — SKIP (missing: $guard)"
      return 0
    fi
    SKIP=$((SKIP+1)); SKIPPED_STEPS+=("$name (missing: $guard)")
    warn "SKIP  [$tier] $name — missing: $guard"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] [$tier] $name — would run: $cmd"
    return 0
  fi
  info "[$tier] $name"
  if ( cd "$REPO" && eval "$cmd" ); then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); FAILED_STEPS+=("$name")
    warn "FAIL  [$tier] $name"
  fi
}

run_step_need_cmd() {
  # Same as run_step but guards on a required command instead of a repo path.
  local tier="$1" name="$2" bin="$3" cmd="$4"
  if [ "$MODE" = "list" ]; then log "[$tier] $name :: $cmd"; return 0; fi
  if ! have "$bin"; then
    if [ "$DRY_RUN" = "1" ]; then
      warn "[dry-run] [$tier] $name — SKIP (missing command: $bin)"
      return 0
    fi
    SKIP=$((SKIP+1)); SKIPPED_STEPS+=("$name (missing command: $bin)")
    warn "SKIP  [$tier] $name — command not found: $bin"
    return 0
  fi
  run_step "$tier" "$name" "" "$cmd"
}

run_step_skip4() {
  # Like run_step, but a command exiting 4 means "SKIP: <reason printed by the command>".
  local tier="$1" name="$2" guard="$3" cmd="$4"
  if [ "$MODE" = "list" ]; then log "[$tier] $name :: $cmd"; return 0; fi
  if [ -n "$guard" ] && [ ! -e "$REPO/$guard" ]; then
    if [ "$DRY_RUN" = "1" ]; then warn "[dry-run] [$tier] $name — SKIP (missing: $guard)"; return 0; fi
    SKIP=$((SKIP+1)); SKIPPED_STEPS+=("$name (missing: $guard)")
    warn "SKIP  [$tier] $name — missing: $guard"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then log "[dry-run] [$tier] $name — would run: $cmd"; return 0; fi
  info "[$tier] $name"
  local out rc logfile=""
  if [ -n "${VERIFY_STEP_LOG_DIR:-}" ]; then
    mkdir -p "$VERIFY_STEP_LOG_DIR" 2>/dev/null || true
    logfile="$VERIFY_STEP_LOG_DIR/$(printf '%s' "$name" | tr ' /()' '____').log"
  fi
  out="$( cd "$REPO" && eval "$cmd" 2>&1 )"; rc=$?
  if [ -n "$logfile" ]; then
    printf '%s\n' "$out" >"$logfile" 2>/dev/null && info "log: $logfile"
  fi
  if [ "$rc" -eq 4 ]; then
    SKIP=$((SKIP+1)); SKIPPED_STEPS+=("$name ($(printf '%s' "$out" | tail -n 1))")
    warn "SKIP  [$tier] $name — $(printf '%s' "$out" | tail -n 1)"
  elif [ "$rc" -eq 0 ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); FAILED_STEPS+=("$name")
    printf '%s\n' "$out" | tail -n 20
    warn "FAIL  [$tier] $name"
  fi
}

# --------------------------------------------------------------------------- self-test
# Proves that the script itself cannot report "all green" when checks are skipped,
# and that repo-layout detection works for both normal and legacy layouts.
run_self_test() {
  if [ "${VERIFY_SELFTEST:-0}" = "1" ]; then
    return 0   # nested run spawned by run_self_test; do not recurse
  fi
  info "self-test: fail-on-skip + layout detection"
  local tmp fail=0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/verify-selftest.XXXXXX")" || { warn "self-test: mktemp failed"; return 1; }
  # Restricted PATH: node/python3 available, flutter/dart deliberately absent.
  local node_dir py_dir restricted
  node_dir="$(dirname "$(command -v node 2>/dev/null || echo /nonexistent/node)")"
  py_dir="$(dirname "$(command -v python3 2>/dev/null || echo /nonexistent/python3)")"
  restricted="$node_dir:$py_dir:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"

  # Fake repo (normal layout): scripts/verify.sh + app/pubspec.yaml + .github/
  mkdir -p "$tmp/repo/app" "$tmp/repo/.github" "$tmp/repo/scripts" "$tmp/repo/test/fixtures"
  printf 'name: app\n' > "$tmp/repo/app/pubspec.yaml"
  cp "$SCRIPT_DIR/verify.sh" "$tmp/repo/scripts/verify.sh"
  cp "$SCRIPT_DIR/../test/fixtures/mock_model_server.mjs" "$tmp/repo/test/fixtures/mock_model_server.mjs" 2>/dev/null || true

  # 1) --list detects the repo and does not execute anything.
  if env -i PATH="$restricted" HOME="$HOME" VERIFY_SELFTEST=1 bash "$tmp/repo/scripts/verify.sh" --list > "$tmp/list.out" 2>&1; then
    list_repo="$(sed -n 's/.*repo: //p' "$tmp/list.out" 2>/dev/null | head -1)"
    if [ -n "$list_repo" ] && [ "$(cd "$list_repo" 2>/dev/null && pwd -P)" = "$(cd "$tmp/repo" && pwd -P)" ]; then
      pass_info "PASS self-test: --list detects repo"
    else
      warn "FAIL self-test: --list detected wrong repo ($list_repo)"; fail=1
    fi
  else
    warn "FAIL self-test: --list did not detect repo"; fail=1
    sed -n '1,20p' "$tmp/list.out" 2>/dev/null | sed 's/^/  selftest: /' >&2
  fi
  # 2) --static with missing flutter/dart must fail (fail-on-skip), not exit 0.
  if env -i PATH="$restricted" HOME="$HOME" VERIFY_SELFTEST=1 bash "$tmp/repo/scripts/verify.sh" --static > "$tmp/static.out" 2>&1; then
    warn "FAIL self-test: --static exited 0 while checks were skipped"; fail=1
  else
    if grep -q "skip" "$tmp/static.out"; then
      pass_info "PASS self-test: --static fails on skip"
    else
      warn "FAIL self-test: --static failed without skip report"; fail=1
    fi
  fi
  # 3) --static --allow-skip=<reason> may exit 0 (explicit, reported).
  if env -i PATH="$restricted" HOME="$HOME" VERIFY_SELFTEST=1 bash "$tmp/repo/scripts/verify.sh" --static --allow-skip=selftest > "$tmp/allow.out" 2>&1; then
    pass_info "PASS self-test: --allow-skip is explicit"
  else
    warn "FAIL self-test: --allow-skip did not allow skips (or a real check failed)"; fail=1
  fi
  # 4) --dry-run prints guard status without executing.
  if env -i PATH="$restricted" HOME="$HOME" VERIFY_SELFTEST=1 bash "$tmp/repo/scripts/verify.sh" --static --dry-run > "$tmp/dry.out" 2>&1 \
     && grep -q "dry-run" "$tmp/dry.out"; then
    pass_info "PASS self-test: --dry-run reports guard status"
  else
    warn "FAIL self-test: --dry-run output missing"; fail=1
  fi
  # 5) legacy side-by-side layout: <tmp>/legacy/scripts/verify.sh + <tmp>/repo (auto-detect, no --repo)
  mkdir -p "$tmp/legacy/scripts"
  cp "$SCRIPT_DIR/verify.sh" "$tmp/legacy/scripts/verify.sh"
  if env -i PATH="$restricted" HOME="$HOME" VERIFY_SELFTEST=1 bash "$tmp/legacy/scripts/verify.sh" --list > "$tmp/legacy.out" 2>&1; then
    legacy_repo="$(sed -n 's/.*repo: //p' "$tmp/legacy.out" 2>/dev/null | head -1)"
    if [ -n "$legacy_repo" ] && [ "$(cd "$legacy_repo" 2>/dev/null && pwd -P)" = "$(cd "$tmp/repo" && pwd -P)" ]; then
      pass_info "PASS self-test: legacy layout auto-detection (no --repo)"
    else
      warn "FAIL self-test: legacy detected wrong repo ($legacy_repo)"; fail=1
    fi
  else
    warn "FAIL self-test: legacy layout auto-detection"; fail=1
    sed -n '1,20p' "$tmp/legacy.out" 2>/dev/null | sed 's/^/  selftest: /' >&2
  fi
  rm -rf "$tmp"
  if [ "$fail" -ne 0 ]; then
    FAIL=$((FAIL+1)); FAILED_STEPS+=("verify.sh self-test")
    return 1
  fi
  return 0
}

if [ "$MODE" = "self-test" ]; then
  if run_self_test; then
    info "self-test: PASS"; exit 0
  else
    info "self-test: FAIL"; exit 1
  fi
fi

REPO="$(resolve_repo || true)"

# --------------------------------------------------------------------------- no-repo fallback (migration only)
if [ -z "$REPO" ]; then
  if [ "$MODE" = "fast" ] || [ "$MODE" = "full" ] || [ "$MODE" = "static" ]; then
    echo "verify.sh: repo not found (need app/pubspec.yaml + .github). Pass --repo PATH or set DSH_REPO." >&2
    exit 2
  fi
  info "repo not found — listing only"
  exit 0
fi

info "repo: $REPO"
info "mode: --$MODE"
[ -n "$ALLOW_SKIP" ] && info "allow-skip: $ALLOW_SKIP"

# ---- iOS Simulator resolution (--full) -------------------------------------
# Names are resolved to UDIDs because a machine can have more than one simulator
# with the same name (e.g. a duplicated iPhone 17 Pro); flutter/xcodebuild both
# become ambiguous by name. DSH_SIM_17PRO / DSH_SIM_SE3 override the choice.
sim_udid() {
  have xcrun || return 0
  have python3 || return 0
  xcrun simctl list devices available -j 2>/dev/null | python3 -c '
import json, sys
name = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
for runtime, rows in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for row in rows:
        if row.get("name") == name and row.get("isAvailable", True):
            print(row.get("udid", ""))
            raise SystemExit(0)
' "$1"
}
if [ "$MODE" = "full" ] || [ "$MODE" = "list" ]; then
  IOS_SIM_17PRO="${DSH_SIM_17PRO:-$(sim_udid "iPhone 17 Pro")}"
  IOS_SIM_SE3="${DSH_SIM_SE3:-$(sim_udid "iPhone SE3")}"
  info "simulators: iPhone 17 Pro=${IOS_SIM_17PRO:-<not found>} iPhone SE3=${IOS_SIM_SE3:-<not found>}"
else
  IOS_SIM_17PRO=""
  IOS_SIM_SE3=""
fi
export IOS_SIM_17PRO IOS_SIM_SE3

# ---- L0 static -------------------------------------------------------------
run_step_need_cmd static "flutter analyze" flutter \
  'cd app && flutter analyze --no-pub'
run_step_need_cmd static "dart analyze packages" dart \
  'for p in packages/*/pubspec.yaml; do d="$PWD/$(dirname "$p")"; (cd "$d" && dart analyze) || exit 1; done'
run_step static "l10n sync (--check)" "app/tool/l10n_merge.py" \
  'python3 app/tool/l10n_merge.py --check'
run_step static "user guide sync (--check)" "app/tool/guide_sync.py" \
  'python3 app/tool/guide_sync.py --check'
run_step static "plugin skill sync (--check)" "sdk/plugin-kit/scripts/sync-skill.mjs" \
  'node sdk/plugin-kit/scripts/sync-skill.mjs --check'
run_step static "mock model self-test" "test/fixtures/mock_model_server.mjs" \
  'node test/fixtures/mock_model_server.mjs --self-test'
run_step static "node syntax check (phase1 tests)" "test" \
  'for f in $(find test -name "*.mjs" -not -path "*/fixtures/*"); do node --check "$f" || exit 1; done'
# Swift typecheck is cheap only with Xcode; --full's xcodebuild build covers it.

# ---- L1/L2 fast ------------------------------------------------------------
if [ "$MODE" = "ci" ] || [ "$MODE" = "fast" ] || [ "$MODE" = "full" ] || [ "$MODE" = "list" ]; then
  # Phase 1 test dirs land in T7+; until then report SKIP (never a silent pass).
  run_step_skip4 fast "flutter test (phase1 dirs)" "test" \
    'cd app && FONT="${DSH_TEST_FONT_DIR:-/usr/share/fonts/opentype/noto}/NotoSansCJK-Light.ttc"; { [ -f "$FONT" ] || [ -f /usr/share/fonts/noto-cjk/NotoSansCJK-Light.ttc ]; } || { echo "SKIP: CJK test font missing (set DSH_TEST_FONT_DIR; upstream ci.yml installs fonts-noto-cjk)"; exit 4; }; found=0; for d in test/phase1 test/chat/phase1 test/engine/phase1 test/files/phase1; do if [ -d "$d" ]; then found=1; flutter test --no-pub "$d" || exit 1; fi; done; [ "$found" = 1 ] || { echo "SKIP: no Phase 1 test dirs (test/phase1, test/chat/phase1, test/engine/phase1, test/files/phase1)"; exit 4; }'
  run_step_need_cmd fast "dart test packages" dart \
    'for p in packages/*/pubspec.yaml; do d="$PWD/$(dirname "$p")"; (cd "$d" && dart pub get --offline >/dev/null 2>&1 || dart pub get >/dev/null && dart test) || exit 1; done'
  run_step fast "node --test test/unit" "test/unit" \
    'node --test test/unit/*.test.mjs'
fi

# ---- tooling gates (--ci/--fast/--full) ------------------------------------
if [ "$MODE" = "ci" ] || [ "$MODE" = "fast" ] || [ "$MODE" = "full" ] || [ "$MODE" = "list" ]; then
  # Official cheap gates from ios-compile.yml (no Xcode needed except host-core.py --ios
  # is a python compiler probe; it does not link against Xcode).
  run_step ci "official: guest-embedding fixture" "tooling/ios/test-guest-embedding.py" \
    'python3 -B tooling/ios/test-guest-embedding.py -v'
  run_step ci "official: native loader checks" "tooling/ios/test-native-loader.py" \
    'python3 -B tooling/ios/test-native-loader.py -v'
  run_step ci "official: host-core iOS/HAP generation" "runtime/tests/ohos/host-core.py" \
    'd="$(mktemp -d)"; python3 -B runtime/tests/ohos/host-core.py --ios --out "$d/ios" && python3 -B runtime/tests/ohos/host-core.py --out "$d/hap"'
fi

# ---- L3/L4 full ------------------------------------------------------------
if [ "$MODE" = "full" ] || [ "$MODE" = "list" ]; then
  # Official Flutter subset (heavy; D5=(a) subset + exclude goldens). Moved from --fast to
  # --full in T5 so --ci stays a quick Linux/PR gate; upstream ci.yml still runs the full suite.
  # Goldens are generated against Linux font rendering and cannot match on
  # macOS (verification-baseline.md §5 TODO, test-plan §6 "排除 goldens"). Some
  # files mix behavioural and golden tests and a golden's test name does not
  # always say so, so whole files that reference matchesGoldenFile are left out
  # of this macOS/Linux-agnostic subset; the Phase 1 behavioural suites stay in
  # --fast and the golden-bearing files are listed in reports/T22.
  # stop_reconnect_test is timing-sensitive when dozens of test isolates run at
  # once (P12 B1/B2 failed under the full-suite load but pass alone, 3/3); it
  # runs in its own process in the next step instead of being dropped.
  run_step_skip4 full "flutter test (official phase1-related subset, goldens excluded)" "app/test" \
    'cd app && FONT="${DSH_TEST_FONT_DIR:-/usr/share/fonts/opentype/noto}/NotoSansCJK-Light.ttc"; { [ -f "$FONT" ] || [ -f /usr/share/fonts/noto-cjk/NotoSansCJK-Light.ttc ]; } || { echo "SKIP: CJK test font missing (set DSH_TEST_FONT_DIR; upstream ci.yml installs fonts-noto-cjk)"; exit 4; }; files="$(find test/chat test/session test/files test/remote test/engine test/runtime -name "*_test.dart" ! -name "*_golden_test.dart" 2>/dev/null | sort)"; [ -n "$files" ] || { echo "SKIP: no official subset test files"; exit 4; }; files="$(printf "%s\n" "$files" | xargs grep -L "matchesGoldenFile" 2>/dev/null | sort)"; files="$(printf "%s\n" "$files" | grep -v "^test/chat/stop_reconnect_test.dart$" | sort)"; [ -n "$files" ] || { echo "SKIP: no non-golden official subset files"; exit 4; }; flutter test --no-pub $files'
  run_step_skip4 full "flutter test (stop/reconnect timing suite, isolated)" "app/test/chat/stop_reconnect_test.dart" \
    'cd app && FONT="${DSH_TEST_FONT_DIR:-/usr/share/fonts/opentype/noto}/NotoSansCJK-Light.ttc"; { [ -f "$FONT" ] || [ -f /usr/share/fonts/noto-cjk/NotoSansCJK-Light.ttc ]; } || { echo "SKIP: CJK test font missing (set DSH_TEST_FONT_DIR; upstream ci.yml installs fonts-noto-cjk)"; exit 4; }; flutter test --no-pub test/chat/stop_reconnect_test.dart'
  run_step_need_cmd full "xcodebuild build (simulator)" xcodebuild \
    'cd app && DSH_IOS_GUEST_BUILD=0 bash ../tooling/ios/build.sh --simulator --debug'
  run_step_need_cmd full "xcodebuild build (device, unsigned)" xcodebuild \
    'cd app && DSH_IOS_GUEST_BUILD=0 bash ../tooling/ios/build.sh --release --no-codesign'
  # NativeToolsTests/testSystemTools needs the system Reminders/Contacts/
  # Location permission sheets and tools; Phase 1 marks those D6 capabilities
  # deferred (verification-baseline.md §3 #33/#35/#37, §5). Excluded explicitly
  # here, never silently: every other official suite still runs.
  run_step_need_cmd full "RunnerTests (official contract suites; deferred system-tools case excluded)" xcodebuild \
    'cd app && dest="${IOS_SIM_17PRO:+id=$IOS_SIM_17PRO}"; DSH_IOS_GUEST_BUILD=0 xcodebuild test -workspace ios/Runner.xcworkspace -scheme Runner -destination "platform=iOS Simulator,${dest:-name=iPhone 17 Pro}" -only-testing:RunnerTests -skip-testing:RunnerTests/NativeToolsTests/testSystemTools CODE_SIGNING_ALLOWED=NO'
  run_step_skip4 full "integration_test phase1 (iPhone 17 Pro, canonical mock)" "app/integration_test/phase1_test.dart" \
    'bash app/integration_test/run_phase1_e2e.sh --device "${IOS_SIM_17PRO:-iPhone 17 Pro}"'
  run_step_skip4 full "integration_test phase1 (iPhone SE3, canonical mock)" "app/integration_test/phase1_test.dart" \
    'bash app/integration_test/run_phase1_e2e.sh --device "${IOS_SIM_SE3:-iPhone SE3}"'
  # [TODO-VERIFY(T5)] exact engine-smoke args (drive.mjs needs simulator/smoke/frameworks/runtime/work/ws);
  # T5 creates test/fixtures/run_engine_smoke.sh wrapper and wires it here.
  run_step full "official engine smoke (real engine + mock model)" "test/fixtures/run_engine_smoke.sh" \
    'bash test/fixtures/run_engine_smoke.sh'
  # Phase 1 defers iSH (plan §1; verification-baseline.md §5), and
  # check-archive.sh requires DshGuest.framework/DshGuestBridge.framework plus
  # their source/license notices, which only a guest build produces. The step
  # reports an explicit SKIP instead of a false pass or an unexplained failure;
  # run --full with --allow-skip="Phase 1 iSH guest deferred: check-archive
  # needs DshGuest" so the deferral is recorded. RUNNER_TEMP is a GitHub
  # Actions variable, so a local run gets a temp directory of its own.
  run_step_skip4 full "archive shape check (deferred: iSH guest)" "tooling/ios/check-archive.sh" \
    'if [ ! -d app/ios/Engine/build/iphoneos/guest/DshGuest.framework ]; then echo "SKIP: Phase 1 defers the iSH guest; check-archive.sh requires DshGuest.framework (Phase 2, see verification-baseline.md §5)"; exit 4; fi; export RUNNER_TEMP="${RUNNER_TEMP:-$(mktemp -d)}"; bash tooling/ios/check-archive.sh'
  # Guest tests: DEFERRED for Phase 1 (iSH not built); not listed so --full has no always-failing step.
fi

# Built-in self-check: proves fail-on-skip works (skipped in nested self-test runs).
if [ "$MODE" = "static" ] || [ "$MODE" = "ci" ] || [ "$MODE" = "fast" ] || [ "$MODE" = "full" ]; then
  run_self_test || true
fi

# --------------------------------------------------------------------------- summary
echo
info "summary: pass=$PASS fail=$FAIL skip=$SKIP"
if [ "${#FAILED_STEPS[@]}" -gt 0 ]; then
  warn "failed: ${FAILED_STEPS[*]}"
fi
if [ "${#SKIPPED_STEPS[@]}" -gt 0 ]; then
  warn "skipped: ${SKIPPED_STEPS[*]}"
fi
if [ "$DRY_RUN" = "1" ]; then
  info "dry-run only: nothing was executed"; exit 0
fi
if [ "$FAIL" -gt 0 ]; then exit 1; fi
if [ "$MODE" != "list" ] && [ "$PASS" -eq 0 ]; then
  warn "no checks actually ran (pass=0); refusing to report green"
  exit 1
fi
if [ "$SKIP" -gt 0 ] && [ -z "$ALLOW_SKIP" ]; then
  warn "skips are not allowed without --allow-skip=REASON (plan §7.1)"
  exit 1
fi
[ "$SKIP" -gt 0 ] && warn "skips allowed by caller: $ALLOW_SKIP"
exit 0
