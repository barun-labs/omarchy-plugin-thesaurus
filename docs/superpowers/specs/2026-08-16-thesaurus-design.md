# barun-labs.thesaurus — design (phase 1)

An Omarchy shell plugin. Highlight a word while reading, press a keybind, get a
popup with its definition, an example sentence, synonyms, and antonyms. Phase 1
is the thesaurus/dictionary lookup. Phase 2 (translation) is a later seam, not
built here.

## Platform

Omarchy Quickshell shell (`omarchy-shell` IPC, `omarchy plugin` tooling). Plugins
are QML/Quickshell components declared by a `manifest.json`. Confirmed present on
this machine: `omarchy plugin`, `omarchy-shell`, `quickshell`, and CLI deps
`curl`, `jq`, `wl-paste`, `wl-copy`.

## Kind and files

Kind: `bar-widget` — a bar-widget gives both a clickable bar icon and a floating
panel, which is the pattern every installed plugin uses. No separate `service`
kind needed for phase 1.

```
barun-labs.thesaurus/
├── manifest.json     # id barun-labs.thesaurus, kind bar-widget, entry BarWidget.qml
├── BarWidget.qml     # bar icon; open/close/toggle; Loader for Panel; IpcHandler
├── Panel.qml         # editable text field + result card; Esc closes; Enter re-looks-up
├── lookup.sh         # ALL lookup logic; CLI-testable
├── tests/
│   └── test-lookup.sh
├── README.md
├── LICENSE           # MIT
└── preview.png       # added before publishing
```

## Data sources (online, no API key)

- Synonyms/antonyms: Datamuse — `api.datamuse.com/words?rel_syn=<word>` and
  `?rel_ant=<word>`.
- Definition + example sentence: Free Dictionary API —
  `api.dictionaryapi.dev/api/v2/entries/en/<word>`.

## lookup.sh contract

`lookup.sh [word]`. With no argument it reads the X/Wayland primary selection
via `wl-paste --primary --no-newline` (the highlighted word). It prints exactly
one JSON object on stdout and always exits 0 — offline, 404, and empty input all
resolve to the same shape so the QML side parses one thing:

```json
{
  "word": "perfidious",
  "definition": "deceitful and untrustworthy",
  "example": "a perfidious ally",
  "synonyms": ["treacherous", "disloyal", "faithless"],
  "antonyms": ["loyal", "faithful", "honest"],
  "error": null
}
```

- No network / curl failure → `error: "offline"`, other fields empty.
- Word not in dictionary (404) → definition/example empty, synonyms/antonyms
  still filled from Datamuse if any, `error: null`.
- Empty selection / no word → `error: "empty"`.

`jq` merges the two API responses into this object. Field extraction:
`definition`/`example` = first meaning's first definition and its first example
from dictionaryapi.dev; `synonyms`/`antonyms` = the `word` fields from the
Datamuse arrays (capped, e.g. first 8).

## Flow

```
highlight "perfidious" in book
  → SUPER SHIFT + D
  → Hyprland exec: omarchy-shell shell toggle barun-labs.thesaurus
  → Panel.open(): run lookup.sh (no arg) → reads primary selection
  → render card: word / definition / example / synonyms / antonyms
  → text field editable; Enter re-runs lookup.sh <typed word>
```

Summon is the confirmed IPC pattern `omarchy-shell shell toggle <plugin-id>`
(same form as `omarchy-shell shell toggle omarchy.menu`). The bar icon click
uses the widget's own `toggle()`.

## Error handling (UI)

- `error: "offline"` → card shows "offline — no lookup".
- `error: "empty"` → panel opens with an empty, focused text field.
- 404 with synonyms → show synonyms; definition line reads "no definition found".
- lookup.sh never emits non-JSON, so a parse failure is treated as a bug, not a
  normal path.

## Testing

- `tests/test-lookup.sh`: assert on `lookup.sh perfidious` (has definition +
  synonyms), a nonsense word (valid JSON, empty fields, `error: null`), and empty
  input (`error: "empty"`). Runnable from a plain shell, no framework.
- QML: `omarchy plugin validate <dir>`, `qmllint`, and the Omarchy manual
  checklist — click, Esc closes, `toggle` IPC, disable/re-enable, shell restart
  persistence, clean removal.

## Config / keybind

Keybind lives in `~/.config/hypr/bindings.lua` (Lua config, "quattro" Omarchy),
using the `o.bind(key, desc, cmd)` helper:

```lua
o.bind("SUPER + SHIFT + D", "Define word", "omarchy-shell shell toggle barun-labs.thesaurus")
```

`o.bind`'s key format uses a `+` between every modifier (`SUPER + SHIFT + D`);
Hyprland's own bind list displays the same shortcut as `SUPER SHIFT + D`.

`SUPER SHIFT + D` is free (mnemonic: Define). Editing `bindings.lua` is a
separate, user-confirmed step — not part of installing the plugin itself.

## Security / privacy

Plugins run unsandboxed with user permissions in the shared shell process. Each
looked-up word is sent in plaintext to `api.datamuse.com` and
`api.dictionaryapi.dev`. Acceptable for looking up a book word; recorded here so
it is a known, deliberate boundary.

## Out of scope (phase 2 seam)

Translation. Reserved seams: `lookup.sh --translate <word>` (or a separate
`translate.sh`) plus a mode toggle in `Panel.qml`. Not built now. No offline
WordNet fallback in phase 1 (online-only was the chosen source).
