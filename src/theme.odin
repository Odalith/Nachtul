// Nachtul's night theme: the C# app's palette (App.axaml resources,
// cross-checked against the C++ port's globals.h — D1/D2/A1 agree in
// both) expressed as Niello units + groups.
//
// This file is the seed of NielloUI TODO #29's shipped dark theme:
// when the theme system lands, this palette is what it should feel
// like. Per-song accent (step 4) is one call — group_set(accent_group,
// .Color, song_accent) — because everything that wears the accent is
// a member of accent_group.
package nachtul

import niello "../../NielloUI/niello"

// ---- palette ----------------------------------------------------------------

COL_BG :: niello.Color{0, 4, 13, 255} // #00040d — window base
COL_PANEL :: niello.Color{24, 27, 35, 255} // D1 #181b23
COL_PANEL2 :: niello.Color{29, 34, 47, 255} // D2 #1d222f
COL_PANEL3 :: niello.Color{29, 29, 29, 255} // D3 #1d1d1d
COL_ACCENT :: niello.Color{172, 185, 252, 255} // A1 #acb9fc
COL_TEXT :: niello.Color{255, 254, 234, 255} // L1 #fffeea
COL_DIM :: niello.Color{143, 143, 143, 255} // TextGray #8f8f8f
COL_HOVER :: niello.Color{255, 255, 255, 34} // T1 #22ffffff
COL_PRESS :: niello.Color{255, 255, 255, 16}
COL_TRACK :: niello.Color{255, 255, 255, 20} // seek/volume track
COL_ON_ACCENT :: niello.Color{10, 12, 20, 255} // text on the accent color

// ---- units ------------------------------------------------------------------

root_u: niello.Unit // window root column
topbar_u: niello.Unit
logo_u: niello.Unit
nav_u: niello.Unit // nav / toolbar button (Stack + centered label)
nav_hover_u: niello.Unit
nav_press_u: niello.Unit
nav_label_u: niello.Unit
sync_label_u: niello.Unit
spacer_u: niello.Unit // grow spacer in rows
pb_info_u: niello.Unit // title/artist column in the playback bar

// Now Playing
np_col_u: niello.Unit
np_cover_u: niello.Unit
np_title_u: niello.Unit
np_artist_u: niello.Unit

// Library
lib_row_u: niello.Unit
sidebar_u: niello.Unit
section_u: niello.Unit
section_hover_u: niello.Unit
section_label_u: niello.Unit
lib_panel_u: niello.Unit
placeholder_u: niello.Unit

// Composer
tray_u: niello.Unit
tray_title_u: niello.Unit

// Playback bar
bar_u: niello.Unit
tbtn_u: niello.Unit // transport button (Prev / Next)
tbtn_hover_u: niello.Unit
tbtn_press_u: niello.Unit
tbtn_label_u: niello.Unit
play_u: niello.Unit // the Play/Pause button — accent member
play_label_u: niello.Unit
pb_title_u: niello.Unit
pb_artist_u: niello.Unit
seek_track_u: niello.Unit
seek_fill_u: niello.Unit // accent member
time_u: niello.Unit
vol_track_u: niello.Unit
vol_fill_u: niello.Unit // accent member

// Settings popup
popup_u: niello.Unit
popup_title_u: niello.Unit

// Selection variants: per-instance overlays (With.variant) — the
// engine's mechanism for selected state.
sel_u: niello.Unit // selected background (buttons, section rows)
label_sel_u: niello.Unit // selected label color

// The accent group: everything that recolors with the accent.
// Step 4 drives it from the playing song's accent color.
accent_group: niello.Group

