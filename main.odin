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
	ctx := niello.context_create()
	defer niello.context_destroy(ctx)
	niello_sdl.run(ctx, {title = "Nachtul", width = 1560, height = 900}, nachtul.declare)
}
