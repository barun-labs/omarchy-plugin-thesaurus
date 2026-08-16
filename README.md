# barun-labs.thesaurus

An Omarchy shell plugin for reading. It adds a book icon to the bar. Highlight
a word on screen, press a keybind, and a panel pops up with the word's
definition, an example sentence, its synonyms, and its antonyms.

![Preview](preview.png)

If you mistype a word or highlight something that isn't in the dictionary,
the panel offers "did you mean" suggestions instead — click one and it looks
up that word. The panel's text field is always editable too: type a word and
press Enter to look it up directly, without highlighting anything first.
Press Escape to close the panel.

## Data sources and privacy

Synonyms, antonyms, and spelling suggestions come from
[Datamuse](https://www.datamuse.com/api/) (`api.datamuse.com`) — no API key
needed. The definition and example sentence come from the
[Free Dictionary API](https://dictionaryapi.dev/) (`api.dictionaryapi.dev`).

Every word you look up is sent in plaintext to both of those hosts. There is
no local dictionary or offline fallback in this phase — if you're offline,
lookups simply fail.

## Requirements

- The Omarchy Quickshell shell.
- `curl`, `jq`, and `wl-paste` (from `wl-clipboard`) on your `PATH`.

Nothing else. There's no separate service process and no build step.

## Install

The plugin lives at `~/.config/omarchy/plugins/barun-labs.thesaurus/`. Once
it's there, enable it with:

```
omarchy plugin enable barun-labs.thesaurus right
```

If this plugin is published to a git repository, you can install it directly
instead of placing the files by hand:

```
omarchy plugin add <repo-url> --enable
```

## Keybind

The plugin doesn't bind a key on its own — you add one. Open
`~/.config/hypr/bindings.lua` and add:

```lua
o.bind("SUPER + SHIFT + D", "Define word", "omarchy-shell shell toggle barun-labs.thesaurus")
```

The modifier string needs a `+` between every modifier, including the last
one before the key: `SUPER + SHIFT + D`. Hyprland's own bind list displays
this same shortcut as `SUPER SHIFT + D` (no `+` before the final modifier),
but that display form will not parse if you type it into `bindings.lua`
yourself — write it with a `+` everywhere.

After saving, reload Hyprland's config:

```
hyprctl reload
```

You can also just click the book icon in the bar; the keybind is a shortcut
to the same toggle, not a requirement.

## Editing the plugin

If you change any of the plugin's `.qml` files, the shell's normal file-watch
reload will not pick it up correctly: once a widget has failed to load once,
the watcher caches that failure and won't recompile it even after you fix the
file. Run a full restart instead:

```
omarchy restart shell
```

## Remove

```
omarchy plugin remove barun-labs.thesaurus
```

## Phase 2

A translation mode is planned for a later phase. It isn't built yet.
