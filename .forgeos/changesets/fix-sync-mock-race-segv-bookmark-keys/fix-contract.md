# Fix-contract — sync-test segv (mock race) + bookmark JSON-key split-brain

Origin: Heka dogfood 2026-07-04/05 — `harness test` caught
`testMultipleSynchronizersWithSameRegistry_DoNotConflict` crashing SIGSEGV;
STATE.SplitBrain detector flagged bookmark JSON keys defined independently in
`TPPBookLocation+Locator.swift` and `TPPReadiumBookmark.swift`.

## Root-cause (diagnosed, not speculated)

**Segv:** `TPPBookRegistryMock` is `@unchecked Sendable` with *unsynchronized*
mutable state and a doc comment forbidding concurrent use — but
`testConcurrentLocationUpdates_DoNotCrash` mutates it from 100
`DispatchQueue.global()` threads (`registry[id]?.location = location` races
ARC retain/release on the record's `location` property). Heap corruption
detonates *later* — in the next test to run in the class, which is the
sequential-fluff `testMultipleSynchronizers…` test that got blamed. The mock
violates the thread-safety contract of `TPPBookRegistryProvider` that
production consumers rely on (`TPPLastReadPositionSynchronizer`'s
`@unchecked Sendable` justification explicitly cites "bookRegistry …
thread-safe service objects"; production `TPPBookRegistry` is split-lock
Sendable since ba4a03c69). The MOCK is the only non-conforming implementation.

**Split-brain:** `TPPBookmarkDictionaryRepresentation` (whose doc says
"These keys should not change" — disk-persistence contract) defines
href/time/chapter/progressWithinChapter/progressWithinBook; a `private
extension TPPBookLocation` in `TPPBookLocation+Locator.swift` re-defines the
same five as independent literals. A drift silently breaks the
locator↔bookmark round-trip for persisted positions.

## Scope (in)

1. `PalaceTests/Mocks/TPPBookRegistryMock.swift` — lock-back ALL mutable
   state (`registry`, `processingBooks`, `mockImages`,
   `resetCalledLibraryIDs`, `isSyncing`, `myBooks`, `state`) behind a single
   `NSLock` (mock-grade; production split-lock not needed). **Re-entrancy
   rule (architect finding 2): public methods take the lock exactly once and
   delegate to private UNLOCKED helpers for any work shared between public
   entry points — `preloadData` → `_addGenericBookmark`. No public method
   may call another public method while holding the lock. `NSRecursiveLock`
   is explicitly rejected (masks lock-ordering mistakes).** Public API
   unchanged. Doc comment updated: the mock now HONORS the provider's
   Sendable contract.
2. `PalaceTests/Reader2/TPPLastReadPositionSynchronizerTests.swift`:
   - Rewrite `testMultipleSynchronizersWithSameRegistry_DoNotConflict` to do
     what its name claims: TWO `TPPLastReadPositionSynchronizer` instances
     (spy writers, shared mock registry) driving the real
     `sync(for:book:drmDeviceID:)` concurrently via `withTaskGroup`; assert
     both writers loaded, final registry location consistent, no crash.
   - Annotate `testConcurrentLocationUpdates_DoNotCrash` as the
     provider-contract thread-safety pin (the segv regression test) — it is
     now legitimate because the mock is thread-safe.
3. `Palace/Reader2/Bookmarks/TPPReadiumBookmark.swift` — widen shared keys
   `timeKey`/`chapterKey`/`chapterProgressKey`/`bookProgressKey` from
   `fileprivate` to internal (`hrefKey` already `@objc`); replace ALL FIVE
   in-file duplicate shared-key literals in `toJSONDictionary()` (architect
   finding 1: chapter@~190, href@~192, progressWithinChapter@~193,
   progressWithinBook@~194, time@~196) with the constants, so the
   exactly-1-hit verification greps hold for every shared key.
4. `Palace/Reader2/Bookmarks/TPPBookLocation+Locator.swift` — the private
   extension derives its 5 shared keys from
   `TPPBookmarkDictionaryRepresentation` instead of independent literals.
   Locator-only keys (`@type`, `title`, `part`, `position`, `cssSelector`)
   stay local.
5. New wire-format pin test (in existing
   `PalaceTests/Reader2/TPPReadiumBookmarkTests.swift`): asserts the five
   canonical raw strings. Protects the persisted-data contract for EVERY
   reader of the format (incl. the deferred literal sites below).

## Scope (out) — explicit

- `Palace/Book/Models/TPPBookRegistry*.swift` — production registry already
  Sendable; DO NOT touch.
- `Palace/Reader2/BusinessLogic/TPPLastReadPositionSynchronizer.swift` —
  production logic cleared by diagnosis; DO NOT touch.
- `TPPBookmarkSpec.swift` `locatorChapterProgressionKey` (third definition,
  cross-platform spec namespace), `TPPBookmarkFactory.swift` +
  `RecentlyReadingService.swift` read-side literals — DEFERRED (read paths,
  guarded by the new pin test). Unifying the spec namespace is a design
  decision needing its own pass.
- Other SplitBrain findings (a11y IDs, borrow mapping, auth constants) —
  separate PRs.

## Verification criteria

- `grep -c "TPPLastReadPositionSynchronizer(" PalaceTests/Reader2/TPPLastReadPositionSynchronizerTests.swift` ≥ 12 (SUT instantiated; baseline 12).
- Rewritten test method contains `withTaskGroup` AND two `TPPLastReadPositionSynchronizer(` constructions in its body (multi-step name ↔ body check).
- `grep -rn '"progressWithinChapter"' Palace/Reader2/Bookmarks/TPPReadiumBookmark.swift Palace/Reader2/Bookmarks/TPPBookLocation+Locator.swift` → exactly 1 hit (the SSOT definition). Same for `"progressWithinBook"`, `"time"`, `"chapter"` (scoped to the two files).
- `python3 scripts/check-test-name-vs-body.py PalaceTests/Reader2/TPPLastReadPositionSynchronizerTests.swift` exit 0.
- Concurrency test class passes `-test-iterations 20` locally with zero crashes/restarts (was: segv within 3).
- Mutation `--diff-only` on the two production files ≥50% kill.
- `scripts/verify-pr.sh --quick` PASS.

## Tests required

- Mock thread-safety hammer (existing test, now backed by lock) — the segv-class regression pin.
- Honest two-synchronizer concurrent `sync()` test via production seam.
- Wire-format pin: five canonical key strings.
- Existing `TPPReadiumBookmarkTests` + `Reader2PositionAdapterContractTests` + `Reader2PositionResumeContractTests` stay green (round-trip unaffected).

## Acceptance

All verification criteria pass; full quick battery green; no timeout/restart
lines; DoD evidence pasted in commit body.
