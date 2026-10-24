# Nachtul

A tag-based, night-themed music player, built on
[NielloUI](https://github.com/Odalith/NielloUI) (Odin). This repo is
the port of the Avalonia/.NET original — that codebase now lives at
`Odalith/Nachtul_Old` and serves as the behavioral reference, along
with a partial C++ + Clay port whose data-layer redesign this port
adopts (database as source of truth; a search is a SQL query).

The port proceeds in steps (skeleton + theme → data layer → library
screens → playback → Composer → scanner → tail), each ending with a
runnable app. Step 1 (skeleton + night theme) is what's here.

## Layout

- `main.odin` — thin launcher (context + window). The app lives in
  `src/` so tests can drive it headlessly.
- `src/` — package `nachtul`: `theme.odin` (the night palette as
  Niello units + groups — the seed of NielloUI's shipped dark theme)
  and `app.odin` (shell, screens, playback bar, dispatch).
- `tests/` — headless app tests (real frames, fabricated input):
  `odin test tests -o:speed`.
- `third_party/native/<platform>/` — Nachtul's own per-platform
  native libs (libgstaudio, libTagUtils), laid out like NielloUI's;
  binaries are never committed — see `third_party/native/README.md`
  and `tools/fetch-native.sh`.

## Running

Expects a sibling checkout of NielloUI:

    git clone https://github.com/Odalith/NielloUI   # beside this repo
    odin run .

Window: 1560×900, three screens (Now Playing / Library / Composer),
a working play/pause position synthesis, and a settings popup.
Library data arrives in step 2+; the Sync button says so.
