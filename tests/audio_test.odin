// Step 4 model tests: queue operations, shuffle, loop, volume,
// position, EOF generations, and the gapless slot. No backend (the
// .so is never loaded here), no engine — the procs under test are
// pure when backend.loaded is false.
package tests

import "core:testing"

import nachtul "../src"

// Borrowed literals: player_append/replace clone everything they
// keep, so the passed struct never owns its strings.
fake_entry :: proc(uuid: string = "song-1", location: string = "/music/song-1.mp3", duration_ms: i64 = 200_000) -> nachtul.Play_Entry {
	return nachtul.Play_Entry{uuid = uuid, title = "Title", artists = `["Artist"]`, artists_display = "Artist", location = location, duration_ms = duration_ms}
}

reset_player :: proc() {
	nachtul.player_reset()
}

@(test)
test_append_empty_plays_and_nonempty_appends :: proc(t: ^testing.T) {
	reset_player()
	defer reset_player()
	nachtul.player_append(&nachtul.player, fake_entry("song-1", "/music/1.mp3"))
	testing.expect(t, nachtul.player.state == .Playing, "append to an empty queue starts playing")
	testing.expect(t, nachtul.player.idx == 0, "first song is current")
	nachtul.player_append(&nachtul.player, fake_entry("song-2", "/music/2.mp3"))
	testing.expect(t, nachtul.player.state == .Playing, "second append keeps playing")
	testing.expect(t, nachtul.player.idx == 0, "second append does not move the current song")
	testing.expect(t, len(nachtul.player.truth) == 2, "queue holds both songs")
	// The gapless slot points at the next song.
	testing.expect(t, nachtul.next_slot != nil, "slot set with a next song")
	testing.expect(t, string(nachtul.next_slot) == "file:///music/2.mp3", "slot is the next song's URI")
}

@(test)
test_next_prev_and_stop :: proc(t: ^testing.T) {
	reset_player()
	defer reset_player()
	nachtul.player_append(&nachtul.player, fake_entry("song-1"))
	nachtul.player_append(&nachtul.player, fake_entry("song-2"))
	nachtul.player_append(&nachtul.player, fake_entry("song-3"))
	nachtul.player_next(&nachtul.player)
	testing.expect(t, nachtul.player.idx == 1, "next moves to song 2")
	nachtul.player_next(&nachtul.player)
	testing.expect(t, nachtul.player.idx == 2, "next moves to song 3")
	nachtul.player_next(&nachtul.player)
	testing.expect(t, nachtul.player.state == .Stopped, "next at the end stops (loop Normal)")
	nachtul.player_toggle(&nachtul.player)
	testing.expect(t, nachtul.player.state == .Playing, "play resumes the current song")
	testing.expect(t, nachtul.player.idx == 2, "resume keeps the index")
	// Freshly resumed, the position is ~0 (<= 3.5 s), so Previous
	// goes back rather than restarting.
	nachtul.player_previous(&nachtul.player)
	testing.expect(t, nachtul.player.idx == 1, "previous within 3.5 s goes back")
	nachtul.player_previous(&nachtul.player)
	testing.expect(t, nachtul.player.idx == 0, "previous reaches the first song")
	nachtul.player_previous(&nachtul.player)
	testing.expect(t, nachtul.player.idx == 0, "previous at the first song restarts it")
	// Past 3.5 s, Previous restarts instead of going back.
	nachtul.player_next(&nachtul.player) // song 2
	nachtul.player.pos_base_ms = 10000
	nachtul.player_previous(&nachtul.player)
	testing.expect(t, nachtul.player.idx == 1, "previous past 3.5 s stays on the song")
	testing.expect(t, nachtul.player.seeking, "restart is a seek")
	nachtul.player_on_restart(&nachtul.player, nachtul.player.gen)
	testing.expect(t, !nachtul.player.seeking, "restart clears the seeking flag")
}

@(test)
test_restart_reanchors_on_loop_replay :: proc(t: ^testing.T) {
	reset_player()
	defer reset_player()
	nachtul.player_append(&nachtul.player, fake_entry("song-1"))
	nachtul.player.pos_base_ms = 5000
	nachtul.player_on_restart(&nachtul.player, nachtul.player.gen)
	testing.expect(t, nachtul.player.pos_base_ms == 0, "loop replay re-anchors to 0")
}

