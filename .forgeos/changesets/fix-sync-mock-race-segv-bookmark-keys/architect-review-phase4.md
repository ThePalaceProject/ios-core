# Architect review — Phase 4 (post-implementation)

**Changeset:** fix-sync-mock-race-segv-bookmark-keys
**Branch:** fix/sync-mock-race-segv-bookmark-keys
**Base:** origin/develop
**Reviewer:** independent architect (post-code; approved the fix-contract pre-code)
**Verdict:** APPROVED

## Verdict

APPROVED. The implementation faithfully realizes the approved fix-contract and
both of my pre-code amendment clauses. Root cause is correctly addressed at the
seam that actually raced. All six contract verification criteria hold (re-run
below). No concern/fail findings; three warnings are ship-fine-but-worth-knowing.

## Verification criteria — re-run, all hold

| Criterion | Result |
|---|---|
| `grep -c "TPPLastReadPositionSynchronizer("` ≥ 12 | **12** (passes; note: commit body claims 14 — inaccurate, see W1) |
| Rewritten test has `withTaskGroup` + 2 SUT constructions in body | **1 + 2** — holds |
| Each shared key exactly 1 hit across the 2 prod files | href/time/chapter/progressWithinChapter/progressWithinBook = **1 each** |
| `check-test-name-vs-body.py` exit 0 | **exit 0**, 0 fake-wiring |
| Detector pytest | **6/6 pass** |
| Detector on real tree (blocking scan) | **exit 0** — does NOT false-red develop |

## Amendment-clause compliance (my two pre-code findings)

- **Finding 1 — all five shared literals replaced.** `toJSONDictionary()` now keys
  every entry off `TPPBookmarkDictionaryRepresentation.*` constants; the private
  locator extension derives all five shared keys from the SSOT; locator-only keys
  (`@type`, `title`, `part`, `position`, `cssSelector`) correctly stay local.
  Key-widening is minimal and correct: only the four shared-with-locator keys
  (`timeKey`, `chapterKey`, `chapterProgressKey`, `bookProgressKey`) go
  fileprivate→internal; `hrefKey` was already `@objc`; `pageKey`/`deviceKey`/
  `annotationIdKey`/`readingOrderItem*` stay `fileprivate` (only consumed in-file).
  No over-widening.
