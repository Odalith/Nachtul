// Data-layer tests: schema, queries, search tokens, the V1 importer,
// and the app-level load flow. Real SQLite, throwaway files in /tmp.
package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import niello "../../NielloUI/niello"
import nachtul "../src"

fresh_db :: proc(name: string) -> (nachtul.Db, string) {
	path := fmt.tprintf("/tmp/%s.db", name)
	os.remove(path)
	os.remove(fmt.tprintf("%s-wal", path))
	os.remove(fmt.tprintf("%s-shm", path))
	db, ok := nachtul.db_open(path)
	if !ok {
		return nil, path
	}
	nachtul.db_create_schema(db)
	return db, path
}

exec :: proc(db: nachtul.Db, sql: string) {
	nachtul.db_exec(db, sql)
}

@(test)
test_schema_create_reopen :: proc(t: ^testing.T) {
	db, path := fresh_db("nachtul_t_schema")
	testing.expect(t, db != nil, "db opens")
	testing.expect(t, nachtul.db_migration_version(db) == 1, "migration version is 1")
	f, c, s := nachtul.library_counts(db)
	testing.expect(t, f == 0 && c == 0 && s == 0, "empty library counts")
	nachtul.db_close(db)

	db2, ok := nachtul.db_open(path)
	testing.expect(t, ok, "db reopens")
	testing.expect(t, nachtul.db_create_schema(db2), "schema create is idempotent")
	testing.expect(t, nachtul.db_migration_version(db2) == 1, "version survives reopen")
	nachtul.db_close(db2)
}

@(test)
test_folders_add_list :: proc(t: ^testing.T) {
	db, _ := fresh_db("nachtul_t_folders")
	defer nachtul.db_close(db)
	testing.expect(t, nachtul.folder_add(db, "/music/rock"), "first folder adds")
	testing.expect(t, nachtul.folder_add(db, "/music/jazz"), "second folder adds")
	testing.expect(t, !nachtul.folder_add(db, "/music/rock"), "duplicate folder does not add")
	folders := nachtul.folders_list(db)
	testing.expect(t, len(folders) == 2, "two folders listed")
	found := 0
	for f in folders {
		if f.path == "/music/rock" || f.path == "/music/jazz" {
			found += 1
		}
	}
	testing.expect(t, found == 2, "listed paths match")
}

seed_library :: proc(db: nachtul.Db) {
	exec(db, `INSERT INTO Collections (uuid, typeEnum, name, searchTokens, description, addedAt, lastOpened, thumbnail)
		VALUES ('c-artist', 0, 'The Testers', '["the","testers"]', '', 100, 100, NULL);`)
	exec(db, `INSERT INTO Collections (uuid, typeEnum, name, searchTokens, description, addedAt, lastOpened, thumbnail)
		VALUES ('c-album', 7, 'Debut', '["debut"]', '', 200, 200, NULL);`)
	exec(db, `INSERT INTO Collections (uuid, typeEnum, name, searchTokens, description, addedAt, lastOpened, thumbnail)
		VALUES ('c-list', 5, 'Faves', '["faves"]', '', 300, 300, NULL);`)
	exec(db, `INSERT INTO Songs (uuid, location, addedAt, createdAt, title, searchTokens, artists, parentCollection_fk,
		triHash, fileName, sizeInBytes, duration, lastPlayedAt, playCount, playSeconds, completedPlayCount,
		skipCount, earlySkipCount, isMissing, isCoverArtManuallySet)
		VALUES ('s-2', '/music/b.flac', 1, 1, 'Beta Song', '["beta","song","bs"]', '["The Testers"]', 'c-album',
		'', 'b.flac', 2000, 180000, 0, 3, 0, 1, 0, 0, 0, 0);`)
	exec(db, `INSERT INTO Songs (uuid, location, addedAt, createdAt, title, searchTokens, artists, parentCollection_fk,
		triHash, fileName, sizeInBytes, duration, lastPlayedAt, playCount, playSeconds, completedPlayCount,
		skipCount, earlySkipCount, isMissing, isCoverArtManuallySet)
		VALUES ('s-1', '/music/a.flac', 1, 1, 'Alpha Song (Live)', '["alpha","song","alternate","as"]', '["The Testers"]', 'c-album',
		'', 'a.flac', 1000, 200000, 0, 9, 0, 4, 0, 0, 0, 0);`)
	exec(db, "INSERT INTO CollectionSongs (collectionUuid_fk, songUuid_fk, position) VALUES ('c-album', 's-2', 2);")
	exec(db, "INSERT INTO CollectionSongs (collectionUuid_fk, songUuid_fk, position) VALUES ('c-album', 's-1', 1);")
	exec(db, "INSERT INTO CollectionSongs (collectionUuid_fk, songUuid_fk, position) VALUES ('c-list', 's-1', 0);")
}

