// The library layer: named queries over the V2 schema (D1 — screens
// are SQL queries, not in-memory scans), the V1 importer (F2's test
// load), and the startup loader that runs them on a worker thread
// and lands the result through the one inbox.
package nachtul

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"

import niello "../../NielloUI/niello"
import inbox "../../NielloUI/niello/inbox"

// ---- row types ------------------------------------------------------------------

Collection_Type :: enum i64 {
	Artist        = 0,
	Album         = 1,
	ExtendedPlay  = 2,
	Single        = 3,
	Compilation   = 4,
	Playlist      = 5,
	Taglist       = 6,
	Uncategorized = 7,
}

Folder :: struct {
	path:     string,
	added_at: i64,
}

Collection_Row :: struct {
	uuid:          string,
	type:          Collection_Type,
	name:          string,
	added_at:      i64,
	last_opened:   i64,
	has_thumbnail: bool,
	thumbnail:     Maybe([]u8), // filled by page queries only
}

Song_Row :: struct {
	uuid:     string,
	title:    string,
	artists:  string, // JSON array, as stored
	location: string,
	file_name: string,
	duration: i64, // ms
	size:     i64, // bytes
	position: i64, // within the queried collection
}

// The data generation (D1): bumped by every write through this
// layer. Query results are stamped with it; a moved generation is
// what makes declare refetch instead of trusting a cached page.
data_generation: u64

bump_generation :: proc() {
	data_generation += 1
}

// ---- folders ---------------------------------------------------------------------

folder_add :: proc(db: Db, path: string) -> bool {
	stmt, ok := stmt_prepare(db, "INSERT INTO Folders (folderPath, addedAt) VALUES (?1, ?2);")
	if !ok {
		return false
	}
	defer stmt_finalize(stmt)
	bind_text(stmt, 1, path)
	bind_i64(stmt, 2, now_ms())
	if !stmt_finish(stmt) {
		return false // already present (PK) or a real error; both read as "not added"
	}
	bump_generation()
	return true
}

// Row sets that cross the inbox are [dynamic], not slices: a slice
// cannot be deleted back to its backing array, so the old slice
// shape leaked the array itself on every overwrite (5,000 song rows
// is ~500KB of backing alone). The frame thread owns a set once it
// lands and frees it with free_*_rows below — never the worker.
folders_list :: proc(db: Db) -> [dynamic]Folder {
	stmt, ok := stmt_prepare(db, "SELECT folderPath, addedAt FROM Folders ORDER BY addedAt;")
	if !ok {
		return nil
	}
	defer stmt_finalize(stmt)
	out: [dynamic]Folder
	for stmt_step(stmt) {
		append(&out, Folder{path = col_text(stmt, 0), added_at = col_i64(stmt, 1)})
	}
	return out
}

// ---- collections -------------------------------------------------------------------

scan_collection :: proc(stmt: Stmt) -> Collection_Row {
	return Collection_Row{
		uuid = col_text(stmt, 0),
		type = Collection_Type(col_i64(stmt, 1)),
		name = col_text(stmt, 2),
		added_at = col_i64(stmt, 3),
		last_opened = col_i64(stmt, 4),
		has_thumbnail = col_i64(stmt, 5) != 0,
	}
}

// A collection's display art: its own thumbnail when set (playlists
// carry one — GOOber in the real library is the only collection that
// does), else the large thumbnail of its first song by position —
// every song in the real library carries one. Resolved in SQL so
// cards and the collection header agree (D1).
RESOLVED_THUMB :: "COALESCE(thumbnail, (SELECT s2.largeThumbnail FROM CollectionSongs cs2 JOIN Songs s2 ON s2.uuid = cs2.songUuid_fk WHERE cs2.collectionUuid_fk = Collections.uuid ORDER BY cs2.position LIMIT 1))"

COLLECTION_COLS :: "uuid, typeEnum, name, addedAt, lastOpened, (" + RESOLVED_THUMB + " IS NOT NULL)"

collections_run :: proc(db: Db, sql: string, limit: int) -> []Collection_Row {
	stmt, ok := stmt_prepare(db, sql)
	if !ok {
		return nil
	}
	defer stmt_finalize(stmt)
	bind_i64(stmt, 1, i64(limit))
	out: [dynamic]Collection_Row
	for stmt_step(stmt) {
		append(&out, scan_collection(stmt))
	}
	return out[:]
}

collections_all :: proc(db: Db, limit: int) -> []Collection_Row {
	return collections_run(db, "SELECT " + COLLECTION_COLS + " FROM Collections ORDER BY name LIMIT ?1;", limit)
}

collections_recent :: proc(db: Db, limit: int) -> []Collection_Row {
	return collections_run(db, "SELECT " + COLLECTION_COLS + " FROM Collections ORDER BY lastOpened DESC LIMIT ?1;", limit)
}

