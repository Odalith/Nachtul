// The data layer's core: SQLite FFI, connection handling, the V2
// schema (docs/schema-v2.md — SCHEMA_SQL below is that document's DDL
// verbatim), UUID v7 generation, and the search-token builder.
//
// D1 shape: this file knows nothing about the UI. Queries live in
// library.odin; every query runs to completion inside one call, which
// is what makes SQLITE_STATIC binding safe here (bound text outlives
// the statement by construction).
package nachtul

import "core:c"
import "core:fmt"
import "core:strings"
import "core:time"

// ---- SQLite FFI ---------------------------------------------------------------

// The import name is per-platform (file-scope when; the foreign
// block below binds to whichever declaration is active). Linux links
// the versioned runtime soname directly — the unversioned -lsqlite3
// would demand the -dev package. Windows arrives with its build.
when ODIN_OS == .Linux {
	foreign import sqlite3 "system:libsqlite3.so.0"
} else when ODIN_OS == .Darwin {
	foreign import sqlite3 "system:sqlite3"
}

Db_Handle :: struct {}
Stmt_Handle :: struct {}

Db :: ^Db_Handle
Stmt :: ^Stmt_Handle

foreign sqlite3 {
	sqlite3_open :: proc "c" (filename: cstring, db: ^Db) -> c.int ---
	sqlite3_open_v2 :: proc "c" (filename: cstring, db: ^Db, flags: c.int, vfs: cstring) -> c.int ---
	sqlite3_close :: proc "c" (db: Db) -> c.int ---
	sqlite3_exec :: proc "c" (db: Db, sql: cstring, callback: rawptr, arg: rawptr, errmsg: ^^c.char) -> c.int ---
	sqlite3_free :: proc "c" (p: rawptr) ---
	sqlite3_errmsg :: proc "c" (db: Db) -> cstring ---
	sqlite3_prepare_v2 :: proc "c" (db: Db, sql: cstring, n_byte: c.int, stmt: ^Stmt, tail: ^cstring) -> c.int ---
	sqlite3_step :: proc "c" (stmt: Stmt) -> c.int ---
	sqlite3_reset :: proc "c" (stmt: Stmt) -> c.int ---
	sqlite3_finalize :: proc "c" (stmt: Stmt) -> c.int ---
	sqlite3_bind_text :: proc "c" (stmt: Stmt, idx: c.int, text: cstring, n: c.int, destructor: rawptr) -> c.int ---
	sqlite3_bind_int64 :: proc "c" (stmt: Stmt, idx: c.int, v: c.longlong) -> c.int ---
	sqlite3_bind_blob :: proc "c" (stmt: Stmt, idx: c.int, data: rawptr, n: c.int, destructor: rawptr) -> c.int ---
	sqlite3_bind_null :: proc "c" (stmt: Stmt, idx: c.int) -> c.int ---
	sqlite3_column_text :: proc "c" (stmt: Stmt, idx: c.int) -> rawptr ---
	sqlite3_column_bytes :: proc "c" (stmt: Stmt, idx: c.int) -> c.int ---
	sqlite3_column_int64 :: proc "c" (stmt: Stmt, idx: c.int) -> c.longlong ---
	sqlite3_column_type :: proc "c" (stmt: Stmt, idx: c.int) -> c.int ---
	sqlite3_column_blob :: proc "c" (stmt: Stmt, idx: c.int) -> rawptr ---
}

SQLITE_OK :: 0
SQLITE_ROW :: 100
SQLITE_DONE :: 101
SQLITE_OPEN_READONLY :: 0x0001
SQLITE_COL_NULL :: 5

MIGRATION_VERSION :: 1

// ---- schema ---------------------------------------------------------------------

