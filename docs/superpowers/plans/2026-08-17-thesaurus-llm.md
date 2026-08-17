# Thesaurus Phase 2 (LLM Explain + Transform) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an LLM layer to the thesaurus plugin so slang, foreign words, and phrases (which the free dictionary can't answer) get a plain-English explanation, plus on-demand text transforms — while ordinary English words still use the free, keyless, offline-capable phase-1 path.

**Architecture:** A new CLI script `llm.sh` mirrors the existing `lookup.sh` contract: it reads the highlighted word (or an argument), calls DeepSeek over the OpenAI-compatible chat endpoint, and prints exactly one JSON object. `lookup.sh` is untouched. `Panel.qml` gains a second Quickshell `Process` for `llm.sh`, an action row (Define · Explain · Transform▾), an LLM output card, and a "Thinking…" state; it auto-fires Explain when a dictionary lookup comes back empty. `BarWidget.qml` exposes one new IPC verb, `explainSelection`.

**Tech Stack:** bash + curl + jq for `llm.sh` (same as `lookup.sh`); DeepSeek `deepseek-chat` via `https://api.deepseek.com/chat/completions`; Quickshell/QML (`qs.Ui`, `qs.Commons`, `Quickshell.Io`) for the panel.

**Spec:** `docs/superpowers/specs/2026-08-17-thesaurus-llm-design.md`

## Global Constraints

- Plugin id `barun-labs.thesaurus`; every `moduleName` and `IpcHandler` `target` = that id verbatim.
- `lookup.sh` is UNCHANGED by this plan. Phase-1 tests (`tests/test-lookup.sh`) must still pass.
- `llm.sh` MUST always print exactly one JSON object of shape
  `{mode, kind, input, output, error}` and exit 0.
  `error` ∈ `null | "no-key" | "offline" | "timeout" | "rate-limit" | "empty"`.
  Any non-null `error` ⇒ `output` is `""`.
- Key is read from `~/.config/deepseek/thesaurus-key`, overridable via env
  `THESAURUS_KEY_FILE` (this override exists ONLY so tests can point at a temp
  file — it is a normal env read, not a code path). The key is never hardcoded,
  never printed to stdout/stderr, never sent anywhere but the DeepSeek endpoint.
- `llm.sh` top-of-file constants, each on its own line, easy to retarget:
  `MODEL="deepseek-chat"`, `ENDPOINT="https://api.deepseek.com/chat/completions"`
  (overridable via env `DEEPSEEK_ENDPOINT` for tests), `TARGET_LANG="English"`,
  `MAX_TOKENS=300`, `TIMEOUT=8`.
- Deps assumed present (already used by `lookup.sh`): `bash`, `curl`, `jq`,
  `wl-paste`. No new runtime dependency.
- QML uses only stock Omarchy components already used by the phase-1 panel. There
  is no QML test framework in this repo; QML tasks are verified by reloading the
  shell and observing the panel (same as phase 1).
- Git commits: author is the user; do NOT add any Claude/Anthropic co-author or
  "Generated with" trailer.
- Version bumps `0.1.0` → `0.2.0` in `manifest.json` (Task 5).

---

### Task 1: `llm.sh` — the LLM core (with tests)

The whole LLM domain logic, testable from a plain shell with no QML and no live
network/key. This is the largest task; build and green it in isolation.

**Files:**
- Create: `llm.sh`
- Create: `tests/test-llm.sh`

**Interfaces:**
- Produces: an executable `llm.sh`. Usage:
  - `llm.sh --mode explain [word]`
  - `llm.sh --mode transform --kind <formalize|simplify|use-in-sentence|translate> [word]`
  - No word arg ⇒ reads `wl-paste --primary --no-newline`.
  - Prints one JSON object `{mode, kind, input, output, error}`, exits 0.
