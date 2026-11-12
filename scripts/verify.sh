#!/usr/bin/env bash
# Phase 1 verification entry point (v1.1 gates).
#
# Usage:
#   scripts/verify.sh --static [--repo PATH] [--dry-run] [--allow-skip=REASON]
#   scripts/verify.sh --ci     (Linux CI: static + fast + tooling gates; no Xcode/simulator)
#   scripts/verify.sh --fast [--dry-run]
#   scripts/verify.sh --full [--dry-run] [--allow-skip=REASON]
#   scripts/verify.sh --real [--dry-run]
#   scripts/verify.sh --remote [--dry-run]
#   scripts/verify.sh --guest [--dry-run]
#   scripts/verify.sh --list [--repo PATH] [--static|--ci|--fast|--full|--real|--remote|--guest]
#   scripts/verify.sh --self-test
#
# Modes (see docs/specs/phase1/test-plan.md §6, verification-baseline.md §1.1):
#   --static : L0 — flutter analyze, dart analyze, l10n/guide/skill sync checks,
#                   Node syntax checks, mock-model self-test
#   --ci     : --static + --fast + tooling gates (guest-embedding / native-loader /
#                   host-core); everything a Linux runner can do without Xcode
#   --fast   : --static + L1/L2 — flutter test on the Phase 1 dirs
#                   (test/phase1, test/chat/phase1, test/engine/phase1,
#                   test/files/phase1), dart test, node --test test/unit
#   --full   : skip-free deterministic gate: --ci + L3 RunnerTests (every suite,
#                   serial, after simulator privacy/location grants; no
#                   -skip-testing) + all 27 golden-bearing files (macOS baselines
#                   via the platform comparator) + L4 integration_test/phase1_test.dart
#                   on iPhone 17 Pro & iPhone SE3 (canonical mock model) +
#                   Phase1UITests (installed Runner.app, 17 Pro) + build
#                   (simulator + device unsigned) + official engine smoke. The iSH
#                   archive check is NOT part of --full; no --allow-skip is needed.
#   --real   : real opencode-go model via the loopback credential broker:
#                   scripts/e2e/real_provider_smoke.sh, then the real L4 wrappers
#                   under scripts/e2e/ios/ (workspace, approval, chat features,
#                   cold start, SSH, DSH Remote). Needs OPENCODE_GO_API_KEY or
#                   refs.OPENCODE_GO_API_KEY in ~/.dsh/.credentials.yaml.
#   --remote : real local transport acceptance: run_live_ssh.sh +
#                   run_workspace_live.sh + relay_stack.sh self-test +
#                   run_ssh_real.sh + run_remote_real.sh (17 Pro).
#   --guest  : opt-in Phase 2 iSH archive shape check
#                   (tooling/ios/check-archive.sh) for a prepared guest build.
#                   Missing DshGuest/DshGuestBridge build artifacts FAIL.
#   --list   : print the selected plan (all tiers when no mode is given) without
#                   executing or checking prerequisites.
#   --dry-run: print the selected plan and guard state without executing.
#   --self-test: prove fail-on-skip/fail-closed behaviour, layout detection and
#                   the --full/--guest/--real/--remote plans.
#
# Behaviour:
#   - Locates the repo from $DSH_REPO, the parent of scripts/ (normal checkout),
#     or a sibling ../repo (legacy side-by-side layout kept for migration runs).
#   - --full is skip-free: a missing CJK test font FAILS the Flutter steps and
#     every integration step is a required step (exit 4 is a failure, not a pass).
#   - --real/--remote/--guest never SKIP: a missing key, credential, command,
#     network dependency or wrapper is a FAIL (also with --allow-skip).
#   - Each executed --real/--remote/--guest step logs its output under
#     $DSH_VERIFY_EVIDENCE_DIR (default <repo>/reports/phase1-completion/T35b)
#     with a generous per-step timeout (VERIFY_STEP_TIMEOUT, default 7200 s).
#   - --allow-skip=REASON remains for static/ci/fast/full migration windows only;
#     ANY skip fails those modes unless it is given.
#   - PASS == 0 in an executing mode is also a failure ("no assertions ran"
#     cannot be green).
#   - A built-in self-test (`--self-test`, also executed once per executing run
#     unless VERIFY_SELFTEST=1) proves the fail-on-skip/skip-reporting behaviour.
#
# Exit codes: 0 pass, 1 failed / skip-not-allowed / self-test failure, 2 bad usage.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE=""
LIST=0
DRY_RUN=0
ALLOW_SKIP=""
REPO_ARG=""
PASS=0
FAIL=0
SKIP=0
FAILED_STEPS=()
SKIPPED_STEPS=()

usage() {
  sed -n '2,/^set -uo pipefail$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --static) MODE="static"; shift ;;
    --ci) MODE="ci"; shift ;;
    --fast) MODE="fast"; shift ;;
    --full) MODE="full"; shift ;;
    --real) MODE="real"; shift ;;
    --remote) MODE="remote"; shift ;;
    --guest) MODE="guest"; shift ;;
    --list) LIST=1; shift ;;
    --self-test) MODE="self-test"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --allow-skip=*) ALLOW_SKIP="${1#--allow-skip=}"; shift ;;
    --repo=*) REPO_ARG="${1#--repo=}"; shift ;;
    --repo) shift; [ $# -gt 0 ] || { echo "verify.sh: --repo needs a path" >&2; exit 2; }; REPO_ARG="$1"; shift ;;
    -h|--help) usage ;;
    *) echo "verify.sh: unknown argument: $1" >&2; usage ;;
  esac
