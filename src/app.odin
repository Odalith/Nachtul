// Nachtul app shell — step 1 of the port plan: skeleton + night theme.
//
// The shell is a root column (top bar / screen / playback bar) over a
// screen enum, mirroring the C#'s MainWindow with RoutedViewHost
// dissolved into a switch. Screens are placeholders with real state
// wiring (nav, library sections, play toggle, settings popup) so the
// skeleton already exercises dispatch, popups and the frame-side
// position synthesis the player will use for real in step 4.
package nachtul

import "core:fmt"

import niello "../../NielloUI/niello"

Screen :: enum {
	Now_Playing,
	Library,
	Composer,
}

Section :: enum {
	All,
	Recent,
	Popular,
	Taglists,
	Playlists,
	Artists,
	Albums,
	EPs,
	Singles,
	Collections,
	Uncategorized,
}

App :: struct {
	screen:         Screen,
	section:        Section,
	playing:        bool,
	settings_open:  bool,
	position_secs:  f32, // synthesized playback position (step 4 gets a real track)
	sync_status:    string,
}

app := App{sync_status = "Ready"}

// The current frame's clickable instances, refreshed by every declare.
// This is the app's test seam (the port is TODO #45's first consumer):
// headless tests click these by rect and assert on `app`.
Instances :: struct {
	nav:          [3]niello.Instance,
	section:      [11]niello.Instance,
	prev, play, next: niello.Instance,
	queue:        niello.Instance,
	settings:     niello.Instance,
	sync:         niello.Instance,
	popup:        niello.Instance,
	popup_close:  niello.Instance,
}

instances: Instances

FAKE_TRACK_SECS :: 213 // 3:33 — placeholder until step 4

// The glue entry point. One drain point will land here in step 2
// (the one-inbox rule); step 1 has no producers yet.
declare :: proc() {
	// Position synthesis, frame-side (the brief §1 pattern): while
	// playing, re-arm a 250 ms wake and advance the position. Idle
	// with nothing playing, the window sleeps.
	if app.playing {
		niello.wake_in(250)
		app.position_secs += 0.25
		if app.position_secs >= FAKE_TRACK_SECS {
			app.position_secs = 0
		}
	}

	if _, ok := niello.begin(root_u); ok {
		top_bar()
		switch app.screen {
		case .Now_Playing:
			screen_now_playing()
		case .Library:
			screen_library()
		case .Composer:
			screen_composer()
		}
		play_bar()
	}
	if app.settings_open {
		settings_popup()
	}
	dispatch()
}

// ---- top bar ------------------------------------------------------------------

NAV_DEFS := [3]struct {
	screen: Screen,
	key:    string,
	label:  string,
}{
	{.Now_Playing, "nav_np", "Now Playing"},
	{.Library, "nav_lib", "Library"},
	{.Composer, "nav_comp", "Composer"},
}

top_bar :: proc() {
	if _, ok := niello.begin(topbar_u); ok {
		niello.show(logo_u)
		for def, i in NAV_DEFS {
			selected := app.screen == def.screen
			instances.nav[i] = nav_button(def.key, def.label, selected)
		}
		if _, ok2 := niello.begin(spacer_u); ok2 {}
		niello.show(sync_label_u, 0, {text = app.sync_status})
		instances.sync = nav_button("sync", "Sync", false)
		instances.settings = nav_button("settings", "Settings", false)
	}
}

nav_button :: proc(key: string, label: string, selected: bool) -> niello.Instance {
	i, open := niello.begin(nav_u, niello.key(key), {variant = selected ? sel_u : niello.NO_UNIT})
	if open {
		niello.show(nav_label_u, 0, {
			text = label,
			variant = selected ? label_sel_u : niello.NO_UNIT,
		})
	}
	return i
}

// ---- screens ------------------------------------------------------------------

screen_now_playing :: proc() {
	if _, ok := niello.begin(np_col_u); ok {
		niello.show(np_cover_u)
		niello.show(np_title_u)
		niello.show(np_artist_u)
	}
}

SECTION_DEFS := [11]struct {
	section: Section,
	key:     string,
	label:   string,
}{
	{.All, "sec_all", "All"},
	{.Recent, "sec_recent", "Recent"},
	{.Popular, "sec_popular", "Popular"},
	{.Taglists, "sec_taglists", "Tag Lists"},
	{.Playlists, "sec_playlists", "Playlists"},
	{.Artists, "sec_artists", "Artists"},
	{.Albums, "sec_albums", "Albums"},
	{.EPs, "sec_eps", "EPs"},
	{.Singles, "sec_singles", "Singles"},
	{.Collections, "sec_collections", "Collections"},
	{.Uncategorized, "sec_uncat", "Uncategorized"},
}

