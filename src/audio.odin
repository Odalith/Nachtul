// Step 4: playback — the player model + the GStreamer backend (F3).
//
// The model is pure: every proc below is a no-op against the backend
// until audio_start loads it, so tests drive the model headlessly
// with no .so and no audio device. The backend glue is thin procs
// at the bottom, all guarded by backend.loaded.
//
// Two facts from library.c shape this file, and both contradict a
// naive reading of the plan:
//  - Gapless switches are SILENT. about-to-finish sets the next URI
//    and fires no callback, so the app cannot learn a track changed
//    from the backend. The wall clock is the advance signal: while
//    playing, declare checks position >= duration and advances.
//    EOF is only a backstop (it fires when the gapless slot was
//    empty, i.e. the queue really ended). Stale EOFs — the clock
//    already moved on — are dropped by the generation tag.
//  - loop_count is a REMAINING-REPEATS counter, not a mode: -1
//    repeats forever, 0 plays once, 1 plays TWICE (EOS decrements
//    then restarts). The plan's "-1/1 toggle" was ffAudio's count,
//    where 1 meant once. Porting 1 literally would replay every
//    track, so the port maps Normal -> 0, Track -> -1, and Queue
//    (repeat queue, which the C# never implemented — "Todo handle
//    loop playlist") -> 0 with an app-level wrap in the slot.
//  - seek() fires the restart callback synchronously on the
//    calling thread, and EOS-with-loop fires it on the GLib
//    thread. Both funnel through the inbox; the seeking flag
//    tells a seek restart (anchor already set) from a loop replay
//    (re-anchor to 0).
package nachtul

import "core:c"
import "core:dynlib"
import "core:fmt"
import "core:math/rand"
import "base:runtime"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import inbox "../../NielloUI/niello/inbox"

// The one button, three states (F4, in his listed order):
// Normal -> Track -> Queue -> Normal.
Loop_Mode :: enum {
	Normal,
	Track,
	Queue,
}

Player_State :: enum {
	Stopped,
	Playing,
	Paused,
}

// A queued song. Strings are CLONES owned by the queue (the rows
// they come from are freed on page/collection close, like
// open_uuid/selected_song) — free with free_entry. artists_display
// is the joined form, computed ONCE at construction: the bar shows
// it every frame, and joining per frame would heap-leak per frame
// (artists_join returns a heap clone).
Play_Entry :: struct {
	uuid:            string,
	title:           string,
	artists:         string, // JSON array, as stored
	artists_display: string, // joined once, for the bar
	location:        string, // absolute file path, as stored
	duration_ms:     i64,
}

Player :: struct {
	truth:   [dynamic]Play_Entry, // the queue truth list (F5)
	mix:     [dynamic]Play_Entry, // shuffled mix; only when shuffle
	shuffle: bool,
	idx:     int, // index into the active list; -1 = no current song
	state:   Player_State,
	loop:    Loop_Mode,
	volume:  int, // backend units = percent of original volume (F6): 0..130
	muted:   bool,
	seeking: bool, // a backend seek is in flight; its restart clears it
	gen:     u64, // bumped on every play; stale inbox events drop
	pos_base_ms: f64,
	anchor:      time.Tick, // valid while Playing
	paused_ms:   f64,
}

PLAYER_DEFAULT_VOLUME :: 75

player: Player

// ---- ownership ---------------------------------------------------------------

clone_entry :: proc(e: Play_Entry) -> Play_Entry {
	return Play_Entry{
		uuid            = strings.clone(e.uuid),
		title           = strings.clone(e.title),
		artists         = strings.clone(e.artists),
		artists_display = strings.clone(e.artists_display),
		location        = strings.clone(e.location),
		duration_ms     = e.duration_ms,
	}
}

free_entry :: proc(e: ^Play_Entry) {
	if len(e.uuid) > 0 {
		delete(e.uuid)
	}
	if len(e.title) > 0 {
		delete(e.title)
	}
	if len(e.artists) > 0 {
		delete(e.artists)
	}
	if len(e.artists_display) > 0 {
		delete(e.artists_display)
	}
	if len(e.location) > 0 {
		delete(e.location)
	}
	e^ = {}
}

