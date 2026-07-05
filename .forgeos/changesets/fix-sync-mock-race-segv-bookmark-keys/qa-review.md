# QA / Test-Quality Review — fix/sync-mock-race-segv-bookmark-keys

**Reviewer role:** qa_test (independent, SoD)
**Verdict:** APPROVED
**Date:** 2026-07-05
**Base:** origin/develop...HEAD (commit 85d429fc1)
**ForgeOS:** disabled in this env — no MCP submission; verdict recorded here.

## Verdict summary

APPROVED. This is a disciplined, dogfood-sourced fix. The mock lock coverage is
complete, the rewritten concurrency test is genuinely load-bearing (not
decorative), the wire-format pins are legitimate persistence contracts rather
than banned fluff, and the detector is wired end-to-end with a fixture that
asserts both the fire and the clean path. Mutation 0/0 is honest for a
pure constant-reference refactor and is correctly compensated by the pin tests.
One non-blocking WARNING: the detector's `missing-dirs` early-exit branch — the
exact false-positive-prevention path it cites for the 2026-06-08 wiring-bug
class — has no direct pytest case.

## Findings

### 1. Mock lock coverage — PASS
TPPBookRegistryMock: every `TPPBookRegistryProvider` / `TPPBookRegistrySyncing`
method that touches mutable state acquires the single `NSLock` exactly once.
Audited all 30 methods: stateless ones (`sync(completion:)`, `load`,
`coverImage`, `with`) correctly take no lock; every stateful accessor and
mutator locks. No public-under-lock-calls-public re-entrancy: shared work is
delegated to the unlocked `_addGenericBookmark` helper from both
`addOrReplaceGenericBookmark` and `preloadData`. Combine `send(...)` / state
notifications are emitted OUTSIDE the lock (snapshot captured under lock, sent
after) — correct deadlock avoidance for synchronous re-entrant subscribers.
`addBook`/`removeBook`/`updateAndRemoveBook`/`setState` all follow that pattern.
Non-recursive lock is the right call (masks nothing). The one documented
limitation — direct `mock.registry[id]?.location = x` mutating a shared
`TPPBookRegistryRecord` (a `final class`) outside the lock — is honestly called
out as a single-threaded convenience; concurrent tests must use protocol
methods, which do lock. That is the exact ARC-race seam that SIGSEGV'd, now
closed on the protocol path.

### 2. Rewritten concurrency test — PASS
`testMultipleSynchronizersWithSameRegistry_DoNotConflict` now drives two REAL
`TPPLastReadPositionSynchronizer.sync(...)` calls concurrently via
`withTaskGroup`, interleaved with 50 `setLocation` writes on the shared
registry. Delegation is load-bearing: `sync()` → `syncReadPosition()` →
`writer.load(for:)` (verified in production source, line 97); the spy asserts
`loadedBookIDs == [bookID]` for BOTH instances. It WOULD fail if `sync()`
stopped delegating to the writer (empty `loadedBookIDs`). It is NOT primarily a
lock-removal detector — that job belongs to the sibling
`testConcurrentLocationUpdates_DoNotCrash` (100-thread hammer), and the
docstrings are honest about that division. This is a correct, non-decorative
test that finally matches its long-standing name.

### 3. Wire-format pin tests — PASS
`testWireFormatKeys_ArePinned` asserts constants against literals. Under
CLAUDE.md this shape is normally banned fluff — but the justification holds:
these are persisted on-disk keys (the type's own doc says changing them orphans
users' bookmarks), and the compiler cannot enforce an external disk contract. A
golden-value pin whose PURPOSE is to fail on future drift is the
contract-snapshot category CLAUDE.md explicitly endorses, not a
mathematically-guaranteed tautology. `testToJSONDictionary_UsesPinnedWireKeys`
is the stronger behavioral companion — it constructs a real bookmark and
asserts the emitted dict is keyed by the pinned strings, guarding the encode
side. No separate locator-round-trip test is needed: the locator keys now
DERIVE from the pinned SSOT constants, so drift is structurally impossible.

### 4. Detector pytest — WARNING (non-blocking)
6 pytest cases cover: violation, clean/locked, latent-note, latent-strict,
deferral-marker, live-repo-clean. Two branches lack a direct unit test:
(a) the `missing-dirs` early-exit (`mocks_dir`/`tests_dir` absent → return 0) —
notable because the code comment cites it as the guard against the 2026-06-08
wiring-bug (false-red) class; it is exercised indirectly by fixture Assert 5 and
the live-repo test, but not pinned in the pytest. (b) the file-scoped (not
type-scoped) `DEFERRAL_MARKER`: a mock file with two `@unchecked Sendable` types
and one marker defers BOTH. Low risk (one-type-per-file norm).
Recommendation: add a 7th pytest case constructing absent dirs and asserting
`rc==0`. Non-blocking.

### 5. Mutation posture (0/0) — PASS
The 30 changed production lines are pure constant-reference swaps (string
literal → `TPPBookmarkDictionaryRepresentation.*`) and visibility widening
(`fileprivate` → internal). There is genuinely no behavioral mutation surface —
no conditional or operator to flip — so 0/0 diff-only is honest, not an evasion.
The change is a zero-behavior-change refactor (emitted dict byte-identical); its
only risk is FUTURE drift, which the pin + round-trip tests guard directly. Pin
tests are the correct compensating control per architect review. Adequate.

## Wiring verified
- Detector wired into `pre-commit-phase35-detectors.sh` (block|scan) AND
  `verify-pr.sh` (block|scan).
- Fixture Assert 6 exercises the detector with a violation (must block) AND a
  clean/latent path (must pass) — satisfies CLAUDE.md green-board contract #4.
- Live runs during review: detector pytest 6/6 passed; live scan rc 0 (3 latent
  notes + 1 documented deferral, none concurrent); `check-test-name-vs-body.py`
  exit 0 on both touched test files; SUT instantiation count 12.

## Deferrals (reviewed, acceptable)
TPPUserAccountMock locking is deferred behind the `unsync-sendable-mock-deferred`
marker + wall entry. Acceptable: it is a MOCK (not production), no concurrent
test drives it today (latent), and the detector will BLOCK the instant any
concurrent test references it — the deferral is self-guarding. Read-side
literals in TPPBookmarkFactory/TPPBookmarkSpec/RecentlyReadingService are
guarded by the pin test. Both are explicit in the intent file's Anti-claims.
