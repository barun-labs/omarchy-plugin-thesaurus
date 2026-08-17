#!/usr/bin/env bash
# LLM explain/transform for the barun-labs.thesaurus Omarchy plugin.
#
# Usage:
#   llm.sh --mode explain [word]
#   llm.sh --mode transform --kind <formalize|simplify|use-in-sentence|translate> [word]
# No word argument -> reads the primary (highlighted) selection.
#
# Always prints ONE JSON object to stdout and exits 0, so the QML caller parses
# a single fixed shape on every path:
#   {mode, kind, input, output, error}
#   error ∈ null | "no-key" | "offline" | "timeout" | "rate-limit" | "empty".
# Any non-null error -> output is "".
set -uo pipefail

MODEL="deepseek-chat"
ENDPOINT="${DEEPSEEK_ENDPOINT:-https://api.deepseek.com/chat/completions}"
KEY_FILE="${THESAURUS_KEY_FILE:-$HOME/.config/deepseek/thesaurus-key}"
TARGET_LANG="English"
MAX_TOKENS=300
TIMEOUT=8

mode=""; kind=""; word_arg=""; have_word=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) mode="${2:-}"; shift 2 ;;
    --kind) kind="${2:-}"; shift 2 ;;
    *)      word_arg="$1"; have_word=1; shift ;;
  esac
done

if [[ $have_word -eq 1 ]]; then
  input="$word_arg"
else
  input="$(wl-paste --primary --no-newline 2>/dev/null || true)"
fi
input="$(printf '%s' "$input" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

emit() { # emit <error> <output>
  jq -cn --arg m "$mode" --arg k "$kind" --arg i "$input" \
     --arg o "$2" --arg e "$1" \
     '{mode:$m, kind:$k, input:$i, output:$o,
       error:(if $e=="" then null else $e end)}'
}

if [[ -z "$input" ]]; then emit "empty" ""; exit 0; fi

if [[ ! -s "$KEY_FILE" ]]; then emit "no-key" ""; exit 0; fi
key="$(tr -d '\r\n' < "$KEY_FILE")"
if [[ -z "$key" ]]; then emit "no-key" ""; exit 0; fi

# One system prompt per mode/kind. Kept short; the model returns prose only.
case "$mode" in
  explain)
    sys="You explain words and phrases concisely for someone reading. If the input is slang, give its meaning and one short example. If it is not English, translate it to English. If it is a phrase or sentence, explain what it means in plain English. 2-3 sentences max. No preamble." ;;
  transform)
    case "$kind" in
      formalize)       sys="Rewrite the input in a formal register. Output only the rewrite, nothing else." ;;
      simplify)        sys="Rewrite the input in plain, simple language a child could follow. Output only the rewrite, nothing else." ;;
      use-in-sentence) sys="Use the input word or phrase naturally in one example sentence. Output only the sentence." ;;
      translate)       sys="Translate the input to ${TARGET_LANG}. Output only the translation, nothing else." ;;
      *) emit "empty" ""; exit 0 ;;
    esac ;;
  *) emit "empty" ""; exit 0 ;;
esac

payload="$(jq -cn --arg model "$MODEL" --argjson max "$MAX_TOKENS" \
  --arg sys "$sys" --arg usr "$input" \
  '{model:$model, max_tokens:$max,
    messages:[{role:"system",content:$sys},{role:"user",content:$usr}]}')"

resp="$(curl -sS --max-time "$TIMEOUT" -w $'\n%{http_code}' \
  -H "Authorization: Bearer $key" -H "Content-Type: application/json" \
  -d "$payload" "$ENDPOINT" 2>/dev/null)"
rc=$?

if [[ $rc -eq 28 ]]; then emit "timeout" ""; exit 0; fi
if [[ $rc -ne 0 ]]; then emit "offline" ""; exit 0; fi

status="$(printf '%s' "$resp" | tail -n1)"
body="$(printf '%s' "$resp" | sed '$d')"

if [[ "$status" == "429" ]]; then emit "rate-limit" ""; exit 0; fi
if [[ "$status" != "200" ]]; then emit "offline" ""; exit 0; fi

output="$(printf '%s' "$body" | jq -r '.choices[0].message.content // ""' 2>/dev/null)"
output="$(printf '%s' "$output" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
if [[ -z "$output" ]]; then emit "offline" ""; exit 0; fi

emit "" "$output"
