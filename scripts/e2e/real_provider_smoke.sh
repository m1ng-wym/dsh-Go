#!/usr/bin/env bash
# Real opencode-go provider smoke for Phase 1 acceptance (T25).
#
# Starts the loopback credential broker, then runs test/fixtures/real_provider_probe.mjs
# against the real API (6 requests max). The key is read by the broker from
# OPENCODE_GO_API_KEY or ~/.dsh/.credentials.yaml and handed to the probe over
# loopback; this script never sees, prints, or stores it.
#
# Usage:
#   scripts/e2e/real_provider_smoke.sh              # real network + real key
#   scripts/e2e/real_provider_smoke.sh --dry-run    # offline preflight (no requests)
#   scripts/e2e/real_provider_smoke.sh --self-test  # offline broker+probe self-tests
#
# Env:
#   DSH_E2E_PROVIDER_BASE_URL   default https://opencode.ai/inference/go/v1
#   DSH_E2E_MODEL               default deepseek-v4.1-flash
#   DSH_E2E_EVIDENCE_DIR        default <repo>/reports/phase1-completion/T25
#   CREDENTIALS_FILE            default ~/.dsh/.credentials.yaml
#
# Exits non-zero on every failure. No skips.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

ROOT="$DSH_E2E_ROOT"
BASE_URL="${DSH_E2E_PROVIDER_BASE_URL:-https://opencode.ai/inference/go/v1}"
MODEL="${DSH_E2E_MODEL:-deepseek-v4.1-flash}"
EVIDENCE="${DSH_E2E_EVIDENCE_DIR:-$ROOT/reports/phase1-completion/T25}"
PROBE="$ROOT/test/fixtures/real_provider_probe.mjs"
BROKER="$ROOT/test/fixtures/credential_broker.mjs"
MODE="real"
case "${1:-}" in
  "") ;;
  --self-test) MODE="self-test" ;;
  --dry-run) MODE="dry-run" ;;
  -h | --help)
    sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) printf 'usage: %s [--dry-run|--self-test]\n' "$0" >&2; exit 2 ;;
esac

BROKER_PID=""
WORK=""
cleanup() {
  local rc=$?
  if [ -n "$BROKER_PID" ] && kill -0 "$BROKER_PID" 2>/dev/null; then
    kill "$BROKER_PID" 2>/dev/null || true
    wait "$BROKER_PID" 2>/dev/null || true
  fi
  e2e_cleanup
  exit "$rc"
}
trap cleanup EXIT INT TERM

preflight() {
  require_cmd node
  require_cmd python3
  [ -f "$PROBE" ] || fail "missing probe: $PROBE"
  [ -f "$BROKER" ] || fail "missing credential broker: $BROKER"
}

run_offline_self_tests() {
  local broker_log probe_log
  broker_log="$(mktemp "${TMPDIR:-/tmp}/dsh-e2e-broker-selftest.XXXXXX")"
  probe_log="$(mktemp "${TMPDIR:-/tmp}/dsh-e2e-probe-selftest.XXXXXX")"
  e2e_log "credential broker self-test"
  node "$BROKER" --self-test >"$broker_log" 2>&1 || {
    cat "$broker_log" >&2
    rm -f "$broker_log" "$probe_log"
    fail "credential broker self-test failed"
  }
  cat "$broker_log"
  e2e_log "real provider probe self-test (offline mock provider)"
  node "$PROBE" --self-test >"$probe_log" 2>&1 || {
    cat "$probe_log" >&2
    rm -f "$broker_log" "$probe_log"
    fail "real provider probe self-test failed"
  }
  cat "$probe_log"
  rm -f "$broker_log" "$probe_log"
}

if [ "$MODE" = "self-test" ]; then
  preflight
  run_offline_self_tests
  printf 'self-test: PASS (real provider smoke harness)\n'
  exit 0
fi

if [ "$MODE" = "dry-run" ]; then
  preflight
  run_offline_self_tests
  # The key is checked without echoing it or starting a request.
  KEY="$(read_credentials_key)" || exit 1
  [ -n "$KEY" ] || fail "credentials resolved to an empty key"
  e2e_log "dry-run: key available (not printed); base=$BASE_URL model=$MODEL max_requests=6"
  e2e_log "dry-run: a real run would write evidence under $EVIDENCE"
  printf 'dry-run: PASS (no network request sent)\n'
  exit 0
fi

preflight
mkdir -p "$EVIDENCE/green"
WORK="$(make_temp_dir dsh-e2e-provider)"
e2e_track_temp "$WORK"

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
BROKER_PORT="$(printf '%s\n' "$BROKER_LINE" | python3 -c 'import json,sys; line=sys.stdin.read().strip(); print(json.loads(line[len("BROKER "):])["port"])')"
BROKER_TOKEN="$(printf '%s\n' "$BROKER_LINE" | python3 -c 'import json,sys; line=sys.stdin.read().strip(); print(json.loads(line[len("BROKER "):])["token"])')"
[ -n "$BROKER_PORT" ] && [ -n "$BROKER_TOKEN" ] || fail "could not parse the broker announcement"
wait_port 127.0.0.1 "$BROKER_PORT" 10

SESSION="$(python3 -c 'import uuid; print(uuid.uuid4())')"
LOG="$EVIDENCE/green/real_provider_probe.log"
: >"$LOG"
chmod 600 "$LOG" 2>/dev/null || true

e2e_log "probing $BASE_URL with model $MODEL (max 6 requests)"
set +e
node "$PROBE" \
  --base-url "$BASE_URL" \
  --model "$MODEL" \
  --session "$SESSION" \
  --max-requests 6 \
  --broker-url "http://127.0.0.1:$BROKER_PORT" \
  --broker-token "$BROKER_TOKEN" \
  --json-out "$EVIDENCE/green/real_provider_probe.json" \
  >"$WORK/probe.out" 2>"$WORK/probe.err"
PROBE_RC=$?
set -e
cat "$WORK/probe.out" >>"$LOG"
cat "$WORK/probe.err" >>"$LOG"

if [ "$PROBE_RC" -ne 0 ]; then
  e2e_log "probe failed (exit $PROBE_RC); broker stderr:"
  cat "$WORK/broker.err" >&2 || true
  fail "real provider smoke failed; see $LOG"
fi

grep -q '"ok":true' "$WORK/probe.out" || fail "probe exited 0 without an ok result"
REQUESTS="$(python3 - "$WORK/probe.out" <<'PY'
import json, sys
line = next((l for l in open(sys.argv[1]) if l.startswith('PROBE_RESULT ')), '')
data = json.loads(line[len('PROBE_RESULT '):])
print(data.get('requests', 0))
PY
)" || fail "could not read the probe result"
[ "$REQUESTS" -le 6 ] || fail "probe exceeded its request budget ($REQUESTS > 6)"

env_json_write "$EVIDENCE/green/real_provider_smoke.env.json" \
  "run=real_provider_smoke" "base_url=$BASE_URL" "model=$MODEL" "session=$SESSION" \
  "requests=$REQUESTS" "result=pass" "commit=$(repo_commit)" "log=$LOG"

printf 'real provider smoke: PASS (%s requests, model %s)\n' "$REQUESTS" "$MODEL"