done
if [ -z "$MODE" ]; then
  if [ "$LIST" = "1" ]; then MODE="list"; else usage; fi
fi

log()  { printf '%s\n' "$*"; }
info() { printf '\033[36m[verify]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[verify]\033[0m %s\n' "$*"; }
pass_info() { printf '\033[32m[verify]\033[0m %s\n' "$*"; }

listing() { [ "$LIST" = "1" ] || [ "$MODE" = "list" ]; }
mode_in() {
  local m
  for m in "$@"; do [ "$MODE" = "$m" ] && return 0; done
  return 1
}

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
  if listing; then
    log "[$tier] $name :: $cmd"
    return 0
  fi
  if [ -n "$guard" ] && [ ! -e "$REPO/$guard" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      warn "[dry-run] [$tier] $name — SKIP (missing: $guard)"
      return 0
    fi
    if [ "$MODE" = "full" ]; then
      FAIL=$((FAIL+1)); FAILED_STEPS+=("$name (missing: $guard)")
      warn "FAIL  [$tier] $name — missing required path: $guard (--full is skip-free)"
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
  if listing; then log "[$tier] $name :: $cmd"; return 0; fi
  if ! have "$bin"; then
    if [ "$DRY_RUN" = "1" ]; then
      warn "[dry-run] [$tier] $name — SKIP (missing command: $bin)"
      return 0
    fi
    if [ "$MODE" = "full" ]; then
      FAIL=$((FAIL+1)); FAILED_STEPS+=("$name (missing command: $bin)")
      warn "FAIL  [$tier] $name — command not found: $bin (--full is skip-free)"
      return 0
    fi
    SKIP=$((SKIP+1)); SKIPPED_STEPS+=("$name (missing command: $bin)")
    warn "SKIP  [$tier] $name — command not found: $bin"
    return 0
  fi
  run_step "$tier" "$name" "" "$cmd"
}

run_step_required() {
  # T35b real/remote/guest runner: every prerequisite is hard, so a missing
  # guard or a non-zero exit (including 4) is a FAIL, never a SKIP. Output is
  # always logged under $STEP_LOG_DIR; the per-step timeout is generous.
  local tier="$1" name="$2" guard="$3" cmd="$4" timeout="${5:-${VERIFY_STEP_TIMEOUT:-7200}}"
  if listing; then log "[$tier] $name :: $cmd"; return 0; fi
  if [ "$DRY_RUN" = "1" ]; then log "[dry-run] [$tier] $name — would run: $cmd"; return 0; fi
  if [ -n "$guard" ] && [ ! -e "$REPO/$guard" ]; then
    FAIL=$((FAIL+1)); FAILED_STEPS+=("$name (missing: $guard)")
    warn "FAIL  [$tier] $name — missing required path: $guard (never skipped)"
    return 0
  fi
  info "[$tier] $name"
  local logfile="" flag="" pid watch rc timed_out=0
  if [ -n "$STEP_LOG_DIR" ]; then
    mkdir -p "$STEP_LOG_DIR" 2>/dev/null || true
    logfile="$STEP_LOG_DIR/$(printf '%s' "$name" | tr ' /()' '____').log"
    flag="$logfile.timeout"
    rm -f "$flag"
  fi
  if [ -n "$logfile" ]; then
    ( cd "$REPO" && eval "$cmd" ) >"$logfile" 2>&1 &
  else
    ( cd "$REPO" && eval "$cmd" ) >/dev/null 2>&1 &
  fi
  pid=$!
  (
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
      sleep 1
      waited=$((waited+1))
      if [ "$waited" -ge "$timeout" ]; then
        [ -n "$flag" ] && : > "$flag"
        kill -TERM "$pid" 2>/dev/null || true
        command -v pkill >/dev/null 2>&1 && pkill -TERM -P "$pid" 2>/dev/null || true
        sleep 5
        kill -KILL "$pid" 2>/dev/null || true
        command -v pkill >/dev/null 2>&1 && pkill -KILL -P "$pid" 2>/dev/null || true
        break
      fi
    done
  ) &
  watch=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill "$watch" 2>/dev/null || true
  wait "$watch" 2>/dev/null || true
  if [ -n "$flag" ] && [ -f "$flag" ]; then timed_out=1; rm -f "$flag"; fi
  if [ "$timed_out" = "1" ]; then
    FAIL=$((FAIL+1)); FAILED_STEPS+=("$name (timeout ${timeout}s)")
    warn "FAIL  [$tier] $name — timed out after ${timeout}s"
    if [ -n "$logfile" ]; then info "log: $logfile"; tail -n 20 "$logfile" 2>/dev/null; fi
  elif [ "$rc" -eq 0 ]; then
    PASS=$((PASS+1))
    [ -n "$logfile" ] && info "log: $logfile"
  else
    FAIL=$((FAIL+1)); FAILED_STEPS+=("$name")
    warn "FAIL  [$tier] $name"
    if [ -n "$logfile" ]; then info "log: $logfile"; tail -n 30 "$logfile" 2>/dev/null; fi
  fi
}

# --------------------------------------------------------------------------- real/remote/guest prereqs

resolve_flutter_path() {
  if have flutter; then command -v flutter; return 0; fi
  if [ -x "${HOME:-/nonexistent}/tools/flutter/bin/flutter" ]; then
    printf '%s\n' "${HOME}/tools/flutter/bin/flutter"; return 0
  fi
  return 1
}

resolve_dsh_path() {
  if have dsh; then command -v dsh; return 0; fi
  if [ -x "${HOME:-/nonexistent}/.local/bin/dsh" ]; then
    printf '%s\n' "${HOME}/.local/bin/dsh"; return 0
  fi
  return 1
}