// Verbatim from docs/schema-v2.md.
SCHEMA_SQL :: `
CREATE TABLE IF NOT EXISTS Info (
  migrationVersion    INTEGER NOT NULL,
  hasDoneInitialSetup INTEGER NOT NULL,
  installedAt         INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS Folders (
  folderPath TEXT NOT NULL,
  addedAt    INTEGER NOT NULL,
  PRIMARY KEY (folderPath)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS Collections (
  uuid         TEXT NOT NULL,
  typeEnum     INTEGER NOT NULL,
  name         TEXT NOT NULL COLLATE NOCASE,
  searchTokens TEXT NOT NULL COLLATE NOCASE,
  description  TEXT NOT NULL,
  addedAt      INTEGER NOT NULL,
  lastOpened   INTEGER NOT NULL,
  thumbnail    BLOB,
  PRIMARY KEY (uuid),
  UNIQUE (typeEnum, name)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS Songs (
  uuid                  TEXT NOT NULL,
  location              TEXT NOT NULL,
  addedAt               INTEGER NOT NULL,
  createdAt             INTEGER NOT NULL,
  title                 TEXT NOT NULL COLLATE NOCASE,
  searchTokens          TEXT NOT NULL COLLATE NOCASE,
  artists               TEXT NOT NULL COLLATE NOCASE,
  parentCollection_fk   TEXT NOT NULL REFERENCES Collections(uuid)
                          ON DELETE CASCADE ON UPDATE CASCADE,
  triHash               TEXT NOT NULL,
  musicbrainzId         TEXT,
  fileName              TEXT NOT NULL,
  sizeInBytes           INTEGER NOT NULL,
  duration              INTEGER NOT NULL,
  lastPlayedAt          INTEGER NOT NULL,
  playCount             INTEGER NOT NULL,
  playSeconds           INTEGER NOT NULL,
  completedPlayCount    INTEGER NOT NULL,
  skipCount             INTEGER NOT NULL,
  earlySkipCount        INTEGER NOT NULL,
  isMissing             INTEGER NOT NULL,
  accentColor           INTEGER,
  backgroundColor       INTEGER,
  coverArt              TEXT,
  isCoverArtManuallySet INTEGER NOT NULL,
  smallThumbnail        BLOB,
  largeThumbnail        BLOB,
  PRIMARY KEY (uuid)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS CollectionSongs (
  collectionUuid_fk TEXT NOT NULL REFERENCES Collections(uuid)
                      ON DELETE CASCADE ON UPDATE CASCADE,
  songUuid_fk       TEXT NOT NULL REFERENCES Songs(uuid)
                      ON DELETE CASCADE ON UPDATE CASCADE,
  position          INTEGER NOT NULL,
  PRIMARY KEY (collectionUuid_fk, songUuid_fk, position)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS Styles (
  uuid      TEXT NOT NULL,
  name      TEXT NOT NULL COLLATE NOCASE,
  color     INTEGER NOT NULL,
  createdAt INTEGER NOT NULL,
  PRIMARY KEY (uuid),
  UNIQUE (name),
  UNIQUE (color)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS Tags (
  uuid      TEXT NOT NULL,
  name      TEXT NOT NULL COLLATE NOCASE,
  createdAt INTEGER NOT NULL,
  style_fk  TEXT NOT NULL REFERENCES Styles(uuid)
              ON DELETE CASCADE ON UPDATE CASCADE,
  color_fk  INTEGER NOT NULL REFERENCES Styles(color)
              ON DELETE CASCADE ON UPDATE CASCADE,
  PRIMARY KEY (uuid),
  UNIQUE (name, style_fk)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS SongTags (
  songUuid_fk TEXT NOT NULL REFERENCES Songs(uuid)
                ON DELETE CASCADE ON UPDATE CASCADE,
  tagUuid_fk  TEXT NOT NULL REFERENCES Tags(uuid)
                ON DELETE CASCADE ON UPDATE CASCADE,
  PRIMARY KEY (songUuid_fk, tagUuid_fk)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS idx_songs_parent ON Songs(parentCollection_fk);
CREATE INDEX IF NOT EXISTS idx_cs_song      ON CollectionSongs(songUuid_fk);
CREATE INDEX IF NOT EXISTS idx_songtags_tag ON SongTags(tagUuid_fk);
CREATE INDEX IF NOT EXISTS idx_collections_type ON Collections(typeEnum);
`

