# Thesaurus Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An Omarchy `bar-widget` plugin that, on a keybind, pops up the definition, an example sentence, synonyms and antonyms for the currently highlighted word.

**Architecture:** All lookup logic lives in one CLI script, `lookup.sh`, which reads the highlighted word (or an argument), queries two free no-key APIs (Datamuse for synonyms/antonyms, dictionaryapi.dev for definition/example), and prints one JSON object. The QML side is thin: `BarWidget.qml` is a bar icon that toggles `Panel.qml`; the panel runs `lookup.sh` via a Quickshell `Process`, parses the JSON, and renders a card. A Hyprland keybind summons the panel over the shell IPC.

**Tech Stack:** Quickshell/QML (Omarchy shell components from `qs.Ui` / `qs.Commons` / `Quickshell.Io`), bash + curl + jq for `lookup.sh`, `wl-paste` for the primary selection.

**Spec:** `docs/superpowers/specs/2026-08-16-thesaurus-design.md`

## Global Constraints

- Plugin id: `barun-labs.thesaurus` (third-party ids may not start with `omarchy.`).
- `moduleName` and every `IpcHandler` `target` string = the plugin id, verbatim.
- Repo root is the plugin dev dir: `~/.config/omarchy/plugins/barun-labs.thesaurus/`.
- `lookup.sh` MUST always print exactly one JSON object of shape
  `{word, definition, example, synonyms[], antonyms[], error}` and exit 0.
  `error` ∈ `null | "empty" | "offline"`.
- Deps assumed present (verified on this machine): `bash`, `curl`, `jq`, `wl-paste`.
- No new runtime dependency may be added; QML uses only stock Omarchy components
  already used by installed plugins.
- Online-only in phase 1. No offline WordNet, no translation (phase-2 seam only).
- Git commits: author is the user; do NOT add any Claude/Anthropic co-author or
  "Generated with" trailer.

---

### Task 1: `lookup.sh` — the lookup core (with tests)

The whole domain logic, testable from a plain shell with no QML involved.

**Files:**
- Create: `lookup.sh`
- Test: `tests/test-lookup.sh`

**Interfaces:**
- Produces: an executable `lookup.sh [word]`. No argument → reads
  `wl-paste --primary`. Prints one JSON object
  `{word, definition, example, synonyms[], antonyms[], error}` to stdout, exit 0.
  An explicit empty argument (`lookup.sh ""`) → `error: "empty"`.

- [ ] **Step 1: Write the failing test**

Create `tests/test-lookup.sh`:

```bash
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
```

Make it executable: `chmod +x tests/test-lookup.sh`.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-lookup.sh`
Expected: FAIL (or a bash error) because `lookup.sh` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `lookup.sh`:

```bash
#!/usr/bin/env bash
# Thesaurus/dictionary lookup for the barun-labs.thesaurus Omarchy plugin.
#
# Usage: lookup.sh [word]
#   No argument  -> reads the primary (highlighted) X/Wayland selection.
#   Empty string -> reports {error:"empty"} without touching the selection.
#
# Always prints ONE JSON object to stdout and exits 0, so the QML caller
# parses a single, fixed shape on every path:
#   {word, definition, example, synonyms[], antonyms[], error}
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

emit() { # emit <error> <definition> <example> <syn-json-array> <ant-json-array>
  jq -cn --arg w "$word" --arg err "$1" --arg def "$2" --arg ex "$3" \
     --argjson syn "$4" --argjson ant "$5" \
     '{word:$w, definition:$def, example:$ex, synonyms:$syn, antonyms:$ant,
       error:(if $err=="" then null else $err end)}'
}

if [[ -z "$word" ]]; then
  emit "empty" "" "" "[]" "[]"
  exit 0
fi

enc="$(jq -rn --arg w "$word" '$w|@uri')"

# Datamuse: synonyms + antonyms. An unknown word returns 200 with [], which is
# not an error; only a transport failure is.
syn_raw="$(curl -fsS --max-time 6 "https://api.datamuse.com/words?max=8&rel_syn=$enc" 2>/dev/null)"
net=$?
ant_raw="$(curl -fsS --max-time 6 "https://api.datamuse.com/words?max=8&rel_ant=$enc" 2>/dev/null)"

if [[ $net -ne 0 && -z "$syn_raw" ]]; then
  emit "offline" "" "" "[]" "[]"
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

emit "" "$def" "$ex" "$syn" "$ant"
```

Make it executable: `chmod +x lookup.sh`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-lookup.sh`
Expected: all `ok` lines; exit 0. (Offline, the network block prints one `skip`
line and the empty-input checks still pass.)
Also eyeball once: `./lookup.sh perfidious | jq .`

- [ ] **Step 5: Commit**

