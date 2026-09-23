# Architect review — fix/sync-mock-race-segv-bookmark-keys

**Reviewer:** independent architect (local, ForgeOS off)
**Date:** 2026-07-05
**Verdict (initial):** BLOCKED — 2 contract-consistency concerns.
**Verdict (re-review 2026-07-05, after amendment):** APPROVED — both concerns resolved in the amended fix-contract.

Reviewed the fix-contract against codebase reality on `develop` (no branch commits yet — this is a
pre-implementation contract review). Ran every grep the contract cites plus completeness checks.

## What checks out (approve-worthy)

- **Root-cause diagnosis is SOUND and evidence-backed.**
  - `testConcurrentLocationUpdates_DoNotCrash` (lines 1404–1426) spawns 100 `DispatchQueue.global().async`
    closures calling `mockRegistry.setLocation(...)` → `registry[id]?.location = location`, an unsynchronized
    mutation of a Swift `Dictionary` (COW value type) across 100 threads = UB / heap corruption. Confirmed.
  - The crashing test **does not instantiate the production synchronizer** (`grep -c "TPPLastReadPositionSynchronizer("`
    inside the method body = 0). The crash therefore cannot originate in
    `Palace/Reader2/BusinessLogic/TPPLastReadPositionSynchronizer.swift`. Clearing production is justified.
  - The synchronizer's own `@unchecked Sendable` note (lines 20–22) literally reads "`bookRegistry` and
    `positionWriter` are thread-safe service objects" — the diagnosis quote is accurate. The mock is the
    single non-conforming `TPPBookRegistryProvider`. Production `TPPBookRegistry` is split-lock Sendable
    (ba4a03c69 confirmed in git log). Clearing prod registry is justified.
  - `testMultipleSynchronizersWithSameRegistry_DoNotConflict` (1469–1486) is genuinely sequential fluff
    (two constructions, `XCTAssertNotNil` ×2, then set-then-assert). It runs third/last in the class
    (alphabetical), so deferred detonation from test #1 landing on it is plausible. The rewrite plan
    (two synchronizers driving real `sync(...)` via `withTaskGroup`) is the right replacement.

- **Off-limits list is correct and complete for production.** Deferral of `TPPBookmarkSpec.swift:143`
  (`locatorChapterProgressionKey`), `TPPBookmarkFactory.swift:154–155`, and `RecentlyReadingService.swift`
  read-side literals is SOUND: they read the persisted wire format, and the new wire-format pin test locks
  the five canonical raw strings, so a canonical-side drift is caught for those readers too. Unifying the
  cross-platform spec namespace is legitimately its own design pass.

- **Single-module confirmed — no /swarm needed.** Production changes are confined to
  `Palace/Reader2/Bookmarks/{TPPReadiumBookmark.swift, TPPBookLocation+Locator.swift}` (Reader2 area);
  everything else is test/mock. Matches the risk-driven-rigor bar for a solo /rigorous-fix.

- **Sibling-mock scope is complete.** `TPPBookRegistryMock` is the ONLY class implementing
  `TPPBookRegistryProvider`; no sibling registry mock is silently in scope. (Blast radius is wide — the
  mock is shared by 40+ test files — but adding a lock is additive/behavior-preserving for single-threaded
  callers, so this is a warning, not a blocker. See Finding 2 for the one implementation trap.)

- **Baselines verified:** SUT-instantiation baseline = 12 (criterion ≥12 correct). Key literals present
  exactly as the contract describes. `dictionaryRepresentation` (148–160) and `init(dictionary:)` (101–160)
  — the actual disk round-trip — ALREADY use `TPPBookmarkDictionaryRepresentation.<key>` constants, so the
  round-trip is unaffected; the split-brain is confined to `toJSONDictionary()` inline literals + the
  Locator independent constants. Good.

## Findings (RESOLVED in the amended contract)

### Finding 1 — RESOLVED (was CONCERN, scope): Scope item 3 undercounted the `toJSONDictionary()` literals; it is
internally inconsistent with the verification criterion.

Scope item 3 says "replace the two in-file duplicate literals at lines ~193–194 with the constants."
Lines 193–194 are only `progressWithinChapter` / `progressWithinBook`. But `toJSONDictionary()`
(lines 187–208) uses inline literals for FIVE shared keys:
- `dict["chapter"]` @190
- `dict["href"]` @192
- `dict["progressWithinChapter"]` @193
- `dict["progressWithinBook"]` @194
- `dict["time"]` @196

