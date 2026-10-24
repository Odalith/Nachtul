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
import "core:strings"

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
	screen:           Screen,
	section:          Section,
	settings_open:    bool,
	seek_pct:         f32, // last percent written to pb.seek_fill (see play_bar)
	seek_pct_valid:   bool,
	vol_pct:          f32, // last fraction written to pb.vol_fill
	vol_pct_valid:    bool,
	// Now Playing art (see update_now_playing_art).
	np_art:          niello.Image, // resolved cover (owned when np_art_owned)
	np_art_owned:    bool,
	np_uuid:         string, // uuid the NP art was resolved for (clone)
	sync_status:      string,
	// Library state, landed by the loader through the inbox (step 2).
	loaded:           bool,
	folders:          [dynamic]Folder,
	folder_count:     int,
	collection_count: int,
	song_count:       int,
	// Library screens (step 3).
	search:         Text_Field,
	sort:           Lib_Sort,
	sort_open:      bool,
	page:           int,
	lib_query:      Lib_Query,
	lib_sent:       Lib_Query,
	lib_sent_gen:   u64,
	lib_rows:       [dynamic]Collection_Row,
	lib_total:      int,
	lib_loaded:     bool,
	open_uuid:      string,
	open_row:       Collection_Row,
	open_songs:     [dynamic]Song_Row,
	open_loaded:    bool,
	open_art:       niello.Image,
	open_art_owned: bool,
	selected_song:  string,
}

PAGE_SIZE :: 30

Sort_Def :: struct {
	sort:  Lib_Sort,
	label: string,
}

SORT_DEFS := [?]Sort_Def{
	{.None, "Section order"},
	{.Name, "Name"},
	{.Date_Added, "Date Added"},
	{.Recent, "Recent"},
	{.Size, "Size"},
	{.Duration, "Duration"},
	{.Tag_Count, "Tag Count"},
}

sort_label :: proc(s: Lib_Sort) -> string {
	for d in SORT_DEFS {
		if d.sort == s {
			return d.label
		}
	}
	return "?"
}

collection_type_label :: proc(t: Collection_Type) -> string {
	switch t {
	case .Artist:
		return "Artist"
	case .Album:
		return "Album"
	case .ExtendedPlay:
		return "EP"
	case .Single:
		return "Single"
	case .Compilation:
		return "Compilation"
	case .Playlist:
		return "Playlist"
	case .Taglist:
		return "Taglist"
	case .Uncategorized:
		return "Uncategorized"
	}
	return "?"
}

app := App{sync_status = "Ready"}

// The current frame's clickable instances, refreshed by every declare.
// This is the app's test seam (the port is TODO #45's first consumer):
// headless tests click these by rect and assert on `app`.
Instances :: struct {
	nav:          [3]niello.Instance,
	section:      [11]niello.Instance,
	grid_scroll:  niello.Instance,
	sort_btn:     niello.Instance,
	sort_items:   [len(SORT_DEFS)]niello.Instance,
	page_prev:    niello.Instance,
	page_next:    niello.Instance,
	cards:        [PAGE_SIZE]niello.Instance,
	back:         niello.Instance,
	song_first:   niello.Instance,
	prev, play, next: niello.Instance,
	seek_track, vol_track: niello.Instance,
	shuffle, loop, mute: niello.Instance,
	queue:        niello.Instance,
	settings:     niello.Instance,
	sync:         niello.Instance,
	popup:        niello.Instance,
	popup_close:  niello.Instance,
}

instances: Instances

