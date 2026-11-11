#!/usr/bin/env bash
# Generated-file drift guard (Phase 1 T36, revised after Lead review).
#
# Regenerates the l10n outputs and fails when a *deterministic* tracked output
# differs from HEAD. The one-shot generation is what T4/T23 already treat as
# canonical; hand-editing generated files is what this gate catches.
#
# Deliberately NOT in the hard scope (environment-dependent, not cross-platform
# oracles; see docs/specs/phase1/ci.md §8):
#   - app/analysis_options.yaml   (Flutter's project migrator adds platform excludes)
#   - app/pubspec.lock            (Flutter resolves platform plugins per host)
#   - packages/*/pubspec.lock     (dart pub get resolves per host)
# With DRIFT_WITH_PUB_GET=1 the script additionally runs `flutter pub get` and
# `dart pub get` and reports those files as WARNINGS, never as a failure.
#
# Scope (hard gate):
#   - app/lib/l10n/**            (part merge + flutter gen-l10n output)
#
# Usage:
#   scripts/check-generated-drift.sh [--repo PATH]
#   DRIFT_WITH_PUB_GET=1 scripts/check-generated-drift.sh   # extra warnings
#
# Exit codes: 0 no drift, 1 drift or a generator failed, 2 bad usage/setup.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ARG=""

usage() {
  sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo=*) REPO_ARG="${1#--repo=}"; shift ;;
    --repo) shift; [ $# -gt 0 ] || { echo "check-generated-drift.sh: --repo needs a path" >&2; exit 2; }; REPO_ARG="$1"; shift ;;
    -h|--help) usage ;;
    *) echo "check-generated-drift.sh: unknown argument: $1" >&2; usage ;;
  esac
done

REPO="${REPO_ARG:-${DSH_REPO:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
REPO="$(cd "$REPO" 2>/dev/null && pwd)" || { echo "check-generated-drift.sh: repo not found: $REPO_ARG" >&2; exit 2; }

for bin in git flutter python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "check-generated-drift.sh: required command missing: $bin" >&2; exit 2; }
done
[ -f "$REPO/app/pubspec.yaml" ] || { echo "check-generated-drift.sh: not a repo (app/pubspec.yaml missing): $REPO" >&2; exit 2; }
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "check-generated-drift.sh: not a git worktree: $REPO" >&2; exit 2; }

SCOPE=(app/lib/l10n)
ENV_SCOPE=(app/analysis_options.yaml app/pubspec.lock 'packages/*/pubspec.lock')

note() { printf '\n[drift] %s\n' "$*"; }
fail() { printf '[drift] FAIL: %s\n' "$*" >&2; exit 1; }
warn() { printf '[drift] WARN: %s\n' "$*" >&2; }

note "repo: $REPO"
note "hard scope: ${SCOPE[*]} (deterministic generated outputs)"
note "warning-only scope: ${ENV_SCOPE[*]} (environment-dependent)"

dirty_before="$(git -C "$REPO" status --porcelain=v1 --untracked-files=all -- "${SCOPE[@]}")" || fail "git status failed"
if [ -n "$dirty_before" ]; then
  note "NOTE: scoped files were already dirty before generation (generation may rewrite them):"
  printf '%s\n' "$dirty_before"
fi

note "l10n generation (python3 app/tool/l10n_merge.py)"
( cd "$REPO" && python3 app/tool/l10n_merge.py ) || fail "l10n generation failed"

dirty_after="$(git -C "$REPO" status --porcelain=v1 --untracked-files=all -- "${SCOPE[@]}")" || fail "git status failed"
if [ -n "$dirty_after" ]; then
  printf '\n[drift] tracked l10n files changed after generation:\n%s\n' "$dirty_after" >&2
  printf '\n[drift] diff stat (tracked):\n' >&2
  git -C "$REPO" diff --stat -- "${SCOPE[@]}" >&2 || true
  printf '\n[drift] Fix: regenerate from the ARB inputs and commit the tracked outputs; do not hand-edit them.\n' >&2
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    echo "::error title=Generated-file drift::tracked l10n output differs from HEAD; see the log." >&2
  fi
  exit 1
fi

if [ "${DRIFT_WITH_PUB_GET:-0}" = "1" ]; then
  note "environment drift probe (flutter/dart pub get; warnings only)"
  ( cd "$REPO/app" && flutter pub get ) || warn "flutter pub get failed"
  for p in "$REPO"/packages/*/pubspec.yaml; do
    [ -f "$p" ] || continue
    pkg_dir="$(dirname "$p")"
    ( cd "$pkg_dir" && dart pub get ) || warn "dart pub get failed in ${pkg_dir#"$REPO"/}"
  done
  env_dirty="$(git -C "$REPO" status --porcelain=v1 --untracked-files=all -- "${ENV_SCOPE[@]}" 2>/dev/null)" || env_dirty=""
  if [ -n "$env_dirty" ]; then
    warn "environment-dependent files changed (not a gate; restore them before committing):"
    printf '%s\n' "$env_dirty" >&2
  fi
fi

note "PASS: app/lib/l10n/** matches HEAD after regeneration"
exit 0