@(test)
test_collection_queries :: proc(t: ^testing.T) {
	db, _ := fresh_db("nachtul_t_queries")
	defer nachtul.db_close(db)
	seed_library(db)

	all := nachtul.collections_all(db, 40)
	testing.expect(t, len(all) == 3, "all collections listed")
	playlists := nachtul.collections_by_type(db, .Playlist, 40)
	testing.expect(t, len(playlists) == 1 && playlists[0].uuid == "c-list", "by-type filters")

	songs := nachtul.songs_from_collection(db, "c-album")
	testing.expect(t, len(songs) == 2, "album has two songs")
	testing.expect(t, songs[0].uuid == "s-1" && songs[1].uuid == "s-2", "songs ordered by position")

	// Recent: touching the album makes it the most recently opened.
	nachtul.collection_touch_opened(db, "c-album")
	recent := nachtul.collections_recent(db, 40)
	testing.expect(t, len(recent) == 3 && recent[0].uuid == "c-album", "touched collection leads Recent")

	f, c, s := nachtul.library_counts(db)
	testing.expect(t, f == 0 && c == 3 && s == 2, "counts")
}

@(test)
test_song_search_is_a_query :: proc(t: ^testing.T) {
	db, _ := fresh_db("nachtul_t_search")
	defer nachtul.db_close(db)
	seed_library(db)

	by_word := nachtul.songs_search(db, "beta", 40)
	testing.expect(t, len(by_word) == 1 && by_word[0].uuid == "s-2", "search by title token")
	by_initials := nachtul.songs_search(db, "bs", 40)
	testing.expect(t, len(by_initials) == 1 && by_initials[0].uuid == "s-2", "search by initials token")
	by_synonym := nachtul.songs_search(db, "alternate", 40)
	testing.expect(t, len(by_synonym) == 1 && by_synonym[0].uuid == "s-1", "search by synonym token (live)")
	none := nachtul.songs_search(db, "nonexistent", 40)
	testing.expect(t, len(none) == 0, "no false positives")
}

@(test)
test_search_tokens :: proc(t: ^testing.T) {
	toks := nachtul.make_search_tokens("The Beatles Song", {"The Beatles"})
	testing.expect(t, strings.contains(toks, "\"beatles\""), "article stripped + lowercased")
	testing.expect(t, !strings.contains(toks, "\"Beatles\""), "no leaked capitalization (the C++ bug, fixed)")
	testing.expect(t, strings.contains(toks, "\"bs\""), "title initials present")
	testing.expect(t, strings.contains(toks, "\"the beatles\""), "full artist token present")
	testing.expect(t, strings.contains(toks, "\"tb\""), "artist initials present")

	live := nachtul.make_search_tokens("Song (Live)", nil)
	testing.expect(t, strings.contains(live, "\"alternate\""), "live expands to synonyms")
	testing.expect(t, strings.contains(live, "\"live\""), "live itself kept")

	feat := nachtul.make_search_tokens("Track ft. Someone", nil)
	testing.expect(t, strings.contains(feat, "\"featuring\""), "ft. expands")
}

// ---- the V1 importer -------------------------------------------------------------

// .NET bytes for 00112233-4455-6677-8899-aabbccddeeff.
GUID_BYTES := []u8{0x33, 0x22, 0x11, 0x00, 0x55, 0x44, 0x77, 0x66, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff}
GUID_BYTES2 := []u8{0x44, 0x33, 0x22, 0x11, 0x66, 0x55, 0x88, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff}

tobinary :: proc(ms: i64) -> i64 {
	return ms * 10000 + 621355968000000000
}