collections_by_type :: proc(db: Db, type: Collection_Type, limit: int) -> []Collection_Row {
	stmt, ok := stmt_prepare(db, "SELECT " + COLLECTION_COLS + " FROM Collections WHERE typeEnum = ?1 ORDER BY name LIMIT ?2;")
	if !ok {
		return nil
	}
	defer stmt_finalize(stmt)
	bind_i64(stmt, 1, i64(type))
	bind_i64(stmt, 2, i64(limit))
	out: [dynamic]Collection_Row
	for stmt_step(stmt) {
		append(&out, scan_collection(stmt))
	}
	return out[:]
}

collection_touch_opened :: proc(db: Db, uuid: string) {
	stmt, ok := stmt_prepare(db, "UPDATE Collections SET lastOpened = ?1 WHERE uuid = ?2;")
	if !ok {
		return
	}
	defer stmt_finalize(stmt)
	bind_i64(stmt, 1, now_ms())
	bind_text(stmt, 2, uuid)
	if stmt_finish(stmt) {
		bump_generation()
	}
}

// ---- songs ---------------------------------------------------------------------------

songs_from_collection :: proc(db: Db, collection_uuid: string) -> [dynamic]Song_Row {
	stmt, ok := stmt_prepare(db, `
		SELECT s.uuid, s.title, s.artists, s.location, s.fileName, s.duration, s.sizeInBytes, cs.position
		FROM CollectionSongs cs JOIN Songs s ON s.uuid = cs.songUuid_fk
		WHERE cs.collectionUuid_fk = ?1
		ORDER BY cs.position, s.title;`)
	if !ok {
		return nil
	}
	defer stmt_finalize(stmt)
	bind_text(stmt, 1, collection_uuid)
	out: [dynamic]Song_Row
	for stmt_step(stmt) {
		append(&out, Song_Row{
			uuid = col_text(stmt, 0),
			title = col_text(stmt, 1),
			artists = col_text(stmt, 2),
			location = col_text(stmt, 3),
			file_name = col_text(stmt, 4),
			duration = col_i64(stmt, 5),
			size = col_i64(stmt, 6),
			position = col_i64(stmt, 7),
		})
	}
	return out
}

// A token search, D1-style: the query IS the search. The term is
// lowercased by the caller side here and matched against the stored
// token JSON.
songs_search :: proc(db: Db, term: string, limit: int) -> []Song_Row {
	stmt, ok := stmt_prepare(db, `
		SELECT uuid, title, artists, location, fileName, duration, sizeInBytes, 0
		FROM Songs
		WHERE searchTokens LIKE ?1
		ORDER BY title LIMIT ?2;`)
	if !ok {
		return nil
	}
	defer stmt_finalize(stmt)
	needle := fmt.tprintf("%%\"%s\"%%", strings.to_lower(term))
	bind_text(stmt, 1, needle)
	bind_i64(stmt, 2, i64(limit))
	out: [dynamic]Song_Row
	for stmt_step(stmt) {
		append(&out, Song_Row{
			uuid = col_text(stmt, 0),
			title = col_text(stmt, 1),
			artists = col_text(stmt, 2),
			location = col_text(stmt, 3),
			file_name = col_text(stmt, 4),
			duration = col_i64(stmt, 5),
			size = col_i64(stmt, 6),
		})
	}
	return out[:]
}

library_counts :: proc(db: Db) -> (folders: int, collections: int, songs: int) {
	count := proc(db: Db, table: string) -> int {
		stmt, ok := stmt_prepare(db, fmt.tprintf("SELECT COUNT(*) FROM %s;", table))
		if !ok {
			return 0
		}
		defer stmt_finalize(stmt)
		if stmt_step(stmt) {
			return int(col_i64(stmt, 0))
		}
		return 0
	}
	return count(db, "Folders"), count(db, "Collections"), count(db, "Songs")
}

// ---- the V1 importer -----------------------------------------------------------------

Import_Result :: struct {
	folders:     int,
	collections: int,
	songs:       int,
	styles:      int,
	tags:        int,
	song_tags:   int,
}

