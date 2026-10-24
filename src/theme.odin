// Nachtul's night theme: the C# app's palette (App.axaml resources,
// cross-checked against the C++ port's globals.h — D1/D2/A1 agree in
// both) expressed as Niello units + groups.
//
// Units are grouped per screen/area into structs (top, np, lib, comp,
// pb, pop) rather than one flat list — a screen's theme reads as one
// object.
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

// ---- unit collections ---------------------------------------------------------

root_u: niello.Unit // the window root column stands alone

Topbar :: struct {
	bar:       niello.Unit,
	logo:      niello.Unit,
	nav:       niello.Unit, // nav / toolbar button (Stack + centered label)
	nav_hover: niello.Unit,
	nav_press: niello.Unit,
	nav_label: niello.Unit,
	sync_label: niello.Unit,
	spacer:    niello.Unit,
}

Now_Playing :: struct {
	col:    niello.Unit,
	cover:  niello.Unit,
	title:  niello.Unit,
	artist: niello.Unit,
}

Library :: struct {
	row:           niello.Unit,
	sidebar:       niello.Unit,
	section:       niello.Unit,
	section_hover: niello.Unit,
	section_label: niello.Unit,
	panel:         niello.Unit,
	placeholder:   niello.Unit,
	content:         niello.Unit, // TTB column: header + grid + pager
	pager:           niello.Unit,
	// Section header + borrowed search field (src/textfield.odin)
	header:          niello.Unit,
	field:           niello.Unit,
	field_focus:     niello.Unit,
	field_text:      niello.Unit,
	caret:           niello.Unit,
	placeholder_text: niello.Unit,
	// Collection grid
	grid_scroll: niello.Unit,
	grid_row:    niello.Unit,
	card:        niello.Unit,
	card_art:    niello.Unit,
	card_letter: niello.Unit,
	card_name:   niello.Unit,
	card_meta:   niello.Unit,
	pager_label: niello.Unit,
	// Sort menu (popup)
	menu_panel: niello.Unit,
	menu_item:  niello.Unit,
	menu_label: niello.Unit,
}

Album :: struct {
	header:    niello.Unit,
	art:       niello.Unit,
	name:      niello.Unit,
	meta:      niello.Unit,
	scroll:    niello.Unit,
	row:       niello.Unit,
	row_hover: niello.Unit,
	row_pos:   niello.Unit,
	row_title: niello.Unit,
	row_artists: niello.Unit,
	row_dur:   niello.Unit,
	row_play:  niello.Unit, // hover play button, anchored over the pos slot
}

Composer :: struct {
	tray:       niello.Unit,
	tray_title: niello.Unit,
}

Playback :: struct {
	bar:        niello.Unit,
	info:       niello.Unit, // title/artist column
	title:      niello.Unit,
	artist:     niello.Unit,
	tbtn:       niello.Unit, // transport button (Prev / Next / Queue)
	tbtn_hover: niello.Unit,
	tbtn_press: niello.Unit,
	tbtn_label: niello.Unit,
	play:       niello.Unit, // Play/Pause — accent member
	play_label: niello.Unit,
	seek_track: niello.Unit,
	seek_fill:  niello.Unit, // accent member
	time:       niello.Unit,
	vol_track:  niello.Unit,
	vol_fill:   niello.Unit, // accent member
	vol_label:  niello.Unit, // numeric volume readout, e.g. "75%"
}

Popup :: struct {
	panel: niello.Unit,
	title: niello.Unit,
	row:   niello.Unit, // a text row inside the popup (folder paths)
}

// Shared selection variants: per-instance overlays (With.variant) —
// the engine's mechanism for selected state.
Common :: struct {
	sel:       niello.Unit, // selected background
	label_sel: niello.Unit, // selected label color
}

top: Topbar
np: Now_Playing
lib: Library
album: Album
comp: Composer
pb: Playback
pop: Popup
common: Common

// The accent group: everything that recolors with the accent.
// Step 4 drives it from the playing song's accent color.
accent_group: niello.Group