make_v1_fixture :: proc(path: string) {
	os.remove(path)
	db, ok := nachtul.db_open(path)
	if !ok {
		return
	}
	defer nachtul.db_close(db)
	exec(db, "CREATE TABLE Folders (folderPath TEXT NOT NULL, addedAt INTEGER NOT NULL, PRIMARY KEY(folderPath)) WITHOUT ROWID;")
	exec(db, "CREATE TABLE Collections (uuid BLOB NOT NULL, typeEnum INTEGER NOT NULL, name TEXT NOT NULL, description TEXT NOT NULL, createdAt INTEGER NOT NULL, coverArt BLOB, totalSizeInBytes INTEGER NOT NULL, totalDuration INTEGER NOT NULL, manuallyTagged INTEGER NOT NULL, tagCount INTEGER NOT NULL, PRIMARY KEY(uuid), UNIQUE(typeEnum, name)) WITHOUT ROWID;")
	exec(db, "CREATE TABLE Songs (uuid BLOB NOT NULL, location TEXT NOT NULL, fileName TEXT NOT NULL, extension TEXT NOT NULL, title TEXT NOT NULL, artist TEXT NOT NULL, addedAt INTEGER NOT NULL, createdAt INTEGER NOT NULL, parentCollection_fk BLOB NOT NULL, sizeInBytes INTEGER NOT NULL, duration INTEGER NOT NULL, parentCollectionPosition INTEGER NOT NULL, lastPlayedAt INTEGER NOT NULL, playCount INTEGER NOT NULL, playSeconds INTEGER NOT NULL, completedPlayCount INTEGER NOT NULL, skipCount INTEGER NOT NULL, earlySkipCount INTEGER NOT NULL, accentColor INTEGER, backgroundColor INTEGER, manuallyTagged INTEGER NOT NULL, isMissing INTEGER NOT NULL, tagCount INTEGER NOT NULL, coverArt TEXT, replayGain TEXT, isCoverArtManuallySet INTEGER NOT NULL, smallThumbnail BLOB, largeThumbnail BLOB, PRIMARY KEY(uuid)) WITHOUT ROWID;")
	exec(db, "CREATE TABLE CollectionSongs (collectionUuid_fk BLOB NOT NULL, songUuid_fk BLOB NOT NULL, position INTEGER NOT NULL, PRIMARY KEY(collectionUuid_fk, songUuid_fk, position)) WITHOUT ROWID;")
	exec(db, "CREATE TABLE Styles (uuid BLOB NOT NULL, name TEXT NOT NULL, color INTEGER NOT NULL, createdAt INTEGER NOT NULL, PRIMARY KEY(uuid), UNIQUE(name), UNIQUE(color)) WITHOUT ROWID;")
	exec(db, "CREATE TABLE Tags (uuid BLOB NOT NULL, name TEXT NOT NULL, createdAt INTEGER NOT NULL, style_fk BLOB NOT NULL, color_fk INTEGER NOT NULL, PRIMARY KEY(uuid), UNIQUE(name, style_fk)) WITHOUT ROWID;")
	exec(db, "CREATE TABLE SongTags (songUuid_fk BLOB NOT NULL, tagUuid_fk BLOB NOT NULL, collectionUuid_fk BLOB, PRIMARY KEY(songUuid_fk, tagUuid_fk)) WITHOUT ROWID;")

	// One folder, one style+tag, one album collection, one song.
	if stmt, ok := nachtul.stmt_prepare(db, "INSERT INTO Folders VALUES (?1, ?2);"); ok {
		nachtul.bind_text(stmt, 1, "/music")
		nachtul.bind_i64(stmt, 2, tobinary(1700000000000))
		nachtul.stmt_finish(stmt)
		nachtul.stmt_finalize(stmt)
	}
	if stmt, ok := nachtul.stmt_prepare(db, "INSERT INTO Styles VALUES (?1, 'Mood', 12345, ?2);"); ok {
		nachtul.bind_blob_or_null(stmt, 1, GUID_BYTES)
		nachtul.bind_i64(stmt, 2, tobinary(1700000000000))
		nachtul.stmt_finish(stmt)
		nachtul.stmt_finalize(stmt)
	}
	if stmt, ok := nachtul.stmt_prepare(db, "INSERT INTO Collections VALUES (?1, 7, 'Old Album', '', ?2, NULL, 0, 0, 0, 0);"); ok {
		nachtul.bind_blob_or_null(stmt, 1, GUID_BYTES2)
		nachtul.bind_i64(stmt, 2, tobinary(1690000000000))
		nachtul.stmt_finish(stmt)
		nachtul.stmt_finalize(stmt)
	}
	if stmt, ok := nachtul.stmt_prepare(db, `INSERT INTO Songs VALUES (?1, '/music/x.flac', 'x.flac', '.flac', 'Imported Song', 'Alpha~;~Beta',
		?2, ?2, ?3, 5000, 123000, 1, 0, 7, 0, 2, 0, 0, 111, 222, 0, 0, 0, NULL, NULL, 0, NULL, NULL);`); ok {
		nachtul.bind_blob_or_null(stmt, 1, GUID_BYTES)
		nachtul.bind_i64(stmt, 2, tobinary(1695000000000))
		nachtul.bind_blob_or_null(stmt, 3, GUID_BYTES2)
		nachtul.stmt_finish(stmt)
		nachtul.stmt_finalize(stmt)
	}
	if stmt, ok := nachtul.stmt_prepare(db, "INSERT INTO Tags VALUES (?1, 'chill', ?2, ?3, 12345);"); ok {
		nachtul.bind_blob_or_null(stmt, 1, GUID_BYTES2)
		nachtul.bind_i64(stmt, 2, tobinary(1700000000000))
		nachtul.bind_blob_or_null(stmt, 3, GUID_BYTES)
		nachtul.stmt_finish(stmt)
		nachtul.stmt_finalize(stmt)
	}
	if stmt, ok := nachtul.stmt_prepare(db, "INSERT INTO SongTags VALUES (?1, ?2, NULL);"); ok {
		nachtul.bind_blob_or_null(stmt, 1, GUID_BYTES)
		nachtul.bind_blob_or_null(stmt, 2, GUID_BYTES2)
		nachtul.stmt_finish(stmt)
		nachtul.stmt_finalize(stmt)
	}
}