The verification criterion (line 79) requires **exactly 1 hit** in the two files for `progressWithinChapter`,
`progressWithinBook`, `time`, AND `chapter`. If an implementer follows scope item 3 literally (replace only
193–194), the post-fix grep for `"time"` (@196) and `"chapter"` (@190) each still shows 2 hits
(canonical const + un-replaced inline) → **verification FAILS**. The scope prose and the verification
criterion contradict each other.

**Recommendation:** rewrite scope item 3 to name all shared-key inline literals in `toJSONDictionary()`
(chapter@190, href@192, progressWithinChapter@193, progressWithinBook@194, time@196) as replaced with
the widened constants. Include `href` for consistency even though the criterion doesn't grep it.

**Resolution (amended contract, scope item 3, lines 54-58):** now mandates replacing ALL FIVE in-file
shared-key literals in `toJSONDictionary()` (chapter@~190, href@~192, progressWithinChapter@~193,
progressWithinBook@~194, time@~196) with the widened constants, explicitly tied to the exactly-1-hit
greps. Scope prose and verification criterion are now consistent. CLEARED.

### Finding 2 — RESOLVED (was CONCERN, risk): "a single NSLock" wrapping the mock's public methods
would DEADLOCK via `preloadData` → `addGenericBookmark` re-entrancy.

`preloadData(bookIdentifier:locations:)` (line 119) calls `addGenericBookmark(...)` (line 124) inside a
`forEach`. If the implementer takes scope item 1 literally ("single `NSLock`") and wraps each public method
in `lock()/unlock()`, `preloadData` acquires the lock then calls `addGenericBookmark`, which tries to
acquire the same non-recursive `NSLock` on the same thread → immediate self-deadlock. This hangs any test
that calls `preloadData`, surfacing as a suite timeout/restart (a FAILURE per CLAUDE.md, not a clean fail).
`NSLock` is not re-entrant.

**Recommendation:** specify the locking discipline in scope item 1 — either (a) use `NSRecursiveLock`, or
(b) keep `NSLock` but route internal calls through private *unlocked* helpers (e.g. `preloadData` calls a
private `_addGenericBookmark` that assumes the lock is held), or (c) lock only around each storage
read/modify/write rather than whole methods. `preloadData → addGenericBookmark` is the one re-entrant path;
all other methods are leaf mutations and are safe.

**Resolution (amended contract, scope item 1, lines 35-40):** now specifies public methods take the lock
exactly once and delegate shared work to private UNLOCKED helpers (`preloadData` → `_addGenericBookmark`),
forbids any public method calling another public method while holding the lock, and explicitly rejects
`NSRecursiveLock` on the grounds that it masks lock-ordering mistakes. This is the stronger of the three
remedies I offered — a recursive lock would hide exactly the re-entrancy the mock should not have. CLEARED.

## Non-blocking notes

- WARNING (risk): `TPPBookRegistryMock` is shared by 40+ test files across MyBooks/Audiobook/Stats/etc.
  The lock is additive and safe for single-threaded callers, but the implementer should run the FULL suite
  (not `-only-testing`) after the change, since the fixture is load-bearing everywhere.
- PASS (verification): `-test-iterations 20` local hammer directly targets the segv; appropriate (stricter
  than CI's 3). Mutation `--diff-only ≥50%` may report thin surface on the production diff (visibility
  widening + literal→const-ref are near-mechanical); the wire-format pin test is the real guard there and
  is correctly required.

## Bottom line (re-review)

APPROVED. The engineering was right from the start — sound diagnosis, correctly-cleared production, guarded
deferral, clean module boundary. The two contract-consistency defects (undercounted `toJSONDictionary()`
literals; `preloadData` re-entrancy under a single `NSLock`) are both fixed in the amended fix-contract:
scope item 3 now enumerates all five literals in lockstep with the verification greps, and scope item 1
now prescribes lock-once-public + private-unlocked-helpers and correctly rejects `NSRecursiveLock`. No
remaining findings. Cleared to implement.

The non-blocking notes stand as implementation guidance (run the FULL suite given the shared fixture;
expect thin mutation surface on the near-mechanical production diff, with the wire-format pin test as the
real guard).