// Frees the entries AND the backing array (the suite's free_*
// helpers do the same) and nils the header, so a reset leaves
// nothing tracked behind.
free_entries :: proc(list: ^[dynamic]Play_Entry) {
	if list^ == nil {
		return
	}
	for &e in list {
		free_entry(&e)
	}
	delete(list^)
	list^ = nil
}

entry_from_song :: proc(s: Song_Row) -> Play_Entry {
	return Play_Entry{
		uuid            = strings.clone(s.uuid),
		title           = strings.clone(s.title),
		artists         = strings.clone(s.artists),
		artists_display = artists_join(s.artists),
		location        = strings.clone(s.location),
		duration_ms     = s.duration,
	}
}

// player_free releases the queues and the gapless slot and restores
// defaults. Tests call it (via player_reset) at teardown; audio_stop
// calls it after the audio thread is joined.
player_free :: proc() {
	free_entries(&player.truth)
	free_entries(&player.mix)
	sync.lock(&player_cb_mu)
	if next_slot != nil {
		delete(next_slot)
		next_slot = nil
	}
	gen_cached = 0
	sync.unlock(&player_cb_mu)
	player = Player{volume = PLAYER_DEFAULT_VOLUME, idx = -1}
}

player_reset :: proc() {
	player_free()
}

// ---- active list -------------------------------------------------------------

player_active :: proc(p: ^Player) -> []Play_Entry {
	if p.shuffle {
		return p.mix[:]
	}
	return p.truth[:]
}

player_current :: proc(p: ^Player) -> (^Play_Entry, bool) {
	list := player_active(p)
	if p.idx < 0 || p.idx >= len(list) {
		return nil, false
	}
	return &list[p.idx], true
}

player_find_uuid :: proc(list: []Play_Entry, uuid: string) -> int {
	for e, i in list {
		if e.uuid == uuid {
			return i
		}
	}
	return -1
}

player_find_uuid_active :: proc(p: ^Player, uuid: string) -> int {
	return player_find_uuid(player_active(p), uuid)
}

// ---- position ----------------------------------------------------------------

// player_position_ms is the bar's clock: wall-clock-anchored while
// playing (a 1 s tick only re-reads it — no tick counting, so no
// drift), frozen while paused, 0 while stopped.
player_position_ms :: proc(p: ^Player) -> f64 {
	switch p.state {
	case .Playing:
		return p.pos_base_ms + time.duration_milliseconds(time.tick_since(p.anchor))
	case .Paused:
		return p.paused_ms
	case .Stopped:
		return 0
	}
	return 0
}

// Pure form for tests: elapsed since the anchor, supplied by the caller.
player_position_at_ms :: proc(p: ^Player, elapsed_ms: f64) -> f64 {
	switch p.state {
	case .Playing:
		return p.pos_base_ms + elapsed_ms
	case .Paused:
		return p.paused_ms
	case .Stopped:
		return 0
	}
	return 0
}

// ---- transport ---------------------------------------------------------------

player_play_entry :: proc(p: ^Player, idx: int) {
	list := player_active(p)
	if idx < 0 || idx >= len(list) {
		return
	}
	e := list[idx]
	p.idx = idx
	p.state = .Playing
	p.pos_base_ms = 0
	p.anchor = time.tick_now()
	p.seeking = false
	p.gen += 1
	sync.lock(&player_cb_mu)
	gen_cached = p.gen
	sync.unlock(&player_cb_mu)
	uri := uri_for(e.location)
	backend_play(uri)
	delete(uri)
	player_update_slot(p)
}

player_stop :: proc(p: ^Player) {
	p.state = .Stopped
	p.pos_base_ms = 0
	p.paused_ms = 0
	p.seeking = false
	backend_pause(true) // hold the pipeline; there is no stop call
	player_update_slot(p)
}

player_toggle :: proc(p: ^Player) {
	switch p.state {
	case .Playing:
		p.paused_ms = player_position_ms(p)
		p.state = .Paused
		backend_pause(true)
	case .Paused:
		p.pos_base_ms = p.paused_ms
		p.anchor = time.tick_now()
		p.state = .Playing
		backend_pause(false)
	case .Stopped:
		// Resume the current song, or the first if none was ever played.
		if p.idx < 0 {
			if len(player_active(p)) == 0 {
				return
			}
			player_play_entry(p, 0)
		} else {
			player_play_entry(p, p.idx)
		}
	}
}