# The real key is never printed here: the shared E2E helper decides whether the
# env var or refs.OPENCODE_GO_API_KEY exists; only its exit status is used.
real_credentials_available() {
  [ -n "${OPENCODE_GO_API_KEY:-}" ] && return 0
  local file="${CREDENTIALS_FILE:-${HOME:-/nonexistent}/.dsh/.credentials.yaml}"
  [ -r "$file" ] || return 1
  [ -f "$REPO/scripts/e2e/lib.sh" ] || return 1
  ( . "$REPO/scripts/e2e/lib.sh" >/dev/null 2>&1 && read_credentials_key "$file" >/dev/null 2>&1 )
}

REAL_L4_WRAPPERS="run_workspace_real.sh run_approval_real.sh run_chat_features_real.sh run_cold_start_real.sh run_ssh_real.sh run_remote_real.sh"

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
  # ---- T35b: --full is skip-free, --guest is opt-in, --real/--remote fail
  # closed. These use only list/dry-run and stubbed wrappers, so the self-test
  # never starts a simulator, a model request or a real ssh/relay stack.
  mkdir -p "$tmp/home" "$tmp/repo/app/test/chat" "$tmp/repo/app/integration_test" \
    "$tmp/repo/app/ios/Runner.xcodeproj/xcshareddata/xcschemes" \
    "$tmp/repo/test/fixtures" "$tmp/repo/tooling/ios" "$tmp/repo/scripts/e2e/ios" \
    "$tmp/repo/scripts/e2e/remote"
  : > "$tmp/repo/app/integration_test/phase1_test.dart"
  : > "$tmp/repo/app/test/chat/stop_reconnect_test.dart"
  : > "$tmp/repo/test/fixtures/run_engine_smoke.sh"
  : > "$tmp/repo/app/ios/Runner.xcodeproj/xcshareddata/xcschemes/Phase1UITests.xcscheme"
  printf '#!/usr/bin/env bash\nprintf "guest\\n" >> "%s/ran-guest.log"\nexit 0\n' "$tmp/repo" \
    > "$tmp/repo/tooling/ios/check-archive.sh"

  # 6) --full has no always-SKIP archive step, no RunnerTests filter and runs
  #    the 27 golden-bearing files plus Phase1UITests.
  if env -i PATH="$restricted" HOME="$HOME" VERIFY_SELFTEST=1 bash "$tmp/repo/scripts/verify.sh" --full --list > "$tmp/full-list.out" 2>&1; then
    if grep -qiE 'check-archive|DshGuest|archive shape' "$tmp/full-list.out"; then
      warn "FAIL self-test: --full still lists the iSH archive step"; fail=1
    elif ! grep -q 'golden-bearing' "$tmp/full-list.out"; then
      warn "FAIL self-test: --full does not run the golden-bearing files"; fail=1
    elif ! grep -q 'Phase1UITests' "$tmp/full-list.out"; then
      warn "FAIL self-test: --full does not run Phase1UITests"; fail=1
    elif grep -q -- '-skip-testing' "$tmp/full-list.out"; then
      warn "FAIL self-test: --full still filters RunnerTests"; fail=1
    elif ! grep -q -- '-parallel-testing-enabled NO' "$tmp/full-list.out"; then
      warn "FAIL self-test: --full does not run RunnerTests serially"; fail=1
    else
      pass_info "PASS self-test: --full is skip-free (goldens + Phase1UITests, no filter)"
    fi
  else
    warn "FAIL self-test: --full --list failed"; fail=1
    sed -n '1,10p' "$tmp/full-list.out" 2>/dev/null | sed 's/^/  selftest: /' >&2
  fi

  # 7) --full --dry-run has the same skip-free plan (no archive step).
  if env -i PATH="$restricted" HOME="$HOME" VERIFY_SELFTEST=1 bash "$tmp/repo/scripts/verify.sh" --full --dry-run > "$tmp/full-dry.out" 2>&1; then
    if grep -qiE 'check-archive|DshGuest|archive shape' "$tmp/full-dry.out"; then
      warn "FAIL self-test: --full --dry-run still plans the iSH archive"; fail=1
    elif grep -q 'golden-bearing' "$tmp/full-dry.out" && grep -q 'Phase1UITests' "$tmp/full-dry.out"; then
      pass_info "PASS self-test: --full --dry-run parity (goldens + Phase1UITests)"
    else
      warn "FAIL self-test: --full --dry-run misses the new full steps"; fail=1
    fi
  else
    warn "FAIL self-test: --full --dry-run failed"; fail=1
  fi

  # 8) --guest is opt-in and a missing guest build is a FAIL, never a SKIP.
  if env -i PATH="$restricted" HOME="$HOME" VERIFY_SELFTEST=1 bash "$tmp/repo/scripts/verify.sh" --guest --list > "$tmp/guest-list.out" 2>&1 \
     && grep -q 'check-archive.sh' "$tmp/guest-list.out"; then
    pass_info "PASS self-test: --guest is the only mode listing check-archive"
  else
    warn "FAIL self-test: --guest --list does not list check-archive.sh"; fail=1
  fi
  if env -i PATH="$restricted" HOME="$HOME" VERIFY_SELFTEST=1 bash "$tmp/repo/scripts/verify.sh" --guest --dry-run > "$tmp/guest-dry.out" 2>&1 \
     && grep -q 'check-archive.sh' "$tmp/guest-dry.out"; then
    pass_info "PASS self-test: --guest --dry-run parity"
  else
    warn "FAIL self-test: --guest --dry-run does not plan check-archive.sh"; fail=1
  fi
  if env -i PATH="$restricted" HOME="$HOME" VERIFY_SELFTEST=1 bash "$tmp/repo/scripts/verify.sh" --guest > "$tmp/guest-missing.out" 2>&1; then
    warn "FAIL self-test: --guest passed without a guest build"; fail=1
  elif grep -q 'SKIP  \[' "$tmp/guest-missing.out"; then
    warn "FAIL self-test: missing guest build was reported as a skip"; fail=1
  elif grep -qiE 'guest build|DshGuest' "$tmp/guest-missing.out"; then
    pass_info "PASS self-test: --guest fails (not skips) without a guest build"
  else
    warn "FAIL self-test: --guest missing build had no guest diagnostic"; fail=1
  fi

  # 9) --real without a key fails; it must not fall back to a skip.
  if env -i PATH="$restricted" HOME="$tmp/home" VERIFY_SELFTEST=1 bash "$tmp/repo/scripts/verify.sh" --real > "$tmp/real-nokey.out" 2>&1; then
    warn "FAIL self-test: --real passed without a key"; fail=1
  elif grep -q 'SKIP  \[' "$tmp/real-nokey.out"; then
    warn "FAIL self-test: --real missing key was reported as a skip"; fail=1
  elif grep -q 'OPENCODE_GO_API_KEY' "$tmp/real-nokey.out"; then
    pass_info "PASS self-test: --real fails (not skips) without a key"
  else
    warn "FAIL self-test: --real missing-key diagnostic absent"; fail=1
  fi

  # 10) --real wires the smoke plus the six real L4 wrappers, and --list and
  #     --dry-run agree on the plan.
  for w in run_workspace_real.sh run_approval_real.sh run_chat_features_real.sh \
           run_cold_start_real.sh run_ssh_real.sh run_remote_real.sh; do
    {
      printf '#!/usr/bin/env bash\n'
      printf 'printf "%%s\\n" "%s" >> "%s/ran.log"\n' "$w" "$tmp/repo"
      printf 'exit 0\n'
    } > "$tmp/repo/scripts/e2e/ios/$w"
  done
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "real_provider_smoke" >> "%s/ran.log"\n' "$tmp/repo"
    printf 'exit 0\n'
  } > "$tmp/repo/scripts/e2e/real_provider_smoke.sh"
  env -i PATH="$restricted" HOME="$tmp/home" VERIFY_SELFTEST=1 bash "$tmp/repo/scripts/verify.sh" --real --list > "$tmp/real-list.out" 2>&1 || true
  env -i PATH="$restricted" HOME="$tmp/home" VERIFY_SELFTEST=1 bash "$tmp/repo/scripts/verify.sh" --real --dry-run > "$tmp/real-dry.out" 2>&1 || true
  real_list_wrappers="$(grep -o 'run_[a-z_]*_real\.sh' "$tmp/real-list.out" 2>/dev/null | sort -u | wc -l | tr -d ' ')"
  real_dry_wrappers="$(grep -o 'run_[a-z_]*_real\.sh' "$tmp/real-dry.out" 2>/dev/null | sort -u | wc -l | tr -d ' ')"
  if [ "$real_list_wrappers" = 6 ] && [ "$real_dry_wrappers" = 6 ] \
     && grep -q 'real provider smoke' "$tmp/real-list.out" && grep -q 'real provider smoke' "$tmp/real-dry.out"; then
    pass_info "PASS self-test: --real --list/--dry-run parity (smoke + 6 wrappers)"
  else
    warn "FAIL self-test: --real plan parity (list=$real_list_wrappers dry=$real_dry_wrappers)"; fail=1
  fi

  # 11) a missing real wrapper is a hard FAIL even with a key.
  mv "$tmp/repo/scripts/e2e/ios/run_ssh_real.sh" "$tmp/repo/run_ssh_real.sh.saved"
  if env -i PATH="$restricted" HOME="$tmp/home" OPENCODE_GO_API_KEY=selftest VERIFY_SELFTEST=1 bash "$tmp/repo/scripts/verify.sh" --real > "$tmp/real-missing-wrapper.out" 2>&1; then
    warn "FAIL self-test: --real passed with a missing wrapper"; fail=1
  elif grep -q 'run_ssh_real.sh' "$tmp/real-missing-wrapper.out" && ! grep -q 'SKIP  \[' "$tmp/real-missing-wrapper.out"; then
    pass_info "PASS self-test: --real fails on a missing wrapper (not a skip)"
  else
    warn "FAIL self-test: missing-wrapper diagnostic absent"; fail=1
  fi
  mv "$tmp/repo/run_ssh_real.sh.saved" "$tmp/repo/scripts/e2e/ios/run_ssh_real.sh"

  # 12) --real runs every wired step once and writes per-step logs.
  rm -f "$tmp/repo/ran.log"
  if env -i PATH="$restricted" HOME="$tmp/home" OPENCODE_GO_API_KEY=selftest \
       DSH_VERIFY_EVIDENCE_DIR="$tmp/evidence-real" VERIFY_SELFTEST=1 \
       bash "$tmp/repo/scripts/verify.sh" --real > "$tmp/real-green.out" 2>&1; then
    real_ran="$(wc -l < "$tmp/repo/ran.log" 2>/dev/null | tr -d ' ')"
    real_logs="$(find "$tmp/evidence-real" -name '*.log' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$real_ran" = 7 ] && [ "$real_logs" = 7 ] \
       && grep -q 'summary: pass=7 fail=0 skip=0' "$tmp/real-green.out"; then
      pass_info "PASS self-test: --real executes 7 steps with per-step logs"
    else
      warn "FAIL self-test: --real ran=$real_ran logs=$real_logs (expected 7/7)"; fail=1
    fi
  else
    warn "FAIL self-test: --real with stubbed wrappers failed"; fail=1
    sed -n '1,20p' "$tmp/real-green.out" 2>/dev/null | sed 's/^/  selftest: /' >&2
  fi

  # 13) --remote wires the five real checks and --list/--dry-run agree.
  env -i PATH="$restricted" HOME="$HOME" VERIFY_SELFTEST=1 bash "$tmp/repo/scripts/verify.sh" --remote --list > "$tmp/remote-list.out" 2>&1 || true
  env -i PATH="$restricted" HOME="$HOME" VERIFY_SELFTEST=1 bash "$tmp/repo/scripts/verify.sh" --remote --dry-run > "$tmp/remote-dry.out" 2>&1 || true
  remote_list_steps="$(grep -c '\[remote\]' "$tmp/remote-list.out" 2>/dev/null | tr -d ' ')"
  remote_dry_steps="$(grep -c '\[remote\]' "$tmp/remote-dry.out" 2>/dev/null | tr -d ' ')"
  if [ "$remote_list_steps" = 5 ] && [ "$remote_dry_steps" = 5 ] \
     && grep -q 'run_live_ssh.sh' "$tmp/remote-list.out" && grep -q 'run_live_ssh.sh' "$tmp/remote-dry.out" \
     && grep -q 'run_workspace_live.sh' "$tmp/remote-list.out" && grep -q 'run_workspace_live.sh' "$tmp/remote-dry.out" \
     && grep -q 'relay_stack.sh self-test' "$tmp/remote-list.out" \
     && grep -q 'run_ssh_real.sh' "$tmp/remote-list.out" && grep -q 'run_remote_real.sh' "$tmp/remote-list.out"; then
    pass_info "PASS self-test: --remote --list/--dry-run parity (5 checks)"
  else
    warn "FAIL self-test: --remote plan parity (list=$remote_list_steps dry=$remote_dry_steps)"; fail=1
  fi

  # 14) --remote with missing prerequisites fails closed.
  if env -i PATH="$restricted" HOME="$tmp/home" OPENCODE_GO_API_KEY=selftest VERIFY_SELFTEST=1 bash "$tmp/repo/scripts/verify.sh" --remote > "$tmp/remote-missing.out" 2>&1; then
    warn "FAIL self-test: --remote passed without prerequisites"; fail=1
  elif grep -q 'FAIL prerequisites' "$tmp/remote-missing.out" && ! grep -q 'SKIP  \[' "$tmp/remote-missing.out"; then
    pass_info "PASS self-test: --remote fails (not skips) on missing prerequisites"
  else
    warn "FAIL self-test: --remote missing-prerequisite diagnostic absent"; fail=1
  fi

  # 15) --guest runs check-archive.sh when the guest build is present.
  mkdir -p "$tmp/repo/app/ios/Engine/build/iphoneos/guest/DshGuest.framework" \
    "$tmp/repo/app/ios/Engine/build/iphoneos/guest/DshGuestBridge.framework"
  rm -f "$tmp/repo/ran-guest.log"
  if env -i PATH="$restricted" HOME="$HOME" DSH_VERIFY_EVIDENCE_DIR="$tmp/evidence-guest" \
       VERIFY_SELFTEST=1 bash "$tmp/repo/scripts/verify.sh" --guest > "$tmp/guest-green.out" 2>&1; then
    guest_ran="$(wc -l < "$tmp/repo/ran-guest.log" 2>/dev/null | tr -d ' ')"
    guest_logs="$(find "$tmp/evidence-guest" -name '*.log' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$guest_ran" = 1 ] && [ "$guest_logs" = 1 ] \
       && grep -q 'summary: pass=1 fail=0 skip=0' "$tmp/guest-green.out"; then
      pass_info "PASS self-test: --guest runs check-archive.sh with evidence log"
    else
      warn "FAIL self-test: --guest ran=$guest_ran logs=$guest_logs (expected 1/1)"; fail=1
    fi
  else
    warn "FAIL self-test: --guest failed with a complete guest build"; fail=1
    sed -n '1,20p' "$tmp/guest-green.out" 2>/dev/null | sed 's/^/  selftest: /' >&2
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
  if mode_in static ci fast full real remote guest; then
    echo "verify.sh: repo not found (need app/pubspec.yaml + .github). Pass --repo PATH or set DSH_REPO." >&2
    exit 2
  fi
  info "repo not found — listing only"
  exit 0