@(test)
test_shuffle_roundtrip :: proc(t: ^testing.T) {
	reset_player()
	defer reset_player()
	ids := []string{"song-1", "song-2", "song-3", "song-4", "song-5"}
	for id in ids {
		nachtul.player_append(&nachtul.player, fake_entry(id))
	}
	nachtul.player_next(&nachtul.player) // song-2
	nachtul.player_next(&nachtul.player) // song-3, idx 2
	nachtul.player_set_shuffle(&nachtul.player, true)
	testing.expect(t, nachtul.player.shuffle, "shuffle on")
	testing.expect(t, len(nachtul.player.mix) == 5, "mix holds the whole queue")
	testing.expect(t, nachtul.player.mix[0].uuid == "song-1" && nachtul.player.mix[1].uuid == "song-2" && nachtul.player.mix[2].uuid == "song-3", "prefix through current is untouched")
	// The suffix is a permutation of song-4/song-5, in some order.
	suffix := nachtul.player.mix[3:]
	testing.expect(t, len(suffix) == 2, "suffix length")
	testing.expect(t, (suffix[0].uuid == "song-4" && suffix[1].uuid == "song-5") || (suffix[0].uuid == "song-5" && suffix[1].uuid == "song-4"), "suffix is a permutation")
	testing.expect(t, nachtul.player.truth[3].uuid == "song-4" && nachtul.player.truth[4].uuid == "song-5", "truth list is untouched by shuffle")
	cur, _ := nachtul.player_current(&nachtul.player)
	testing.expect(t, cur.uuid == "song-3", "current song does not move")
	nachtul.player_set_shuffle(&nachtul.player, false)
	testing.expect(t, !nachtul.player.shuffle, "shuffle off")
	testing.expect(t, nachtul.player.idx == 2, "unshuffle restores the truth index")
	testing.expect(t, len(nachtul.player.mix) == 0, "mix freed on unshuffle")
	cur, _ = nachtul.player_current(&nachtul.player)
	testing.expect(t, cur.uuid == "song-3", "same song after unshuffle")
}

@(test)
test_loop_cycle_and_wrap :: proc(t: ^testing.T) {
	reset_player()
	defer reset_player()
	testing.expect(t, nachtul.player.loop == .Normal, "starts Normal")
	nachtul.player_cycle_loop(&nachtul.player)
	testing.expect(t, nachtul.player.loop == .Track, "Normal -> Track")
	testing.expect(t, nachtul.player_loop_count(&nachtul.player) == -1, "Track maps to -1 (repeat forever)")
	nachtul.player_cycle_loop(&nachtul.player)
	testing.expect(t, nachtul.player.loop == .Queue, "Track -> Queue")
	testing.expect(t, nachtul.player_loop_count(&nachtul.player) == 0, "Queue maps to 0 (backend plays once; the app wraps)")
	nachtul.player_cycle_loop(&nachtul.player)
	testing.expect(t, nachtul.player.loop == .Normal, "Queue -> Normal")
	testing.expect(t, nachtul.player_loop_count(&nachtul.player) == 0, "Normal maps to 0 (plays once, not twice)")

	nachtul.player_append(&nachtul.player, fake_entry("song-1", "/music/1.mp3"))
	nachtul.player_append(&nachtul.player, fake_entry("song-2", "/music/2.mp3"))
	nachtul.player_next(&nachtul.player) // song-2, last
	testing.expect(t, nachtul.next_slot == nil, "no next at the end in Normal mode")
	nachtul.player_set_shuffle(&nachtul.player, false)
	nachtul.player_cycle_loop(&nachtul.player) // Track
	nachtul.player_cycle_loop(&nachtul.player) // Queue
	testing.expect(t, string(nachtul.next_slot) == "file:///music/1.mp3", "repeat-queue wraps the last song's slot to the first")
	nachtul.player_next(&nachtul.player)
	testing.expect(t, nachtul.player.idx == 0 && nachtul.player.state == .Playing, "repeat-queue wraps to the first song")
}

@(test)
test_volume_edges :: proc(t: ^testing.T) {
	reset_player()
	defer reset_player()
	testing.expect(t, nachtul.player.volume == 75, "default volume 75")
	testing.expect(t, !nachtul.player.muted, "starts unmuted")
	nachtul.player_set_volume(&nachtul.player, 0)
	testing.expect(t, nachtul.player.muted, "setting 0 mutes")
	nachtul.player_set_volume(&nachtul.player, 50)
	testing.expect(t, !nachtul.player.muted, "leaving 0 unmutes")
	nachtul.player_toggle_mute(&nachtul.player)
	testing.expect(t, nachtul.player.muted, "mute toggle mutes")
	testing.expect(t, nachtul.player.volume == 50, "mute keeps the volume")
	nachtul.player_toggle_mute(&nachtul.player)
	testing.expect(t, !nachtul.player.muted, "second toggle unmutes")
	nachtul.player_set_volume(&nachtul.player, 0)
	nachtul.player_toggle_mute(&nachtul.player)
	testing.expect(t, !nachtul.player.muted && nachtul.player.volume == 5, "unmuting at 0 sets volume to 5")
	nachtul.player_set_volume(&nachtul.player, 200)
	testing.expect(t, nachtul.player.volume == 130, "volume clamps to 130")
	nachtul.player_set_volume(&nachtul.player, -5)
	testing.expect(t, nachtul.player.volume == 0 && nachtul.player.muted, "volume clamps to 0 (and mutes)")
}