player_next :: proc(p: ^Player) {
	list := player_active(p)
	if len(list) == 0 || p.idx < 0 {
		return
	}
	if p.idx + 1 < len(list) {
		player_play_entry(p, p.idx + 1)
	} else if p.loop == .Queue {
		player_play_entry(p, 0)
	} else {
		player_stop(p)
	}
}

player_previous :: proc(p: ^Player) {
	if p.idx < 0 {
		return
	}
	// C# verbatim: <= 3.5 s goes to the previous track, more
	// restarts the current one. At the first track there is no
	// previous, so it restarts either way.
	if player_position_ms(p) > 3500 {
		player_seek_frac(p, 0)
		return
	}
	if p.idx > 0 {
		player_play_entry(p, p.idx - 1)
	} else {
		player_seek_frac(p, 0)
	}
}

player_seek_frac :: proc(p: ^Player, frac: f64) {
	e, ok := player_current(p)
	if !ok {
		return
	}
	frac := clamp(frac, 0, 1)
	p.pos_base_ms = frac * f64(e.duration_ms)
	if p.state == .Paused {
		p.paused_ms = p.pos_base_ms
	} else {
		p.anchor = time.tick_now()
	}
	p.seeking = true
	backend_seek(frac * 100) // gstaudio takes percent, 0..100
}

// player_natural_advance is the gapless advance signal, called from
// declare while Playing. The backend switches URIs silently, so the
// clock is the only witness: when the position reaches the
// duration, move on. EOF (drained before this runs) is the backstop
// for a track the backend ended early.
player_natural_advance :: proc(p: ^Player) {
	if p.state != .Playing {
		return
	}
	e, ok := player_current(p)
	if !ok || e.duration_ms <= 0 {
		return
	}
	if player_position_ms(p) < f64(e.duration_ms) {
		return
	}
	player_next(p)
}

// ---- volume / mute / loop / shuffle ------------------------------------------

player_set_volume :: proc(p: ^Player, v: int) {
	v := clamp(v, 0, 130)
	p.volume = v
	backend_set_volume(v)
	// C# verbatim: setting 0 mutes; leaving 0 unmutes.
	if v == 0 && !p.muted {
		p.muted = true
		backend_mute(true)
	} else if v > 0 && p.muted {
		p.muted = false
		backend_mute(false)
	}
}

player_toggle_mute :: proc(p: ^Player) {
	p.muted = !p.muted
	backend_mute(p.muted)
	// C# verbatim: unmuting while at 0 sets the volume to 5.
	if !p.muted && p.volume == 0 {
		p.volume = 5
		backend_set_volume(5)
	}
}

player_loop_count :: proc(p: ^Player) -> int {
	if p.loop == .Track {
		return -1
	}
	return 0
}

player_cycle_loop :: proc(p: ^Player) {
	switch p.loop {
	case .Normal:
		p.loop = .Track
	case .Track:
		p.loop = .Queue
	case .Queue:
		p.loop = .Normal
	}
	backend_set_loop_count(player_loop_count(p))
	// Repeat-queue wraps the last song's next.
	player_update_slot(p)
}

player_set_shuffle :: proc(p: ^Player, on: bool) {
	if on == p.shuffle {
		return
	}
	if on {
		// Mix = truth with the post-current remainder shuffled
		// (Fisher-Yates, C# verbatim). The prefix through the
		// current song is untouched, so the index — and the
		// song — do not move. With nothing playing, the whole
		// mix shuffles (C#: start index 0 when position is null).
		free_entries(&p.mix)
		for e in p.truth {
			append(&p.mix, clone_entry(e))
		}
		start := p.idx < 0 ? 0 : p.idx + 1
		if start < len(p.mix) {
			rand.shuffle(p.mix[start:])
		}
		p.shuffle = true
	} else {
		// Back to the truth list (F5): the current song keeps
		// playing, at its truth index.
		if cur, ok := player_current(p); ok {
			p.shuffle = false
			p.idx = player_find_uuid(p.truth[:], cur.uuid)
		} else {
			p.shuffle = false
			p.idx = -1
		}
		free_entries(&p.mix)
	}
	player_update_slot(p)
}

// ---- queue operations (C# PlayClicked, verbatim shapes) ----------------------

