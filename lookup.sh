#!/usr/bin/env bash
# Thesaurus/dictionary lookup for the barun-labs.thesaurus Omarchy plugin.
#
# Usage: lookup.sh [word]
#   No argument  -> reads the primary (highlighted) X/Wayland selection.
#   Empty string -> reports {error:"empty"} without touching the selection.
#
# Always prints ONE JSON object to stdout and exits 0, so the QML caller
# parses a single, fixed shape on every path:
#   {word, definition, example, synonyms[], antonyms[], suggestions[], error}
#   error is one of: null, "empty", "offline".
set -uo pipefail

if [[ $# -ge 1 ]]; then
  word="$1"
else
  word="$(wl-paste --primary --no-newline 2>/dev/null || true)"
fi

# Trim, take the first token, and shed punctuation a selection drags in
# ("perfidious," -> "perfidious").
word="$(printf '%s' "$word" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
word="${word%%[[:space:]]*}"
word="$(printf '%s' "$word" | sed -e 's/^[^[:alnum:]]*//' -e 's/[^[:alnum:]-]*$//')"

emit() { # emit <error> <definition> <example> <syn-json> <ant-json> <sug-json>
  jq -cn --arg w "$word" --arg err "$1" --arg def "$2" --arg ex "$3" \
     --argjson syn "$4" --argjson ant "$5" --argjson sug "$6" \
     '{word:$w, definition:$def, example:$ex, synonyms:$syn, antonyms:$ant,
       suggestions:$sug, error:(if $err=="" then null else $err end)}'
}

if [[ -z "$word" ]]; then
  emit "empty" "" "" "[]" "[]" "[]"
  exit 0
fi

enc="$(jq -rn --arg w "$word" '$w|@uri')"

# Datamuse: synonyms + antonyms. An unknown word returns 200 with [], which is
# not an error; only a transport failure is.
syn_raw="$(curl -fsS --max-time 6 "https://api.datamuse.com/words?max=8&rel_syn=$enc" 2>/dev/null)"
net=$?
ant_raw="$(curl -fsS --max-time 6 "https://api.datamuse.com/words?max=8&rel_ant=$enc" 2>/dev/null)"

if [[ $net -ne 0 && -z "$syn_raw" ]]; then
  emit "offline" "" "" "[]" "[]" "[]"
  exit 0
fi

syn="$(printf '%s' "${syn_raw:-[]}" | jq -c '[.[].word]' 2>/dev/null || echo '[]')"
ant="$(printf '%s' "${ant_raw:-[]}" | jq -c '[.[].word]' 2>/dev/null || echo '[]')"

# Free Dictionary API: first definition + first example. 404 (unknown word)
# makes curl -f fail, leaving def/ex empty — a valid, non-error result.
dict_raw="$(curl -fsS --max-time 6 "https://api.dictionaryapi.dev/api/v2/entries/en/$enc" 2>/dev/null)"
def=""; ex=""
if [[ -n "$dict_raw" ]] && printf '%s' "$dict_raw" | jq -e 'type=="array"' >/dev/null 2>&1; then
  def="$(printf '%s' "$dict_raw" | jq -r 'first(.[].meanings[].definitions[].definition) // ""' 2>/dev/null)"
  ex="$(printf '%s' "$dict_raw" | jq -r 'first(.[].meanings[].definitions[] | select(.example) | .example) // ""' 2>/dev/null)"
fi

# Nothing matched — offer spelling suggestions ("did you mean").
sug="[]"
if [[ -z "$def" && "$syn" == "[]" && "$ant" == "[]" ]]; then
  sug_raw="$(curl -fsS --max-time 6 "https://api.datamuse.com/sug?s=$enc&max=5" 2>/dev/null)"
  sug="$(printf '%s' "${sug_raw:-[]}" | jq -c --arg w "$word" \
        '[.[].word | select(ascii_downcase != ($w|ascii_downcase))]' 2>/dev/null || echo '[]')"
fi

emit "" "$def" "$ex" "$syn" "$ant" "$sug"
