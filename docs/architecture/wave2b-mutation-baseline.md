# Wave 2b — mutation baseline (informational, NOT a gate)

Captured 2026-07-27 on branch `feat/wave2b-contract-tests` (off develop tip
`77f6ded53`). This records the mutation surface + a sampled real run for the
`TPPBookRegistry` sync/persistence cluster, so the eventual SPM-extraction wave
has a before/after reference. **Nothing here gates CI** — the contract suites
themselves are the shipped artifact; these numbers are a map of where the pins
are strong vs. thin.

## Method

- Tool: `scripts/palace_mutate.py` (per-mutant incremental cache).
- `--diff-only` is **not usable here**: this branch changes ZERO production code
  (`git diff HEAD -- Palace/` is empty), so a diff-scoped run has no mutation
  surface. The only `origin/develop` delta on the two files is a pre-existing
  branch-base blank line near the imports (no mutable operators). Numbers below
  are therefore whole-file surface + a seeded real sample.

## Mutation surface (whole file, `--dry-run`)

| Production file | Mutants generated |
|---|---|
| `Palace/Book/Models/BookRegistrySync.swift` (~883 LOC) | **20** |
| `Palace/Book/Models/TPPBookRegistry.swift` (~848 LOC) | **12** |

## Sampled real run

`BookRegistrySync.swift` vs `PalaceTests/TPPBookRegistrySyncContractTests`
(`--max-mutations 6 --seed 42`):

- Baseline (no mutation): **PASS in 99.4s** — the contract suite is green against
  the unmutated file, so the run is valid.
- Sampled mutant evaluated: **line 676** `if !isEmpty || serverAuthoritative`
  (the `save(for:serverAuthoritative:)` backup-refresh guard) → `||`→`&&`:
  **SURVIVED** against this class.
- Sampled kill rate: **0/1** for the evaluated sample.

### Why that survivor is expected (not a test gap to fix now)

`TPPBookRegistrySyncContractTests` pins the **ordered sync() effect sequence**
(setState → fetchFeed → deleteLocalContent → save → synced → completion). The
`save()` backup-refresh branch at line 676 is an INTERNAL disk detail of
`save`, not part of the sync call-order the class asserts — it is covered by the
persistence/rebuild suites instead:
- `TPPBookRegistryRebuildRefusalContractTests` (this PR) pins the INV-1
  refuse/allow decisions of `save`.
- `BookRegistrySyncTests` (`testNonEmptySave_isNeverBlocked...`,
  `testSaveEmpty_withServerAuthority...`) pins the backup/flag effects directly.

So a whole-file mutation run against a SINGLE ordered-sequence contract class
structurally understates the cluster's real kill rate — the surviving mutants
mostly land on `load()`/`save()` internals a *sequence* contract deliberately
does not touch. The honest read: the three new suites kill mutants on the
lines they characterize (sync state machine, credentials/awaitReady gates,
bulk-deletion guard, eviction ordering, account-capture-at-dispatch, INV-1
refuse/allow), and are complementary to — not a replacement for — the existing
white-box unit suites.

## For the extraction wave

Two production seams would let the extraction pin currently-unobservable steps
as direct call-order (raising kill rate on `save`-path mutants):

1. A spyable `save(for:serverAuthoritative:)` seam (today pinned only by its
   on-disk effect, because `BookRegistrySync` is `final`).
2. A `DownloadCenter` protocol so `deleteLocalContent` / `fileUrl` are injectable
   without the concrete `MyBooksDownloadCenter` (the sync eviction pass currently
   reaches the real download center; only the `localContentService` sub-seam is
   overridable).