@(test)
test_import_v1 :: proc(t: ^testing.T) {
	v1_path := "/tmp/nachtul_t_v1.db"
	make_v1_fixture(v1_path)
	dst, _ := fresh_db("nachtul_t_imported")
	defer nachtul.db_close(dst)

	res, ok := nachtul.import_v1(dst, v1_path)
	testing.expect(t, ok, "import succeeds")
	testing.expect(t, res.folders == 1 && res.collections == 1 && res.songs == 1, "import counts: library")
	testing.expect(t, res.styles == 1 && res.tags == 1 && res.song_tags == 1, "import counts: tags")

	folders := nachtul.folders_list(dst)
	testing.expect(t, len(folders) == 1 && folders[0].path == "/music", "folder imported")
	testing.expect(t, folders[0].added_at == 1700000000000, "ToBinary date converted to ms")

	songs := nachtul.songs_from_collection(dst, "11223344-5566-7788-8899-aabbccddeeff")
	testing.expect(t, len(songs) == 1, "song lands in its parent collection")
	if len(songs) == 1 {
		testing.expect(t, songs[0].uuid == "00112233-4455-6677-8899-aabbccddeeff", "GUID bytes convert to canonical text")
		testing.expect(t, songs[0].artists == "[\"Alpha\",\"Beta\"]", "~;~ artists become a JSON array")
		testing.expect(t, songs[0].position == 1, "parentCollectionPosition becomes the link position")
	}
	found := nachtul.songs_search(dst, "imported", 10)
	testing.expect(t, len(found) == 1, "imported song is searchable by token")

	// Direct column check (catches bind misalignment the row API hides).
	if stmt, ok2 := nachtul.stmt_prepare(dst, "SELECT accentColor, backgroundColor, isMissing, playCount FROM Songs;"); ok2 {
		defer nachtul.stmt_finalize(stmt)
		testing.expect(t, nachtul.stmt_step(stmt), "song row readable")
		accent, has_accent := nachtul.col_i64_or_none(stmt, 0).?
		bg, has_bg := nachtul.col_i64_or_none(stmt, 1).?
		testing.expect(t, has_accent && accent == 111, "accentColor lands in its own column")
		testing.expect(t, has_bg && bg == 222, "backgroundColor lands in its own column")
		testing.expect(t, nachtul.col_i64(stmt, 2) == 0, "isMissing lands in its own column")
		testing.expect(t, nachtul.col_i64(stmt, 3) == 7, "playCount lands in its own column")
	}
}

// ---- app-level load flow -------------------------------------------------------------

@(test)
test_app_loads_library_via_inbox :: proc(t: ^testing.T) {
	setup()
	defer teardown()
	dir := "/tmp/nachtul_t_appflow"
	os.make_directory(dir)
	// Pre-seed a V2 db with one folder; the worker should pick it up.
	{
		db, ok := nachtul.db_open(fmt.tprintf("%s/Nachtul.db", dir))
		testing.expect(t, ok, "seed db opens")
		nachtul.db_create_schema(db)
		nachtul.folder_add(db, "/seeded/music")
		nachtul.db_close(db)
	}
	nachtul.start_library_load(niello.test_context(), dir)
	defer nachtul.stop_library()

	loaded := false
	for _ in 0 ..< 400 {
		step(idle())
		if nachtul.app.loaded {
			loaded = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, loaded, "library lands through the inbox")
	testing.expect(t, nachtul.app.folder_count == 1, "folder count applied")
	testing.expect(t, len(nachtul.app.folders) == 1 && nachtul.app.folders[0].path == "/seeded/music", "folder applied")

	// The settings popup lists the real folder path (draw-list check).
	click(nachtul.instances.settings)
	settle()
	draws_folder := false
	for cmd in niello.draw_list() {
		if cmd.tag == .Text && string(cmd.text_ptr[:cmd.text_len]) == "/seeded/music" {
			draws_folder = true
		}
	}
	testing.expect(t, draws_folder, "settings popup draws the folder path")
}