// .NET Guid byte layout is mixed-endian: Data1/2/3 are little-endian
// fields, the rest sequential. Canonical text form undoes that.
dotnet_guid_string :: proc(b: []u8) -> string {
	if len(b) != 16 {
		return ""
	}
	d1 := u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
	d2 := u16(b[4]) | u16(b[5]) << 8
	d3 := u16(b[6]) | u16(b[7]) << 8
	return fmt.tprintf("%08x-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x",
		d1, d2, d3, b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
}

// Reads a 16-byte GUID BLOB column and converts it (the clone is
// freed here — callers keep only the string).
col_guid :: proc(stmt: Stmt, idx: int) -> string {
	raw := col_blob_clone(stmt, idx)
	bytes, _ := raw.?
	defer delete(bytes)
	return dotnet_guid_string(bytes)
}

// .NET DateTime.ToBinary(): ticks (100 ns since 0001-01-01) in the
// low 62 bits, kind flags above. → Unix milliseconds.
tobinary_to_ms :: proc(raw: i64) -> i64 {
	ticks := raw & ((i64(1) << 62) - 1)
	return (ticks - 621355968000000000) / 10000
}

import_v1 :: proc(dst: Db, v1_path: string) -> (Import_Result, bool) {
	res: Import_Result
	src, ok := db_open_readonly(v1_path)
	if !ok {
		return res, false
	}
	defer db_close(src)

	if !db_exec(dst, "BEGIN;") {
		return res, false
	}
	rollback := true
	defer if rollback {
		db_exec(dst, "ROLLBACK;")
	}

	// Styles first (Tags reference them).
	{
		rd, rok := stmt_prepare(src, "SELECT uuid, name, color, createdAt FROM Styles;")
		if !rok {
			return res, false
		}
		defer stmt_finalize(rd)
		wr, wok := stmt_prepare(dst, "INSERT INTO Styles (uuid, name, color, createdAt) VALUES (?1, ?2, ?3, ?4);")
		if !wok {
			return res, false
		}
		defer stmt_finalize(wr)
		for stmt_step(rd) {
			id := col_guid(rd, 0)
			bind_text(wr, 1, id)
			bind_text(wr, 2, col_text(rd, 1))
			bind_i64(wr, 3, col_i64(rd, 2))
			bind_i64(wr, 4, tobinary_to_ms(col_i64(rd, 3)))
			if !stmt_finish(wr) {
				return res, false
			}
			sqlite3_reset(wr)
			res.styles += 1
		}
	}

	// Collections (Songs + CollectionSongs reference them).
	{
		rd, rok := stmt_prepare(src, "SELECT uuid, typeEnum, name, description, createdAt, coverArt FROM Collections;")
		if !rok {
			return res, false
		}
		defer stmt_finalize(rd)
		wr, wok := stmt_prepare(dst, "INSERT INTO Collections (uuid, typeEnum, name, searchTokens, description, addedAt, lastOpened, thumbnail) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);")
		if !wok {
			return res, false
		}
		defer stmt_finalize(wr)
		for stmt_step(rd) {
			id := col_guid(rd, 0)
			name := col_text(rd, 2)
			added := tobinary_to_ms(col_i64(rd, 4))
			bind_text(wr, 1, id)
			bind_i64(wr, 2, col_i64(rd, 1))
			bind_text(wr, 3, name)
			bind_text(wr, 4, make_search_tokens(name, nil))
			bind_text(wr, 5, col_text(rd, 3))
			bind_i64(wr, 6, added)
			bind_i64(wr, 7, added) // lastOpened seeds at addedAt; V1 kept recency in memory only
			thumb := col_blob_clone(rd, 5)
			bind_blob_or_null(wr, 8, thumb)
			fin := stmt_finish(wr)
			if b, ok := thumb.?; ok {
				delete(b)
			}
			if !fin {
				return res, false
			}
			sqlite3_reset(wr)
			res.collections += 1
		}
	}

	// Folders.
	{
		rd, rok := stmt_prepare(src, "SELECT folderPath, addedAt FROM Folders;")
		if !rok {
			return res, false
		}
		defer stmt_finalize(rd)
		wr, wok := stmt_prepare(dst, "INSERT INTO Folders (folderPath, addedAt) VALUES (?1, ?2);")
		if !wok {
			return res, false
		}
		defer stmt_finalize(wr)
		for stmt_step(rd) {
			bind_text(wr, 1, col_text(rd, 0))
			bind_i64(wr, 2, tobinary_to_ms(col_i64(rd, 1)))
			if !stmt_finish(wr) {
				return res, false
			}
			sqlite3_reset(wr)
			res.folders += 1
		}
	}

	// Songs (+ their parent CollectionSongs row).
	{
		rd, rok := stmt_prepare(src, `SELECT uuid, location, fileName, title, artist, addedAt, createdAt,
			parentCollection_fk, sizeInBytes, duration, parentCollectionPosition,
			lastPlayedAt, playCount, playSeconds, completedPlayCount, skipCount, earlySkipCount,
			accentColor, backgroundColor, isMissing, coverArt, isCoverArtManuallySet,
			smallThumbnail, largeThumbnail FROM Songs;`)
		if !rok {
			return res, false
		}
		defer stmt_finalize(rd)
		wr, wok := stmt_prepare(dst, `INSERT INTO Songs (uuid, location, addedAt, createdAt, title, searchTokens, artists,
			parentCollection_fk, triHash, musicbrainzId, fileName, sizeInBytes, duration,
			lastPlayedAt, playCount, playSeconds, completedPlayCount, skipCount, earlySkipCount,
			isMissing, accentColor, backgroundColor, coverArt, isCoverArtManuallySet,
			smallThumbnail, largeThumbnail)
			VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, '', NULL, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24);`)
		if !wok {
			return res, false
		}
		defer stmt_finalize(wr)
		link, lok := stmt_prepare(dst, "INSERT INTO CollectionSongs (collectionUuid_fk, songUuid_fk, position) VALUES (?1, ?2, ?3);")
		if !lok {
			return res, false
		}
		defer stmt_finalize(link)
		for stmt_step(rd) {
			id := col_guid(rd, 0)
			title := col_text(rd, 3)
			artist_raw := col_text(rd, 4)
			artists: []string
			if strings.trim_space(artist_raw) != "" {
				artists = strings.split(artist_raw, "~;~")
			}
			parent := col_guid(rd, 7)
			bind_text(wr, 1, id)
			bind_text(wr, 2, col_text(rd, 1)) // location
			bind_i64(wr, 3, tobinary_to_ms(col_i64(rd, 5)))
			bind_i64(wr, 4, tobinary_to_ms(col_i64(rd, 6)))
			bind_text(wr, 5, title)
			bind_text(wr, 6, make_search_tokens(title, artists))
			bind_text(wr, 7, json_string_array(artists))
			bind_text(wr, 8, parent)
			bind_text(wr, 9, col_text(rd, 2)) // fileName
			bind_i64(wr, 10, col_i64(rd, 8)) // sizeInBytes
			bind_i64(wr, 11, col_i64(rd, 9)) // duration
			bind_i64(wr, 12, tobinary_to_ms(col_i64(rd, 11)))
			bind_i64(wr, 13, col_i64(rd, 12))
			bind_i64(wr, 14, col_i64(rd, 13))
			bind_i64(wr, 15, col_i64(rd, 14))
			bind_i64(wr, 16, col_i64(rd, 15))
			bind_i64(wr, 17, col_i64(rd, 16))
			bind_i64(wr, 18, col_i64(rd, 19)) // isMissing
			bind_i64_or_null(wr, 19, col_i64_or_none(rd, 17)) // accentColor
			bind_i64_or_null(wr, 20, col_i64_or_none(rd, 18)) // backgroundColor
			bind_text_or_null(wr, 21, col_text_or_none(rd, 20))
			bind_i64(wr, 22, col_i64(rd, 21))
			small_thumb := col_blob_clone(rd, 22)
			large_thumb := col_blob_clone(rd, 23)
			bind_blob_or_null(wr, 23, small_thumb)
			bind_blob_or_null(wr, 24, large_thumb)
			if artists != nil {
				delete(artists)
			}
			fin := stmt_finish(wr)
			if b, ok := small_thumb.?; ok {
				delete(b)
			}
			if b, ok := large_thumb.?; ok {
				delete(b)
			}
			if !fin {
				return res, false
			}
			sqlite3_reset(wr)
			bind_text(link, 1, parent)
			bind_text(link, 2, id)
			bind_i64(link, 3, col_i64(rd, 10))
			if !stmt_finish(link) {
				return res, false
			}
			sqlite3_reset(link)
			res.songs += 1
		}
	}

	// CollectionSongs (playlists etc. — parent rows already written above
	// may collide with a V1 row for the same triple; OR IGNORE keeps both
	// sources consistent).
	{
		rd, rok := stmt_prepare(src, "SELECT collectionUuid_fk, songUuid_fk, position FROM CollectionSongs;")
		if !rok {
			return res, false
		}
		defer stmt_finalize(rd)
		wr, wok := stmt_prepare(dst, "INSERT OR IGNORE INTO CollectionSongs (collectionUuid_fk, songUuid_fk, position) VALUES (?1, ?2, ?3);")
		if !wok {
			return res, false
		}
		defer stmt_finalize(wr)
		for stmt_step(rd) {
			bind_text(wr, 1, col_guid(rd, 0))
			bind_text(wr, 2, col_guid(rd, 1))
			bind_i64(wr, 3, col_i64(rd, 2))
			if !stmt_finish(wr) {
				return res, false
			}
			sqlite3_reset(wr)
		}
	}

	// Tags + SongTags.
	{
		rd, rok := stmt_prepare(src, "SELECT uuid, name, createdAt, style_fk, color_fk FROM Tags;")
		if !rok {
			return res, false
		}
		defer stmt_finalize(rd)
		wr, wok := stmt_prepare(dst, "INSERT INTO Tags (uuid, name, createdAt, style_fk, color_fk) VALUES (?1, ?2, ?3, ?4, ?5);")
		if !wok {
			return res, false
		}
		defer stmt_finalize(wr)
		for stmt_step(rd) {
			bind_text(wr, 1, col_guid(rd, 0))
			bind_text(wr, 2, col_text(rd, 1))
			bind_i64(wr, 3, tobinary_to_ms(col_i64(rd, 2)))
			bind_text(wr, 4, col_guid(rd, 3))
			bind_i64(wr, 5, col_i64(rd, 4))
			if !stmt_finish(wr) {
				return res, false
			}
			sqlite3_reset(wr)
			res.tags += 1
		}
	}
	{
		rd, rok := stmt_prepare(src, "SELECT songUuid_fk, tagUuid_fk FROM SongTags;")
		if !rok {
			return res, false
		}
		defer stmt_finalize(rd)
		wr, wok := stmt_prepare(dst, "INSERT INTO SongTags (songUuid_fk, tagUuid_fk) VALUES (?1, ?2);")
		if !wok {
			return res, false
		}
		defer stmt_finalize(wr)
		for stmt_step(rd) {
			bind_text(wr, 1, col_guid(rd, 0))
			bind_text(wr, 2, col_guid(rd, 1))
			if !stmt_finish(wr) {
				return res, false
			}
			sqlite3_reset(wr)
			res.song_tags += 1
		}
	}

	if !db_exec(dst, "COMMIT;") {
		return res, false
	}
	rollback = false
	bump_generation()
	return res, true
}

// ---- startup loading through the inbox ----------------------------------------------

// The library worker: one thread, one connection, a job queue. The
// frame thread posts jobs; results land through the one inbox (the
// messages below). Declare never touches SQL (D1).

Msg :: union {
	Library_Loaded,
	Collections_Page,
	Collection_Songs,
	Track_Ended,
	Playback_Restarted,
}

// Audio backend events (step 4). gen is the player's generation at
// send time; the drain drops events whose gen no longer matches —
// the wall clock usually advances first, so a late EOF/restart for
// the old track must not move the new one.
Track_Ended :: struct {
	gen: u64,
}

Playback_Restarted :: struct {
	gen: u64,
}

Library_Loaded :: struct {
	folders:          [dynamic]Folder,
	folder_count:     int,
	collection_count: int,
	song_count:       int,
	imported:         bool,
	import_songs:     int,
	failed:           string,
}

Collections_Page :: struct {
	query: Lib_Query,
	gen:   u64, // data_generation at fetch time
	total: int,
	rows:  [dynamic]Collection_Row,
}

Collection_Songs :: struct {
	collection: Collection_Row,
	rows:       [dynamic]Song_Row,
}

Job :: union {
	Job_Load,
	Job_Collections,
	Job_Songs,
	Job_Quit,
}

Job_Load :: struct {}

Job_Collections :: struct {
	query: Lib_Query,
}

Job_Songs :: struct {
	collection_uuid: string,
}

Job_Quit :: struct {}

box: inbox.Inbox(Msg)
box_ready: bool
load_thread: ^thread.Thread
load_dir: string

jobs: [dynamic]Job
jobs_mu: sync.Mutex
jobs_sema: sync.Sema

post_job :: proc(j: Job) {
	sync.lock(&jobs_mu)
	append(&jobs, j)
	sync.unlock(&jobs_mu)
	sync.sema_post(&jobs_sema)
}

pop_job :: proc() -> Job {
	sync.sema_wait(&jobs_sema)
	sync.lock(&jobs_mu)
	j := jobs[0]
	ordered_remove(&jobs, 0)
	sync.unlock(&jobs_mu)
	return j
}

request_collections :: proc(q: Lib_Query) {
	post_job(Job_Collections{query = q})
}

// The queued job OWNS its uuid: request_songs clones it, and the
// worker deletes it after the songs case runs. The clone is what
// makes freeing lib_rows safe — the old code passed the row's own
// uuid string into the queue, so freeing the page while the job was
// still queued would have left the worker holding a freed string.
request_songs :: proc(collection_uuid: string) {
	post_job(Job_Songs{collection_uuid = strings.clone(collection_uuid)})
}

start_library_load :: proc(ctx: ^niello.Context, dir: string) {
	load_dir = dir
	// Session scratch is (re)made here, under the caller's context:
	// a dynamic array's header carries its allocator, and letting one
	// outlive a stop would leave the next start appending through a
	// stale allocator (the headless suite starts/stops per test).
	jobs = make([dynamic]Job)
	drain_scratch = make([dynamic]Msg)
	page_thumbs = make(map[string]niello.Image)
	box = inbox.create(Msg, ctx)
	box_ready = true
	// The worker MUST run under the caller's context, not the default
	// one: row ownership crosses threads (the worker allocates row
	// strings/blobs, the frame thread frees them, and vice versa for
	// the queued job uuid), and an allocation freed under a different
	// allocator than it was made under is corruption, not a leak.
	// The default thread context is the heap; the headless suite's
	// thread context is a tracking allocator over a rollback arena,
	// and freeing an arena pointer with the heap allocator hung the
	// flow test after the first songs job (no crash, just a worker
	// that never made progress again). With the caller's context,
	// both sides share one allocator — heap in the app, the test
	// tracker in the suite, where the frees then show up as tracked
	// instead of bad frees. Temp stays safe: _select_context_for_thread
	// swaps a default temp allocator to the global one for the child.
	load_thread = thread.create_and_start_with_data(nil, lib_worker, context)
	post_job(Job_Load{})
}

stop_library :: proc() {
	if load_thread != nil {
		post_job(Job_Quit{})
		thread.join(load_thread)
		thread.destroy(load_thread)
		load_thread = nil
	}
	if box_ready {
		inbox.destroy(&box)
		box_ready = false
	}
}

lib_worker :: proc(_: rawptr) {
	// Both are no-ops when profiling is off — and they must sit at
	// proc top level, NOT inside an if block: a defer inside a block
	// runs at the end of that block, which would flush the worker's
	// buffer right after the name event and silence every job event.
	prof_init_thread("library")
	defer prof_shutdown_thread()
	db_path := fmt.tprintf("%s/Nachtul.db", load_dir)
	v1_path := fmt.tprintf("%s/NachtulV1.db", load_dir)
	fresh := !os.exists(db_path)
	db, ok := db_open(db_path)
	if !ok {
		inbox.send(&box, Library_Loaded{failed = "Could not open Nachtul.db"})
		return
	}
	defer db_close(db)
	db_create_schema(db)
	imported := false
	import_songs := 0
	if fresh && os.exists(v1_path) {
		prof_begin("import_v1")
		res, iok := import_v1(db, v1_path)
		prof_end()
		if iok {
			imported = true
			import_songs = res.songs
		}
	}

	for {
		job := pop_job()
		switch j in job {
		case Job_Load:
			{
				prof_begin("library_load")
				msg: Library_Loaded
				msg.folders = folders_list(db)
				msg.folder_count, msg.collection_count, msg.song_count = library_counts(db)
				msg.imported = imported
				msg.import_songs = import_songs
				inbox.send(&box, msg)
				prof_end()
			}
		case Job_Collections:
			{
				prof_begin("collections_page")
				rows, total := collections_page(db, j.query)
				inbox.send(&box, Collections_Page{query = j.query, gen = data_generation, total = total, rows = rows})
				prof_end()
			}
		case Job_Songs:
			{
				prof_begin("songs_from_collection")
				collection_touch_opened(db, j.collection_uuid)
				row, found := collection_by_uuid(db, j.collection_uuid)
				if found {
					inbox.send(&box, Collection_Songs{collection = row, rows = songs_from_collection(db, j.collection_uuid)})
				}
				prof_end()
			}
			// The job's uuid is a clone owned by the queue (see
			// request_songs); it dies here, after its last use.
			delete(j.collection_uuid)
		case Job_Quit:
			return
		}
	}
}

collection_by_uuid :: proc(db: Db, uuid: string) -> (Collection_Row, bool) {
	stmt, ok := stmt_prepare(db, "SELECT " + COLLECTION_COLS + ", " + RESOLVED_THUMB + " FROM Collections WHERE uuid = ?1;")
	if !ok {
		return {}, false
	}
	defer stmt_finalize(stmt)
	bind_text(stmt, 1, uuid)
	if !stmt_step(stmt) {
		return {}, false
	}
	row := scan_collection(stmt)
	row.thumbnail = col_blob_clone(stmt, 6)
	return row, true
}

// ---- page queries ---------------------------------------------------------------------

Lib_Sort :: enum {
	None, // the section's own order
	Name,
	Date_Added,
	Recent,
	Size,
	Duration,
	Tag_Count,
}

Lib_Query :: struct {
	section:   Section,
	search:    string,
	sort:      Lib_Sort,
	page:      int,
	page_size: int,
}

// One page of collections for a query, thumbnails included, plus the
// total match count. Sorting by Size/Duration/Tag_Count/Popular is
// aggregate SQL over CollectionSongs — the query IS the feature (D1).
collections_page :: proc(db: Db, q: Lib_Query) -> ([dynamic]Collection_Row, int) {
	cond := strings.builder_make()
	defer strings.builder_destroy(&cond)
	strings.write_string(&cond, " WHERE 1 = 1")
	#partial switch q.section {
	case .Taglists:
		strings.write_string(&cond, " AND c.typeEnum = 6")
	case .Playlists:
		strings.write_string(&cond, " AND c.typeEnum = 5")
	case .Artists:
		strings.write_string(&cond, " AND c.typeEnum = 0")
	case .Albums:
		strings.write_string(&cond, " AND c.typeEnum = 1")
	case .EPs:
		strings.write_string(&cond, " AND c.typeEnum = 2")
	case .Singles:
		strings.write_string(&cond, " AND c.typeEnum = 3")
	case .Collections:
		strings.write_string(&cond, " AND c.typeEnum IN (1, 2, 3, 4)")
	case .Uncategorized:
		strings.write_string(&cond, " AND c.typeEnum = 7")
	case .Recent:
		strings.write_string(&cond, " AND c.lastOpened > 0")
	}
	search := strings.trim_space(q.search)
	if search != "" {
		terms := strings.split(strings.to_lower(search), " ")
		defer delete(terms)
		for term in terms {
			clean := strings.trim(term, "\"%_")
			if clean == "" {
				continue
			}
			fmt.sbprintf(&cond, " AND c.searchTokens LIKE '%%\"%s\"%%'", clean)
		}
	}
	where_sql := strings.to_string(cond)

	order: string
	switch q.sort {
	case .None:
		switch q.section {
		case .Recent:
			order = "c.lastOpened DESC"
		case .Popular:
			order = "agg.tplays DESC, c.name"
		case .All, .Taglists, .Playlists, .Artists, .Albums, .EPs, .Singles, .Collections, .Uncategorized:
			order = "c.name"
		}
	case .Name:
		order = "c.name"
	case .Date_Added:
		order = "c.addedAt DESC"
	case .Recent:
		order = "c.lastOpened DESC"
	case .Size:
		order = "agg.tsize DESC, c.name"
	case .Duration:
		order = "agg.tdur DESC, c.name"
	case .Tag_Count:
		order = "agg.ttags DESC, c.name"
	}

	count_sql := fmt.tprintf("SELECT COUNT(*) FROM Collections c%s;", where_sql)
	total := 0
	if stmt, ok := stmt_prepare(db, count_sql); ok {
		defer stmt_finalize(stmt)
		if stmt_step(stmt) {
			total = int(col_i64(stmt, 0))
		}
	}

	page_sql := fmt.tprintf(`
		SELECT c.uuid, c.typeEnum, c.name, c.addedAt, c.lastOpened, (COALESCE(c.thumbnail, (SELECT s2.largeThumbnail FROM CollectionSongs cs2 JOIN Songs s2 ON s2.uuid = cs2.songUuid_fk WHERE cs2.collectionUuid_fk = c.uuid ORDER BY cs2.position LIMIT 1)) IS NOT NULL), COALESCE(c.thumbnail, (SELECT s2.largeThumbnail FROM CollectionSongs cs2 JOIN Songs s2 ON s2.uuid = cs2.songUuid_fk WHERE cs2.collectionUuid_fk = c.uuid ORDER BY cs2.position LIMIT 1))
		FROM Collections c
		LEFT JOIN (
			SELECT cs.collectionUuid_fk AS cid,
			       SUM(s.sizeInBytes) AS tsize,
			       SUM(s.duration) AS tdur,
			       SUM(s.playCount) AS tplays,
			       (SELECT COUNT(*) FROM SongTags st JOIN CollectionSongs cs2
			        ON cs2.songUuid_fk = st.songUuid_fk
			        WHERE cs2.collectionUuid_fk = cs.collectionUuid_fk) AS ttags
			FROM CollectionSongs cs JOIN Songs s ON s.uuid = cs.songUuid_fk
			GROUP BY cs.collectionUuid_fk
		) agg ON agg.cid = c.uuid
		%s ORDER BY %s LIMIT ?1 OFFSET ?2;`, where_sql, order)
	stmt, ok := stmt_prepare(db, page_sql)
	if !ok {
		return nil, total
	}
	defer stmt_finalize(stmt)
	bind_i64(stmt, 1, i64(q.page_size))
	bind_i64(stmt, 2, i64(q.page * q.page_size))
	out: [dynamic]Collection_Row
	for stmt_step(stmt) {
		row := scan_collection(stmt)
		row.thumbnail = col_blob_clone(stmt, 6)
		append(&out, row)
	}
	return out, total
}

