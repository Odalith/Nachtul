# Nachtul

A tag-based, night-themed music player, built on
[NielloUI](https://github.com/Odalith/NielloUI) (Odin). This repo is
the port of the Avalonia/.NET original — that codebase now lives at
`Odalith/Nachtul_Old` and serves as the behavioral reference, along
with a partial C++ + Clay port whose data-layer redesign this port
adopts (database as source of truth; a search is a SQL query).

The port proceeds in steps (skeleton + theme → data layer → library
screens → playback → Composer → scanner → tail), each ending with a
runnable app. Steps 1 (skeleton + night theme) and 2 (schema V2 +
data layer — see `docs/schema-v2.md`) are what's here: on startup
the app creates `Nachtul.db` in the working directory, imports a
`NachtulV1.db` sitting beside it if this is the first run, and the
Settings popup lists the library's real folders.

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

## Profiling (Spall)

Off by default. To record a trace, run with the environment variable
set (no rebuild needed) and open the resulting file in the free web
viewer at https://gravitymoth.com/spall/spall-web.html:

    NACHTUL_SPALL=1 odin run .
    NACHTUL_SPALL_FILE=/tmp/nachtul.spall NACHTUL_SPALL=1 odin run .

The trace has two threads — `main` (one `declare` event per frame,
with `screen_library`, `screen_collection`, and `play_bar` inside it)
and `library` (one event per worker job: `library_load`,
`collections_page`, `songs_from_collection`, `import_v1`). Close the
window to flush and close the file; `*.spall` is gitignored. The
implementation is `src/prof.odin`, built on Odin's `core:prof/spall` —
no new dependency, and no engine instrumentation: this traces the
app's boundaries, not every procedure in the program.
