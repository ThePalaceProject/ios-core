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
  registry.json.bak           last-good backup, unchanged
  books-state.json            {appVersion, attempts, verified, registryDigest}
  books/
    <sha256(id)>.record.json    {"identifier": id, "record": {...}}  record without "location"
    <sha256(id)>.position.json  {"identifier": id, "location": {...}} or no "location"
  books.migrating/            staging folder, only while a migration runs
```

File names are a SHA-256 of the book identifier because identifiers are URLs
and URNs. Every file write is `.atomic`. Keys are sorted so unchanged content
gives unchanged bytes, and a save writes only the files whose bytes changed.

## When the per-book files are used

The flag is read once per library load. With it off, nothing new runs: load,
save and the backup are the code path from before, and per-book files from an
earlier launch are left as they are. The only exception is sign-out, which
always deletes them with the rest of the shelf.

With it on, load decides on the disk queue:

1. **Trusted.** `books-state.json` says `verified` and its `registryDigest` is the
   SHA-256 of the `registry.json` bytes now on disk. The shelf is every per-book
   record, plus every `registry.json` record the per-book files lack, with each
   position file over the location it covers. Missing per-book files never hide
   a book the old file holds.
2. **Not trusted, `registry.json` valid.** Migrate (below). The old file's records
   are the shelf for this launch either way.
3. **Not trusted, `registry.json` absent, corrupt or recovered from `.bak`.** Use
   the old file's recovery as before; the next launch migrates once a valid file
   has been written.

The digest is what makes a flag-off launch, a downgrade or any other writer of
`registry.json` safe: once something else rewrites the single file, the per-book
files are older than it and the next flag-on launch migrates again from it.

## Migration

1. Write `books-state.json` with `verified: false` and the attempt counted.
2. Write every record and position into `books.migrating/`.
3. Read the staged files back and compare every record with the old file
   (`NSDictionary` equality of the JSON objects, `null` values included).
4. Any difference: delete the staging folder, log the identifiers that differed,
   keep `registry.json` in use. The next launch tries again.
5. Equal: replace `books/` with the staging folder and write `verified: true` with
   the digest of the old file's bytes.

A shelf gets three tries per app version (`appVersion` is `short (build)`); a
success resets the count. A valid but empty `registry.json` never replaces
per-book files that hold books.

## Saves with the per-book files in use

| Save | Writes |
|---|---|
| Position (`setLocation`, a due coalesced position, a position flush) | the book's position file, nothing else |
| Shelf change (add, remove, state, bookmarks, metadata) | changed per-book files, then `registry.json` and `.bak` as before, then `books-state.json` |
| App events: background, terminate, library switch (all through `flushPendingPositions`), sync end | `registry.json` when position files are newer than it |

Order inside a shelf save is per-book files first, single file second, trust
record last. A crash between any two steps leaves, for each book, the files from
before or after the save: per-book files written but `registry.json` not yet
means the digest still matches and the newer per-book files win; `registry.json`
written but the trust record not means the next launch migrates from a complete
`registry.json`. Within one book the position file is written before the record
file, so a new book is never loaded without the position it was saved with.

A write error in the per-book files (a full disk) stops using them for the rest
of the launch: the save still writes `registry.json`, later positions go to it,
and no trust record is written, so the next launch migrates again.

An empty save without server authority is refused when per-book record files
exist, in addition to the existing `registry.json` and `.bak` checks.

## Not in this stage

- Shelf changes still rewrite `registry.json`; only positions skip it.
- The scheduled backup of the per-book files.
- Recovering from per-book files when `registry.json` is corrupt: that launch
  follows the old recovery path, and the per-book files are replaced by the
  next migration.
- Retiring `registry.json`, planned two releases after the flag is on by default.

<!-- audit-verified -->
