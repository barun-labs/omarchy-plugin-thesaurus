# barun-labs.thesaurus — design (phase 2: LLM explain + transform)

Phase 1 gives dictionary/thesaurus lookup for real English words via free,
keyless APIs. It has one gap: slang (`delulu`), foreign words, and phrases
return nothing, because a curated dictionary does not carry them. Phase 2 adds
an LLM layer that answers exactly those cases, plus on-demand text transforms.

The phase-1 free path is untouched and stays the default. The LLM fires only
when the free path can't answer, or when the user explicitly asks for it — so a
common English word still costs nothing and works offline.

## What phase 2 adds

- **Explain** — plain-English meaning of the selection. One LLM call that
  auto-detects the case: slang → what it means + example; foreign word/phrase →
  translation to English; ordinary phrase/sentence → explanation. Covers the
  "slang decode", "cross-language translate", and "explain whole selection"
  capabilities in one mode.
- **Transform** — an explicit, user-chosen rewrite of the selection:
  `formalize`, `simplify`, `use-in-sentence`, `translate` (to a configured
  target language). This is an active command, never automatic.

## Trigger model (approach A: auto-fallback)

1. Selection/word loads → `lookup.sh` runs first (free, fast, existing).
2. If the dictionary path returns nothing (no definition, no synonyms, no
   antonyms) → **auto-fire Explain** via the LLM. This is the delulu path: the
   user highlights a slang word and gets an answer with zero extra clicks.
3. If the dictionary path hits → done. No LLM call, no cost.
4. `Explain` and `Transform` are also available as explicit panel actions and
   (Explain only) a keybind, independent of the auto-fallback.

Auto-fallback runs Explain at most once per lookup and only on an empty
dictionary result, so cost is bounded to the words the free path genuinely
can't answer.

## Engine

DeepSeek, model `deepseek-chat` (the cheap, fast tier — a ~200-token lookup is a
fraction of a cent). Called over the OpenAI-compatible endpoint
`https://api.deepseek.com/chat/completions`. Blocking call with an 8s timeout;
no streaming (flash-tier latency is ~1-2s, and the panel already has a loading
state).

The exact model id is a single constant in `llm.sh` so it can be retargeted
(e.g. `deepseek-reasoner`, or a different provider) without touching the panel.

### Key handling

The key is read from `~/.config/deepseek/thesaurus-key` (mode 600) — a
plugin-specific key, separate from the user's main DeepSeek key, so this public
plugin never assumes or reuses a shared credential.

- Key file missing or empty → `llm.sh` prints `{error:"no-key"}` and exits 0.
  The panel shows "Add a DeepSeek key to enable Explain" and the free path keeps
  working. The LLM layer degrades to off, it does not break the plugin.
- The key is never hardcoded, never logged, never sent anywhere except the
  DeepSeek endpoint. README documents where to put it.

## Files

```
barun-labs.thesaurus/
├── lookup.sh          # phase 1, UNCHANGED
├── llm.sh             # NEW — explain + transform, DeepSeek call, CLI-testable
├── Panel.qml          # + action row, LLM output card, Thinking state
├── BarWidget.qml      # + explainSelection IPC verb
├── manifest.json      # version bump 0.1.0 -> 0.2.0
├── tests/
│   ├── test-lookup.sh # phase 1, unchanged
│   └── test-llm.sh    # NEW — mocked DeepSeek, asserts JSON shape + error branches
└── README.md          # + LLM section, key setup
```

## llm.sh contract

`llm.sh --mode explain [word]`
`llm.sh --mode transform --kind <formalize|simplify|use-in-sentence|translate> [word]`

Same discipline as `lookup.sh`: reads the primary selection when no word arg is
given, prints exactly one JSON object on stdout, always exits 0. The panel
parses one fixed shape on every path.

```json
{
  "mode": "explain",
  "kind": "",
  "input": "delulu",
  "output": "Slang for \"delusional\" — believing something unrealistically...",
  "error": null
}
```

- `error` is one of: `null`, `"no-key"`, `"offline"`, `"timeout"`,
  `"rate-limit"`, `"empty"`.
- `no-key` — key file absent/empty (checked before any network call).
- `offline` — curl transport failure.
- `timeout` — request exceeded 8s (`curl --max-time 8`, distinct exit code).
- `rate-limit` — HTTP 429 from DeepSeek.
- `empty` — no selection / empty word arg.
- Any non-null error → `output` empty.

### Prompts

One system prompt per mode, kept short and inlined in `llm.sh`:

- **explain**: "You explain words and phrases concisely for someone reading. If
  the input is slang, give its meaning and one short example. If it is not
  English, translate it to English. If it is a phrase or sentence, explain what
  it means in plain English. 2-3 sentences max. No preamble."
- **transform/formalize**: rewrite the input in formal register, output only the
  rewrite.
- **transform/simplify**: rewrite in plain, simple language, output only the
  rewrite.
- **transform/use-in-sentence**: use the input word naturally in one example
  sentence, output only the sentence.
- **transform/translate**: translate the input to `<TARGET_LANG>` (a constant in
  `llm.sh`, default English — the phase-2 target-language setting), output only
  the translation.

Output is capped (`max_tokens`) so a runaway response can't blow up cost or the
panel.

## Panel.qml changes

- **Action row** under the query field, visible once a word/selection is
  present: `Define · Explain · Transform▾`. `Define` re-runs `lookup.sh`;
  `Explain` runs `llm.sh --mode explain`; `Transform` is a small dropdown of the
  four kinds, each running `llm.sh --mode transform --kind <k>`.
- **LLM output card** — renders `output` in the existing definition/example text
  style, with a small source tag ("via DeepSeek") so the user knows a model
  answered, not the dictionary.
- **Auto-fallback wiring** — when `applyResult` from `lookup.sh` yields an empty
  result (no definition, no synonyms, no antonyms, no error), the panel fires
  `llm.sh --mode explain` for the same word automatically.
- **States** — "Thinking…" while an LLM call is in flight (distinct from the
  dictionary's "Looking up…"); a status line per `llm.sh` error kind (`no-key`,
  `offline`, `timeout`, `rate-limit`).
- A second `Process` + `StdioCollector` handles `llm.sh`, mirroring the existing
  `lookupProcess`, so the two paths don't clobber each other. Only one runs at a
  time (guard on `running`).

## BarWidget.qml changes

- New IPC verb `explainSelection`: highlight → keybind → open panel and run
  Explain directly (the power path for slang/translate). Existing
  `lookupSelection` / `toggleSelection` stay dictionary-first.
- The keybind itself is a user-side Omarchy binding; the plugin only exposes the
  verb. README documents an example binding.

## Testing

`tests/test-llm.sh`, framework-free (matches `test-lookup.sh`):

- Mocks the DeepSeek HTTP call (stub `curl` on PATH, or a `LLM_ENDPOINT`
  override pointing at a local fixture) so tests never need a live key.
- Asserts the JSON shape for a normal explain response.
- Asserts each error branch resolves to the right `error` value and empty
  `output`: no-key (unset key path), offline (curl fails), timeout (curl
  exit 28), rate-limit (HTTP 429), empty (no input).
- Asserts transform kinds pass the right prompt and cap output.

No live network, no live key in the suite.

## Out of scope (phase 2)

- Streaming output.
- Conversation / follow-up ("explain more") — each call is stateless, like
  phase 1.
- A settings UI. Target language and model id are constants in `llm.sh`;
  changing them is an edit, not a preference screen. (A later phase can promote
  them if wanted.)
- Provider abstraction. One provider (DeepSeek) behind one constant. Adding a
  second provider is a later change, not a speculative interface now.