```bash
git add lookup.sh tests/test-lookup.sh
git commit -m "feat: lookup.sh — dictionary + thesaurus JSON lookup with tests"
```

---

### Task 2: Plugin manifest + bar icon skeleton

A validatable, enable-able plugin that shows an icon in the bar and loads a
(stub) panel. No lookup yet.

**Files:**
- Create: `manifest.json`
- Create: `BarWidget.qml`
- Create: `Panel.qml` (stub — replaced in Task 3)
- Create: `LICENSE` (MIT, copyright the user)

**Interfaces:**
- Produces: bar-widget root `BarWidget.qml` exposing `opened`,
  `popoutSwitchClosing`, `open()`, `close()`, `toggle()`,
  `closeForPopoutSwitch()`, and an `IpcHandler` with target
  `barun-labs.thesaurus` and methods `open/close/show/hide/toggle`. It injects
  `bar`, `anchorItem`, `hostWidget` into the loaded panel.
- Consumes (from Task 1): nothing yet.

- [ ] **Step 1: Write `manifest.json`**

```json
{
  "schemaVersion": 1,
  "id": "barun-labs.thesaurus",
  "name": "Thesaurus",
  "version": "0.1.0",
  "author": "barun-labs",
  "license": "MIT",
  "description": "Highlight a word while reading and get its definition, an example, synonyms and antonyms.",
  "kinds": ["bar-widget"],
  "entryPoints": { "barWidget": "BarWidget.qml" },
  "barWidget": {
    "displayName": "Thesaurus",
    "description": "Definition, example, synonyms and antonyms for the highlighted word",
    "category": "Utilities",
    "allowMultiple": false
  }
}
```

- [ ] **Step 2: Write `BarWidget.qml`**

```qml
import QtQuick
import Quickshell
import qs.Ui

// Bar icon for the thesaurus. Left-click toggles the lookup panel; the same
// panel is summoned by keybind through the IpcHandler below. Panel state and
// the popout contract are forwarded from the nested Panel.qml.
BarWidget {
  id: root
  moduleName: "barun-labs.thesaurus"

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "barun-labs.thesaurus"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰗊"
    tooltipText: "Thesaurus — look up the highlighted word"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
    }
  }
}
```

- [ ] **Step 3: Write a stub `Panel.qml`**

Minimal panel so the widget loads and validates; Task 3 replaces the body.

```qml
import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "barun-labs.thesaurus"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function open() { root.controller.show() }
  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      Column {
        id: content
        width: parent.width
        Text {
          text: "Thesaurus"
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
        }
      }
    }
  }
}
```

- [ ] **Step 4: Write `LICENSE`**

MIT license text, copyright line: `Copyright (c) 2026 barun-labs`.

- [ ] **Step 5: Validate and lint**

Run:
```bash
omarchy plugin validate ~/.config/omarchy/plugins/barun-labs.thesaurus
qmllint -I "$(omarchy-shell -q shell pathOfShell 2>/dev/null || echo /usr/share/omarchy/shell)" BarWidget.qml Panel.qml
```
Expected: validate reports the manifest OK. (If `qmllint`'s `-I` shell path is
wrong, find the shell QML dir with `qmllint` erroring on unresolved `qs.*`
imports — resolve the include path once and reuse it. A clean validate is the
gate; qmllint import warnings for `qs.*` are acceptable if the shell path can't
be located, since the running shell resolves them.)

- [ ] **Step 6: Enable and eyeball the icon**

Run:
```bash
omarchy plugin enable barun-labs.thesaurus right
omarchy-shell -q shell rescanPlugins
```
Expected: a book icon (󰗊) appears in the bar; clicking it opens a small panel
reading "Thesaurus"; Escape closes it.

- [ ] **Step 7: Commit**

```bash
git add manifest.json BarWidget.qml Panel.qml LICENSE
git commit -m "feat: bar-widget skeleton, manifest, and stub panel"
```

---

### Task 3: Panel — run lookup.sh and render the card

Replace the stub panel with the real one: a text field, a `Process` that runs
`lookup.sh`, and a result card.

**Files:**
- Modify: `Panel.qml` (full replacement of the stub from Task 2)

**Interfaces:**
- Consumes (Task 1): runs `["bash", helperPath, <word?>]`; parses the JSON shape
  `{word, definition, example, synonyms[], antonyms[], error}` from stdout.
- Consumes (Task 2): injected `bar`, `anchorItem`, `hostWidget`; the base
  `Panel` `controller`, `opened`, `popoutSwitchClosing`, `closeForPopoutSwitch`.
- Produces: `open()` runs a lookup of the highlighted word; `lookupWord(text)`
  looks up a typed word; `close()`, `toggle()`, `switchPanel(direction)`.

- [ ] **Step 1: Write the real `Panel.qml`**