// ---- connections ------------------------------------------------------------------

db_open :: proc(path: string) -> (Db, bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	db: Db
	if sqlite3_open(cpath, &db) != SQLITE_OK {
		fmt.eprintfln("nachtul: cannot open db %s: %s", path, sqlite3_errmsg(db))
		if db != nil {
			sqlite3_close(db)
		}
		return nil, false
	}
	db_exec(db, "PRAGMA foreign_keys = ON;")
	db_exec(db, "PRAGMA journal_mode = WAL;")
	return db, true
}

db_open_readonly :: proc(path: string) -> (Db, bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	db: Db
	if sqlite3_open_v2(cpath, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
		if db != nil {
			sqlite3_close(db)
		}
		return nil, false
	}
	return db, true
}

db_close :: proc(db: Db) {
	if db != nil {
		sqlite3_close(db)
	}
}

db_exec :: proc(db: Db, sql: string) -> bool {
	err: ^c.char
	csql := strings.clone_to_cstring(sql, context.temp_allocator)
	if sqlite3_exec(db, csql, nil, nil, &err) != SQLITE_OK {
		fmt.eprintfln("nachtul: sql failed: %s\n  in: %s", err != nil ? string(cstring(err)) : "?", sql)
		if err != nil {
			sqlite3_free(err)
		}
		return false
	}
	return true
}

// Creates the schema (idempotent) and the one-row Info table.
db_create_schema :: proc(db: Db) -> bool {
	if !db_exec(db, "BEGIN;") {
		return false
	}
	ok := db_exec(db, SCHEMA_SQL)
	if ok {
		seed := fmt.tprintf(
			"INSERT INTO Info (migrationVersion, hasDoneInitialSetup, installedAt) SELECT %d, 0, %d WHERE NOT EXISTS (SELECT 1 FROM Info);",
			MIGRATION_VERSION, now_ms())
		ok = db_exec(db, seed)
	}
	db_exec(db, ok ? "COMMIT;" : "ROLLBACK;")
	return ok
}

db_migration_version :: proc(db: Db) -> int {
	stmt, ok := stmt_prepare(db, "SELECT migrationVersion FROM Info LIMIT 1;")
	if !ok {
		return 0
	}
	defer stmt_finalize(stmt)
	if stmt_step(stmt) {
		return int(col_i64(stmt, 0))
	}
	return 0
}

// ---- statements -----------------------------------------------------------------

stmt_prepare :: proc(db: Db, sql: string) -> (Stmt, bool) {
	csql := strings.clone_to_cstring(sql, context.temp_allocator)
	stmt: Stmt
	if sqlite3_prepare_v2(db, csql, -1, &stmt, nil) != SQLITE_OK {
		fmt.eprintfln("nachtul: prepare failed: %s\n  in: %s", sqlite3_errmsg(db), sql)
		return nil, false
	}
	return stmt, true
}

stmt_finalize :: proc(stmt: Stmt) {
	if stmt != nil {
		sqlite3_finalize(stmt)
	}
}

// true = a row is available to read with col_*.
stmt_step :: proc(stmt: Stmt) -> bool {
	return sqlite3_step(stmt) == SQLITE_ROW
}

// true = completed without a row (INSERT/UPDATE/DELETE finished).
stmt_finish :: proc(stmt: Stmt) -> bool {
	return sqlite3_step(stmt) == SQLITE_DONE
}

bind_text :: proc(stmt: Stmt, idx: int, v: string) {
	cv := strings.clone_to_cstring(v, context.temp_allocator)
	sqlite3_bind_text(stmt, c.int(idx), cv, -1, nil) // SQLITE_STATIC: caller outlives the statement
}