fi

info "repo: $REPO"
info "mode: --$MODE"
[ "$LIST" = "1" ] && info "list: yes (no execution)"
[ -n "$ALLOW_SKIP" ] && info "allow-skip: $ALLOW_SKIP"

# Every real/remote/guest step logs here. The default keeps T35b's evidence
# together; set DSH_VERIFY_EVIDENCE_DIR to keep a different run together.
EVIDENCE_DIR="${DSH_VERIFY_EVIDENCE_DIR:-$REPO/reports/phase1-completion/T35b}"
STEP_LOG_DIR=""
if mode_in real remote guest || [ -n "${DSH_VERIFY_EVIDENCE_DIR:-}" ]; then
  STEP_LOG_DIR="$EVIDENCE_DIR"
  info "evidence logs: $STEP_LOG_DIR"
fi

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
if mode_in static ci fast full || [ "$MODE" = "list" ]; then
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
fi

# ---- L1/L2 fast ------------------------------------------------------------
if mode_in ci fast full || [ "$MODE" = "list" ]; then
  # The CJK font and the Phase 1 dirs are required: a missing environment is a
  # FAIL here, not a silent skip (T36 installs the font in Linux CI).
  run_step fast "flutter test (phase1 dirs)" "test" \
    'cd app && FONT="${DSH_TEST_FONT_DIR:-/usr/share/fonts/opentype/noto}/NotoSansCJK-Light.ttc"; { [ -f "$FONT" ] || [ -f /usr/share/fonts/noto-cjk/NotoSansCJK-Light.ttc ]; } || { echo "FAIL: CJK test font missing (set DSH_TEST_FONT_DIR; upstream ci.yml installs fonts-noto-cjk)"; exit 1; }; found=0; for d in test/phase1 test/chat/phase1 test/engine/phase1 test/files/phase1; do if [ -d "$d" ]; then found=1; flutter test --no-pub "$d" || exit 1; fi; done; [ "$found" = 1 ] || { echo "FAIL: no Phase 1 test dirs (test/phase1, test/chat/phase1, test/engine/phase1, test/files/phase1)"; exit 1; }'
  run_step_need_cmd fast "dart test packages" dart \
    'for p in packages/*/pubspec.yaml; do d="$PWD/$(dirname "$p")"; (cd "$d" && dart pub get --offline >/dev/null 2>&1 || dart pub get >/dev/null && dart test) || exit 1; done'
  run_step fast "node --test test/unit" "test/unit" \
    'node --test test/unit/*.test.mjs'