```qml
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Dictionary + thesaurus lookup panel. Opens pre-filled with the highlighted
// word (lookup.sh reads it via wl-paste); the field is editable and Enter
// re-runs the lookup. All lookup logic lives in lookup.sh — this panel only
// runs it and renders the one JSON object it prints.
Panel {
  id: root
  moduleName: "barun-labs.thesaurus"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  property string word: ""
  property string definition: ""
  property string example: ""
  property var synonyms: []
  property var antonyms: []
  property string errorKind: ""
  property bool loading: false

  // lookup.sh's absolute path. Qt.resolvedUrl gives a file:// URL; Process
  // needs a plain filesystem path.
  readonly property string helperPath: {
    var url = String(Qt.resolvedUrl("lookup.sh"))
    return decodeURIComponent(url.indexOf("file://") === 0 ? url.substring(7) : url)
  }

  function open() {
    root.controller.show()
    runLookup([])            // no arg -> lookup.sh reads the highlighted word
  }

  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function lookupWord(text) {
    var w = String(text || "").trim()
    if (w === "") return
    runLookup([w])
  }

  function runLookup(extraArgs) {
    if (lookupProcess.running) return
    root.loading = true
    root.errorKind = ""
    lookupProcess.command = ["bash", root.helperPath].concat(extraArgs)
    lookupProcess.running = true
  }

  function applyResult(raw) {
    var parsed
    try { parsed = JSON.parse(raw) } catch (e) { parsed = null }
    if (!parsed) { root.errorKind = "offline"; return }
    root.word = String(parsed.word || "")
    root.definition = String(parsed.definition || "")
    root.example = String(parsed.example || "")
    root.synonyms = parsed.synonyms || []
    root.antonyms = parsed.antonyms || []
    root.errorKind = parsed.error ? String(parsed.error) : ""
    // Keep the field showing the looked-up word, unless the user is mid-typing.
    if (!queryField.activeFocus && root.word !== "") queryField.text = root.word
  }

  Process {
    id: lookupProcess
    stdout: StdioCollector {
      id: lookupStdout
      waitForEnd: true
      onStreamFinished: root.applyResult(text)
    }
    onExited: function(exitCode) {
      root.loading = false
      if (exitCode !== 0 && root.errorKind === "") root.errorKind = "offline"
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: queryField
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

        TextField {
          id: queryField
          width: parent.width
          placeholderText: "Look up a word…"
          text: root.word
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.lookupWord(queryField.text)
              event.accepted = true
            } else if (event.key === Qt.Key_Escape) {
              root.close()
              event.accepted = true
            }
          }
        }

        // Status line for the loading / empty / offline paths.
        Text {
          visible: root.loading || root.errorKind !== ""
          width: parent.width
          text: root.loading ? "Looking up…"
            : root.errorKind === "offline" ? "Offline — no lookup"
            : root.errorKind === "empty" ? "Highlight a word, or type one above"
            : ""
          color: Util.alpha(root.contentForeground, 0.64)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // Result card. Shown once a word resolves without error.
        Column {
          visible: root.errorKind === "" && !root.loading && root.word !== ""
          width: parent.width
          spacing: Style.space(8)

          Text {
            width: parent.width
            text: root.word
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            visible: root.definition !== ""
            width: parent.width
            text: root.definition
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.example !== ""
            width: parent.width
            text: "“" + root.example + "”"
            color: Util.alpha(root.contentForeground, 0.64)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            font.italic: true
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.definition === ""
            width: parent.width
            text: "No definition found."
            color: Util.alpha(root.contentForeground, 0.5)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }

          PanelSeparator {
            visible: root.synonyms.length > 0 || root.antonyms.length > 0
            width: parent.width
          }

          Repeater {
            model: [
              { label: "SYN", terms: root.synonyms },
              { label: "ANT", terms: root.antonyms }
            ]
            Row {
              required property var modelData
              visible: modelData.terms.length > 0
              width: content.width
              spacing: Style.space(8)
              Text {
                width: Style.space(34)
                text: modelData.label
                color: Util.alpha(root.contentForeground, 0.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
              Text {
                width: content.width - Style.space(34) - Style.space(8)
                text: modelData.terms.join(", ")
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }
            }
          }
        }
      }
    }
  }
}
```

- [ ] **Step 2: Validate and lint**

Run: `omarchy plugin validate ~/.config/omarchy/plugins/barun-labs.thesaurus`
Expected: OK.

- [ ] **Step 3: Reload and test a typed lookup**

Run: `omarchy-shell -q shell rescanPlugins`
Then: click the bar icon, type `perfidious`, press Enter.
Expected: card shows a definition, an example, and SYN/ANT rows. Escape closes.

- [ ] **Step 4: Test the offline/empty paths**

- Click the icon with nothing highlighted → status reads
  "Highlight a word, or type one above".
