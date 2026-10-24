// Step 3: page queries + the library screens driven end to end
// (worker → inbox → cards → collection view → search).
package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import niello "../../NielloUI/niello"
import nachtul "../src"

@(test)
test_collections_page :: proc(t: ^testing.T) {
	dir := "/tmp/nachtul_t_page"
	os.make_directory(dir)
	db, ok := nachtul.db_open(fmt.tprintf("%s/Nachtul.db", dir))
	testing.expect(t, ok, "db opens")
	defer nachtul.db_close(db)
	nachtul.db_create_schema(db)
	seed_library(db)
	// Give the album a thumbnail blob (the shared seed leaves them
	// NULL) — hex for "JPEGDATA". And give s-1 a large song thumbnail
	// ("SONG"): the album's own blob must win for the album, and the
	// playlist (which contains s-1 and has no blob of its own) must
	// fall back to the song's — the real library's shape, where only
	// playlists carry collection thumbnails and every song has one.
	nachtul.db_exec(db, "UPDATE Collections SET thumbnail = x'4A50454744415441' WHERE uuid = 'c-album';")
	nachtul.db_exec(db, "UPDATE Songs SET largeThumbnail = x'534F4E47' WHERE uuid = 's-1';")

	base := nachtul.Lib_Query{section = .All, sort = .None, page = 0, page_size = 30}
	rows, total := nachtul.collections_page(db, base)
	testing.expect(t, total == 3 && len(rows) == 3, "all: 3 collections")
	// Name order: Debut Album, List, The Testers.
	testing.expect(t, rows[0].uuid == "c-album" && rows[2].uuid == "c-artist", "default order is name")
	testing.expect(t, rows[0].has_thumbnail, "album has a thumbnail flag")
	if thumb, tok := rows[0].thumbnail.?; tok {
		testing.expect(t, string(thumb) == "JPEGDATA", "page query carries thumbnail bytes")
	} else {
		testing.expect(t, false, "thumbnail bytes present")
	}

	pl := base
	pl.section = .Playlists
	rows, total = nachtul.collections_page(db, pl)
	testing.expect(t, total == 1 && rows[0].uuid == "c-list", "playlists section filters")
	testing.expect(t, rows[0].has_thumbnail, "playlist resolves art from its first song")
	if thumb, tok := rows[0].thumbnail.?; tok {
		testing.expect(t, string(thumb) == "SONG", "fallback thumbnail is the song's large thumb")
	} else {
		testing.expect(t, false, "fallback thumbnail present")
	}

	cols := base
	cols.section = .Collections
	rows, total = nachtul.collections_page(db, cols)
	testing.expect(t, total == 0, "collections section: seed has no album-family rows")

	unc := base
	unc.section = .Uncategorized
	rows, total = nachtul.collections_page(db, unc)
	testing.expect(t, total == 1 && rows[0].uuid == "c-album", "uncategorized section finds the seed album")

	by_size := base
	by_size.sort = .Size
	rows, _ = nachtul.collections_page(db, by_size)
	testing.expect(t, rows[0].uuid == "c-album", "size sort: album (3000 bytes of songs) first")

	by_tags := base
	by_tags.sort = .Tag_Count
	rows, total = nachtul.collections_page(db, by_tags)
	testing.expect(t, total == 3 && len(rows) == 3, "tag-count sort runs (all zero here)")

	s1 := base
	s1.search = "debut"
	rows, total = nachtul.collections_page(db, s1)
	testing.expect(t, total == 1 && rows[0].uuid == "c-album", "search by token")

	s2 := base
	s2.search = "testers"
	rows, total = nachtul.collections_page(db, s2)
	testing.expect(t, total == 1 && rows[0].uuid == "c-artist", "search finds the artist")

	s3 := base
	s3.search = "zzzz"
	rows, total = nachtul.collections_page(db, s3)
	testing.expect(t, total == 0 && len(rows) == 0, "search miss is empty, not an error")

	p0 := base
	p0.sort = .Name
	p0.page_size = 2
	rows, total = nachtul.collections_page(db, p0)
	testing.expect(t, total == 3 && len(rows) == 2, "page 0 of 2")
	p1 := p0
	p1.page = 1
	rows, _ = nachtul.collections_page(db, p1)
	testing.expect(t, len(rows) == 1 && rows[0].uuid == "c-artist", "page 1 has the remainder")
}

@(test)
test_artists_join :: proc(t: ^testing.T) {
	testing.expect(t, nachtul.artists_join(`["Alpha","Beta"]`) == "Alpha, Beta", "two artists join")
	testing.expect(t, nachtul.artists_join(`[]`) == "", "empty array is empty")
	testing.expect(t, nachtul.artists_join(`["Say \"Hi\""]`) == `Say "Hi"`, "escapes undo")
}

// Thread-crossing waits get a generous budget: the worker is a real
// thread, and on a loaded machine its wakeups can lag far behind the
// (trivial) work itself.
wait_for :: proc(cond: proc() -> bool, budget := 3000) -> bool {
	for _ in 0 ..< budget {
		step(idle())
		if cond() {
			return true
		}
		time.sleep(5 * time.Millisecond)
	}
	return false
}

