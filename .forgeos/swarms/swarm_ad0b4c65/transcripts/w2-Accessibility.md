# Wave-2 Wall-Clock-Wait Conversion — Module: Accessibility

Worktree: `swarm_ad0b4c65-w2-accessibility`
Scope: `PalaceTests/Accessibility/` only (14 files, 2675 LOC)

## Result: no code changes required

`git status --porcelain PalaceTests/Accessibility/` is empty — every wait
occurrence in scope resolved to **KEEP** per the dispatch nuance carve-out for
`TPPAccessibilityAnnouncementCenter`. Nothing was CONVERTed, DELETEd, or left
UNMAPPED because nothing qualified for those buckets.

## Scan methodology

1. Broad grep across the whole directory for every wait-shaped construct:
   `wait(for:|waitForExpectations|fulfillment(of:|Thread.sleep|usleep|asyncAfter|
   while.*Date()|awaitCondition|XCTestExpectation|.fulfill()` — 55 raw hits.
2. Narrowed to files containing `expectation(|XCTestExpectation|Task.sleep|
   .sleep(|async ` — only 2 of the 14 files matched:
   - `AccessibilityAnnouncementCenterTests.swift`
   - `StatusAnnouncementTests.swift`

   The other 12 files (`AccessibilityLabelTests`, `AccessLintComplianceTests`,
   `AudiobookAccessibilityTests`, `BookImageViewAccessibilityTests`,
   `BookListViewAccessibilityTests`, `CatalogAccessibilityTests`,
   `FacetToolbarAccessibilityTests`, `FocusIndicationTests`,
   `PDFAccessibilityToolbarTests`, `ReaderAccessibilityTests`,
   `SearchAccessibilityTests`, `TPPBookAccessibilityLabelTests`) contain **zero**
   wall-clock-wait constructs — no action needed, no mention below.
3. Confirmed the DELETE-bucket patterns (`Thread.sleep|usleep|asyncAfter.*fulfill|
   while.*Date().*<`) are absent from the whole directory (`grep` → no matches).
4. Confirmed no `DispatchSemaphore`/`.wait()`/`RunLoop`/`CFRunLoopRun` usage
   anywhere in scope.

## Why every occurrence is KEEP, not CONVERT

Both files exercise `TPPAccessibilityAnnouncementCenter`
(`Palace/Utilities/TPPAccessibilityAnnouncementCenter.swift`), which per the
dispatch nuance:

> uses a main-hop + a debounce `asyncAfter`; the S12 inject-scheduler seam is
> NOT yet built. Expectations fulfilled by the center's DIRECT postHandler
> callback are KEEP; the debounce-dependent waits are UNMAPPED.

I verified which code path every test in scope actually exercises by reading
`TPPAccessibilityAnnouncementCenter.announce(_:)`:

- When **not** in a transition window and **not** already draining a queue
  (`isProcessingQueue == false`, `isInTransitionPeriod() == false`), `announce`
  takes the **direct** path: `DispatchQueue.main.async { postHandler(...) }` —
  no `asyncAfter`, no debounce timer.
- The debounce/queue path (`scheduleQueueDrain` → `asyncAfter` → `drainNext` →
  `announcementTimeout` retry `asyncAfter`) is only entered when
  `notifyScreenTransition()` (or the `.TPPAccessibilityScreenTransition`
  notification) has fired within `transitionSettleDelay` (1.5s default).

I grepped both test files for `notifyScreenTransition|TPPAccessibilityScreenTransition|
isProcessingQueue|scheduleQueueDrain|drainNext` — **zero matches in either
file**. No test in this module's scope ever exercises the debounce/transition
path. Every `postHandler` invocation in scope is therefore a DIRECT callback
(mediated by the injected `postHandler` closure fired via `DispatchQueue.main.async`,
never `asyncAfter`), and `TPPAccessibilityAnnouncementCenter` has no catalog
seam (S1–S11, nor the pre-existing list) — so per the bucket protocol + the
dispatch carve-out, these fall to **KEEP**, not CONVERT (no seam exists to
join on) and not UNMAPPED (the dispatch explicitly names this exact shape as
KEEP).

The negative "nothing fired" assertions (`wait(for: [neverFired], timeout: 0.3)`
in `AccessibilityAnnouncementCenterTests.swift`) are separately covered by
playbook rule 3 — intrinsically time-based absence checks — and were left
untouched regardless.

## Per-file tallies

| File | wait(for:)/waitForExpectations before | after | CONVERT | DELETE | KEPT | UNMAPPED |
|---|---|---|---|---|---|---|
| `AccessibilityAnnouncementCenterTests.swift` | 20 | 20 | 0 | 0 | 20 | 0 |
| `StatusAnnouncementTests.swift` | 19 | 19 | 0 | 0 | 19 | 0 |
| (12 other files in scope) | 0 | 0 | 0 | 0 | 0 | 0 |
| **Total** | **39** | **39** | **0** | **0** | **39** | **0** |

`grep -c 'wait(for:\|waitForExpectations\|fulfillment(of:' <file>`:
- `AccessibilityAnnouncementCenterTests.swift`: 20 → 20 (unchanged)
- `StatusAnnouncementTests.swift`: 19 → 19 (unchanged)

Remainder (39) == KEPT (39) + UNMAPPED (0). No silent drop.

## KEPT list (39, byte-for-byte, all DIRECT-postHandler-callback shape)