fi

# ---- tooling gates (--ci/--fast/--full) ------------------------------------
if mode_in ci fast full || [ "$MODE" = "list" ]; then
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
if mode_in full || [ "$MODE" = "list" ]; then
  # Deterministic Phase 1 full gate. Every step is required: the CJK font guard
  # exits non-zero (not 4) and integration wrappers are not allowed to report a
  # skip. The iSH archive check lives in --guest, never here.
  #
  # Official Flutter subset (heavy): behavioural files that do not reference
  # matchesGoldenFile. Golden-bearing files (13 named + 14 mixed) run in their
  # own step below with the macOS/Linux platform comparator and committed
  # baselines (T35a). stop_reconnect_test is timing-sensitive under the full
  # parallel suite (P12 B1/B2 failed under load but pass alone, 3/3); it runs in
  # its own process in the next step instead of being dropped.
  run_step full "flutter test (official phase1-related subset, goldens excluded)" "app/test" \
    'cd app && FONT="${DSH_TEST_FONT_DIR:-/usr/share/fonts/opentype/noto}/NotoSansCJK-Light.ttc"; { [ -f "$FONT" ] || [ -f /usr/share/fonts/noto-cjk/NotoSansCJK-Light.ttc ]; } || { echo "FAIL: CJK test font missing (set DSH_TEST_FONT_DIR; upstream ci.yml installs fonts-noto-cjk)"; exit 1; }; files="$(find test/chat test/session test/files test/remote test/engine test/runtime -name "*_test.dart" ! -name "*_golden_test.dart" 2>/dev/null | sort)"; [ -n "$files" ] || { echo "FAIL: no official subset test files"; exit 1; }; files="$(printf "%s\n" "$files" | xargs grep -L "matchesGoldenFile" 2>/dev/null | sort)"; files="$(printf "%s\n" "$files" | grep -v "^test/chat/stop_reconnect_test.dart$" | sort)"; [ -n "$files" ] || { echo "FAIL: no non-golden official subset files"; exit 1; }; flutter test --no-pub $files'
  run_step full "flutter test (stop/reconnect timing suite, isolated)" "app/test/chat/stop_reconnect_test.dart" \
    'cd app && FONT="${DSH_TEST_FONT_DIR:-/usr/share/fonts/opentype/noto}/NotoSansCJK-Light.ttc"; { [ -f "$FONT" ] || [ -f /usr/share/fonts/noto-cjk/NotoSansCJK-Light.ttc ]; } || { echo "FAIL: CJK test font missing (set DSH_TEST_FONT_DIR; upstream ci.yml installs fonts-noto-cjk)"; exit 1; }; flutter test --no-pub test/chat/stop_reconnect_test.dart'
  # All 27 golden-bearing files (13 named *_golden_test.dart + 14 mixed files
  # containing matchesGoldenFile; reports/phase1-completion/skip-audit.md §3).
  # The count is asserted so a new golden cannot silently join the excluded set.
  run_step full "flutter test (27 golden-bearing files, macOS comparator)" "app/test" \
    'cd app && FONT="${DSH_TEST_FONT_DIR:-/usr/share/fonts/opentype/noto}/NotoSansCJK-Light.ttc"; { [ -f "$FONT" ] || [ -f /usr/share/fonts/noto-cjk/NotoSansCJK-Light.ttc ]; } || { echo "FAIL: CJK test font missing (set DSH_TEST_FONT_DIR; upstream ci.yml installs fonts-noto-cjk)"; exit 1; }; files="$(for f in $(find test/chat test/session test/files test/remote test/engine test/runtime -name "*_test.dart" 2>/dev/null | sort); do if [ "$f" != "${f%_golden_test.dart}" ]; then printf "%s\n" "$f"; elif grep -q "matchesGoldenFile" "$f" 2>/dev/null; then printf "%s\n" "$f"; fi; done)"; count="$(printf "%s\n" "$files" | sed "/^$/d" | wc -l | tr -d " ")"; [ "$count" -eq 27 ] || { echo "FAIL: expected 27 golden-bearing files, found $count (skip-audit.md §3; update the baselines and this count together)"; exit 1; }; flutter test --no-pub $files'
  run_step_need_cmd full "xcodebuild build (simulator)" xcodebuild \
    'cd app && DSH_IOS_GUEST_BUILD=0 bash ../tooling/ios/build.sh --simulator --debug'
  run_step_need_cmd full "xcodebuild build (device, unsigned)" xcodebuild \
    'cd app && DSH_IOS_GUEST_BUILD=0 bash ../tooling/ios/build.sh --release --no-codesign'
  # T35a proved the complete 367-case RunnerTests suite passes on the base
  # iPhone 17 Pro when it runs serially after the system privacy/location grants.
  # Parallel simulator clones do not inherit those grants, which is why this is
  # serial and why there is no -skip-testing filter any more.
  run_step_need_cmd full "RunnerTests (367 cases, serial, grants, no filter)" xcodebuild \
    'cd app && test -n "$IOS_SIM_17PRO" || { echo "FAIL: iPhone 17 Pro simulator not found (set DSH_SIM_17PRO)"; exit 1; }; xcrun simctl bootstatus "$IOS_SIM_17PRO" -b >/dev/null; xcrun simctl install "$IOS_SIM_17PRO" build/ios/iphonesimulator/Runner.app; for svc in all reminders contacts contacts-limited calendar location location-always photos siri; do xcrun simctl privacy "$IOS_SIM_17PRO" grant "$svc" io.github.ccch1mneyyy.dshgo || exit 1; done; xcrun simctl location "$IOS_SIM_17PRO" set 31.2304,121.4737; DSH_IOS_GUEST_BUILD=0 xcodebuild test -workspace ios/Runner.xcworkspace -scheme Runner -destination "platform=iOS Simulator,id=$IOS_SIM_17PRO" -only-testing:RunnerTests -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO'
  # Phase1UITests launches the real installed Runner.app by bundle identifier and
  # covers the process-level cold-launch/relaunch path (T34a).
  run_step_need_cmd full "Phase1UITests (process-level, installed Runner.app)" xcodebuild \
    'cd app && test -n "$IOS_SIM_17PRO" || { echo "FAIL: iPhone 17 Pro simulator not found (set DSH_SIM_17PRO)"; exit 1; }; xcrun simctl bootstatus "$IOS_SIM_17PRO" -b >/dev/null; xcrun simctl install "$IOS_SIM_17PRO" build/ios/iphonesimulator/Runner.app; xcodebuild test -workspace ios/Runner.xcworkspace -scheme Phase1UITests -destination "platform=iOS Simulator,id=$IOS_SIM_17PRO" CODE_SIGNING_ALLOWED=NO'
  run_step full "integration_test phase1 (iPhone 17 Pro, canonical mock)" "app/integration_test/phase1_test.dart" \
    'bash app/integration_test/run_phase1_e2e.sh --device "${IOS_SIM_17PRO:-iPhone 17 Pro}"'
  run_step full "integration_test phase1 (iPhone SE3, canonical mock)" "app/integration_test/phase1_test.dart" \
    'bash app/integration_test/run_phase1_e2e.sh --device "${IOS_SIM_SE3:-iPhone SE3}"'
  run_step full "official engine smoke (real engine + mock model)" "test/fixtures/run_engine_smoke.sh" \
    'bash test/fixtures/run_engine_smoke.sh'
