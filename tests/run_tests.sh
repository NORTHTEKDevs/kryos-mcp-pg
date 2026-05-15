#!/usr/bin/env bash
# tests/run_tests.sh — offline validator tests for kryos-mcp-pg.
#
# Drives main.kry over stdio with a fixed JSON-RPC scenario list and asserts
# expected substrings appear in each response. Uses dry_run only — no network.
#
# Usage:
#   bash tests/run_tests.sh
#
# Exit code 0 on full pass, 1 on any failure.

set -u

cd "$(dirname "$0")/.."

export DATABASE_URL="postgresql://fake:fake@ep-test-host.aws.neon.tech/db"
export KRYOS_MCP_PG_GRANTS="grants.example.json"

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

# Run server with all requests piped in; capture stdout. Stderr goes to /dev/null
# (it has the "grants loaded" startup line plus any runtime warnings).
kryos run src/main.kry < tests/scenarios.jsonl > "$OUT" 2>/dev/null

PASS=0
FAIL=0

assert_line() {
  local id="$1"
  local pattern="$2"
  local label="$3"
  # Find the response line for this id
  local line
  line="$(grep -E "\"id\":${id}([,}])" "$OUT" | head -n1)"
  if [ -z "$line" ]; then
    echo "FAIL  [$label]  no response for id=$id"
    FAIL=$((FAIL+1))
    return
  fi
  if echo "$line" | grep -qE "$pattern"; then
    echo "PASS  [$label]"
    PASS=$((PASS+1))
  else
    echo "FAIL  [$label]"
    echo "      expected pattern: $pattern"
    echo "      got: $line"
    FAIL=$((FAIL+1))
  fi
}

echo "=== kryos-mcp-pg validator tests ==="
echo

# 1. initialize
assert_line 1  '"protocolVersion":"2024-11-05"'                                "initialize returns protocol version"
assert_line 1  '"name":"kryos-mcp-pg"'                                          "initialize returns server name"

# 2. tools/list — six tools
assert_line 2  '"name":"query"'                                                 "tools/list includes query"
assert_line 2  '"name":"explain"'                                               "tools/list includes explain"
assert_line 2  '"name":"dry_run"'                                               "tools/list includes dry_run"
assert_line 2  '"name":"tables"'                                                "tools/list includes tables"
assert_line 2  '"name":"schema"'                                                "tools/list includes schema"
assert_line 2  '"name":"grants"'                                                "tools/list includes grants"

# 3. grants tool
assert_line 3  'host: ep-test-host.aws.neon.tech'                               "grants reports parsed host"
assert_line 3  'ddl_allowed: 0'                                                 "grants reports ddl_allowed=0"
assert_line 3  'deny_select_star: 1'                                            "grants reports deny_select_star=1"

# 4. tables tool
assert_line 4  'public \\| users'                                               "tables lists users"
assert_line 4  'public \\| orders'                                              "tables lists orders"
assert_line 4  'public \\| audit_log'                                           "tables lists audit_log"

# README scenarios 1–7
assert_line 10 'WOULD ALLOW.*action=read.*users'                                "S1: read users with WHERE allowed"
assert_line 11 'WOULD REFUSE.*deny_select_star'                                 "S2: SELECT * refused"
assert_line 12 'WOULD REFUSE.*require_where_on_writes'                          "S3: DELETE without WHERE refused"
assert_line 13 'WOULD REFUSE.*not in grants'                                    "S4: SELECT from secrets refused"
assert_line 14 'WOULD REFUSE.*ddl.allowed = false'                              "S5: DROP TABLE refused"
assert_line 15 'WOULD ALLOW.*action=write.*audit_log'                           "S6: INSERT into audit_log allowed"
assert_line 16 'WOULD REFUSE.*audit_log.*not granted action.*read'              "S7: SELECT from audit_log refused"

# Edge cases
assert_line 20 'WOULD ALLOW.*action=write.*orders'                              "E1: UPDATE orders WHERE id=1 allowed"
assert_line 21 'WOULD REFUSE.*require_where_on_writes'                          "E2: UPDATE without WHERE refused"
assert_line 22 'WOULD REFUSE.*not in grants'                                    "E3: JOIN onto ungranted table refused"
assert_line 23 'WOULD REFUSE.*allow_window'                                     "E4: window function OVER refused"
assert_line 24 'WOULD ALLOW.*action=read.*orders'                               "E5: EXPLAIN treated as read"
assert_line 25 'WOULD REFUSE.*could not classify'                               "E6: VACUUM unknown action refused"
assert_line 26 'WOULD REFUSE.*users.*not granted action.*write'                 "E7: DELETE on read-only users refused"
assert_line 27 'WOULD REFUSE.*not in grants'                                    "E8: INSERT into ungranted secrets refused"
assert_line 28 'WOULD ALLOW.*action=read.*orders'                               "E9: lowercase SQL works"

# Tool-level error handling
assert_line 29 'missing .table. argument'                                       "schema without table arg errors"
assert_line 30 'missing .sql. argument'                                         "query without sql arg errors"

echo
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  echo
  echo "--- raw output (for debugging) ---"
  cat "$OUT"
  exit 1
fi
exit 0
