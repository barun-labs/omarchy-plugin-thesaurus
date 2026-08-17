#!/usr/bin/env bash
# Checks llm.sh's JSON contract using a stubbed curl and a temp key file.
# No live DeepSeek key or network is used.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
sh="$here/llm.sh"
fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
keyfile="$work/key"; printf 'sk-test-key' > "$keyfile"
shimdir="$work/bin"; mkdir -p "$shimdir"

# make_curl <exit-code> <stdout-body-including-trailing-httpcode-line>
# llm.sh calls: curl ... -w '\n%{http_code}' ; so the shim must print the body,
# then a newline, then the HTTP status code, and exit with <exit-code>.
make_curl() {
  { printf '#!/usr/bin/env bash\n'; printf 'cat <<'\''BODY'\''\n%s\nBODY\n' "$2";
    printf 'exit %s\n' "$1"; } > "$shimdir/curl"
  chmod +x "$shimdir/curl"
}

ok_body='{"choices":[{"message":{"content":"Slang for delusional."}}]}
200'

run() { PATH="$shimdir:$PATH" THESAURUS_KEY_FILE="$keyfile" DEEPSEEK_ENDPOINT="http://stub" "$sh" "$@"; }

# --- empty input: no network, no key needed ---
out="$(THESAURUS_KEY_FILE="$keyfile" "$sh" --mode explain "")"
check "empty: valid json"   'printf "%s" "$out" | jq -e . >/dev/null 2>&1'
check "empty: error==empty"  '[ "$(printf "%s" "$out" | jq -r .error)" = "empty" ]'
check "empty: output blank"  '[ "$(printf "%s" "$out" | jq -r .output)" = "" ]'

# --- no key: key file missing, must not call network ---
out="$(THESAURUS_KEY_FILE="$work/nope" "$sh" --mode explain delulu)"
check "nokey: error==no-key" '[ "$(printf "%s" "$out" | jq -r .error)" = "no-key" ]'
check "nokey: output blank"  '[ "$(printf "%s" "$out" | jq -r .output)" = "" ]'

# --- happy path: explain ---
make_curl 0 "$ok_body"
out="$(run --mode explain delulu)"
check "explain: valid json"  'printf "%s" "$out" | jq -e . >/dev/null 2>&1'
check "explain: error==null" '[ "$(printf "%s" "$out" | jq -r .error)" = "null" ]'
check "explain: mode"        '[ "$(printf "%s" "$out" | jq -r .mode)" = "explain" ]'
check "explain: input kept"  '[ "$(printf "%s" "$out" | jq -r .input)" = "delulu" ]'
check "explain: has output"  '[ -n "$(printf "%s" "$out" | jq -r .output)" ]'

# --- transform: kind carried through ---
out="$(run --mode transform --kind formalize "gonna")"
check "transform: valid json" 'printf "%s" "$out" | jq -e . >/dev/null 2>&1'
check "transform: kind"       '[ "$(printf "%s" "$out" | jq -r .kind)" = "formalize" ]'

# --- rate limit: HTTP 429 ---
make_curl 0 '{"error":"rate limited"}
429'
out="$(run --mode explain delulu)"
check "429: error==rate-limit" '[ "$(printf "%s" "$out" | jq -r .error)" = "rate-limit" ]'

# --- offline: curl non-zero (generic) ---
make_curl 7 ''
out="$(run --mode explain delulu)"
check "offline: error==offline" '[ "$(printf "%s" "$out" | jq -r .error)" = "offline" ]'

# --- timeout: curl exit 28 ---
make_curl 28 ''
out="$(run --mode explain delulu)"
check "timeout: error==timeout" '[ "$(printf "%s" "$out" | jq -r .error)" = "timeout" ]'

exit $fail