bind_text_or_null :: proc(stmt: Stmt, idx: int, v: Maybe(string)) {
	if s, ok := v.?; ok {
		bind_text(stmt, idx, s)
	} else {
		sqlite3_bind_null(stmt, c.int(idx))
	}
}

bind_i64 :: proc(stmt: Stmt, idx: int, v: i64) {
	sqlite3_bind_int64(stmt, c.int(idx), c.longlong(v))
}

bind_i64_or_null :: proc(stmt: Stmt, idx: int, v: Maybe(i64)) {
	if n, ok := v.?; ok {
		bind_i64(stmt, idx, n)
	} else {
		sqlite3_bind_null(stmt, c.int(idx))
	}
}

bind_blob_or_null :: proc(stmt: Stmt, idx: int, v: Maybe([]u8)) {
	if b, ok := v.?; ok && len(b) > 0 {
		sqlite3_bind_blob(stmt, c.int(idx), raw_data(b), c.int(len(b)), nil)
	} else {
		sqlite3_bind_null(stmt, c.int(idx))
	}
}

col_text :: proc(stmt: Stmt, idx: int) -> string {
	p := sqlite3_column_text(stmt, c.int(idx))
	if p == nil {
		return ""
	}
	n := sqlite3_column_bytes(stmt, c.int(idx))
	bytes := ([^]u8)(p)[:n]
	return strings.clone(string(bytes))
}

col_text_or_none :: proc(stmt: Stmt, idx: int) -> Maybe(string) {
	if sqlite3_column_type(stmt, c.int(idx)) == SQLITE_COL_NULL {
		return nil
	}
	return col_text(stmt, idx)
}

col_i64 :: proc(stmt: Stmt, idx: int) -> i64 {
	return i64(sqlite3_column_int64(stmt, c.int(idx)))
}

col_i64_or_none :: proc(stmt: Stmt, idx: int) -> Maybe(i64) {
	if sqlite3_column_type(stmt, c.int(idx)) == SQLITE_COL_NULL {
		return nil
	}
	return col_i64(stmt, idx)
}

col_blob_clone :: proc(stmt: Stmt, idx: int) -> Maybe([]u8) {
	if sqlite3_column_type(stmt, c.int(idx)) == SQLITE_COL_NULL {
		return nil
	}
	n := sqlite3_column_bytes(stmt, c.int(idx))
	if n <= 0 {
		return nil
	}
	p := sqlite3_column_blob(stmt, c.int(idx))
	out := make([]u8, int(n))
	copy(out, ([^]u8)(p)[:n])
	return out
}

// ---- time + ids -------------------------------------------------------------------

now_ms :: proc() -> i64 {
	return time.time_to_unix_nano(time.now()) / 1_000_000
}

// splitmix64 — ID-grade randomness without a stdlib dependency hunt;
// seeded once from the clock. UUID uniqueness in one local library
// does not need cryptographic strength.
rng_state: u64
rng_seeded: bool

rng_seed :: proc() {
	rng_state = u64(time.time_to_unix_nano(time.now())) ~ 0x9E3779B97F4A7C15
	rng_seeded = true
}