fi

# ---- L4-Real (--real) ------------------------------------------------------
# Real opencode-go model and the real on-device engine. The six real L4
# wrappers are a data-driven list; a missing key/credential or wrapper is a
# hard FAIL, never a SKIP. Each wrapper is started up front so one missing
# wrapper fails before any long real run starts.
if mode_in real || [ "$MODE" = "list" ]; then
  real_prereqs_ok=1
  if ! listing && [ "$DRY_RUN" != "1" ]; then
    if ! real_credentials_available; then
      warn "FAIL prerequisites (--real): no OPENCODE_GO_API_KEY and no readable refs.OPENCODE_GO_API_KEY in ${CREDENTIALS_FILE:-${HOME:-/nonexistent}/.dsh/.credentials.yaml}"
      real_prereqs_ok=0
    fi
    if [ ! -f "$REPO/scripts/e2e/real_provider_smoke.sh" ]; then
      warn "FAIL prerequisites (--real): missing scripts/e2e/real_provider_smoke.sh (never skipped)"
      real_prereqs_ok=0
    fi
    for w in $REAL_L4_WRAPPERS; do
      if [ ! -f "$REPO/scripts/e2e/ios/$w" ]; then
        warn "FAIL prerequisites (--real): missing scripts/e2e/ios/$w (never skipped)"
        real_prereqs_ok=0
      fi
    done
    if [ "$real_prereqs_ok" = "0" ]; then
      FAIL=$((FAIL+1)); FAILED_STEPS+=("--real prerequisites")
    fi
  fi
  if [ "$real_prereqs_ok" = "1" ]; then
    run_step_required real "real provider smoke (opencode-go)" "scripts/e2e/real_provider_smoke.sh" \
      'bash scripts/e2e/real_provider_smoke.sh' 1800
    for w in $REAL_L4_WRAPPERS; do
      run_step_required real "real L4: $w" "scripts/e2e/ios/$w" \
        "bash scripts/e2e/ios/$w" 7200
    done
  fi
