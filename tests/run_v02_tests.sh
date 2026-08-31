#!/usr/bin/env bash
# tests/run_v02_tests.sh — v0.2 feature tests:
#   1. Schema-qualified table matching
#   2. Per-call audit log

set -u

cd "$(dirname "$0")/.."

export DATABASE_URL="postgresql://fake:fake@ep-test-host.aws.neon.tech/db"

OUT="$(mktemp)"
AUDIT_FILE="$(mktemp)"
rm -f "$AUDIT_FILE"
trap 'rm -f "$OUT" "$AUDIT_FILE"' EXIT

PASS=0
FAIL=0

assert_line() {
  local id="$1"
  local pattern="$2"
  local label="$3"
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
    echo "      expected: $pattern"
    echo "      got: $line"
    FAIL=$((FAIL+1))
  fi
}

assert_file_match() {
  local pattern="$1"
  local label="$2"
  local n
  n="$(grep -cE "$pattern" "$AUDIT_FILE")"
  if [ "$n" -ge 1 ]; then
    echo "PASS  [$label]  ($n match)"
    PASS=$((PASS+1))
  else
    echo "FAIL  [$label]  no audit-log line matched: $pattern"
    FAIL=$((FAIL+1))
  fi
}

echo "=== v0.2: Schema-qualified table matching ==="
echo

KRYOS_MCP_PG_GRANTS=tests/v02-grants-schemas.json \
  kryos run src/main.kry < tests/v02-scenarios-schemas.jsonl > "$OUT" 2>/dev/null

assert_line 1 'WOULD ALLOW.*public\.users'                     "S1: bare 'users' resolves to public.users"
assert_line 2 'WOULD ALLOW.*public\.users'                     "S2: explicit public.users allowed"
assert_line 3 'WOULD ALLOW.*analytics\.events'                 "S3: qualified analytics.events allowed"
assert_line 4 'WOULD REFUSE.*not in grants'                    "S4: bare 'events' refused (events not in public)"
assert_line 5 'WOULD REFUSE.*not in grants'                    "S5: analytics.users refused (no such grant)"
assert_line 6 'WOULD ALLOW.*public\.users.*analytics\.events'  "S6: cross-schema join works when both granted"

echo
echo "=== v0.2: Per-call audit log ==="
echo

export KRYOS_MCP_PG_AUDIT_LOG="$AUDIT_FILE"
KRYOS_MCP_PG_GRANTS=grants.example.json \
  kryos run src/main.kry < tests/v02-scenarios-audit.jsonl > "$OUT" 2>/dev/null
unset KRYOS_MCP_PG_AUDIT_LOG

if [ ! -s "$AUDIT_FILE" ]; then
  echo "FAIL  [audit log file was created and non-empty]"
  echo "      path: $AUDIT_FILE"
  FAIL=$((FAIL+1))
else
  echo "PASS  [audit log file is non-empty]"
  PASS=$((PASS+1))
fi

# Each scenario should have produced one JSONL line.
LINES="$(wc -l < "$AUDIT_FILE")"
if [ "$LINES" -eq 3 ]; then
  echo "PASS  [audit log has 3 lines for 3 dry_run calls]"
  PASS=$((PASS+1))
else
  echo "FAIL  [audit log line count]  expected 3, got $LINES"
  echo "--- audit file ---"
  cat "$AUDIT_FILE"
  FAIL=$((FAIL+1))
fi

assert_file_match '"tool":"dry_run"'                             "audit: tool field is dry_run"
assert_file_match '"verdict":"allowed".*FROM users'              "audit: allowed line for SELECT users"
assert_file_match '"verdict":"refused".*deny_select_star'        "audit: refused line carries reason for SELECT *"
assert_file_match '"verdict":"refused".*ddl.allowed = false'     "audit: refused line carries reason for DROP TABLE"
assert_file_match '"ts":[0-9]+'                                  "audit: ts is a number"

# JSON validity: each line should parse as JSON.
PARSE_FAILS=0
while IFS= read -r line; do
  if ! echo "$line" | python3 -c "import sys, json; json.loads(sys.stdin.read())" 2>/dev/null; then
    PARSE_FAILS=$((PARSE_FAILS+1))
  fi
done < "$AUDIT_FILE"
if [ "$PARSE_FAILS" -eq 0 ]; then
  echo "PASS  [audit: every line is valid JSON]"
  PASS=$((PASS+1))
else
  echo "FAIL  [audit: $PARSE_FAILS lines failed JSON parse]"
  cat "$AUDIT_FILE"
  FAIL=$((FAIL+1))
fi

echo
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
