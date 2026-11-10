#!/usr/bin/env bash
# Official iOS engine smoke on the Simulator: a real DSH engine round against a fake
# model, then restart in place. This wraps the exact steps CI runs in
# `.github/workflows/ios-compile.yml` (engine job), measured locally on 2026-11-10
# (macOS 26.5.2, Xcode 26.6, Node 24.22.1 cache, iPhone 17 Pro simulator).
#
#   bash test/fixtures/run_engine_smoke.sh [--work DIR] [--keep]
#
# Exit codes: 0 pass; 4 SKIP with a "SKIP: <reason>" line (prerequisites absent, e.g.
# Linux runner or engine not prepared); other = failure. `scripts/verify.sh --full`
# maps exit 4 to SKIP (never to green).
#
# Prerequisites (same as CI):
#   - app/ios/Engine/.ready + app/ios/Engine/runtime.zip (tooling/ios/prepare-engine.sh)
#   - Node 24.22.1 cache at $DSH_IOS_ENGINE_WORK (default ~/Library/Caches/dsh-ios-engine)
#   - Xcode command line tools with an iOS Simulator, and an iPhone simulator device
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="${DSH_ENGINE_SMOKE_WORK:-/tmp/dsh-engine-smoke}"
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --work) WORK="${2:?}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "run_engine_smoke.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

skip() { echo "SKIP: $*"; exit 4; }
fail() { echo "FAIL: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || skip "missing command: $1"; }

# ---- prerequisites ---------------------------------------------------------
[ -f "$ROOT/app/ios/Engine/.ready" ] || skip "engine not prepared (app/ios/Engine/.ready missing; run tooling/ios/prepare-engine.sh)"
[ -f "$ROOT/app/ios/Engine/runtime.zip" ] || skip "engine runtime.zip missing"
[ -d "$ROOT/app/ios/Engine/NodeMobile.xcframework/ios-arm64-simulator" ] || skip "NodeMobile simulator slice missing"
need xcrun
need xcodebuild
xcrun simctl list runtimes >/dev/null 2>&1 || skip "iOS simulator runtime unavailable (xcrun simctl)"

ENGINE_WORK="${DSH_IOS_ENGINE_WORK:-$HOME/Library/Caches/dsh-ios-engine}"
NODE_BIN="$(ls -d "$ENGINE_WORK"/node-v*/bin/node 2>/dev/null | head -n 1)"
[ -n "$NODE_BIN" ] && [ -x "$NODE_BIN" ] || skip "Node 24.22.1 cache missing under $ENGINE_WORK (run tooling/ios/prepare-engine.sh)"
[ -f "$ROOT/tooling/ios/engine-smoke/drive.mjs" ] || skip "tooling/ios/engine-smoke/drive.mjs missing"

echo "engine smoke: node=$NODE_BIN work=$WORK"
rm -rf "$WORK"
mkdir -p "$WORK/tree" "$WORK/frameworks"

# ---- engine pieces (same as ios-compile.yml) -------------------------------
echo "== unzip runtime =="
unzip -q "$ROOT/app/ios/Engine/runtime.zip" 'files/*' -d "$WORK/tree" || fail "unzip runtime.zip"

echo "== build native pieces (simulator) =="
bash "$ROOT/tooling/ios/build-engine-native.sh" iphonesimulator "$WORK/frameworks" -DDSH_IOS_ENGINE_SMOKE \
  || fail "build-engine-native.sh iphonesimulator"
cp -R "$ROOT/app/ios/Engine/NodeMobile.xcframework/ios-arm64-simulator/NodeMobile.framework" "$WORK/frameworks/" \
  || fail "copy NodeMobile.framework"

echo "== compile smoke binary =="
xcrun --sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator \
  "$ROOT/tooling/ios/engine-smoke/smoke.c" -o "$WORK/smoke" || fail "compile smoke.c"

# ---- simulator + round -----------------------------------------------------
echo "== boot simulator =="
UDID="$(cd "$ROOT" && python3 tooling/ios/engine-smoke/pick-simulator.py)" || skip "no iPhone simulator available"
xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || skip "simulator $UDID did not boot"
echo "simulator=$UDID"

echo "== drive real engine round (fake model) =="
status=0
"$NODE_BIN" "$ROOT/tooling/ios/engine-smoke/drive.mjs" \
  --simulator "$UDID" --smoke "$WORK/smoke" --frameworks "$WORK/frameworks" \
  --runtime "$WORK/tree/files" --work "$WORK/work" --ws "$WORK/tree/files" || status=$?
if [ -d "$WORK/work" ]; then
  "$NODE_BIN" "$ROOT/tooling/ios/engine-smoke/annotate.mjs" "$WORK/work" | tail -n 5 || true
fi
if [ "$status" -ne 0 ]; then
  echo "engine smoke: FAIL (drive.mjs=$status; artifacts kept under $WORK)"; exit "$status"
fi
if [ "$KEEP" = "1" ]; then echo "artifacts kept: $WORK"; else echo "artifacts: $WORK/work/report.json"; fi
echo "engine smoke: PASS"