// ---- apply (frame thread) --------------------------------------------------------------

drain_scratch: [dynamic]Msg

// Decoded thumbnails for the current page only — bounded by the page
// size, released wholesale when the page changes (D1's cache, kept
// deliberately small).
page_thumbs: map[string]niello.Image

// Row ownership, fixed 2026-10-24: every row set that crosses the
// inbox is heap-owned (col_text clones every string, col_blob_clone
// copies every thumbnail blob), and the frame thread owns it once it
// lands. The old code overwrote app.lib_rows / app.open_songs and
// dropped stale pages without freeing anything, so every page turn,
// search keystroke and collection open/close leaked a page of strings
// plus a page of ~9KB thumbnail blobs. The free_* helpers below are
// the only way a landed set dies: before an overwrite, on a stale
// drop, and in close_collection. String deletes are guarded on len:
// an empty string may be a literal, and deleting a literal is not a
// free at all.
// A single row (open_row) has owned fields but no backing array, so
// free_collection_row frees the fields and zeroes the row; the
// plural helpers free every row's fields, then the backing array.
// Freeing a set is only safe because nothing else borrows it by
// then: open_uuid and selected_song are clones (see app.odin), the
// thumb map is released first (its keys borrow row uuids), and a
// queued Job_Songs carries a cloned uuid (see request_songs).
free_collection_row :: proc(row: ^Collection_Row) {
    if len(row.uuid) > 0 {
        delete(row.uuid)
    }
    if len(row.name) > 0 {
        delete(row.name)
    }
    if thumb, ok := row.thumbnail.?; ok && len(thumb) > 0 {
        delete(thumb)
    }
    row^ = Collection_Row{}
}