screen_library :: proc() {
	if _, ok := niello.begin(lib_row_u); ok {
		if _, ok2 := niello.begin(sidebar_u); ok2 {
			for def, i in SECTION_DEFS {
				selected := app.section == def.section
				inst, open := niello.begin(section_u, niello.key(def.key), {variant = selected ? sel_u : niello.NO_UNIT})
				instances.section[i] = inst
				if open {
					niello.show(section_label_u, 0, {
						text = def.label,
						variant = selected ? label_sel_u : niello.NO_UNIT,
					})
				}
			}
		}
		if _, ok3 := niello.begin(lib_panel_u); ok3 {
			niello.show(placeholder_u, 0, {
				text = "No collections yet — the library arrives in step 3.\nFolders and sync land in steps 2 and 6.",
			})
		}
	}
}

screen_composer :: proc() {
	if _, ok := niello.begin(lib_row_u, niello.key("composer")); ok {
		tray("tray_in", "Input — drop chips here")
		tray("tray_all", "Has All — and")
		tray("tray_none", "Has None — not")
		if _, ok2 := niello.begin(lib_panel_u); ok2 {
			niello.show(placeholder_u, 0, {text = "Matching songs — the Composer arrives in step 5."})
		}
	}
}

tray :: proc(key: string, title: string) {
	if _, ok := niello.begin(tray_u, niello.key(key)); ok {
		niello.show(tray_title_u, 0, {text = title})
	}
}

// ---- playback bar ---------------------------------------------------------------

play_bar :: proc() {
	if _, ok := niello.begin(bar_u); ok {
		instances.prev = transport_button("prev", "Prev")
		{
			i, open := niello.begin(play_u, niello.key("play"))
			instances.play = i
			if open {
				niello.show(play_label_u, 0, {text = app.playing ? "Pause" : "Play"})
			}
		}
		instances.next = transport_button("next", "Next")
		if _, ok2 := niello.begin(pb_info_u); ok2 {
			niello.show(pb_title_u)
			niello.show(pb_artist_u)
		}
		if _, ok3 := niello.begin(seek_track_u); ok3 {
			// The fill is a singleton unit, so its fraction is a
			// per-frame unit write (With carries content, not size).
			pct := app.position_secs / FAKE_TRACK_SECS
			niello.set(seek_fill_u, niello.Field.Size, niello.Size{niello.percent(pct), niello.percent(1)})
			niello.show(seek_fill_u)
		}
		niello.show(time_u, 0, {text = fmt.tprintf("%s / %s", fmt_time(app.position_secs), fmt_time(FAKE_TRACK_SECS))})
		if _, ok4 := niello.begin(vol_track_u); ok4 {
			niello.show(vol_fill_u)
		}
		instances.queue = transport_button("queue", "Queue")
	}
}

transport_button :: proc(key: string, label: string) -> niello.Instance {
	i, open := niello.begin(tbtn_u, niello.key(key))
	if open {
		niello.show(tbtn_label_u, 0, {text = label})
	}
	return i
}

fmt_time :: proc(secs: f32) -> string {
	s := int(secs)
	return fmt.tprintf("%d:%02d", s / 60, s % 60)
}

// ---- settings popup --------------------------------------------------------------

settings_popup :: proc() {
	pi, open := niello.begin_popup(popup_u, 0, niello.Placement.Center, {modal = true}, key = niello.key("settings_popup"))
	instances.popup = pi
	if open {
		niello.show(popup_title_u)
		niello.show(placeholder_u, 0, {text = "Music folders live here in step 6."})
		instances.popup_close = nav_button("popup_close", "Close", false)
	}
}

// ---- dispatch ----------------------------------------------------------------------

dispatch :: proc() {
	for def, i in NAV_DEFS {
		if niello.clicked(instances.nav[i]) {
			app.screen = def.screen
		}
	}
	for def, i in SECTION_DEFS {
		if niello.clicked(instances.section[i]) {
			app.section = def.section
		}
	}
	if niello.clicked(instances.play) {
		app.playing = !app.playing
	}
	if niello.clicked(instances.settings) {
		app.settings_open = true
	}
	if niello.clicked(instances.sync) {
		// Manual sync is by design (F7). The scanner lands in step 6;
		// until then the button reports that honestly.
		app.sync_status = "Sync arrives in step 6"
	}
	if app.settings_open {
		if niello.clicked(instances.popup_close) || niello.dismiss_requested(instances.popup) {
			app.settings_open = false
		}
	}
}