fi

# ---- L4-Process / real transport (--remote) --------------------------------
# Real local sshd + real dsh web + self-hosted DSH Remote. Credentials, the
# sshd binary, the dsh/flutter toolchain and every wrapper are hard
# prerequisites: missing means FAIL, never SKIP.
if mode_in remote || [ "$MODE" = "list" ]; then
  remote_prereqs_ok=1
  if ! listing && [ "$DRY_RUN" != "1" ]; then
    if ! real_credentials_available; then
      warn "FAIL prerequisites (--remote): no OPENCODE_GO_API_KEY and no readable refs.OPENCODE_GO_API_KEY in ${CREDENTIALS_FILE:-${HOME:-/nonexistent}/.dsh/.credentials.yaml} (the SSH/Remote App L4s use the real model)"
      remote_prereqs_ok=0
    fi
    for f in scripts/e2e/run_live_ssh.sh scripts/e2e/run_workspace_live.sh \
             scripts/e2e/remote/relay_stack.sh scripts/e2e/ios/run_ssh_real.sh \
             scripts/e2e/ios/run_remote_real.sh; do
      if [ ! -f "$REPO/$f" ]; then
        warn "FAIL prerequisites (--remote): missing $f (never skipped)"
        remote_prereqs_ok=0
      fi
    done
    if ! resolve_flutter_path >/dev/null 2>&1; then
      warn "FAIL prerequisites (--remote): flutter not found (PATH or \$HOME/tools/flutter)"; remote_prereqs_ok=0
    fi
    if ! resolve_dsh_path >/dev/null 2>&1; then
      warn "FAIL prerequisites (--remote): dsh launcher not found (PATH or \$HOME/.local/bin/dsh)"; remote_prereqs_ok=0
    fi
    for bin in xcrun xcodebuild ssh node; do
      if ! have "$bin"; then
        warn "FAIL prerequisites (--remote): required command not found: $bin"; remote_prereqs_ok=0
      fi
    done
    sshd_bin="${DSH_E2E_SSHD_BIN:-/usr/sbin/sshd}"
    if [ ! -x "$sshd_bin" ]; then
      warn "FAIL prerequisites (--remote): sshd not executable: $sshd_bin"; remote_prereqs_ok=0
    fi
    if [ "$remote_prereqs_ok" = "0" ]; then
      FAIL=$((FAIL+1)); FAILED_STEPS+=("--remote prerequisites")
    fi
  fi
  if [ "$remote_prereqs_ok" = "1" ]; then
    run_step_required remote "remote: live SSH suite (real sshd + dsh web)" "scripts/e2e/run_live_ssh.sh" \
      'bash scripts/e2e/run_live_ssh.sh' 1800
    run_step_required remote "remote: live workspace suite (real dsh web)" "scripts/e2e/run_workspace_live.sh" \
      'bash scripts/e2e/run_workspace_live.sh' 1800
    run_step_required remote "remote: self-hosted relay stack self-test" "scripts/e2e/remote/relay_stack.sh" \
      'bash scripts/e2e/remote/relay_stack.sh self-test' 3600
    run_step_required remote "remote: real SSH host L4 (real model)" "scripts/e2e/ios/run_ssh_real.sh" \
      'bash scripts/e2e/ios/run_ssh_real.sh' 7200
    run_step_required remote "remote: real DSH Remote L4 (real model)" "scripts/e2e/ios/run_remote_real.sh" \
      'bash scripts/e2e/ios/run_remote_real.sh' 7200
  fi