// Append (F1): append; if the queue was empty, start playing.
player_append :: proc(p: ^Player, e: Play_Entry) {
	was_empty := len(p.truth) == 0
	append(&p.truth, clone_entry(e))
	if p.shuffle {
		append(&p.mix, clone_entry(e))
	}
	if was_empty {
		player_play_entry(p, 0)
	} else {
		player_update_slot(p)
	}
}

// Replace: the queue becomes entries, playing play_idx. Shuffle, if
// on, re-mixes the new list's post-current remainder. The four queue
// options land as a row popup later; Replace/Next/Now ship in the
// model now so the popup wires to procs, not new logic.
player_replace :: proc(p: ^Player, entries: []Play_Entry, play_idx: int) {
	free_entries(&p.truth)
	free_entries(&p.mix)
	for e in entries {
		append(&p.truth, clone_entry(e))
	}
	if p.shuffle {
		for e in p.truth {
			append(&p.mix, clone_entry(e))
		}
		start := play_idx < 0 ? 0 : play_idx + 1
		if start < len(p.mix) {
			rand.shuffle(p.mix[start:])
		}
	}
	if play_idx >= 0 && play_idx < len(p.truth) {
		player_play_entry(p, play_idx)
	} else {
		p.idx = -1
		p.state = .Stopped
		player_update_slot(p)
	}
}

// Insert after the current song in each list; returns the inserted
// song's index in the active list.
player_insert_after_current :: proc(p: ^Player, e: Play_Entry) -> int {
	if len(p.truth) == 0 {
		append(&p.truth, clone_entry(e))
		if p.shuffle {
			append(&p.mix, clone_entry(e))
		}
		player_update_slot(p)
		return 0
	}
	if p.idx < 0 {
		append(&p.truth, clone_entry(e))
		if p.shuffle {
			append(&p.mix, clone_entry(e))
		}
		player_update_slot(p)
		return len(player_active(p)) - 1
	}
	cur, _ := player_current(p)
	ti := player_find_uuid(p.truth[:], cur.uuid)
	inject_at(&p.truth, ti + 1, clone_entry(e))
	if p.shuffle {
		mi := player_find_uuid(p.mix[:], cur.uuid)
		inject_at(&p.mix, mi + 1, clone_entry(e))
	}
	player_update_slot(p)
	return p.idx + 1
}

// Next (PlaceNextInQueue): after the current song, or play now when
// the queue is empty (the PlayClicked empty-queue rule).
player_place_next :: proc(p: ^Player, e: Play_Entry) {
	if len(p.truth) == 0 {
		player_append(p, e)
		return
	}
	player_insert_after_current(p, e)
}

// Now (PlayNowInQueue): jump to it if queued, else insert after
// current and play it.
player_play_now :: proc(p: ^Player, e: Play_Entry) {
	if i := player_find_uuid_active(p, e.uuid); i >= 0 {
		player_play_entry(p, i)
		return
	}
	at := player_insert_after_current(p, e)
	player_play_entry(p, at)
}

// ---- inbox backstops -----------------------------------------------------------

// EOF with a matching generation means the backend really ended the
// track and the wall clock has not advanced yet: advance here. A
// mismatched generation is stale (the clock already moved on).
player_on_track_ended :: proc(p: ^Player, gen: u64) {
	if gen != p.gen || p.state != .Playing {
		return
	}
	player_next(p)
}

// A restart is either a seek confirmation (anchor already set — just
// clear the flag) or a backend loop replay (repeat track — the track
// restarted, so re-anchor to 0). Stale restarts drop on generation.
player_on_restart :: proc(p: ^Player, gen: u64) {
	if gen != p.gen {
		return
	}
	if p.seeking {
		p.seeking = false
	} else if p.state == .Playing {
		p.pos_base_ms = 0
		p.anchor = time.tick_now()
	}
}

// ---- gapless slot --------------------------------------------------------------

// The next URI, precomputed on every queue/index/loop/shuffle
// change. The about-to-finish callback only READS it — it must
// never allocate (it runs on the GLib thread), so the slot is a
// heap cstring owned here, replaced under the callback mutex.
next_slot: cstring
player_cb_mu: sync.Mutex
// The generation as the callback thread last saw it. The model
// itself is frame-thread-owned; only gen + slot cross threads.
gen_cached: u64

