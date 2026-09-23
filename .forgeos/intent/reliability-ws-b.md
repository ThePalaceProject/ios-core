# Intent — Reliability WS-B: Registry Resilience

## Context
Critical-path work item of the "Bulletproof Ownership" reliability initiative.
`TPPBookRegistry` is the shelf's source of truth; a corrupt-load-then-empty-save
can erase a patron's entire shelf (initiative plan §1 Problem 4, §2 WS-B, INV-1).

## Claims (what this diff does)
- Adds a new pure classification + recovery helper `RegistryFileRecovery` that
  distinguishes an absent registry file (`.empty`) from an existing-but-unparseable
  one (`.corrupt`) from a well-formed one (`.valid(records:)`).
- In `BookRegistrySync.load`, splits the old conflated `else` so a corrupt file
  takes a QUARANTINE branch (copies to `registry.json.corrupt-<timestamp>`, never
  destroys), attempts recovery from a `.bak` sidecar, and — when unrecoverable —
  leaves the in-memory registry empty and sets a `needsRebuildFromServer` flag
  instead of silently zeroing.
- On every successful non-empty (or server-authoritative) `save`/`saveSync`,
  first writes a `.bak` sidecar via write-new -> fsync -> rename (keeps last-good).
- Guards the empty save (INV-1): `save(for:)` refuses to persist an empty snapshot
  over a non-empty last-good `.bak` while `needsRebuildFromServer` is set, unless
  the caller marks the save server-authoritative. `sync()`'s reconciliation save is
  the authoritative path that repopulates from the loans feed and clears the flag.
- Adds a `schemaVersion` field (v1 = today's shape) to the persisted payload in
  `save` and `saveSync`; old unversioned files load fine and are migrated to
  versioned on the next save.

## Anti-claims (what this diff must NOT do)
- Does NOT change `shouldSkipBulkDeletion` behavior (preserved byte-for-byte).
- Does NOT edit `MyBooksDownloadCenter` (WS-A) — the load-time re-download
  scheduling calls stay as-is on its existing public API.
- Does NOT touch any WS-A / WS-C file (MyBooks/Download*, MyBooksViewModel,
  BookReturnService, OfflineQueueService, TPPAppDelegate, DownloadStateManager).
- Does NOT change DRM/LCP fulfillment or re-download paths (INV-6).

## Files in scope
- `Palace/Book/Models/BookRegistrySync.swift` (edit)
- `Palace/Book/Models/RegistryFileRecovery.swift` (new)
- `PalaceTests/Book/BookRegistrySyncTests.swift` (edit)
- `PalaceTests/Book/RegistryFileRecoveryTests.swift` (new)

## Guarding tests (INV-1)
- `RegistryFileRecoveryTests.testCorruptFile_isQuarantined_notOverwrittenEmpty`
- `BookRegistrySyncTests.testSaveEmptyOverNonEmptyBackup_isRefusedWithoutServerAuthority`
- `.bak` restore on corrupt load; schema migration of an old unversioned file.
