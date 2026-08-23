#!/usr/bin/env bash
set -Eeuo pipefail
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL=0

pass(){ echo "[PASS] $*"; }
fail(){ echo "[FAIL] $*"; FAIL=1; }

for f in "$BASE"/*.sh "$BASE"/lib/*.sh "$BASE"/modules/*.sh "$BASE"/payload/*.sh "$BASE"/prometheus/*.sh; do
  [ -f "$f" ] || continue
  bash -n "$f" && pass "bash -n ${f#$BASE/}" || fail "bash -n ${f#$BASE/}"
done

if grep -R -nE '(^|[[:space:]])docker-compose([[:space:]]|$)|(^|[[:space:]])docker compose([[:space:]]|$)' \
  "$BASE" --include='*.sh' --exclude='self-test.sh' >/tmp/vps-bootstrap-compose.$$ 2>/dev/null; then
  cat /tmp/vps-bootstrap-compose.$$
  fail "Docker Compose dependency found"
else
  pass "no Docker Compose dependency"
fi
rm -f /tmp/vps-bootstrap-compose.$$ 2>/dev/null || true

if grep -R -nE 'curl[^|]*\|[[:space:]]*grep[[:space:]]+-q' \
  "$BASE" --include='*.sh' --exclude='self-test.sh' >/tmp/vps-bootstrap-pipe.$$ 2>/dev/null; then
  cat /tmp/vps-bootstrap-pipe.$$
  fail "unsafe curl | grep -q pipeline found"
else
  pass "no unsafe curl | grep -q pipeline"
fi
rm -f /tmp/vps-bootstrap-pipe.$$ 2>/dev/null || true

for f in "$BASE"/modules/*.sh; do
  grep -q '^module_context$' "$f" || fail "module_context missing: ${f#$BASE/}"
done

# Privacy/reusability guard: examples and first-run flow must not ship a real
# user domain/email. This only checks known private values from the prior build.
if grep -R -nE 'zgo\.supercool\.top|tr_hzz@qq\.com' "$BASE" \
  --exclude='SHA256SUMS' --exclude='self-test.sh' >/tmp/vps-bootstrap-private.$$ 2>/dev/null; then
  cat /tmp/vps-bootstrap-private.$$
  fail "user-specific domain/email embedded"
else
  pass "no prior user domain/email embedded"
fi
rm -f /tmp/vps-bootstrap-private.$$ 2>/dev/null || true

[ "$FAIL" -eq 0 ] && echo "SELF_TEST_PASS" || exit 1
