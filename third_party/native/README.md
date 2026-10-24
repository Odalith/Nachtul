# Per-platform native libraries

Nachtul's own native dependencies, laid out like NielloUI's
`third_party/native/`:

- `linux-x64/`, `windows-x64/`, `macos-arm64/` — one directory per
  target platform holding `libgstaudio` and `libTagUtils` builds for
  that platform (plus their transitive deps where the platform needs
  them: GStreamer + TagLib are system packages on Linux; other
  platforms TBD when their builds happen).
- `include/` — the C headers the Odin FFI bindings are written
  against (`gstaudio.h`, `tagutils.h`). Committed; they are the
  binding contract.

Binaries are **never committed** (see the repo `.gitignore`) — they
arrive via `tools/fetch-native.sh` from a GitHub Release, or are
dropped in from a local build of the gstaudio / TagUtils repos.

The Odin bindings will live in `audio/` and `tags/` packages at the
repo root, with per-platform `foreign import` splits resolving to
these directories — written in step 4 (audio) and step 6 (scanner).
