# Per-book registry storage

PP-5507. Status: storage layer and migration, behind the Remote Config flag
`per_book_registry_storage_enabled` (default off).

## Why

The shelf is one file per library, `registry.json`. Every save rewrites every
book, including the save of one reading position. The per-book layout keeps
each book in its own files, so a position save writes one small file.

## On-disk layout

Per library, in the folder that already holds `registry.json`:

```
registry/
  registry.json               the single file, still written (see below)
  registry.json.bak           last-good backup, on a schedule (see Backup)
  books-state.json            {appVersion, attempts, verified, registryDigest, registrySequence}
  books/
    <sha256(id)>.record.json    {"identifier", "record": {...whole record, location included}, "sequence"}
    <sha256(id)>.position.json  {"identifier", "location"?, "sequence"}
  books.migrating/            staging folder, only while a migration runs
```

File names are a SHA-256 of the book identifier because identifiers are URLs
and URNs. Every file write is `.atomic`. Keys are sorted so unchanged content
gives unchanged bytes, and a save writes only the files whose content changed.

## Sequences: which file is newest

Every per-book file carries the sequence number of the save that wrote it, and
`books-state.json` carries `registrySequence`, the sequence `registry.json` was
written at. For each book the newest source wins:

- a record file newer than `registry.json` replaces that book's record (a shelf
  save that crashed before `registry.json` was written);
- a record file not newer than `registry.json`, for a book `registry.json` lacks,
  is a removal that already reached `registry.json`, and is ignored;
- a position file newer than the location it competes with replaces it.

A save takes its sequence in the same read of the in-memory shelf as its
snapshot (a shelf save) or its positions (a position save), so no change can
fall between the two. A save with a higher number therefore always saw a later
shelf, and a snapshot that missed a position change loses to the position file.
A position save also queues its write inside that read, so position writes reach
the disk queue in sequence order.

A position save skips the write when the book's position file already holds the
same position. That is decided against what the file would win at load: a record
write for the book makes its position file older than the record, so the next
position save for that book writes the file again, even with the same position.
At load, a position file that does not win over its record or `registry.json`
counts as not written.

One record file holds a book's whole record, so a save that changes a book's
state and position together is one atomic write for that book.

## When the per-book files are used

The flag is read at each library load, so a change applies from the next load.

With it on, load decides on the disk queue:

1. **Trusted.** `books-state.json` says `verified` and its `registryDigest` is the
   SHA-256 of the `registry.json` bytes on disk. Each book is merged by sequence
   as above. Missing per-book files never hide a book the old file holds. When
   any file is newer than `registry.json` (positions saved before a kill), the
   library is marked so the next app event writes `registry.json` again.
2. **Not trusted, `registry.json` valid.** Migrate (below). The old file's records
   are the shelf for this launch either way.
3. **Not trusted, `registry.json` absent, corrupt or recovered from `.bak`.** Use
   the old file's recovery as before; the next launch migrates once a valid file
   has been written.

The digest makes any other writer of `registry.json` visible: once it rewrites
the single file, the per-book files are older than it and the next flag-on
launch migrates again from it.

With the flag off, load and save are the old code path, with one addition: when
`books-state.json` is trusted against the `registry.json` bytes on disk, position
files newer than `registry.json` are applied, read-only, and `registry.json` is
written with them. So turning the flag off keeps every saved position. Record
files are not read with the flag off; a shelf save that crashed before
`registry.json` was written loads as before that save.

Sign-out deletes the per-book files with the rest of the shelf, flag or not.

## Migration

1. Write `books-state.json` with `verified: false` and the attempt counted.
2. Remove a leftover `books.migrating/`, then write every record into it.
3. Read the staged files back and compare every record with the old file
   (`NSDictionary` equality of the JSON objects, `null` values included).
4. Any difference: remove the staging folder, log the identifiers that differed,
   keep `registry.json` in use. The next launch tries again.
5. Equal: remove `books/`, move the staging folder in its place, and write
   `verified: true` with the digest of the old file's bytes and sequence 0.

A crash at any of these steps leaves `verified: false` (or the previous trust
record, which no longer matches), so the next launch migrates again from
`registry.json`. A shelf gets three tries per app version (`short (build)`); a
success resets the count. A valid but empty `registry.json` never replaces
per-book files that hold books.

## Saves with the per-book files in use

| Save | Writes |
|---|---|
| Position (`setLocation`, a due coalesced position, a position flush) | the book's position file, nothing else |
| Shelf change (add, remove, state, bookmarks, metadata) | changed record files, then `.bak` when due (see Backup), then `registry.json`, then `books-state.json`, then the files of removed books |
| App events: background, terminate, library switch (all through `flushPendingPositions`), sync end | `registry.json` when files are newer than it |

A crash at any step leaves each book as it was before or after the save:

- before `registry.json` is written, the trust record still matches the old
  `registry.json`, and each record file already written is newer than it;
- after `registry.json` and before the trust record, the digest no longer
  matches and the next launch migrates from the `registry.json` just written,
  which holds the whole in-memory shelf, positions included.
- after the trust record and before a removed book's files are gone, the files
  left behind are not newer than `registry.json`, which lacks the book, so they
  are ignored and the next shelf save removes them. Until `registry.json` is
  written a removed book's files stay, because its position file may hold its
  newest position.

A write error in the per-book files (a full disk) stops using them for the rest
of the launch: the save still writes `registry.json`, later positions go to it,
and no trust record is written, so the next launch migrates again.

An empty save without server authority is refused when per-book record files
exist, in addition to the existing `registry.json` and `.bak` checks.

## Backup

`registry.json.bak` is the last-good copy that load uses when `registry.json` is
corrupt. With the per-book files in use, a shelf save writes it only when it is
due: at the first shelf save after each load, when the file is missing, when the
last write failed, or when 10 minutes have passed since the last one. A
synchronous save (the app-event write of `registry.json` at background,
terminate and library switch, and a reader's teardown save) is a full snapshot
and always writes it too. A position save never writes it. With
the flag off, or after a per-book write error, every shelf save writes it as
before.

A corrupt `registry.json` therefore loads the shelf as of the last backup: shelf
changes from at most the last 10 minutes, and positions saved since, can be
missing until the next sync. Recovering them from the per-book files is not in
this stage (below).

## Downgrade

A build without this code reads only `registry.json`. It misses positions saved
to position files after `registry.json` was last written. That window closes at
every app event (background, terminate, library switch, sync end), and the app
is in the background or not running when an install replaces it, so the
background flush has normally run. The loss needs a kill or crash after the last
position save and before the next app event, followed by the downgrade. It is at most the positions saved in that window; shelf changes are
always in `registry.json`.

## Not in this stage

- Shelf changes still rewrite `registry.json`; only positions skip it.
- Recovering from per-book files when `registry.json` is corrupt: that launch
  follows the old recovery path, and the per-book files are replaced by the
  next migration.
- Retiring `registry.json`, planned two releases after the flag is on by default.

<!-- audit-verified -->