@(test)
test_position_forms :: proc(t: ^testing.T) {
	reset_player()
	defer reset_player()
	testing.expect(t, nachtul.player_position_at_ms(&nachtul.player, 9999) == 0, "stopped position is 0")
	nachtul.player_append(&nachtul.player, fake_entry("song-1"))
	nachtul.player.pos_base_ms = 1000
	testing.expect(t, nachtul.player_position_at_ms(&nachtul.player, 500) == 1500, "playing position is base + elapsed")
	nachtul.player.state = .Paused
	nachtul.player.paused_ms = 3000
	testing.expect(t, nachtul.player_position_at_ms(&nachtul.player, 500) == 3000, "paused position is frozen")
}

@(test)
test_queue_modes :: proc(t: ^testing.T) {
	reset_player()
	defer reset_player()
	nachtul.player_replace(&nachtul.player, []nachtul.Play_Entry{fake_entry("song-1"), fake_entry("song-2"), fake_entry("song-3")}, 1)
	testing.expect(t, nachtul.player.state == .Playing && nachtul.player.idx == 1, "replace plays the given index")
	cur, _ := nachtul.player_current(&nachtul.player)
	testing.expect(t, cur.uuid == "song-2", "replace current is song-2")
	nachtul.player_place_next(&nachtul.player, fake_entry("song-4"))
	testing.expect(t, nachtul.player.truth[2].uuid == "song-4" && nachtul.player.truth[3].uuid == "song-3", "place-next inserts after current")
	nachtul.player_next(&nachtul.player)
	cur, _ = nachtul.player_current(&nachtul.player)
	testing.expect(t, cur.uuid == "song-4", "next reaches the inserted song")
	nachtul.player_play_now(&nachtul.player, fake_entry("song-3"))
	cur, _ = nachtul.player_current(&nachtul.player)
	testing.expect(t, cur.uuid == "song-3", "play-now jumps to a queued song")
	nachtul.player_play_now(&nachtul.player, fake_entry("song-5"))
	cur, _ = nachtul.player_current(&nachtul.player)
	testing.expect(t, cur.uuid == "song-5", "play-now inserts and plays a new song")
	nachtul.player_replace(&nachtul.player, []nachtul.Play_Entry{}, -1)
	testing.expect(t, nachtul.player.state == .Stopped && nachtul.player.idx == -1, "replace with no index stops")
}

@(test)
test_eof_generation_guard :: proc(t: ^testing.T) {
	reset_player()
	defer reset_player()
	nachtul.player_append(&nachtul.player, fake_entry("song-1"))
	nachtul.player_append(&nachtul.player, fake_entry("song-2"))
	gen := nachtul.player.gen
	nachtul.player_on_track_ended(&nachtul.player, gen - 1)
	testing.expect(t, nachtul.player.idx == 0, "stale EOF (old generation) is ignored")
	nachtul.player_on_track_ended(&nachtul.player, gen)
	testing.expect(t, nachtul.player.idx == 1, "fresh EOF advances")
	nachtul.player_on_track_ended(&nachtul.player, gen)
	testing.expect(t, nachtul.player.idx == 1, "the same EOF twice does not double-advance")
	// EOF at the end of a one-song queue stops.
	reset_player()
	nachtul.player_append(&nachtul.player, fake_entry("song-1"))
	nachtul.player_on_track_ended(&nachtul.player, nachtul.player.gen)
	testing.expect(t, nachtul.player.state == .Stopped, "EOF at the end stops")
}

@(test)
test_uri_for :: proc(t: ^testing.T) {
	u := nachtul.uri_for("/music/My Song #1?.mp3")
	defer delete(u)
	testing.expect(t, u == "file:///music/My%20Song%20%231%3F.mp3", "spaces, #, ? are escaped")
	v := nachtul.uri_for("/music/100%.mp3")
	defer delete(v)
	testing.expect(t, v == "file:///music/100%25.mp3", "% escapes first")
}