// The glue entry point. One drain point will land here in step 2
// (the one-inbox rule); step 1 has no producers yet.
declare :: proc() {
	prof_begin("declare")
	defer prof_end()
	// The one drain point: producers (the library loader today, the
	// audio backend and scanner later) land here, before anything
	// projects state.
	drain_library_msgs()

	// Playback position + advance (step 4): while playing, re-arm
	// a 1 s wake (his ruling — the bar updates at 1 Hz, and the
	// position itself is wall-clock-anchored, so no tick counting
	// and no drift) and advance on wall-clock track end. Gapless
	// switches are silent (no callback), so the clock is the
	// advance signal; EOF, drained above, is only a backstop.
	// Idle with nothing playing, the window sleeps.
	if player.state == .Playing {
		niello.wake_in(1000)
		player_natural_advance(&player)
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
	if _, ok := niello.begin(top.bar); ok {
		niello.show(top.logo)
		for def, i in NAV_DEFS {
			selected := app.screen == def.screen
			instances.nav[i] = nav_button(def.key, def.label, selected)
		}
		if _, ok2 := niello.begin(top.spacer); ok2 {}
		niello.show(top.sync_label, 0, {text = app.sync_status})
		instances.sync = nav_button("sync", "Sync", false)
		instances.settings = nav_button("settings", "Settings", false)
	}
}

nav_button :: proc(key: string, label: string, selected: bool, disabled: bool = false) -> niello.Instance {
	i, open := niello.begin(top.nav, niello.key(key), {variant = selected ? common.sel : niello.NO_UNIT, disabled = disabled})
	if open {
		niello.show(top.nav_label, 0, {
			text = label,
			variant = selected ? common.label_sel : niello.NO_UNIT,
		})
	}
	return i
}

// ---- screens ------------------------------------------------------------------

// Now Playing follows the player: title + artist from the
// current queue entry, and the cover resolved on song change
// (coverArt path, then the file's embedded image — see
// coverart.odin). Resolving does file I/O + a decode, so it
// runs only when the current song's uuid changed, not per frame.
update_now_playing_art :: proc() {
	cur, ok := player_current(&player)
	uuid := ""
	if ok {
		uuid = cur.uuid
	}
	if uuid == app.np_uuid {
		return
	}
	if app.np_art_owned && app.np_art != niello.NO_IMAGE {
		niello.image_release(app.np_art)
	}
	app.np_art = niello.NO_IMAGE
	app.np_art_owned = false
	if len(app.np_uuid) > 0 {
		delete(app.np_uuid)
	}
	if len(uuid) > 0 {
		app.np_uuid = strings.clone(uuid)
	} else {
		app.np_uuid = ""
	}
	if ok {
		if img, iok := resolve_np_art(cur^); iok {
			app.np_art = img
			app.np_art_owned = true
		}
	}
}

screen_now_playing :: proc() {
	update_now_playing_art()
	if _, ok := niello.begin(np.col); ok {
		if app.np_art != niello.NO_IMAGE {
			niello.show(np.cover, 0, {image = app.np_art})
		} else {
			niello.show(np.cover)
		}
		if cur, okc := player_current(&player); okc {
			niello.show(np.title, 0, {text = cur.title})
			niello.show(np.artist, 0, {text = len(cur.artists_display) > 0 ? cur.artists_display : "—"})
		} else {
			niello.show(np.title)
			niello.show(np.artist)
		}
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
	prof_begin("screen_library")
	defer prof_end()
	if app.open_uuid != "" {
		screen_collection()
		return
	}
	// The search box edits at declare (the form example's pattern);
	// a change re-pages from the top.
	if edit_text_field(&app.search) {
		app.page = 0
	}
	// The query trigger (D1): desired state vs what was last posted.
	desired := Lib_Query{
		section = app.section,
		search = text_field_string(&app.search),
		sort = app.sort,
		page = app.page,
		page_size = PAGE_SIZE,
	}
	app.lib_query = desired
	if app.loaded && (desired != app.lib_sent || data_generation != app.lib_sent_gen) {
		app.lib_sent = desired
		app.lib_sent_gen = data_generation
		request_collections(desired)
	}

	if _, ok := niello.begin(lib.row); ok {
		if _, ok2 := niello.begin(lib.sidebar); ok2 {
			for def, i in SECTION_DEFS {
				selected := app.section == def.section
				inst, open := niello.begin(lib.section, niello.key(def.key), {variant = selected ? common.sel : niello.NO_UNIT})
				instances.section[i] = inst
				if open {
					niello.show(lib.section_label, 0, {
						text = def.label,
						variant = selected ? common.label_sel : niello.NO_UNIT,
					})
				}
			}
		}
		if _, ok3 := niello.begin(lib.content, niello.key("lib_content")); ok3 {
			if _, okh := niello.begin(lib.header); okh {
				show_text_field(&app.search, niello.key("search"), "Search")
				instances.sort_btn = nav_button("sort", fmt.tprintf("Sort: %s", sort_label(app.sort)), app.sort_open)
			}
			grid_columns()
			gs, okg := niello.begin(lib.grid_scroll)
			instances.grid_scroll = gs
			if okg {
				if !app.lib_loaded {
					niello.show(lib.placeholder, 0, {text = app.loaded ? "Loading…" : "Loading library…"})
				} else if len(app.lib_rows) == 0 {
					niello.show(lib.placeholder, 0, {text = text_field_string(&app.search) != "" ? "No matches." : "No collections in this section yet."})
				} else {
					cols := grid_cols
					row_count := (len(app.lib_rows) + cols - 1) / cols
					for r in 0 ..< row_count {
						if _, okr := niello.begin(lib.grid_row, niello.key_int(r)); okr {
							for c in 0 ..< cols {
								idx := r * cols + c
								if idx < len(app.lib_rows) {
									collection_card(&app.lib_rows[idx], idx)
								}
							}
						}
					}
				}
			}
			if _, okp := niello.begin(lib.pager); okp {
				instances.page_prev = nav_button("page_prev", "Prev", false, app.page <= 0)
				niello.show(lib.pager_label, 0, {text = fmt.tprintf("Page %d of %d · %d collections", app.page + 1, pager_pages(), app.lib_total)})
				instances.page_next = nav_button("page_next", "Next", false, app.page + 1 >= pager_pages())
			}
		}
	}
	if app.sort_open {
		sort_menu()
	}
}

// Column count for the card grid, from the grid's last-frame width.
grid_cols: int = 5

grid_columns :: proc() {
	if r, ok := niello.rect(instances.grid_scroll); ok && r.size.x > 0 {
		grid_cols = clamp(int((r.size.x + 12) / (168 + 12)), 1, 8)
	}
}

collection_card :: proc(row: ^Collection_Row, idx: int) {
	i, open := niello.begin(lib.card, niello.key(row.uuid))
	instances.cards[idx] = i
	if !open {
		return
	}
	if img, ok := page_thumbs[row.uuid]; ok {
		niello.begin(lib.card_art, niello.key_int(1), {image = img})
	} else if _, aopen := niello.begin(lib.card_art, niello.key_int(1)); aopen {
		first := row.name != "" ? row.name[:1] : "?"
		niello.show(lib.card_letter, 0, {text = first})
	}
	niello.show(lib.card_name, niello.key_int(2), {text = row.name})
	niello.show(lib.card_meta, niello.key_int(3), {text = collection_type_label(row.type)})
}

sort_menu :: proc() {
	pi, open := niello.begin_popup(lib.menu_panel, instances.sort_btn, niello.Placement.Below, {gap = 4}, key = niello.key("sort_menu"))
	if open {
		for def, i in SORT_DEFS {
			inst, iopen := niello.begin(lib.menu_item, niello.key_int(i), {variant = app.sort == def.sort ? common.sel : niello.NO_UNIT})
			instances.sort_items[i] = inst
			if iopen {
				niello.show(lib.menu_label, 0, {text = def.label})
			}
		}
	}
	if niello.dismiss_requested(pi) {
		app.sort_open = false
	}
}

pager_pages :: proc() -> int {
	if app.lib_total <= 0 {
		return 1
	}
	return (app.lib_total + PAGE_SIZE - 1) / PAGE_SIZE
}

screen_collection :: proc() {
	prof_begin("screen_collection")
	defer prof_end()
	if _, ok := niello.begin(lib.content, niello.key("collection")); ok {
		instances.back = nav_button("back", "Back", false)
		if _, okh := niello.begin(album.header); okh {
			if app.open_art != 0 {
				niello.show(album.art, 0, {image = app.open_art})
			} else {
				niello.show(album.art)
			}
			if _, oki := niello.begin(lib.content, niello.key("album_info")); oki {
				niello.show(album.name, 0, {text = app.open_loaded ? app.open_row.name : "Loading…"})
				niello.show(album.meta, 0, {text = album_meta_text()})
			}
		}
		if _, oks := niello.begin(album.scroll); oks {
			clear(&song_row_insts)
			clear(&song_row_play_insts)
			for &song, idx in app.open_songs {
				i, open := niello.begin(album.row, niello.key(song.uuid), {variant = song.uuid == app.selected_song ? common.sel : niello.NO_UNIT})
				append(&song_row_insts, i)
				append(&song_row_play_insts, 0)
				if idx == 0 {
					instances.song_first = i
				}
				if open {
					pos := song.position != 0 ? song.position : i64(idx + 1)
					niello.show(album.row_pos, niello.key_int(1), {text = fmt.tprintf("%d", pos)})
					niello.show(album.row_title, niello.key_int(2), {text = song.title})
					niello.show(album.row_artists, niello.key_int(3), {text = artists_join(song.artists)})
					niello.show(album.row_dur, niello.key_int(4), {text = fmt_duration_ms(song.duration)})
					// Hover play button (F1): anchored over the
					// row's position slot. Anchored children take
					// no flow slot, so appearing on hover never
					// shifts the row's text — and on hover it
					// replaces the track number, like every player.
					if niello.hovered(i) {
						song_row_play_insts[idx] = niello.show(album.row_play, 0, {text = "Play", anchored = true})
					}
				}
			}
			if app.open_loaded && len(app.open_songs) == 0 {
				niello.show(lib.placeholder, 0, {text = "No songs."})
			}
		}
	}
}

song_row_insts: [dynamic]niello.Instance
song_row_play_insts: [dynamic]niello.Instance // hover play buttons, parallel to song_row_insts

album_meta_text :: proc() -> string {
	if !app.open_loaded {
		return ""
	}
	total_ms: i64 = 0
	for s in app.open_songs {
		total_ms += s.duration
	}
	return fmt.tprintf("%s · %d songs · %s", collection_type_label(app.open_row.type), len(app.open_songs), fmt_duration_ms(total_ms))
}

fmt_duration_ms :: proc(ms: i64) -> string {
	secs := ms / 1000
	return fmt.tprintf("%d:%02d", secs / 60, secs % 60)
}

// Joins the artists JSON array for display: walks the string
// literals, undoing the escapes the encoder emits.
artists_join :: proc(json: string) -> string {
	b := strings.builder_make()
	count := 0
	i := 0
	for i < len(json) {
		if json[i] != '"' {
			i += 1
			continue
		}
		i += 1 // opening quote
		start := i
		for i < len(json) && json[i] != '"' {
			if json[i] == '\\' {
				i += 1
			}
			i += 1
		}
		if count > 0 {
			strings.write_string(&b, ", ")
		}
		raw := json[start:i]
		j := 0
		for j < len(raw) {
			if raw[j] == '\\' && j + 1 < len(raw) {
				j += 1
			}
			strings.write_byte(&b, raw[j])
			j += 1
		}
		count += 1
		i += 1 // closing quote
	}
	out := strings.clone(strings.to_string(b))
	strings.builder_destroy(&b)
	return out
}

// close_collection frees everything the open collection owns: the
// song rows, the header row's cloned strings + thumbnail blob, and
// the two cloned uuid strings below. The len guards match the free
// helpers: an empty string may be a literal, never a clone.
close_collection :: proc() {
	if app.open_art_owned && int(app.open_art) != 0 {
		niello.image_release(app.open_art)
	}
	app.open_art = 0
	app.open_art_owned = false
	if len(app.open_uuid) > 0 {
		delete(app.open_uuid)
	}
	app.open_uuid = ""
	app.open_loaded = false
	free_song_rows(app.open_songs)
	app.open_songs = nil
	free_collection_row(&app.open_row)
	app.open_row = Collection_Row{}
	if len(app.selected_song) > 0 {
		delete(app.selected_song)
	}
	app.selected_song = ""
}

open_collection :: proc(uuid: string) {
	close_collection()
	// A CLONE, not the row's string: the page that supplied uuid can
	// be freed (page turn, search) while this collection is open, and
	// drain matches incoming songs against open_uuid.
	app.open_uuid = strings.clone(uuid)
	request_songs(uuid)
}

screen_composer :: proc() {
	if _, ok := niello.begin(lib.row, niello.key("composer")); ok {
		tray("tray_in", "Input — drop chips here")
		tray("tray_all", "Has All — and")
		tray("tray_none", "Has None — not")
		if _, ok2 := niello.begin(lib.panel); ok2 {
			niello.show(lib.placeholder, 0, {text = "Matching songs — the Composer arrives in step 5."})
		}
	}
}

tray :: proc(key: string, title: string) {
	if _, ok := niello.begin(comp.tray, niello.key(key)); ok {
		niello.show(comp.tray_title, 0, {text = title})
	}
}

// ---- playback bar ---------------------------------------------------------------

play_bar :: proc() {
	prof_begin("play_bar")
	defer prof_end()
	if _, ok := niello.begin(pb.bar); ok {
		instances.prev = transport_button("prev", "Prev")
		{
			i, open := niello.begin(pb.play, niello.key("play"))
			instances.play = i
			if open {
				niello.show(pb.play_label, 0, {text = player.state == .Playing ? "Pause" : "Play"})
			}
		}
		instances.next = transport_button("next", "Next")
		if _, ok2 := niello.begin(pb.info); ok2 {
			if cur, okc := player_current(&player); okc {
				niello.show(pb.title, 0, {text = cur.title})
				niello.show(pb.artist, 0, {text = len(cur.artists_display) > 0 ? cur.artists_display : "—"})
			} else {
				niello.show(pb.title)
				niello.show(pb.artist)
			}
		}
		cur, has_cur := player_current(&player)
		dur_ms: f64 = 0
		if has_cur {
			dur_ms = f64(cur.duration_ms)
		}
		// Seek (F2a, corrected): the gesture commits exactly once,
		// on release. pressed() is NOT a press event — it stays
		// true for the whole hold (capture), so seeking on it
		// fired a backend flush seek EVERY FRAME of a drag: the
		// pipeline never settled, audio stopped at drag start,
		// and the release seek landed on a wedged backend. A
		// drag's release seeks to the release position; a plain
		// click's release seeks to the click position. During a
		// drag only the preview moves. (A click's seek lands on
		// release instead of press — the one observable F2a
		// deviation, and it is what makes drags work at all.)
		// The fill is a singleton unit, so its fraction is a unit
		// write (With carries content, not size). It must ONLY be
		// written when the percent actually changed: niello.set
		// touches unconditionally, and a touch bumps the unit's
		// visual generation, which pass F reads as damage, which
		// makes frame_end report changed, which makes the glue
		// frame again immediately — a self-perpetuating loop that
		// framed this app at vsync even idle (470 declares in an
		// idle trace, play off). Guarding the write breaks the
		// loop: idle frames stop after the first unchanged one
		// and the host blocks.
		if track, ok3 := niello.begin(pb.seek_track); ok3 {
			instances.seek_track = track
			if niello.drag_completed(track) {
				player_seek_frac(&player, frac_from_drag(track))
			} else if niello.clicked(track) {
				player_seek_frac(&player, frac_from_pointer(track))
			}
			frac := seek_frac_for_bar()
			if niello.dragging(track) {
				frac = frac_from_drag(track)
			}
			if !app.seek_pct_valid || f32(frac) != app.seek_pct {
				app.seek_pct = f32(frac)
				app.seek_pct_valid = true
				niello.set(pb.seek_fill, niello.Field.Size, niello.Size{niello.percent(f32(frac)), niello.percent(1)})
			}
			niello.show(pb.seek_fill)
		}
		pos_ms := player_position_ms(&player)
		if niello.dragging(instances.seek_track) {
			pos_ms = frac_from_drag(instances.seek_track) * dur_ms
		}
		niello.show(pb.time, 0, {text = fmt.tprintf("%s / %s", fmt_time(f32(pos_ms / 1000)), fmt_time(f32(dur_ms / 1000)))})
		instances.shuffle = transport_button("shuffle", player.shuffle ? "Shuffle On" : "Shuffle")
		instances.loop = transport_button("loop", loop_label(player.loop))
		// Volume (F3b: the linear track stays; the radial knob is
		// deferred): volume sets LIVE — unlike seek it costs no
		// flush, so there is no preview/commit split. The live
		// set rides dragging(); a plain click sets on release.
		// (pressed() was the same held-frame bug as seek —
		// harmless for volume, since sets are cheap and
		// idempotent, but the click/drag split is the correct
		// shape and costs nothing.) The fill write is guarded
		// like the seek fill's.
		if track, ok4 := niello.begin(pb.vol_track); ok4 {
			instances.vol_track = track
			if niello.dragging(track) {
				player_set_volume(&player, int(frac_from_drag(track) * 130 + 0.5))
			} else if niello.clicked(track) {
				player_set_volume(&player, int(frac_from_pointer(track) * 130 + 0.5))
			}
			vfrac := f32(player.volume) / 130
			if !app.vol_pct_valid || vfrac != app.vol_pct {
				app.vol_pct = vfrac
				app.vol_pct_valid = true
				niello.set(pb.vol_fill, niello.Field.Size, niello.Size{niello.percent(vfrac), niello.percent(1)})
			}
			niello.show(pb.vol_fill)
		}
		niello.show(pb.vol_label, 0, {text = fmt.tprintf("%d%%", player.volume)})
		instances.mute = transport_button("mute", player.muted ? "Unmute" : "Mute")
		instances.queue = transport_button("queue", "Queue")
	}
}

// The seek fill + time fraction: position over duration, 0 with
// nothing playing or an unknown duration.
seek_frac_for_bar :: proc() -> f64 {
	cur, ok := player_current(&player)
	if !ok || cur.duration_ms <= 0 {
		return 0
	}
	return clamp(player_position_ms(&player) / f64(cur.duration_ms), 0, 1)
}

// Fraction of a bar track under the pointer (press) or under the
// drag position (scrub), clamped to the track.
frac_from_pointer :: proc(track: niello.Instance) -> f64 {
	r, ok := niello.rect(track)
	if !ok || r.size.x <= 0 {
		return 0
	}
	p, pok := niello.mouse_position()
	if !pok {
		return 0
	}
	return clamp(f64(p.x - r.pos.x) / f64(r.size.x), 0, 1)
}

frac_from_drag :: proc(track: niello.Instance) -> f64 {
	r, ok := niello.rect(track)
	if !ok || r.size.x <= 0 {
		return 0
	}
	return clamp(f64(niello.drag_pos(track).x) / f64(r.size.x), 0, 1)
}

loop_label :: proc(l: Loop_Mode) -> string {
	switch l {
	case .Normal:
		return "Loop Off"
	case .Track:
		return "Loop Track"
	case .Queue:
		return "Loop Queue"
	}
	return "Loop Off"
}

transport_button :: proc(key: string, label: string) -> niello.Instance {
	i, open := niello.begin(pb.tbtn, niello.key(key))
	if open {
		niello.show(pb.tbtn_label, 0, {text = label})
	}
	return i
}

fmt_time :: proc(secs: f32) -> string {
	s := int(secs)
	return fmt.tprintf("%d:%02d", s / 60, s % 60)
}

// ---- settings popup --------------------------------------------------------------

settings_popup :: proc() {
	pi, open := niello.begin_popup(pop.panel, 0, niello.Placement.Center, {modal = true}, key = niello.key("settings_popup"))
	instances.popup = pi
	if open {
		niello.show(pop.title)
		niello.show(lib.placeholder, 0, {text = "Music Folders"})
		if !app.loaded {
			niello.show(pop.row, 0, {text = "Loading…"})
		} else if len(app.folders) == 0 {
			niello.show(pop.row, 0, {text = "No folders yet — adding arrives with the picker in step 6."})
		} else {
			// Folder rows are plain text this step; the list becomes a
			// scrollable, editable list in step 6.
			for folder, i in app.folders {
				niello.show(pop.row, niello.key_int(i), {text = folder.path})
			}
		}
		instances.popup_close = nav_button("popup_close", "Close", false)
	}
}

// ---- dispatch ----------------------------------------------------------------------

dispatch :: proc() {
	for def, i in NAV_DEFS {
		if niello.clicked(instances.nav[i]) {
			app.screen = def.screen
			close_collection()
			app.sort_open = false
		}
	}
	for def, i in SECTION_DEFS {
		if niello.clicked(instances.section[i]) {
			app.section = def.section
			app.page = 0
			close_collection()
		}
	}
	if niello.clicked(instances.sort_btn) {
		app.sort_open = true
	}
	if app.sort_open {
		for def, i in SORT_DEFS {
			if niello.clicked(instances.sort_items[i]) {
				app.sort = def.sort
				app.page = 0
				app.sort_open = false
			}
		}
	}
	if niello.clicked(instances.page_prev) && app.page > 0 {
		app.page -= 1
	}
	if niello.clicked(instances.page_next) && app.page + 1 < pager_pages() {
		app.page += 1
	}
	if app.open_uuid == "" {
		for _, idx in app.lib_rows {
			if niello.clicked(instances.cards[idx]) {
				open_collection(app.lib_rows[idx].uuid)
				break
			}
		}
	} else {
		if niello.clicked(instances.back) {
			close_collection()
		}
		for inst, idx in song_row_insts {
			if idx < len(app.open_songs) && niello.clicked(inst) {
				// A clone, like open_uuid: the song rows can be
				// freed (close, reopen) while the selection lives.
				if len(app.selected_song) > 0 {
					delete(app.selected_song)
				}
				app.selected_song = strings.clone(app.open_songs[idx].uuid)
				break
			}
		}
		// Hover play buttons (F1): append (+ play if the queue was
		// empty). Clicking one also selects the row (the button is
		// the row's child, so the row is on the click chain too) —
		// harmless: the playing song gets selected.
		for inst, idx in song_row_play_insts {
			if idx < len(app.open_songs) && niello.clicked(inst) {
				player_append(&player, entry_from_song(app.open_songs[idx]))
				break
			}
		}
	}
	if niello.clicked(instances.prev) {
		player_previous(&player)
	}
	if niello.clicked(instances.play) {
		player_toggle(&player)
	}
	if niello.clicked(instances.next) {
		player_next(&player)
	}
	if niello.clicked(instances.shuffle) {
		player_set_shuffle(&player, !player.shuffle)
	}
	if niello.clicked(instances.loop) {
		player_cycle_loop(&player)
	}
	if niello.clicked(instances.mute) {
		player_toggle_mute(&player)
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