lib_loaded :: proc() -> bool {
	return nachtul.app.lib_loaded
}

collection_open :: proc() -> bool {
	return nachtul.app.open_loaded
}

back_to_three :: proc() -> bool {
	return len(nachtul.app.lib_rows) == 3
}

one_match :: proc() -> bool {
	return len(nachtul.app.lib_rows) == 1 && nachtul.app.lib_rows[0].uuid == "c-artist"
}

@(test)
test_library_flow :: proc(t: ^testing.T) {
	setup()
	defer teardown()
	nachtul.stop_library()
	dir := "/tmp/nachtul_t_libflow"
	os.make_directory(dir)
	{
		db, ok := nachtul.db_open(fmt.tprintf("%s/Nachtul.db", dir))
		testing.expect(t, ok, "seed db opens")
		nachtul.db_create_schema(db)
		seed_library(db)
		nachtul.db_close(db)
	}
	nachtul.start_library_load(niello.test_context(), dir)
	defer nachtul.stop_library()

	testing.expect(t, wait_for(proc() -> bool { return nachtul.app.loaded }), "library loads")
	click(nachtul.instances.nav[1])
	testing.expect(t, wait_for(lib_loaded), "first page lands")
	testing.expect(t, len(nachtul.app.lib_rows) == 3 && nachtul.app.lib_total == 3, "3 cards on page 1")

	// Sort menu: open, pick Name — state lands, menu closes.
	click(nachtul.instances.sort_btn)
	settle()
	testing.expect(t, nachtul.app.sort_open, "sort menu opens")
	click(nachtul.instances.sort_items[1])
	settle()
	testing.expect(t, nachtul.app.sort == .Name && !nachtul.app.sort_open, "sort picked + menu closed")

	// Open the first card (Debut Album in name order).
	click(nachtul.instances.cards[0])
	testing.expect(t, nachtul.app.open_uuid == "c-album", "card click opens the album")
	testing.expect(t, wait_for(collection_open), "songs land")
	testing.expect(t, len(nachtul.app.open_songs) == 2, "album has its 2 songs")
	draws_song := false
	for cmd in niello.draw_list() {
		if cmd.tag == .Text && string(cmd.text_ptr[:cmd.text_len]) == "Alpha Song (Live)" {
			draws_song = true
		}
	}
	testing.expect(t, draws_song, "song rows draw")

	click(nachtul.instances.song_first)
	testing.expect(t, nachtul.app.selected_song == "s-1", "song row click selects")

	click(nachtul.instances.back)
	settle()
	testing.expect(t, nachtul.app.open_uuid == "", "back closes the collection")
	testing.expect(t, wait_for(back_to_three), "grid page still there")

	// Search: focus the field, type, the page re-queries.
	click(nachtul.app.search.inst)
	typed := idle()
	typed.text = "testers"
	step(typed)
	settle(2)
	testing.expect(t, wait_for(one_match), "search narrows to the artist")
	testing.expect(t, nachtul.app.lib_total == 1, "total follows the search")

	// Clear it with backspaces; the full page returns.
	for _ in 0 ..< 7 {
		bs := idle()
		bs.keys[0] = niello.Key_Event{scancode = 42, down = true}
		bs.key_count = 1
		step(bs)
	}
	settle(2)
	testing.expect(t, wait_for(back_to_three), "clearing the search restores the page")
}

// The row free helpers, on same-thread allocations: they must run
// clean under the test tracking allocator (no double free, no bad
// free) and leave a single row zeroed. The flow test above covers
// the drain paths (overwrite, back/close, search re-page); this
// pins the helpers themselves.
@(test)
test_free_rows_helpers :: proc(t: ^testing.T) {
	rows: [dynamic]nachtul.Collection_Row
	append(&rows, nachtul.Collection_Row{
		uuid = strings.clone("c-1"),
		name = strings.clone("One"),
		thumbnail = make([]u8, 4),
	})
	append(&rows, nachtul.Collection_Row{
		uuid = strings.clone("c-2"),
		name = strings.clone("Two"),
	})
	songs: [dynamic]nachtul.Song_Row
	append(&songs, nachtul.Song_Row{
		uuid = strings.clone("s-1"),
		title = strings.clone("Song"),
		artists = strings.clone("[]"),
		location = strings.clone("/x"),
		file_name = strings.clone("x.mp3"),
	})
	folders: [dynamic]nachtul.Folder
	append(&folders, nachtul.Folder{path = strings.clone("/music")})
	nachtul.free_collection_rows(rows)
	nachtul.free_song_rows(songs)
	nachtul.free_folders(folders)
	// A single row frees its fields and zeroes itself, so a second
	// free through close_collection-style reuse is a no-op, not a
	// double free.
	row := nachtul.Collection_Row{
		uuid = strings.clone("c-3"),
		name = strings.clone("Three"),
		thumbnail = make([]u8, 2),
	}
	nachtul.free_collection_row(&row)
	testing.expect(t, row.uuid == "" && row.name == "" && row.thumbnail == nil,
		"a freed single row is zeroed")
	nachtul.free_collection_row(&row)
}
