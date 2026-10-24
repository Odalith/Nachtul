// Headless tests for the Nachtul shell — the app is driven through
// real frames with fabricated input (the model TODO #45 prescribes;
// this suite is its first consumer). No window, no backend: the
// engine runs on its mock text metrics.
package tests

import "core:testing"

import niello "../../NielloUI/niello"
import nachtul "../src"

setup :: proc() {
	niello.test_reset()
	nachtul.init_theme()
	nachtul.app = nachtul.App{sync_status = "Ready"}
}

teardown :: proc() {
	niello.test_teardown()
}

idle :: proc() -> niello.Input {
	return niello.Input{viewport = {1560, 900}, window_focused = true}
}

step :: proc(input: niello.Input) {
	niello.frame_begin(niello.test_context(), input, 1.0 / 60.0)
	nachtul.declare()
	niello.frame_end()
}

settle :: proc(n := 3) {
	for _ in 0 ..< n {
		step(idle())
	}
}

// A full click (press frame + release frame + a settle frame) at the
// center of the instance's committed rect.
click :: proc(inst: niello.Instance) {
	r, ok := niello.rect(inst)
	if !ok {
		return
	}
	pt := r.pos + r.size * 0.5
	press := idle()
	press.mouse = pt
	press.mouse_valid = true
	press.buttons_pressed = {.Left}
	press.buttons_down = {.Left}
	step(press)
	rel := idle()
	rel.mouse = pt
	rel.mouse_valid = true
	rel.buttons_released = {.Left}
	step(rel)
	step(idle())
}

@(test)
test_nav_switches_screens :: proc(t: ^testing.T) {
	setup()
	defer teardown()
	settle()
	testing.expect(t, nachtul.app.screen == .Now_Playing, "starts on Now Playing")
	click(nachtul.instances.nav[1])
	testing.expect(t, nachtul.app.screen == .Library, "Library nav click switches screen")
	click(nachtul.instances.nav[2])
	testing.expect(t, nachtul.app.screen == .Composer, "Composer nav click switches screen")
	click(nachtul.instances.nav[0])
	testing.expect(t, nachtul.app.screen == .Now_Playing, "Now Playing nav click switches back")
}

@(test)
test_library_sections_select :: proc(t: ^testing.T) {
	setup()
	defer teardown()
	settle()
	click(nachtul.instances.nav[1])
	settle()
	testing.expect(t, nachtul.app.section == .All, "starts on All")
	click(nachtul.instances.section[5]) // Artists
	testing.expect(t, nachtul.app.section == .Artists, "section click selects Artists")
	click(nachtul.instances.section[1]) // Recent
	testing.expect(t, nachtul.app.section == .Recent, "section click selects Recent")
}

@(test)
test_play_toggle_and_position_synthesis :: proc(t: ^testing.T) {
	setup()
	defer teardown()
	settle()
	testing.expect(t, !nachtul.app.playing, "starts paused")
	click(nachtul.instances.play)
	testing.expect(t, nachtul.app.playing, "play click toggles playing")
	before := nachtul.app.position_secs
	settle(4)
	testing.expect(t, nachtul.app.position_secs > before, "position synthesizes forward while playing")
	click(nachtul.instances.play)
	testing.expect(t, !nachtul.app.playing, "second click pauses")
	frozen := nachtul.app.position_secs
	settle(4)
	testing.expect(t, nachtul.app.position_secs == frozen, "position holds while paused")
}

@(test)
test_settings_popup_open_close_dismiss :: proc(t: ^testing.T) {
	setup()
	defer teardown()
	settle()
	click(nachtul.instances.settings)
	testing.expect(t, nachtul.app.settings_open, "settings click opens the popup")
	settle()
	testing.expect(t, nachtul.instances.popup != 0, "popup instance exists")
	click(nachtul.instances.popup_close)
	testing.expect(t, !nachtul.app.settings_open, "Close dismisses the popup")

	// Reopen, then a press outside the modal dismisses it.
	click(nachtul.instances.settings)
	settle()
	testing.expect(t, nachtul.app.settings_open, "popup reopens")
	press := idle()
	press.mouse = {20, 870}
	press.mouse_valid = true
	press.buttons_pressed = {.Left}
	press.buttons_down = {.Left}
	step(press)
	testing.expect(t, !nachtul.app.settings_open, "outside press dismisses the modal")
}

@(test)
test_sync_button_reports_step6 :: proc(t: ^testing.T) {
	setup()
	defer teardown()
	settle()
	click(nachtul.instances.sync)
	testing.expect(t, nachtul.app.sync_status == "Sync arrives in step 6", "sync button is honest about step 6")
}