fi

# ---- guest archive (--guest, opt-in Phase 2) -------------------------------
# The iSH archive shape check needs a prepared guest build (DshGuest +
# DshGuestBridge). It is no longer part of --full; when --guest is selected, a
# missing build is a FAIL with the build command, never a skip.
if mode_in guest || [ "$MODE" = "list" ]; then
  guest_prereqs_ok=1
  if ! listing && [ "$DRY_RUN" != "1" ]; then
    if ! have xcodebuild; then
      warn "FAIL prerequisites (--guest): xcodebuild not found"; guest_prereqs_ok=0
    fi
    if ! resolve_flutter_path >/dev/null 2>&1; then
      warn "FAIL prerequisites (--guest): flutter not found (PATH or \$HOME/tools/flutter)"; guest_prereqs_ok=0
    fi
    if [ ! -f "$REPO/tooling/ios/check-archive.sh" ]; then
      warn "FAIL prerequisites (--guest): missing tooling/ios/check-archive.sh"; guest_prereqs_ok=0
    fi
    for fw in DshGuest DshGuestBridge; do
      if [ ! -d "$REPO/app/ios/Engine/build/iphoneos/guest/$fw.framework" ]; then
        warn "FAIL prerequisites (--guest): missing guest build app/ios/Engine/build/iphoneos/guest/$fw.framework; build it with tooling/ios/build-ish.sh + tooling/ios/build-guest-addon.sh (a missing guest build is a FAIL, not a skip)"
        guest_prereqs_ok=0
      fi
    done
    if [ "$guest_prereqs_ok" = "0" ]; then
      FAIL=$((FAIL+1)); FAILED_STEPS+=("--guest prerequisites")
    fi
  fi
  if [ "$guest_prereqs_ok" = "1" ]; then
    run_step_required guest "guest: iSH archive shape check (opt-in Phase 2)" "tooling/ios/check-archive.sh" \
      'tmp="$(mktemp -d "${TMPDIR:-/tmp}/dsh-guest-archive.XXXXXX")"; RUNNER_TEMP="$tmp"; export RUNNER_TEMP; rc=0; bash tooling/ios/check-archive.sh || rc=$?; rm -rf "$tmp"; exit "$rc"' 3600
  fi
fi

# Built-in self-check: proves fail-on-skip/fail-closed works (skipped in nested self-test runs).
# --list/--dry-run must not execute anything, so only real runs pay for it.
if mode_in static ci fast full real remote guest && ! listing && [ "$DRY_RUN" != "1" ]; then
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
if listing; then
  info "list only: nothing was executed"; exit 0
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