free_collection_rows :: proc(rows: [dynamic]Collection_Row) {
    if rows == nil {
        return
    }
    for &row in rows {
        free_collection_row(&row)
    }
    delete(rows)
}

free_song_rows :: proc(rows: [dynamic]Song_Row) {
    if rows == nil {
        return
    }
    for &row in rows {
        if len(row.uuid) > 0 {
            delete(row.uuid)
        }
        if len(row.title) > 0 {
            delete(row.title)
        }
        if len(row.artists) > 0 {
            delete(row.artists)
        }
        if len(row.location) > 0 {
            delete(row.location)
        }
        if len(row.file_name) > 0 {
            delete(row.file_name)
        }
    }
    delete(rows)
}

free_folders :: proc(folders: [dynamic]Folder) {
    if folders == nil {
        return
    }
    for &f in folders {
        if len(f.path) > 0 {
            delete(f.path)
        }
    }
    delete(folders)
}

release_page_thumbs :: proc() {
	for _, img in page_thumbs {
		niello.image_release(img)
	}
	clear(&page_thumbs)
}

apply_page_thumbs :: proc(rows: [dynamic]Collection_Row) {
	prof_begin("apply_page_thumbs")
	defer prof_end()
	for &row in rows {
		if thumb, ok := row.thumbnail.?; ok {
			if img, iok := niello.image_load_memory(thumb, 168, 168); iok {
				page_thumbs[row.uuid] = img
			}
		}
	}
}