player_update_slot :: proc(p: ^Player) {
	sync.lock(&player_cb_mu)
	defer sync.unlock(&player_cb_mu)
	if next_slot != nil {
		delete(next_slot)
		next_slot = nil
	}
	list := player_active(p)
	next_idx := -1
	if p.state != .Stopped && p.idx >= 0 {
		if p.idx + 1 < len(list) {
			next_idx = p.idx + 1
		} else if p.loop == .Queue && len(list) > 0 {
			next_idx = 0
		}
	}
	if next_idx >= 0 {
		uri := uri_for(list[next_idx].location)
		next_slot = strings.clone_to_cstring(uri)
		delete(uri)
	}
}

// playbin wants a URI; the DB stores plain paths. Minimal escaping
// (% first, then the characters that break a file URI); paths with
// other specials are a known limitation, not a silent wrong answer.
uri_for :: proc(location: string) -> string {
	b: strings.Builder
	strings.builder_init(&b)
	strings.write_string(&b, "file://")
	for ch in location {
		switch ch {
		case '%':
			strings.write_string(&b, "%25")
		case ' ':
			strings.write_string(&b, "%20")
		case '#':
			strings.write_string(&b, "%23")
		case '?':
			strings.write_string(&b, "%3F")
		case:
			strings.write_rune(&b, ch)
		}
	}
	return strings.to_string(b)
}

// ---- backend glue --------------------------------------------------------------

// The .so is gitignored local-only (third_party/native, like the
// library worker's DB it is never committed), and tests must run
// without it — so it is loaded at runtime with dynlib, not linked.
// A missing .so fails loudly at startup and leaves the transport
// dead (backend.loaded false); it never fails silently mid-play.
Audio_Error_Cb :: proc "c" (message: cstring, request: c.int)
Audio_Void_Cb :: proc "c" ()
Audio_Next_Cb :: proc "c" () -> cstring
Audio_Initialize :: proc "c" (cstring, c.int, c.int, Audio_Error_Cb, Audio_Void_Cb, Audio_Void_Cb, Audio_Next_Cb) -> c.int
Audio_Play :: proc "c" (cstring)
Audio_Pause :: proc "c" (bool)
Audio_Seek :: proc "c" (f64)
Audio_Set_Volume :: proc "c" (c.int)
Audio_Mute :: proc "c" (bool)
Audio_Set_Loop :: proc "c" (c.int)
Audio_Shutdown :: proc "c" ()

Backend :: struct {
	lib:            dynlib.Library,
	loaded:         bool,
	initialize:     Audio_Initialize,
	play_audio:     Audio_Play,
	pause:          Audio_Pause,
	seek:           Audio_Seek,
	set_volume:     Audio_Set_Volume,
	mute:           Audio_Mute,
	set_loop_count: Audio_Set_Loop,
	shutdown:       Audio_Shutdown,
}

backend: Backend
audio_thread: ^thread.Thread

APP_NAME_CSTR: cstring = "Nachtul"

audio_start :: proc() {
	player_reset()
	lib, ok := dynlib.load_library("third_party/native/linux-x64/libgstaudio.so", false, context.allocator)
	if !ok {
		// Loud, once, at startup — the transport stays dead rather
		// than pretending to play.
		fmt.eprintln("nachtul: could not load third_party/native/linux-x64/libgstaudio.so — playback disabled")
		return
	}
	backend.lib = lib
	resolve :: proc(name: string) -> (rawptr, bool) {
		return dynlib.symbol_address(backend.lib, name)
	}
	if p, ok := resolve("initialize"); ok {
		backend.initialize = cast(Audio_Initialize)p
	} else {
		fmt.eprintln("nachtul: libgstaudio.so has no initialize — playback disabled")
		dynlib.unload_library(lib)
		return
	}
	if p, ok := resolve("play_audio"); ok {
		backend.play_audio = cast(Audio_Play)p
	} else {
		fmt.eprintln("nachtul: libgstaudio.so has no play_audio — playback disabled")
		dynlib.unload_library(lib)
		return
	}
	if p, ok := resolve("pause"); ok {
		backend.pause = cast(Audio_Pause)p
	} else {
		fmt.eprintln("nachtul: libgstaudio.so has no pause — playback disabled")
		dynlib.unload_library(lib)
		return
	}
	if p, ok := resolve("seek"); ok {
		backend.seek = cast(Audio_Seek)p
	} else {
		fmt.eprintln("nachtul: libgstaudio.so has no seek — playback disabled")
		dynlib.unload_library(lib)
		return
	}
	if p, ok := resolve("set_volume"); ok {
		backend.set_volume = cast(Audio_Set_Volume)p
	} else {
		fmt.eprintln("nachtul: libgstaudio.so has no set_volume — playback disabled")
		dynlib.unload_library(lib)
		return
	}
	if p, ok := resolve("mute"); ok {
		backend.mute = cast(Audio_Mute)p
	} else {
		fmt.eprintln("nachtul: libgstaudio.so has no mute — playback disabled")
		dynlib.unload_library(lib)
		return
	}
	if p, ok := resolve("set_loop_count"); ok {
		backend.set_loop_count = cast(Audio_Set_Loop)p
	} else {
		fmt.eprintln("nachtul: libgstaudio.so has no set_loop_count — playback disabled")
		dynlib.unload_library(lib)
		return
	}
	if p, ok := resolve("shutdown"); ok {
		backend.shutdown = cast(Audio_Shutdown)p
	} else {
		fmt.eprintln("nachtul: libgstaudio.so has no shutdown — playback disabled")
		dynlib.unload_library(lib)
		return
	}
	backend.loaded = true
	// Initial volume + loop ride initialize's parameters (the
	// pipeline does not exist until the audio thread builds it, so
	// no set_* call may run before then). Later changes use the
	// setters, which user actions trigger long after startup.
	audio_thread = thread.create_and_start_with_data(nil, audio_thread_proc, context)
}

