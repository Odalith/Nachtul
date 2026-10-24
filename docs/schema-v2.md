# Nachtul schema V2 — design pass (step 2)

Status: **implemented as written** in `src/db.odin` (the DDL below is
the code's `SCHEMA_SQL` verbatim). Object to anything here and the
code follows.

Basis: the C++ port's `sql/tables.sql` (Malkj's own V2 draft) as the
starting point, the C# V1 schema (`TablesV1.cs`) for the tag system
the C++ draft doesn't have yet, and the port plan's rulings (F2
schema is open, D1 DB-as-source-of-truth, D3 Taglist type).

## Conventions

- **UUIDs are TEXT**, canonical lowercase hyphenated form, generated
  as **v7** (time-ordered — index locality for free).
- **Timestamps are int64 milliseconds since the Unix epoch**
  everywhere; `0` means "never" for `lastPlayedAt`/`lastOpened`.
  (V1's .NET `ToBinary()` exists only in the importer.)
- **Artists are a JSON array string** (`["A","B"]`), split at import
  time. The V1 `"~;~"` join survives only in the importer.
- **`searchTokens`** (Songs, Collections) is a JSON array of cleaned
  tokens built at insert time by `make_search_tokens` — search is a
  SQL query over this column (D1), never an in-memory scan.
- Everything is `WITHOUT ROWID` with explicit PKs, as in both
  predecessors. Foreign keys are declared and enforced
  (`PRAGMA foreign_keys = ON` per connection).

## Tables

```sql
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
```

`Info` holds exactly one row; `migrationVersion` is the migration
chain's cursor. Current version: **1** (this schema). Migrations are
append-only `ALTER`s guarded by the version, run at open.

Collection types (the C++ enum, D3 included):
`Artist 0, Album 1, ExtendedPlay 2, Single 3, Compilation 4,
Playlist 5, Taglist 6, Uncategorized 7`.

## Deltas

**From the C++ draft:** tag tables added (Styles/Tags/SongTags, from
C# V1 with TEXT uuids + ms timestamps); indexes added; the joke
column `Info.isPaid_YepYouCanJustEditThis` dropped; `Songs.extension`
stays dropped (derivable from fileName/location).

**From C# V1:** GUID BLOBs → TEXT v7; `ToBinary` dates → ms;
`artist` `"~;~"` string → JSON array; `Collections.coverArt` →
`thumbnail`; `Collections.createdAt` → `addedAt` + `lastOpened`;
dropped as *computed, not stored* (D1): `Collections.totalSizeInBytes`,
`totalDuration`, `manuallyTagged`, `tagCount`, `Songs.tagCount`,
`Songs.manuallyTagged`; dropped outright: `Songs.replayGain` (the
GStreamer backend's rgvolume reads RG tags from the stream),
`Songs.parentCollectionPosition` (order lives in
`CollectionSongs.position`), `SongTags.collectionUuid_fk` (collection
tagging was dead at every layer — F5a drops it).

**One deliberate fix vs the C++ code:** its `make_search_tokens`
strips the leading article from the *pre-lowercase* string, so
"The Beatles" tokenizes with a capital-B "Beatles". V2 strips from
the lowercased copy. Tokens are rebuilt at import/scan time, so the
fix costs nothing and query-side lowercasing stays consistent.

## The V1 importer (F2's test load)

On first run, if `Nachtul.db` doesn't exist but `NachtulV1.db` sits
beside it, the app imports it (one transaction) and reports the
counts. Mapping, per table: folders copied; collections copied with
`coverArt → thumbnail`, `createdAt → addedAt`, `lastOpened := addedAt`;
songs copied with artists split on `"~;~"` → JSON, tokens generated,
and a `CollectionSongs` row for the parent at
`parentCollectionPosition`; `CollectionSongs`, `Styles`, `Tags`,
`SongTags` copied. GUID BLOBs convert from .NET's mixed-endian byte
layout to canonical text; `ToBinary` int64s convert via
`ticks = raw & (2^62 − 1)`, `ms = (ticks − 621355968000000000) / 10000`.
One caveat: `ToBinary` stores *local-time* ticks for Local/Utc-kinded
values, and the importer treats the ticks as UTC-based — imported
timestamps can carry the old app's UTC offset. The shift is uniform,
so ordering (Recent, addedAt sorts) is unaffected; only absolute
clock readings move. Ratings don't exist in V1 (F5c deferred them
anyway).

## DB placement

`Nachtul.db` in the process working directory, like both
predecessors. (A per-user app-data dir can come later; the loader
takes a directory parameter, so it's a call-site change, not a
redesign.)