- Consumes (from Task 2's panel): the panel invokes it as
  `["bash", llmPath, "--mode", ...]`.

- [ ] **Step 1: Write the failing tests**

Create `tests/test-llm.sh`. It shims `curl` and the key file so no live key or
network is needed. Each scenario shim is a tiny script placed first on `PATH`.

```bash
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-llm.sh`
Expected: FAIL (llm.sh does not exist yet — errors / non-zero exit).

- [ ] **Step 3: Write `llm.sh`**

```bash
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
```

Then `chmod +x llm.sh`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `chmod +x llm.sh && bash tests/test-llm.sh`
Expected: every line `ok - …`, exit 0.

- [ ] **Step 5: Confirm phase 1 still green**

Run: `bash tests/test-lookup.sh`
Expected: unchanged from before (all `ok`, or the offline skip line).

- [ ] **Step 6: Commit**

```bash
git add llm.sh tests/test-llm.sh
git commit -m "feat: llm.sh — DeepSeek explain + transform with full error contract"
```

---

### Task 2: Panel — Explain action + LLM process + output card

Wire `llm.sh` into the panel as a second process, add the action row and the
`Explain` button, render the LLM output, and add the Thinking/error states.

**Files:**
- Modify: `Panel.qml`

**Interfaces:**
- Consumes: `llm.sh` from Task 1 (JSON `{mode, kind, input, output, error}`).
- Produces (for Tasks 3 & 4): a QML function `runLlm(mode, kind)` that starts
  `llmProcess`; properties `llmOutput`, `llmError`, `llmLoading`, `llmSource`.

- [ ] **Step 1: Add LLM state + helper path**

Below the existing phase-1 properties, add:

```qml
  property string llmOutput: ""
  property string llmError: ""
  property bool llmLoading: false

  readonly property string llmHelperPath: {
    var url = String(Qt.resolvedUrl("llm.sh"))
    return decodeURIComponent(url.indexOf("file://") === 0 ? url.substring(7) : url)
  }
```

Extend `clearResult()` to also reset `llmOutput`, `llmError`, `llmLoading`.

- [ ] **Step 2: Add `runLlm` + a second Process**

```qml
  function runLlm(mode, kind) {
    if (llmProcess.running || lookupProcess.running) return
    root.llmLoading = true
    root.llmError = ""
    root.llmOutput = ""
    var args = [root.llmHelperPath, "--mode", mode]
    if (kind && kind !== "") args = args.concat(["--kind", kind])
    if (root.word !== "") args = args.concat([root.word])
    llmProcess.command = ["bash"].concat(args)
    llmProcess.running = true
  }

  function applyLlm(raw) {
    var parsed
    try { parsed = JSON.parse(raw) } catch (e) { parsed = null }
    if (!parsed) { root.llmError = "offline"; return }
    root.llmError = parsed.error ? String(parsed.error) : ""
    root.llmOutput = root.llmError === "" ? String(parsed.output || "") : ""
  }

  Process {
    id: llmProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyLlm(text)
    }
    onExited: function(exitCode) {
      root.llmLoading = false
      if (exitCode !== 0 && root.llmError === "" && root.llmOutput === "")
        root.llmError = "offline"
    }
  }
```

Note: `runLlm` passes `root.word`. When a selection was looked up, `root.word`
is already set by `applyResult`; when the user typed a word, it is the typed
word. If `root.word` is empty (raw selection, dictionary found nothing and did
not set a word), omit the arg so `llm.sh` reads the selection itself — the
`if (root.word !== "")` guard already does this.

- [ ] **Step 3: Add the action row**

Inside the result `Column` (or just under `queryField`), add a Row visible once
there is a word/selection to act on. Follow the existing suggestion-chip styling
(a `Text` + `MouseArea`, accent on hover):

```qml
  Row {
    visible: root.word !== "" || queryField.text !== ""
    width: parent.width
    spacing: Style.space(14)

    // Reuse this inline for Define / Explain. Transform added in Task 4.
    Text {
      text: "Define"
      color: defMouse.containsMouse ? Color.accent : root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.body
      MouseArea { id: defMouse; anchors.fill: parent; hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.lookupWord(queryField.text !== "" ? queryField.text : root.word) }
    }
    Text {
      text: "Explain"
      color: expMouse.containsMouse ? Color.accent : root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.body
      MouseArea { id: expMouse; anchors.fill: parent; hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.runLlm("explain", "") }
    }
  }
```

- [ ] **Step 4: Render LLM output + states**

Add, after the dictionary result card:

```qml
  // LLM "Thinking…" line.
  Text {
    visible: root.llmLoading
    width: parent.width
    text: "Thinking…"
    color: Util.alpha(root.contentForeground, 0.64)
    font.family: root.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  // LLM error line (distinct messages per kind).
  Text {
    visible: !root.llmLoading && root.llmError !== ""
    width: parent.width
    text: root.llmError === "no-key"
        ? "Add a DeepSeek key to enable Explain (see README)."
      : root.llmError === "rate-limit" ? "Rate limited — try again shortly."
      : root.llmError === "timeout" ? "Timed out — try again."
      : "Offline — Explain unavailable."
    color: Util.alpha(root.contentForeground, 0.64)
    font.family: root.contentFontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  // LLM output card.
  Column {
    visible: !root.llmLoading && root.llmError === "" && root.llmOutput !== ""
    width: parent.width
    spacing: Style.space(4)
    Text {
      width: parent.width
      text: root.llmOutput
      color: root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.body
      wrapMode: Text.WordWrap
    }
    Text {
      text: "via DeepSeek"
      color: Util.alpha(root.contentForeground, 0.4)
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }
  }
```

- [ ] **Step 5: Verify (manual — no QML test harness)**

With a key present at `~/.config/deepseek/thesaurus-key`: reload the Omarchy
shell, open the panel, type `delulu`, press Enter (dictionary finds nothing),
click **Explain** → a plain-English explanation appears with "via DeepSeek".
Remove/rename the key file, click Explain → "Add a DeepSeek key…" line shows,
dictionary still works. Confirm the panel loads with no QML errors in the shell
log.

- [ ] **Step 6: Commit**

```bash
git add Panel.qml
git commit -m "feat: panel Explain action, LLM process, output card and states"
```

---

### Task 3: Panel — auto-fallback to Explain on empty dictionary result

When a dictionary lookup returns nothing usable, fire Explain automatically so
slang/foreign selections answer with zero extra clicks.

**Files:**
- Modify: `Panel.qml`

**Interfaces:**
- Consumes: `runLlm` and the LLM state from Task 2; `applyResult` from phase 1.

- [ ] **Step 1: Trigger Explain from `applyResult`**

At the end of `applyResult(raw)`, after the existing field-fill logic, add: if
the dictionary result is genuinely empty (no definition, no synonyms, no
antonyms) AND there was no transport error AND there is a word to explain, run
Explain once.

```qml
    // Auto-fallback: dictionary found nothing usable (not an offline error) —
    // ask the LLM to explain. Fires at most once per lookup.
    if (root.errorKind === "" && root.definition === ""
        && root.synonyms.length === 0 && root.antonyms.length === 0
        && root.word !== "") {
      root.runLlm("explain", "")
    }
```

Note the ordering: `applyResult` already set `root.word`. The `runLlm` guard
skips if a process is already running, so this cannot stack.

- [ ] **Step 2: Verify (manual)**

Reload the shell. Type `delulu`, press Enter. Without any click, "Thinking…"
then the explanation appears. Type `perfidious`, press Enter → dictionary card
shows and NO LLM call fires (no "Thinking…", no "via DeepSeek"). With the key
removed, `delulu` shows the dictionary "No definition found" plus the "Add a
DeepSeek key…" line, and the plugin stays usable.

- [ ] **Step 3: Commit**

```bash
git add Panel.qml
git commit -m "feat: auto-fallback to Explain when dictionary returns nothing"
```

---

### Task 4: Panel — Transform menu

Add the `Transform▾` control with the four transform kinds.

**Files:**
- Modify: `Panel.qml`

**Interfaces:**
- Consumes: `runLlm(mode, kind)` from Task 2.

- [ ] **Step 1: Add a Transform toggle + kind list**

Add a bool `property bool transformOpen: false` near the other panel state.
In the action row (Task 2, Step 3), after `Explain`, add:

```qml
    Text {
      text: root.transformOpen ? "Transform ▾" : "Transform ▸"
      color: xfMouse.containsMouse ? Color.accent : root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.body
      MouseArea { id: xfMouse; anchors.fill: parent; hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.transformOpen = !root.transformOpen }
    }
```

- [ ] **Step 2: Add the kind chips**

Below the action row, a Flow of the four kinds, visible only when open:

```qml
  Flow {
    visible: root.transformOpen && (root.word !== "" || queryField.text !== "")
    width: parent.width
    spacing: Style.space(12)
    Repeater {
      model: ["formalize", "simplify", "use-in-sentence", "translate"]
      Text {
        required property var modelData
        text: modelData
        color: kMouse.containsMouse ? Color.accent : Util.alpha(root.contentForeground, 0.8)
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.body
        font.underline: kMouse.containsMouse
        MouseArea { id: kMouse; anchors.fill: parent; hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: { root.transformOpen = false; root.runLlm("transform", modelData) } }
      }
    }
  }
```

- [ ] **Step 3: Verify (manual)**

Reload the shell. Type `gonna`, click **Transform ▸** → four kinds appear. Click
`formalize` → LLM output card shows a formal rewrite ("going to") with "via
DeepSeek". Click `translate` on a word → the target-language rendering appears.

- [ ] **Step 4: Commit**

```bash
git add Panel.qml
git commit -m "feat: Transform menu — formalize / simplify / use-in-sentence / translate"
```

---

### Task 5: `explainSelection` IPC verb, manifest bump, README

Expose the keybind path and document setup.

**Files:**
- Modify: `BarWidget.qml`
- Modify: `manifest.json`
- Modify: `README.md`

**Interfaces:**
- Consumes: `Panel.qml`'s functions.

- [ ] **Step 1: Add the panel entry point**

In `BarWidget.qml`, next to `openSelection()`/`toggleSelection()`, add:

```qml
  function explainSelection() { if (panelLoader.item) panelLoader.item.explainWithSelection() }
```

And add the IPC verb inside `IpcHandler`:

```qml
    function explainSelection(): void { root.explainSelection() }
```

- [ ] **Step 2: Add `explainWithSelection` to Panel.qml**

```qml
  // Open and immediately explain the highlighted selection via the LLM. Bound
  // to the explainSelection IPC verb / a keybind.
  function explainWithSelection() {
    root.controller.show()
    root.clearResult()
    queryField.text = ""
    queryField.prefilled = false
    root.runLlm("explain", "")   // no word set yet -> llm.sh reads the selection
  }
```

- [ ] **Step 3: Bump the version**

In `manifest.json`, change `"version": "0.1.0"` to `"version": "0.2.0"`, and
update `description` to mention explain/translate, e.g.:
`"Highlight a word for its definition, synonyms and antonyms — or an LLM explanation for slang, foreign words and phrases."`

- [ ] **Step 4: Document in README**

Add a section covering: the Explain/Transform features; that they need a DeepSeek
key at `~/.config/deepseek/thesaurus-key` (`chmod 600`), and that without it the
dictionary still works; and an example keybind wiring the `explainSelection`
verb, e.g.:

```
# Omarchy keybind (user config) — highlight, then this key explains it:
bind = SUPER, e, global, quickshell:barun-labs.thesaurus:explainSelection
```

State that `deepseek-chat` is the model and that the model / target language are
constants at the top of `llm.sh`.

- [ ] **Step 5: Verify (manual)**

Reload the shell. Highlight a slang word anywhere, press the bound key → panel
opens and explains it directly. Confirm `manifest.json` parses
(`jq . manifest.json`).

- [ ] **Step 6: Commit**

```bash
git add BarWidget.qml Panel.qml manifest.json README.md
git commit -m "feat: explainSelection IPC verb, v0.2.0, README key + keybind docs"
```

---

## Self-Review

**Spec coverage:**
- Explain (slang/translate/phrase) → Task 1 (prompt) + Task 2 (action) + Task 3 (auto-fallback). ✓
- Transform (4 kinds) → Task 1 (prompts) + Task 4 (menu). ✓
- Auto-fallback trigger model → Task 3. ✓
- DeepSeek engine, model constant, endpoint → Task 1 constants. ✓
- Key at `~/.config/deepseek/thesaurus-key`, graceful no-key → Task 1 (`no-key`) + Task 2 (error line) + Task 5 (README). ✓
- Error kinds no-key/offline/timeout/rate-limit/empty → Task 1 contract + tests. ✓
- Panel action row, output card, Thinking state → Task 2. ✓
- `explainSelection` verb + keybind → Task 5. ✓
- Tests mock DeepSeek, no live key → Task 1 `tests/test-llm.sh`. ✓
- `lookup.sh` unchanged, phase-1 tests still pass → Task 1 Step 5. ✓
- Out of scope (streaming, settings UI, provider abstraction) → not built. ✓

**Type/name consistency:** `runLlm(mode, kind)`, `applyLlm`, `llmProcess`,
`llmOutput`/`llmError`/`llmLoading`, `llmHelperPath`, `explainWithSelection`,
`explainSelection` used identically across Tasks 2–5. `llm.sh` JSON keys
`{mode, kind, input, output, error}` match between Task 1 script, Task 1 tests,
and Task 2 `applyLlm`. ✓

**Placeholder scan:** no TBD/TODO; every code step carries real code. ✓