// Called at the top of declare. Applies whatever producers sent —
// the app's one drain point.
drain_library_msgs :: proc() {
	if !box_ready {
		return
	}
	inbox.drain(&box, &drain_scratch)
	for msg in drain_scratch {
		switch m in msg {
		case Library_Loaded:
			free_folders(app.folders)
			app.folders = m.folders
			app.folder_count = m.folder_count
			app.collection_count = m.collection_count
			app.song_count = m.song_count
			app.loaded = true
			if m.failed != "" {
				app.sync_status = m.failed
			} else if m.imported {
				app.sync_status = fmt.tprintf("Imported %d songs from NachtulV1.db", m.import_songs)
			}
		case Collections_Page:
		// Stale pages (an older query's answer landing late) drop:
		// only the page we last asked for, at the current data
		// generation, applies.
			if m.query == app.lib_query && m.gen == app.lib_sent_gen {
				release_page_thumbs()
				free_collection_rows(app.lib_rows)
				app.lib_rows = m.rows
				app.lib_total = m.total
				app.lib_loaded = true
				apply_page_thumbs(m.rows)
			} else {
				free_collection_rows(m.rows)
			}
		case Collection_Songs:
			if m.collection.uuid == app.open_uuid {
				free_song_rows(app.open_songs)
				free_collection_row(&app.open_row)
				app.open_row = m.collection
				app.open_songs = m.rows
				app.open_loaded = true
				if img, ok := page_thumbs[m.collection.uuid]; ok {
					app.open_art = img
				} else if thumb, tok := m.collection.thumbnail.?; tok {
					if img, iok := niello.image_load_memory(thumb, 280, 280); iok {
						app.open_art = img
						app.open_art_owned = true
					}
				}
			} else {
				col := m.collection
				free_collection_row(&col)
				free_song_rows(m.rows)
			}
		case Track_Ended:
			player_on_track_ended(&player, m.gen)
		case Playback_Restarted:
			player_on_restart(&player, m.gen)
		}
	}
	clear(&drain_scratch)
}