audio_stop :: proc() {
	if audio_thread != nil {
		backend_shutdown() // quits the GLib loop; initialize returns
		thread.join(audio_thread)
		thread.destroy(audio_thread)
		audio_thread = nil
	}
	if backend.loaded {
		dynlib.unload_library(backend.lib)
		backend.loaded = false
	}
	player_free()
}

audio_thread_proc :: proc(_: rawptr) {
	// Blocks on the GLib main loop until shutdown().
	backend.initialize(APP_NAME_CSTR, PLAYER_DEFAULT_VOLUME, 0, audio_on_error, audio_on_eof, audio_on_restart, audio_on_next)
}

// The error callback is NEVER invoked by this backend (errors print
// to stderr) — registered only because initialize requires it, and
// nothing may depend on it.
audio_on_error :: proc "c" (message: cstring, request: c.int) {
	_ = message
	_ = request
}

// C callbacks have no implicit context, so the send runs under the
// default context. That is the same heap allocator the frame thread
// uses (the library worker's passed context is the main context),
// so the inbox queue's backing array stays single-allocator — the
// worker thread already sends through this inbox the same way.
audio_on_eof :: proc "c" () {
	context = runtime.default_context()
	if !box_ready {
		return
	}
	sync.lock(&player_cb_mu)
	gen := gen_cached
	sync.unlock(&player_cb_mu)
	inbox.send(&box, Track_Ended{gen = gen})
}

audio_on_restart :: proc "c" () {
	context = runtime.default_context()
	if !box_ready {
		return
	}
	sync.lock(&player_cb_mu)
	gen := gen_cached
	sync.unlock(&player_cb_mu)
	inbox.send(&box, Playback_Restarted{gen = gen})
}

audio_on_next :: proc "c" () -> cstring {
	sync.lock(&player_cb_mu)
	defer sync.unlock(&player_cb_mu)
	return next_slot
}

// Thin guarded wrappers: no-ops until audio_start loads the backend,
// so the model (and the tests) never touch a missing .so.
backend_play :: proc(uri: string) {
	if !backend.loaded {
		return
	}
	c := strings.clone_to_cstring(uri)
	backend.play_audio(c)
	delete(c)
}

backend_pause :: proc(paused: bool) {
	if backend.loaded {
		backend.pause(paused)
	}
}

backend_seek :: proc(pct: f64) {
	if backend.loaded {
		backend.seek(pct)
	}
}

backend_set_volume :: proc(v: int) {
	if backend.loaded {
		backend.set_volume(c.int(v))
	}
}

backend_mute :: proc(m: bool) {
	if backend.loaded {
		backend.mute(m)
	}
}

backend_set_loop_count :: proc(n: int) {
	if backend.loaded {
		backend.set_loop_count(c.int(n))
	}
}

backend_shutdown :: proc() {
	if backend.loaded {
		backend.shutdown()
	}
}