**`AccessibilityAnnouncementCenterTests.swift`** (20):
- `testPP3594_downloadAnnouncements_respectVoiceOverDisabled` (neverFired, timeout 0.3 — also rule-3 negative)
- `testPP3594_borrowAndReturnAnnouncements_postMessages`
- `testPP3673_searchResults_announcesResultCountAndQuery`
- `testPP3673_searchNoResults_announcesNoResults`
- `testPP3673_searchFailed_announcesFailure`
- `testPP3673_searchRerun_announcesUpdatedResults`
- `testPP3673_additionalResultsLoaded_announcesCount`
- `testPP3673_additionalResultsLoaded_zeroCount_doesNotAnnounce` (neverFired — rule-3 negative)
- `testPP3673_announceError_postsMessage`
- `testPP3673_announceStatus_combinesTitleAndMessage`
- `testPP3673_announceMessage_postsArbitraryMessage`
- `testPP3673_deduplication_suppressesDuplicateWithinWindow`
- `testPP3673_deduplication_allowsRepeatAfterWindowExpires`
- `testPP3673_deduplication_allowsDifferentMessages`
- `testPP3673_deduplication_rapidFireSameMessage_onlyOneAnnouncement`
- `testPP3673_deduplication_crossMethod_sameText`
- `testPP3673_searchAnnouncements_respectVoiceOverDisabled` (neverFired — rule-3 negative)
- `testPP3673_errorAnnouncements_respectVoiceOverDisabled` (neverFired — rule-3 negative)
- `testPP3673_emptyMessage_isNotPosted` (neverFired — rule-3 negative)
- `testPP3673_allAnnouncements_useAnnouncementNotificationType`

**`StatusAnnouncementTests.swift`** (19):
- `testPP3673_searchWithResults_announcesResultsForQuery`
- `testPP3673_searchNoResults_announcesNoResults`
- `testPP3673_searchFailed_announces`
- `testPP3673_searchRerun_announcesNewStatus`
- `testPP3673_searchAnnouncement_usesAnnouncementNotification`
- `testPP3673_borrowStarted_announces`
- `testPP3673_borrowSucceeded_announcesWithoutFocusShift`
- `testPP3673_borrowFailed_announces`
- `testPP3673_downloadStarted_announces`
- `testPP3673_downloadCompleted_announces`
- `testPP3673_downloadFailed_announces`
- `testPP3673_borrowLifecycle_producesSequentialAnnouncements`
- `testPP3673_errorMessage_announcedViaVoiceOver`
- `testPP3673_statusWithTitleAndMessage_isClear`
- `testPP3673_errorAnnouncement_doesNotMoveFocus`
- `testPP3673_quickSuccession_sameMessage_collapsed`
- `testPP3673_updatedStatus_replacesOld`
- `testPP3673_differentMessages_allAnnounced`
- `testPP3673_allAnnouncementTypes_areProgrammaticallyDeterminable`

(`testPP3673_voiceOverDisabled_noAnnouncements` in `StatusAnnouncementTests.swift`
creates no expectation and has no wait call at all — asserts synchronously
after firing with VoiceOver off; not in the wait-count, not touched.)

## UNMAPPED list

None. No test in scope exercises the debounce/transition-queue path
(`scheduleQueueDrain`/`drainNext`/`announcementTimeout` retry), so the
UNMAPPED bucket the dispatch anticipated for that path is empty for this
module. If Wave-3 adds an S12 inject-scheduler seam for
`TPPAccessibilityAnnouncementCenter`, these 39 KEPT tests remain correctly
classified (they never touch the debounce path) — only new transition-aware
tests, if added later, would land in CONVERT under an S12 seam.

## Bounded-await proof

N/A — zero `await …ForTesting()` calls or continuations were added. No test
method signatures were changed to `async`. No seam from the Wave-1 catalog
(S1–S11, or the pre-existing list) applies to `TPPAccessibilityAnnouncementCenter`,
and per the dispatch nuance the direct-postHandler waits are KEEP rather than
converted, so no bounded-await citation is applicable.

## Verification commands run

```bash
# per-file before/after counts (identical — no conversions)
grep -c 'wait(for:\|waitForExpectations\|fulfillment(of:' PalaceTests/Accessibility/AccessibilityAnnouncementCenterTests.swift   # 20
grep -c 'wait(for:\|waitForExpectations\|fulfillment(of:' PalaceTests/Accessibility/StatusAnnouncementTests.swift               # 19

# DELETE-bucket patterns — confirmed absent directory-wide
grep -rnE 'Thread\.sleep|usleep|asyncAfter.*fulfill|while.*Date\(\).*<' PalaceTests/Accessibility/   # (no output)

# confirm no debounce/transition path exercised by either file
grep -n 'notifyScreenTransition\|TPPAccessibilityScreenTransition\|isProcessingQueue\|scheduleQueueDrain\|drainNext' \
  PalaceTests/Accessibility/AccessibilityAnnouncementCenterTests.swift \
  PalaceTests/Accessibility/StatusAnnouncementTests.swift   # (no output)

# working tree confirmation — no edits made
git status --porcelain PalaceTests/Accessibility/   # (empty)
```

## Off-limits compliance

- No edits to `Palace/**` (production untouched).
- No edits to `PalaceTests/XCTestCase+drainMainQueue.swift`.
- No edits outside `PalaceTests/Accessibility/`.
- No unbounded `await` introduced (none introduced at all).
- No commit/push performed.

## Files changed

None.
