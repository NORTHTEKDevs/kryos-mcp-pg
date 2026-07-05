#!/usr/bin/env bash
# tests/run_adversarial_tests.sh — regression gate for the token-based validator.
# Each case is a known bypass (must REFUSE) or a legitimate query (must ALLOW).
# Born from the 2026-07-05 adversarial probe that broke the v0.2 substring validator.
set -u
cd "$(dirname "$0")/.."
export DATABASE_URL="postgresql://fake:fake@ep-test-host.aws.neon.tech/db"
export KRYOS_MCP_PG_GRANTS="grants.example.json"

OUT="$(mktemp)"; trap 'rm -f "$OUT"' EXIT
kryos run src/main.kry < tests/adversarial-scenarios.jsonl > "$OUT" 2>/dev/null

# id -> expected verdict + label
declare -A EXP=(
  [100]="ALLOW|legit filtered read"
  [101]="REFUSE|column allowlist (password_hash)"
  [102]="REFUSE|read missing required filter"
  [103]="REFUSE|SELECT * double-space bypass"
  [104]="REFUSE|comma-join to ungranted table"
  [105]="REFUSE|WHERE hidden in string literal"
  [106]="REFUSE|window over( without space"
  [107]="REFUSE|stacked DROP after SELECT"
  [108]="REFUSE|subquery on ungranted table"
  [109]="REFUSE|DELETE without WHERE"
  [110]="REFUSE|comment-smuggled FROM secrets"
  [111]="ALLOW|count(*) is not SELECT *"
  [112]="ALLOW|write with WHERE"
)

PASS=0; FAIL=0
for id in $(printf '%s\n' "${!EXP[@]}" | sort -n); do
  exp="${EXP[$id]%%|*}"; label="${EXP[$id]#*|}"
  line="$(grep "\"id\":$id[,}]" "$OUT" | head -1)"
  if echo "$line" | grep -q "WOULD ALLOW"; then got="ALLOW"; else got="REFUSE"; fi
  if [ "$got" = "$exp" ]; then echo "PASS  [$id $got] $label"; PASS=$((PASS+1))
  else echo "FAIL  [$id got=$got exp=$exp] $label"; FAIL=$((FAIL+1)); fi
done
echo ""
echo "=== Adversarial Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