rng_next :: proc() -> u64 {
	if !rng_seeded {
		rng_seed()
	}
	rng_state += 0x9E3779B97F4A7C15
	z := rng_state
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

// A v7 UUID: 48-bit unix ms, version 0111, variant 10, the rest random.
uuid_v7 :: proc() -> string {
	ms := u64(now_ms()) & 0x0000_FFFF_FFFF_FFFF
	r1 := rng_next()
	r2 := rng_next()
	b: [16]u8
	b[0] = u8(ms >> 40)
	b[1] = u8(ms >> 32)
	b[2] = u8(ms >> 24)
	b[3] = u8(ms >> 16)
	b[4] = u8(ms >> 8)
	b[5] = u8(ms)
	b[6] = u8(0x70 | ((r1 >> 8) & 0x0F))
	b[7] = u8(r1)
	b[8] = u8(0x80 | ((r1 >> 16) & 0x3F))
	for i in 0 ..< 7 {
		b[9 + i] = u8(r2 >> u32(48 - 8 * i))
	}
	return fmt.tprintf(
		"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
		b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
		b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
}

// ---- JSON string arrays -------------------------------------------------------------

json_escape_into :: proc(b: ^strings.Builder, s: string) {
	for r in s {
		switch r {
		case '"':
			strings.write_string(b, "\\\"")
		case '\\':
			strings.write_string(b, "\\\\")
		case '\n':
			strings.write_string(b, "\\n")
		case '\r':
			strings.write_string(b, "\\r")
		case '\t':
			strings.write_string(b, "\\t")
		case:
			if r < 0x20 {
				fmt.sbprintf(b, "\\u%04x", u32(r))
			} else {
				strings.write_rune(b, r)
			}
		}
	}
}

json_string_array :: proc(items: []string) -> string {
	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for item, i in items {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_byte(&b, '"')
		json_escape_into(&b, item)
		strings.write_byte(&b, '"')
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

// ---- search tokens -----------------------------------------------------------------

// The C++ port's make_search_tokens, ported (folders_table_service.h):
// cleaned title words + their initials + synonym expansions, then per
// artist the full lowercased name + its initials — as a JSON array.
// One deliberate fix (schema doc): the leading article is stripped
// from the lowercased text, where the C++ strips from the pre-lower
// copy and leaks the original capitalization into the tokens.
make_search_tokens :: proc(title: string, artists: []string) -> string {
	tokens: [dynamic]string
	defer delete(tokens)

	// Clean the title: trim, drop punctuation, lowercase, strip article.
	trimmed := strings.trim(title, " \t\r\n.")
	cleaned := strings.builder_make()
	defer strings.builder_destroy(&cleaned)
	for r in trimmed {
		switch r {
		case '"', '\'', '(', ')', '[', ']', '<', '>', ',', '`', '-':
			// dropped
		case:
			strings.write_rune(&cleaned, r)
		}
	}
	lowered := strings.to_lower(strings.to_string(cleaned))
	defer delete(lowered)
	text := lowered
	if strings.has_prefix(text, "the ") {
		text = text[4:]
	} else if strings.has_prefix(text, "an ") {
		text = text[3:]
	} else if strings.has_prefix(text, "a ") {
		text = text[2:]
	}

	initials := strings.builder_make()
	defer strings.builder_destroy(&initials)
	words := strings.split(text, " ")
	defer delete(words)
	for word in words {
		if len(word) == 0 {
			continue
		}
		strings.write_byte(&initials, word[0])
		if word == "ft." || word == "feat." || word == "featuring" {
			append(&tokens, "ft", "feat", "featuring")
			continue
		}
		switch word {
		case "instrumental", "acapella", "remix", "remastered", "live", "version":
			append(&tokens, "alternate", "alternative", "different", "other")
		}
		append(&tokens, word)
	}
	if initials_len := strings.builder_len(initials); initials_len > 0 {
		append(&tokens, strings.clone(strings.to_string(initials)))
	}

	for artist in artists {
		lowered_artist := strings.to_lower(artist)
		append(&tokens, lowered_artist)
		artist_initials := strings.builder_make()
		parts := strings.split(lowered_artist, " ")
		for part in parts {
			if len(part) > 0 {
				strings.write_byte(&artist_initials, part[0])
			}
		}
		delete(parts)
		if strings.builder_len(artist_initials) > 0 {
			append(&tokens, strings.clone(strings.to_string(artist_initials)))
		}
		strings.builder_destroy(&artist_initials)
	}

	return json_string_array(tokens[:])
}
