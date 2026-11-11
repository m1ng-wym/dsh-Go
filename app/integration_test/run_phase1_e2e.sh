#!/usr/bin/env bash
# Runs the Phase 1 L4 integration test (integration_test/phase1_test.dart) on an
# iOS Simulator with the canonical mock model server
# (test/fixtures/mock_model_server.mjs, docs/specs/phase1/mocks.md §2).
#
#   integration_test/run_phase1_e2e.sh [--device NAME|UDID] [--no-uninstall] [--keep-mock]
#
# - Resolves NAME to a simulator UDID (exact device-name match, first available
#   one; `DSH_SIM_17PRO`/`DSH_SIM_SE3` may still override the caller's choice).
# - Boots it, starts the mock on 127.0.0.1:3901 (or reuses one already healthy
#   there), uninstalls the app so the run starts from a real first launch, then
#   runs the test from app/.
# - Exit codes: 0 pass; 1 test/mock failure; 4 SKIP with a `SKIP: <reason>` line
#   (no simulator / flutter missing), which scripts/verify.sh maps to SKIP, never
#   to green.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEVICE="${DSH_SIM_17PRO:-iPhone 17 Pro}"
UNINSTALL=1
KEEP_MOCK=0
MOCK_PORT=3901
BUNDLE_ID="io.github.ccch1mneyyy.dshgo"

while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE="${2:?}"; shift 2 ;;
    --no-uninstall) UNINSTALL=0; shift ;;
    --keep-mock) KEEP_MOCK=1; shift ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "run_phase1_e2e.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

skip() { echo "SKIP: $*"; exit 4; }
fail() { echo "FAIL: $*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

FLUTTER="$(command -v flutter 2>/dev/null || true)"
[ -n "$FLUTTER" ] || [ -x "$HOME/tools/flutter/bin/flutter" ] && FLUTTER="${FLUTTER:-$HOME/tools/flutter/bin/flutter}"
[ -n "$FLUTTER" ] || skip "flutter not found on PATH"
have xcrun || skip "xcrun not found (not macOS/Xcode)"
have python3 || skip "python3 not found"

NODE=""
for candidate in \
  "$HOME/tools/node-v24.22.1-darwin-arm64/bin/node" \
  "$(ls -d "$HOME"/Library/Caches/dsh-ios-engine/node-v*/bin/node 2>/dev/null | head -n 1)" \
  "$(command -v node 2>/dev/null || true)"; do
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then NODE="$candidate"; break; fi
done
[ -n "$NODE" ] || skip "node not found (needed for the mock model server)"

[ -f "$ROOT/test/fixtures/mock_model_server.mjs" ] || fail "test/fixtures/mock_model_server.mjs missing"
[ -f "$ROOT/app/integration_test/phase1_test.dart" ] || fail "app/integration_test/phase1_test.dart missing"

# ---- resolve simulator ------------------------------------------------------
if [[ "$DEVICE" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
  UDID="$DEVICE"
else
  UDID="$(python3 - "$DEVICE" <<'PY'
import json, subprocess, sys
name = sys.argv[1]
out = subprocess.run(["xcrun", "simctl", "list", "devices", "available", "-j"],
                     capture_output=True, text=True)
try:
    devices = json.loads(out.stdout)["devices"]
except Exception:
    sys.exit(0)
for runtime, rows in devices.items():
    if "iOS" not in runtime:
        continue
    for row in rows:
        if row.get("name") == name and row.get("isAvailable", True):
            print(row.get("udid", ""))
            sys.exit(0)
PY
)"
fi
[ -n "$UDID" ] || skip "no available iOS Simulator named '$DEVICE'"

echo "phase1 e2e: device=$UDID flutter=$FLUTTER node=$NODE"
xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || skip "simulator $UDID did not boot"

# ---- mock model server ------------------------------------------------------
MOCK_PID=""
MOCK_LOG="$(mktemp -t dsh-phase1-mock.XXXXXX.log)"
STARTED_MOCK=0
cleanup() {
  local rc=$?
  if [ -n "$MOCK_PID" ]; then
    kill "$MOCK_PID" >/dev/null 2>&1 || true
    wait "$MOCK_PID" >/dev/null 2>&1 || true
  fi
  if [ "$rc" -ne 0 ] && [ -s "$MOCK_LOG" ]; then
    echo "--- mock model server log (tail) ---" >&2
    tail -n 30 "$MOCK_LOG" >&2
  fi
  echo "mock log: $MOCK_LOG"
  exit "$rc"
}
trap cleanup EXIT INT TERM

mock_healthy() {
  python3 - "$MOCK_PORT" <<'PY' >/dev/null 2>&1
import sys, urllib.request
port = sys.argv[1]
with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=0.5) as response:
    sys.exit(0 if response.status == 200 else 1)
PY
}

if mock_healthy; then
  echo "mock model: reusing the healthy server already on 127.0.0.1:$MOCK_PORT"
else
  "$NODE" "$ROOT/test/fixtures/mock_model_server.mjs" --port "$MOCK_PORT" >"$MOCK_LOG" 2>&1 &
  MOCK_PID=$!
  STARTED_MOCK=1
  for _ in $(seq 1 50); do
    if mock_healthy; then break; fi
    sleep 0.2
  done
  mock_healthy || fail "mock model server did not answer on 127.0.0.1:$MOCK_PORT (see $MOCK_LOG)"
fi

if [ "$STARTED_MOCK" = "0" ] && [ "$KEEP_MOCK" = "0" ]; then
  : # An already-running server is not ours to stop.
fi

# ---- first launch -----------------------------------------------------------
if [ "$UNINSTALL" = "1" ]; then
  xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  echo "app uninstalled from $UDID (fresh first run)"
fi

# ---- test -------------------------------------------------------------------
cd "$ROOT/app" || fail "cannot enter $ROOT/app"
# Phase 1 defers iSH: the standard Phase 1 build gate skips the guest addon
# (tooling/ios/embed-engine.sh; see plan §1 and ci.md). Without this the Xcode
# build phase tries to build iSH and needs llvm/lld/meson/ninja.
export DSH_IOS_GUEST_BUILD=0
echo "== flutter test integration_test/phase1_test.dart -d $UDID =="
"$FLUTTER" test --no-pub -r expanded integration_test/phase1_test.dart -d "$UDID"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "phase1 e2e: FAIL (flutter test exit $rc)" >&2
  exit "$rc"
fi
echo "phase1 e2e: PASS (device $UDID)"