init_theme :: proc() {
	niello.mint(&root_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		color = COL_BG,
	})

	// Top bar
	niello.mint(&top.bar, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size = niello.Size{niello.grow(), niello.fixed(48)},
		padding = [4]u16{16, 8, 16, 8}, gap = 8,
		align = [2]niello.Align_Kind{niello.Align_Kind.Start, niello.Align_Kind.Center},
	})
	niello.mint(&top.logo, niello.NO_UNIT, {
		font_size = 18, font_weight = niello.Font_Weight.Bold,
		font_color = COL_ACCENT, text = "Nachtul",
	})
	niello.mint(&top.nav_hover, niello.NO_UNIT, {color = COL_HOVER})
	niello.mint(&top.nav_press, niello.NO_UNIT, {color = COL_PRESS})
	niello.mint(&top.nav, niello.NO_UNIT, {
		layout = niello.Layout.Stack,
		align = [2]niello.Align_Kind{niello.Align_Kind.Center, niello.Align_Kind.Center},
		size = niello.Size{niello.fixed(132), niello.fixed(34)},
		corner_radius = 8,
		hover = top.nav_hover, press = top.nav_press, focusable = true,
	})
	niello.mint(&top.nav_label, niello.NO_UNIT, {font_size = 14, font_color = COL_TEXT})
	niello.mint(&top.sync_label, niello.NO_UNIT, {font_size = 12.5, font_color = COL_DIM, text = "Ready"})
	niello.mint(&top.spacer, niello.NO_UNIT, {
		size = niello.Size{niello.grow(), niello.fit()},
	})

	// Now Playing
	niello.mint(&np.col, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.grow(), niello.grow()},
		padding = [4]u16{24, 24, 24, 24}, gap = 14,
		align = [2]niello.Align_Kind{niello.Align_Kind.Center, niello.Align_Kind.Center},
	})
	niello.mint(&np.cover, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(320), niello.fixed(320)},
		color = COL_PANEL2, corner_radius = 12,
	})
	niello.mint(&np.title, niello.NO_UNIT, {font_size = 22, font_color = COL_TEXT, text = "Nothing playing"})
	niello.mint(&np.artist, niello.NO_UNIT, {font_size = 15, font_color = COL_DIM, text = "—"})

	// Library
	niello.mint(&lib.row, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size = niello.Size{niello.grow(), niello.grow()},
		padding = [4]u16{12, 12, 12, 12}, gap = 12,
	})
	niello.mint(&lib.sidebar, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.fixed(196), niello.grow()},
		gap = 4,
	})
	niello.mint(&lib.section_hover, niello.NO_UNIT, {color = COL_HOVER})
	niello.mint(&lib.section, niello.NO_UNIT, {
		layout = niello.Layout.Stack,
		align = [2]niello.Align_Kind{niello.Align_Kind.Start, niello.Align_Kind.Center},
		size = niello.Size{niello.grow(), niello.fixed(34)},
		padding = [4]u16{12, 0, 12, 0},
		corner_radius = 8,
		hover = lib.section_hover, press = top.nav_press, focusable = true,
	})
	niello.mint(&lib.section_label, niello.NO_UNIT, {font_size = 13.5, font_color = COL_TEXT})
	niello.mint(&lib.panel, niello.NO_UNIT, {
		layout = niello.Layout.Stack,
		size = niello.Size{niello.grow(), niello.grow()},
		color = COL_PANEL, corner_radius = 8,
		align = [2]niello.Align_Kind{niello.Align_Kind.Center, niello.Align_Kind.Center},
	})
	niello.mint(&lib.placeholder, niello.NO_UNIT, {font_size = 14, font_color = COL_DIM})

	niello.mint(&lib.content, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.grow(), niello.grow()},
		gap = 8,
	})
	niello.mint(&lib.pager, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size = niello.Size{niello.grow(), niello.fixed(36)},
		gap = 8,
		align = [2]niello.Align_Kind{niello.Align_Kind.Center, niello.Align_Kind.Center},
	})
	niello.mint(&lib.header, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size = niello.Size{niello.grow(), niello.fixed(44)},
		gap = 8,
		align = [2]niello.Align_Kind{niello.Align_Kind.Start, niello.Align_Kind.Center},
	})
	niello.mint(&lib.field_focus, niello.NO_UNIT, {
		color = niello.Color{255, 255, 255, 14},
		overlay_border_color = COL_ACCENT, overlay_border_width = 2,
	})
	niello.mint(&lib.field, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size = niello.Size{niello.grow(1), niello.fixed(36)},
		color = COL_PANEL2, corner_radius = 8,
		padding = [4]u16{12, 0, 12, 0},
		align = [2]niello.Align_Kind{niello.Align_Kind.Start, niello.Align_Kind.Center},
		focus = lib.field_focus, focusable = true,
	})
	niello.mint(&lib.field_text, niello.NO_UNIT, {
		font_size = 14, font_color = COL_TEXT,
		whitespace = niello.Whitespace.Preserve,
	})
	niello.mint(&lib.caret, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(2), niello.fixed(20)},
		color = COL_ACCENT,
	})
	niello.mint(&lib.placeholder_text, niello.NO_UNIT, {font_size = 14, font_color = COL_DIM})
	niello.mint(&lib.grid_scroll, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.grow(), niello.grow()},
		scroll = niello.Scroll.Vertical, smooth_scroll = true,
		gap = 12,
	})
	niello.mint(&lib.grid_row, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size = niello.Size{niello.grow(), niello.fit()},
		gap = 12,
	})
	niello.mint(&lib.card, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.fixed(168), niello.fixed(212)},
		gap = 4,
		hover = top.nav_hover, focusable = true, corner_radius = 8,
	})
	niello.mint(&lib.card_art, niello.NO_UNIT, {
		layout = niello.Layout.Stack,
		size = niello.Size{niello.fixed(168), niello.fixed(168)},
		color = COL_PANEL2, corner_radius = 8,
		image_fit = niello.Image_Fit.Uniform_Fill,
		align = [2]niello.Align_Kind{niello.Align_Kind.Center, niello.Align_Kind.Center},
	})
	niello.mint(&lib.card_letter, niello.NO_UNIT, {font_size = 44, font_color = COL_DIM})
	niello.mint(&lib.card_name, niello.NO_UNIT, {font_size = 13.5, font_color = COL_TEXT})
	niello.mint(&lib.card_meta, niello.NO_UNIT, {font_size = 12, font_color = COL_DIM})
	niello.mint(&lib.pager_label, niello.NO_UNIT, {font_size = 13, font_color = COL_DIM})
	niello.mint(&lib.menu_panel, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.fixed(200), niello.fit()},
		color = COL_PANEL2, corner_radius = 8,
		padding = [4]u16{6, 6, 6, 6}, gap = 2,
	})
	niello.mint(&lib.menu_item, niello.NO_UNIT, {
		layout = niello.Layout.Stack,
		size = niello.Size{niello.grow(), niello.fixed(30)},
		padding = [4]u16{10, 0, 10, 0},
		align = [2]niello.Align_Kind{niello.Align_Kind.Start, niello.Align_Kind.Center},
		corner_radius = 6,
		hover = top.nav_hover, focusable = true,
	})
	niello.mint(&lib.menu_label, niello.NO_UNIT, {font_size = 13, font_color = COL_TEXT})

	// Album (collection view)
	niello.mint(&album.header, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size = niello.Size{niello.grow(), niello.fixed(172)},
		padding = [4]u16{16, 16, 16, 16}, gap = 16,
	})
	niello.mint(&album.art, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(140), niello.fixed(140)},
		color = COL_PANEL2, corner_radius = 8,
		image_fit = niello.Image_Fit.Uniform_Fill,
	})
	niello.mint(&album.name, niello.NO_UNIT, {font_size = 20, font_color = COL_TEXT})
	niello.mint(&album.meta, niello.NO_UNIT, {font_size = 13.5, font_color = COL_DIM})
	niello.mint(&album.scroll, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.grow(), niello.grow()},
		scroll = niello.Scroll.Vertical, smooth_scroll = true,
		padding = [4]u16{8, 4, 8, 4},
	})
	niello.mint(&album.row_hover, niello.NO_UNIT, {color = COL_HOVER})
	niello.mint(&album.row, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size = niello.Size{niello.grow(), niello.fixed(38)},
		padding = [4]u16{12, 0, 12, 0}, gap = 10,
		align = [2]niello.Align_Kind{niello.Align_Kind.Start, niello.Align_Kind.Center},
		corner_radius = 6,
		hover = album.row_hover, focusable = true,
	})
	niello.mint(&album.row_pos, niello.NO_UNIT, {
		font_size = 12.5, font_color = COL_DIM,
		size = niello.Size{niello.fixed(30), niello.fit()},
	})
	niello.mint(&album.row_title, niello.NO_UNIT, {font_size = 14, font_color = COL_TEXT})
	niello.mint(&album.row_artists, niello.NO_UNIT, {
		font_size = 13, font_color = COL_DIM,
		size = niello.Size{niello.grow(), niello.fit()},
	})
	niello.mint(&album.row_dur, niello.NO_UNIT, {font_size = 12.5, font_color = COL_DIM})
	niello.mint(&album.row_play, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(52), niello.fixed(38)},
		align = [2]niello.Align_Kind{niello.Align_Kind.Start, niello.Align_Kind.Center},
		color = COL_PANEL, corner_radius = 6,
		font_size = 13, font_color = COL_TEXT,
	})

	// Composer
	niello.mint(&comp.tray, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.grow(), niello.grow()},
		color = COL_PANEL, corner_radius = 8,
		padding = [4]u16{12, 12, 12, 12}, gap = 8,
	})
	niello.mint(&comp.tray_title, niello.NO_UNIT, {font_size = 13, font_color = COL_DIM})

	// Playback bar
	niello.mint(&pb.bar, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size = niello.Size{niello.grow(), niello.fixed(76)},
		color = COL_PANEL,
		padding = [4]u16{16, 10, 16, 10}, gap = 12,
		align = [2]niello.Align_Kind{niello.Align_Kind.Start, niello.Align_Kind.Center},
	})
	niello.mint(&pb.info, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.fixed(220), niello.fit()},
		gap = 2,
	})
	niello.mint(&pb.title, niello.NO_UNIT, {font_size = 14, font_color = COL_TEXT, text = "Nothing playing"})
	niello.mint(&pb.artist, niello.NO_UNIT, {font_size = 12.5, font_color = COL_DIM, text = "—"})
	niello.mint(&pb.tbtn_hover, niello.NO_UNIT, {color = COL_HOVER})
	niello.mint(&pb.tbtn_press, niello.NO_UNIT, {color = COL_PRESS})
	niello.mint(&pb.tbtn, niello.NO_UNIT, {
		layout = niello.Layout.Stack,
		align = [2]niello.Align_Kind{niello.Align_Kind.Center, niello.Align_Kind.Center},
		size = niello.Size{niello.fixed(52), niello.fixed(40)},
		corner_radius = 8,
		hover = pb.tbtn_hover, press = pb.tbtn_press, focusable = true,
	})
	niello.mint(&pb.tbtn_label, niello.NO_UNIT, {font_size = 13, font_color = COL_TEXT})
	niello.mint(&pb.play, niello.NO_UNIT, {
		layout = niello.Layout.Stack,
		align = [2]niello.Align_Kind{niello.Align_Kind.Center, niello.Align_Kind.Center},
		size = niello.Size{niello.fixed(64), niello.fixed(40)},
		color = COL_ACCENT, corner_radius = 8,
		hover = pb.tbtn_hover, press = pb.tbtn_press, focusable = true,
	})
	niello.mint(&pb.play_label, niello.NO_UNIT, {font_size = 13, font_weight = niello.Font_Weight.Bold, font_color = COL_ON_ACCENT})
	niello.mint(&pb.seek_track, niello.NO_UNIT, {
		layout = niello.Layout.Stack,
		size = niello.Size{niello.grow(), niello.fixed(6)},
		color = COL_TRACK, corner_radius = 3,
	})
	niello.mint(&pb.seek_fill, niello.NO_UNIT, {
		size = niello.Size{niello.percent(0), niello.percent(1)},
		color = COL_ACCENT, corner_radius = 3,
	})
	niello.mint(&pb.time, niello.NO_UNIT, {font_size = 12.5, font_color = COL_DIM})
	niello.mint(&pb.vol_track, niello.NO_UNIT, {
		layout = niello.Layout.Stack,
		size = niello.Size{niello.fixed(110), niello.fixed(6)},
		color = COL_TRACK, corner_radius = 3,
	})
	niello.mint(&pb.vol_fill, niello.NO_UNIT, {
		size = niello.Size{niello.percent(0.75), niello.percent(1)},
		color = COL_ACCENT, corner_radius = 3,
	})
	niello.mint(&pb.vol_label, niello.NO_UNIT, {font_size = 12.5, font_color = COL_TEXT})

	// Settings popup
	niello.mint(&pop.panel, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.fixed(420), niello.fixed(240)},
		color = COL_PANEL2, corner_radius = 12,
		padding = [4]u16{20, 18, 20, 18}, gap = 12,
	})
	niello.mint(&pop.title, niello.NO_UNIT, {font_size = 17, font_color = COL_TEXT, text = "Settings"})
	niello.mint(&pop.row, niello.NO_UNIT, {font_size = 13, font_color = COL_TEXT})

	// Shared selection variants
	niello.mint(&common.sel, niello.NO_UNIT, {color = COL_PANEL2, corner_radius = 8})
	niello.mint(&common.label_sel, niello.NO_UNIT, {font_color = COL_ACCENT})

	// The accent group — set once here; step 4 re-sets it per song.
	accent_group = niello.group_new("accent")
	niello.group_add(accent_group, pb.seek_fill)
	niello.group_add(accent_group, pb.vol_fill)
	niello.group_add(accent_group, pb.play)
	niello.group_set(accent_group, niello.Field.Color, COL_ACCENT)
}