- **Finding 2 — NSLock-once + unlocked `_`-helpers, no NSRecursiveLock.** Confirmed.
  Single `NSLock`; public methods lock exactly once; shared work delegated to the
  unlocked `_addGenericBookmark` helper (called from `addGenericBookmark`,
  `preloadData`, `addOrReplaceGenericBookmark`, all under the caller's lock). No
  public method calls another public method under lock. `NSRecursiveLock` absent.

## Architect-canon concerns (as requested)

- **Lock granularity / no send-under-lock.** Mechanically verified (brace-balanced
  scan): every `registrySubject.send` / `bookStateSubject.send` /
  `NotificationCenter.post` is OUTSIDE the `withLock` block. `addBook`/`removeBook`/
  `updateAndRemoveBook`/`setState` take a snapshot under lock, then publish outside.
  Re-entrancy rule honored; no deadlock path for a synchronous subscriber.
- **Computed-accessor soundness.** `TPPBookRegistryRecord` is a `final class`
  (reference type). The `var registry` computed getter returns a locked *copy of
  the dictionary*, but the records are shared references — so the convenience path
  `mock.registry[id]?.state = …` mutates a shared object OUTSIDE the lock. This is
  correctly documented as a single-threaded-only convenience, and — crucially — the
  segv regression hammer (`testConcurrentLocationUpdates_DoNotCrash`) drives the
  LOCKED protocol method `setLocation(...)`, not the convenience path. The 100-thread
  ARC retain/release race on `record.location` is therefore now serialized. Sound.
- **Detector join / false-positive risk as a BLOCKING gate.** Analyzed:
  - Sync-primitive detection is file-level and coarse → fails OPEN (false
    negatives, not false positives) — safe for a gate.
  - The concurrency join is also file-level: (mock genuinely unsynchronized) AND
    (a test file references the mock name) AND (that file contains ANY concurrency
    primitive anywhere). A large shared test file with one unrelated
    `DispatchQueue.global` could couple an unsynchronized mock to concurrency it
    never actually touches → a residual false-positive vector (W3). Mitigated by:
    only hitting genuinely-unsynchronized mocks, and the
    `// unsync-sendable-mock-deferred:` escape hatch. Acceptable for a conservative
    blocking gate; the error message points at the fix.
  - Wiring is correct: pytest 6/6, the hook fixture asserts BOTH fire and
    clean-pass (green-board contract #4), and the detector exits 0 on the real
    tree today (three latent mocks reported as notes, TPPUserAccountMock deferred).

## Reader verification-checklist reconciliation

Change touches `Palace/Reader2/Bookmarks/` (bookmark wire format) and a Reader2
test mock. No reader open-path, DRM-gating, or WKWebView surface touched — the
XCTest-invisible reading surface is unaffected, so no simdrive journey is required
for this change. Locator↔bookmark round-trip is guarded by the existing
`Reader2PositionAdapterContractTests` / `Reader2PositionResumeContractTests` plus
the new wire-format pin. Consistent with Section 6 behavior-must-survive tests.

## Findings

### W1 — WARNING (discipline / evidence accuracy)
Commit-body DoD evidence #1 states `grep -c "TPPLastReadPositionSynchronizer(" = 14`;
the actual count is **12**. The criterion is `≥ 12`, so it still passes — but the
pasted number does not match reality. Inaccurate evidence numbers erode the DoD's
value (constraint #9 spirit). Recommendation: correct to 12 in the commit body /
PR body before merge.

### W2 — WARNING (scope)
The diff bundles an unrelated `coverage_by_fr` sidecar-missing fix (Heka dogfood
finding R8) into `scripts/verify-pr.sh` (lines ~986–1010). This is outside the
stated fix-contract scope (mock race + bookmark-key SSOT + detector wall) and lands
a behavioral change to a CI-gating script with no accompanying shell test.
Recommendation: split R8 into its own commit, or explicitly note it in the PR body
so it is reviewed on its own merits. Non-blocking — the change itself is defensible
(fail-open on absent sidecar) — but "while I'm here" edits to gate scripts deserve
their own scrutiny.

### W3 — WARNING (risk / detector false-positive vector)
The new blocking `scan`-mode detector uses a file-level concurrency join (see
canon analysis above). A genuinely-unsynchronized mock referenced in a large test
file that also contains an unrelated concurrency primitive elsewhere could
false-block a future PR. Escapable via the deferral marker and only affects
genuinely-unsynchronized mocks, so acceptable — but document the residual vector
in the detector header or wall entry so a future false-positive is diagnosed
quickly rather than worked around by weakening the gate.

### Passes (substantive confirmations)
- **P1 (architecture):** lock-once + unlocked `_`-helper pattern correctly
  implemented; no NSRecursiveLock; publishes outside lock. Both amendment clauses
  satisfied.
- **P2 (verification):** the blamed test is now honest — two real
  `TPPLastReadPositionSynchronizer` instances drive `sync(for:book:drmDeviceID:)`
  concurrently via `withTaskGroup` against a shared mock, with actor-spy-writer
  assertions (`loadedBookIDs == [bookID]` per instance). The segv hammer uses the
  locked protocol path. Wire-format pin has a behavioral companion
  (`testToJSONDictionary_UsesPinnedWireKeys` constructs a bookmark and asserts
  emitted keys + values). The bare-constant pin is borderline-tautology but
  justified by the persisted-disk-format contract.
- **P3 (scope-out honored):** production changes are exactly the two Bookmarks
  files. No touch to `TPPLastReadPositionSynchronizer.swift` or production
  `TPPBookRegistry` — the `positionWriter:` seam preexisted. Contract scope-out
  respected.
- **P4 (scope-deferral honored):** `TPPUserAccountMock` left unsynchronized but
  explicitly deferred via marker + wall entry + commit-body `**Deferred:**` stanza.
  Same segv class, potentially still live, but honestly tracked and the detector
  gates NEW instances. Correct application of the scope-deferral protocol.
- **P5 (mutation honesty):** "0/0 mutation points on changed prod lines" is honest
  — the prod diff is pure literal→constant-reference swaps (no conditionals/
  operators to mutate); the pin tests are the behavioral guard, as the pre-code
  review directed.

## Bottom line

Ship it after correcting the W1 count and (ideally) splitting out W2. The fix is
sound, honestly documented, well-tested at the seam that actually raced, and the
new wall (detector + fixture clean-pass + real-tree exit 0) makes the segv class
structurally harder to reintroduce.
