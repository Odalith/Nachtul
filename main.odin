// Nachtul — a tag-based, night-themed music player on NielloUI.
// Port of the Avalonia original (now Odalith/Nachtul_Old); plan:
// Nachtul_Port_Plan.md. This file stays thin on purpose — the app
// lives in src/ (package nachtul) so tests can drive it headlessly.
package main

import niello "../NielloUI/niello"
import niello_sdl "../NielloUI/niello/sdl"

import nachtul "./src"

main :: proc() {
	nachtul.init_theme()
	// Spall profiling (src/prof.odin): off unless NACHTUL_SPALL is
	// set. This defer is registered FIRST, at proc top level, so it
	// runs LAST — after stop_library joins the worker (flushing its
	// buffer) and after the context is destroyed. It must NOT sit
	// inside the if block: a defer in a block runs at the end of
	// that block, which would close the trace before run() starts.
	// prof_shutdown is a no-op when profiling is off, so registering
	// it unconditionally is safe.
	defer nachtul.prof_shutdown()
	if nachtul.prof_init_from_env() {
		nachtul.prof_init_main()
	}
	ctx := niello.context_create()
	defer niello.context_destroy(ctx)
	// The library loads on a worker and lands through the inbox;
	// the DB lives in the working directory (docs/schema-v2.md).
	nachtul.start_library_load(ctx, ".")
	defer nachtul.stop_library()
	// The audio backend (step 4) lives on its own GLib thread; a
	// missing .so fails loudly in audio_start and leaves the
	// transport dead. Registered after stop_library, so this
	// defer runs first — the audio thread is joined before the
	// inbox is destroyed.
	nachtul.audio_start()
	defer nachtul.audio_stop()
	niello_sdl.run(ctx, {title = "Nachtul", width = 1560, height = 900}, nachtul.declare)
}
