#!/usr/bin/env bash
# Checks lookup.sh's JSON contract. Network cases are skipped cleanly offline.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
sh="$here/lookup.sh"
fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

# Empty input: deterministic, needs no network.
out="$("$sh" "")"
check "empty: valid json"   'printf "%s" "$out" | jq -e . >/dev/null 2>&1'
check "empty: error==empty" '[ "$(printf "%s" "$out" | jq -r .error)" = "empty" ]'
check "empty: synonyms==[]"  '[ "$(printf "%s" "$out" | jq -c .synonyms)" = "[]" ]'

if curl -fsS --max-time 5 "https://api.datamuse.com/words?max=1&rel_syn=test" >/dev/null 2>&1; then
  out="$("$sh" perfidious)"
  check "word: valid json"     'printf "%s" "$out" | jq -e . >/dev/null 2>&1'
  check "word: error==null"    '[ "$(printf "%s" "$out" | jq -r .error)" = "null" ]'
  check "word: has synonyms"   '[ "$(printf "%s" "$out" | jq ".synonyms|length")" -gt 0 ]'
  check "word: has definition" '[ -n "$(printf "%s" "$out" | jq -r .definition)" ]'

  out="$("$sh" zxqwvyx)"
  check "nonsense: valid json"     'printf "%s" "$out" | jq -e . >/dev/null 2>&1'
  check "nonsense: error==null"    '[ "$(printf "%s" "$out" | jq -r .error)" = "null" ]'
  check "nonsense: word preserved" '[ "$(printf "%s" "$out" | jq -r .word)" = "zxqwvyx" ]'
else
  echo "skip - network cases (offline)"
fi
exit $fail