init_theme :: proc() {
	niello.mint(&root_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		color = COL_BG,
	})
	niello.mint(&topbar_u, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size = niello.Size{niello.grow(), niello.fixed(48)},
		padding = [4]u16{16, 8, 16, 8}, gap = 8,
		align = [2]niello.Align_Kind{niello.Align_Kind.Start, niello.Align_Kind.Center},
	})
	niello.mint(&logo_u, niello.NO_UNIT, {
		font_size = 18, font_weight = niello.Font_Weight.Bold,
		font_color = COL_ACCENT, text = "Nachtul",
	})
	niello.mint(&nav_hover_u, niello.NO_UNIT, {color = COL_HOVER})
	niello.mint(&nav_press_u, niello.NO_UNIT, {color = COL_PRESS})
	niello.mint(&nav_u, niello.NO_UNIT, {
		layout = niello.Layout.Stack,
		align = [2]niello.Align_Kind{niello.Align_Kind.Center, niello.Align_Kind.Center},
		size = niello.Size{niello.fixed(132), niello.fixed(34)},
		corner_radius = 8,
		hover = nav_hover_u, press = nav_press_u, focusable = true,
	})
	niello.mint(&nav_label_u, niello.NO_UNIT, {font_size = 14, font_color = COL_TEXT})
	niello.mint(&sync_label_u, niello.NO_UNIT, {font_size = 12.5, font_color = COL_DIM, text = "Ready"})
	niello.mint(&spacer_u, niello.NO_UNIT, {
		size = niello.Size{niello.grow(), niello.fit()},
	})
	niello.mint(&pb_info_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.fixed(220), niello.fit()},
		gap = 2,
	})

	// Now Playing
	niello.mint(&np_col_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.grow(), niello.grow()},
		padding = [4]u16{24, 24, 24, 24}, gap = 14,
		align = [2]niello.Align_Kind{niello.Align_Kind.Center, niello.Align_Kind.Center},
	})
	niello.mint(&np_cover_u, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(320), niello.fixed(320)},
		color = COL_PANEL2, corner_radius = 12,
	})
	niello.mint(&np_title_u, niello.NO_UNIT, {font_size = 22, font_color = COL_TEXT, text = "Nothing playing"})
	niello.mint(&np_artist_u, niello.NO_UNIT, {font_size = 15, font_color = COL_DIM, text = "—"})

	// Library
	niello.mint(&lib_row_u, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size = niello.Size{niello.grow(), niello.grow()},
		padding = [4]u16{12, 12, 12, 12}, gap = 12,
	})
	niello.mint(&sidebar_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.fixed(196), niello.grow()},
		gap = 4,
	})
	niello.mint(&section_hover_u, niello.NO_UNIT, {color = COL_HOVER})
	niello.mint(&section_u, niello.NO_UNIT, {
		layout = niello.Layout.Stack,
		align = [2]niello.Align_Kind{niello.Align_Kind.Start, niello.Align_Kind.Center},
		size = niello.Size{niello.grow(), niello.fixed(34)},
		padding = [4]u16{12, 0, 12, 0},
		corner_radius = 8,
		hover = section_hover_u, press = nav_press_u, focusable = true,
	})
	niello.mint(&section_label_u, niello.NO_UNIT, {font_size = 13.5, font_color = COL_TEXT})
	niello.mint(&lib_panel_u, niello.NO_UNIT, {
		layout = niello.Layout.Stack,
		size = niello.Size{niello.grow(), niello.grow()},
		color = COL_PANEL, corner_radius = 8,
		align = [2]niello.Align_Kind{niello.Align_Kind.Center, niello.Align_Kind.Center},
	})
	niello.mint(&placeholder_u, niello.NO_UNIT, {font_size = 14, font_color = COL_DIM})

	// Composer
	niello.mint(&tray_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.grow(), niello.grow()},
		color = COL_PANEL, corner_radius = 8,
		padding = [4]u16{12, 12, 12, 12}, gap = 8,
	})
	niello.mint(&tray_title_u, niello.NO_UNIT, {font_size = 13, font_color = COL_DIM})

	// Playback bar
	niello.mint(&bar_u, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size = niello.Size{niello.grow(), niello.fixed(76)},
		color = COL_PANEL,
		padding = [4]u16{16, 10, 16, 10}, gap = 12,
		align = [2]niello.Align_Kind{niello.Align_Kind.Start, niello.Align_Kind.Center},
	})
	niello.mint(&tbtn_hover_u, niello.NO_UNIT, {color = COL_HOVER})
	niello.mint(&tbtn_press_u, niello.NO_UNIT, {color = COL_PRESS})
	niello.mint(&tbtn_u, niello.NO_UNIT, {
		layout = niello.Layout.Stack,
		align = [2]niello.Align_Kind{niello.Align_Kind.Center, niello.Align_Kind.Center},
		size = niello.Size{niello.fixed(52), niello.fixed(40)},
		corner_radius = 8,
		hover = tbtn_hover_u, press = tbtn_press_u, focusable = true,
	})
	niello.mint(&tbtn_label_u, niello.NO_UNIT, {font_size = 13, font_color = COL_TEXT})
	niello.mint(&play_u, niello.NO_UNIT, {
		layout = niello.Layout.Stack,
		align = [2]niello.Align_Kind{niello.Align_Kind.Center, niello.Align_Kind.Center},
		size = niello.Size{niello.fixed(64), niello.fixed(40)},
		color = COL_ACCENT, corner_radius = 8,
		hover = tbtn_hover_u, press = tbtn_press_u, focusable = true,
	})
	niello.mint(&play_label_u, niello.NO_UNIT, {font_size = 13, font_weight = niello.Font_Weight.Bold, font_color = COL_ON_ACCENT})
	niello.mint(&pb_title_u, niello.NO_UNIT, {font_size = 14, font_color = COL_TEXT, text = "Nothing playing"})
	niello.mint(&pb_artist_u, niello.NO_UNIT, {font_size = 12.5, font_color = COL_DIM, text = "—"})
	niello.mint(&seek_track_u, niello.NO_UNIT, {
		layout = niello.Layout.Stack,
		size = niello.Size{niello.grow(), niello.fixed(6)},
		color = COL_TRACK, corner_radius = 3,
	})
	niello.mint(&seek_fill_u, niello.NO_UNIT, {
		size = niello.Size{niello.percent(0), niello.percent(1)},
		color = COL_ACCENT, corner_radius = 3,
	})
	niello.mint(&time_u, niello.NO_UNIT, {font_size = 12.5, font_color = COL_DIM})
	niello.mint(&vol_track_u, niello.NO_UNIT, {
		layout = niello.Layout.Stack,
		size = niello.Size{niello.fixed(110), niello.fixed(6)},
		color = COL_TRACK, corner_radius = 3,
	})
	niello.mint(&vol_fill_u, niello.NO_UNIT, {
		size = niello.Size{niello.percent(0.75), niello.percent(1)},
		color = COL_ACCENT, corner_radius = 3,
	})

	niello.mint(&sel_u, niello.NO_UNIT, {color = COL_PANEL2, corner_radius = 8})
	niello.mint(&label_sel_u, niello.NO_UNIT, {font_color = COL_ACCENT})

	// Settings popup
	niello.mint(&popup_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.fixed(420), niello.fixed(240)},
		color = COL_PANEL2, corner_radius = 12,
		padding = [4]u16{20, 18, 20, 18}, gap = 12,
	})
	niello.mint(&popup_title_u, niello.NO_UNIT, {font_size = 17, font_color = COL_TEXT, text = "Settings"})

	// The accent group — set once here; step 4 re-sets it per song.
	accent_group = niello.group_new("accent")
	niello.group_add(accent_group, seek_fill_u)
	niello.group_add(accent_group, vol_fill_u)
	niello.group_add(accent_group, play_u)
	niello.group_set(accent_group, niello.Field.Color, COL_ACCENT)
}