- Optionally, with wifi off, type a word + Enter → "Offline — no lookup".

- [ ] **Step 5: Commit**

```bash
git add Panel.qml
git commit -m "feat: panel runs lookup.sh and renders the result card"
```

---

### Task 4: Summon by keybind on the highlighted word

Wire a Hyprland keybind to toggle the panel; confirm it opens pre-filled from
the primary selection.

**Files:**
- Modify: `~/.config/hypr/bindings.lua` (user's config — see the gate below)

**Interfaces:**
- Consumes (Task 2): the `IpcHandler` target `barun-labs.thesaurus`, method
  `toggle`; and/or the shell's built-in `shell toggle <id>` routing.

- [ ] **Step 1: Confirm which IPC form the running shell honors**

Open the panel by hand first (bar icon), then from a terminal run each and see
which toggles it:
```bash
omarchy-shell -q barun-labs.thesaurus toggle
omarchy-shell -q shell toggle barun-labs.thesaurus
```
Use whichever works as the keybind command below (prefer the first; fall back
to the second).

- [ ] **Step 2: GATE — get the user's OK before editing their Hyprland config**

Editing `bindings.lua` changes the user's global keybindings. Confirm the key
(`SUPER SHIFT + D`, verified free) and the working IPC command from Step 1
before writing anything.

- [ ] **Step 3: Add the keybind**

Append to `~/.config/hypr/bindings.lua` (use the command confirmed in Step 1):

```lua
o.bind("SUPER SHIFT + D", "Define word", "omarchy-shell -q barun-labs.thesaurus toggle")
```

- [ ] **Step 4: Reload and test the full flow**

Reload Hyprland config (`hyprctl reload`). Then: highlight a word in any app,
press `SUPER SHIFT + D`.
Expected: the panel opens already showing that word's card. Pressing the keybind
again closes it.

- [ ] **Step 5: Commit (plugin repo only)**

The hypr config lives outside this repo, so there is nothing to commit here for
the keybind itself. Record the bind in `README.md` in Task 5. No commit this
step.

---

### Task 5: Packaging + full plugin checklist

README, preview, and the Omarchy lifecycle checklist before calling it done.

**Files:**
- Create: `README.md`
- Create: `.gitignore` (ignore `*.bak*`)
- Create: `preview.png` (screenshot of the panel; optional but wanted for publish)

**Interfaces:** none (documentation + verification only).

- [ ] **Step 1: Write `README.md`**

Cover, in prose: what it does (highlight a word → definition/example/syn/ant),
install (`omarchy plugin add <repo-url> --enable`), the `SUPER SHIFT + D`
keybind and the exact `o.bind(...)` line to add, that lookups hit
`api.datamuse.com` and `api.dictionaryapi.dev` (privacy note), configure/remove
steps, and that phase 2 will add translation.

- [ ] **Step 2: Add `.gitignore`**

```
*.bak
*.bak.*
```

- [ ] **Step 3: Capture `preview.png`**

Open the panel on a real word and screenshot it into `preview.png`.

- [ ] **Step 4: Run the Omarchy lifecycle checklist**

Verify each and note the result:
- Click icon opens/closes; Escape closes.
- `SUPER SHIFT + D` toggles with the highlighted word.
- `omarchy plugin disable barun-labs.thesaurus` then `enable` — clean.
- Restart the shell (`omarchy-shell -q shell restart` or relogin) — icon persists.
- `omarchy plugin validate` — OK.

- [ ] **Step 5: Commit**

```bash
git add README.md .gitignore preview.png
git commit -m "docs: README, gitignore, and preview for publish"
```

---

## Self-Review

**Spec coverage:**
- `bar-widget` + `Panel.qml` → Tasks 2, 3.
- Datamuse + dictionaryapi sources → Task 1.
- `lookup.sh` JSON contract (empty/offline/404 paths) → Task 1 + its tests.
- Selection read via `wl-paste --primary` → Task 1 (script) + Task 3 (`open()`
  runs no-arg) + Task 4 (keybind).
- Content: definition + example + synonyms + antonyms → Task 3 card.
- Keybind `SUPER SHIFT + D` in `bindings.lua` → Task 4.
- Error handling (offline / empty / no-definition) → Task 3 status line + card.
- Tests + manual QML checklist → Task 1 tests, Tasks 2/3/5 validate + checklist.
- Privacy boundary, phase-2 seam → Task 5 README.

**Placeholder scan:** none — every code step carries full content.

**Type consistency:** `open/close/toggle/closeForPopoutSwitch`, `opened`,
`popoutSwitchClosing`, `helperPath`, `applyResult`, `runLookup`, `lookupWord`,
and the JSON keys `word/definition/example/synonyms/antonyms/error` are used
identically across Tasks 1–3.
