# Swarm Outcome — `swarm_f3b9b087` — 3.2.0 review-driven quality pass

**Status:** complete
**Created:** 2026-05-21T03:25:00Z
**Completed:** 2026-05-21T04:32:00Z
**Total duration:** ~67 minutes (incl. triage, dispatch, integration, review, promote)

## ForgeOS
- Project: `proj_87884c17`
- Initiative: `init_a04c4a2c` — "3.2.0 review-driven quality pass — App Store + Crashlytics findings"
- Changeset: `cs_34dc66ba` — risk score 30/100 ("startup" preset)
- Gates (all passed):
  - `review` (architect) → `rev_8cd9d48c` approved (4 warnings, 3 addressed)
  - `testing` (qa_test) → `rev_1d39b5c0` approved (3 warnings, addressed via integrator follow-up)
  - `release` → no role/evidence required, promoted

## Modules touched (4 buckets, 4 parallel implementers)
| Bucket | Items | Impl. commit | Files | Critical path? |
|---|---|---|---|---|
| Reader2-ReadState | P0 #1, #2, #3 | `db69f090a` | 3 prod + 3 test + pbxproj | adjacent |
| Audiobook-Position | P0 #4, #5, #10 | `520573305` | 2 prod + 1 new + 3 test + pbxproj | YES |
| MyBooks-Borrow | P2 #7, #8, #12 | `08bc3bcd6` | 1 prod + 4 test + 2 snapshots | YES |
| Notifications-OPDS-Errors | P1+P2 #6, #9, #11 | `10aa2dfc4` | 3 prod + 3 test | no |

## Diff summary
- 39 files changed, +4,007 insertions, -136 deletions
- 12 production files modified (Swift)
- ~77 new tests across 13 test files
- 2 contract snapshots (1 regenerated, 1 new)
- 8 swarm scaffolding/transcript files
- 2 merged pending PRs (PR #978 PP-4421, PR #975 account state-machine) preserved as merge-base commits

## Outcomes by App Store complaint / Crashlytics non-fatal

| Complaint | Crashlytics signal closed | Fix location | Status |
|---|---|---|---|
| EPUB position not saved | "Error posting annotation (902)" 151,841 events REGRESSED | `TPPLastReadPositionPoster.shouldStore` tighter predicate | ✅ |
| Bookmark loses chapter progression | "Got bookmark for a different book (501)" 4,439 events REGRESSED | `TPPReadiumBookmark.init` precedence fix | ✅ |
| EPUB page-turn freeze / random page | `Failed to determine navigation direction for scroll` fatal (25 events) | New `ReaderInitialLocationNavigator` gate | ✅ |
| Audiobook restarts at chapter 1 | (no single Crashlytics signal — review-driven) | `isAtBeginning` strict-zero + `getValidLocalPosition` fallback | ✅ |
| Audiobook silent recovery failure | "Audiobook failed to open (401)" 14,291 events | `getValidLocalPosition` non-fatal + bookmark fallback | ✅ |
| Chapter count wrong (182 vs 56) | (no Crashlytics — review-driven) | `ChapterTOCNormalizer` collapse heuristic | ✅ |
| Borrow failed / unknown network | "Network request failed (912)" 35,543 events REGRESSED | `BorrowAuthErrorDecision.routeToReauth` for 401-no-problem-doc | ✅ |
| Borrow button clocks indefinitely | (review-driven) | `BorrowAuthErrorDecision.suppressAndClearSpinner` | ✅ |
| Download stuck "no taskInfo for task" | "No taskInfo for task N (907)" 3k events REGRESSED | Verified safe via call-site audit; 3 regression-guard tests added | ✅ (no prod change) |
| No hold-ready push notification | "Error retrieving user profile document (902+914)" 5,290 events | `NotificationService` FCM retry on auth-state change | ✅ |
| Raw "Invalid OPDS feed" error | "NYPLOPDSFeed: Failed to parse data as XML (604)" 30,177 events | `PalaceError.opdsFeedInvalid` placeholder NSLocalizedString | ⚠️ REQUIRES DESIGN APPROVAL |
| Audio stops on background | (review-driven) | `UIBackgroundModes` audio verified already present | ✅ (no change needed) |

## Risks / follow-up

- **Design approval required** for `opds.error.feed_invalid` localized copy before 3.2.0 release. Placeholder English string in PR is "We can't load your library catalog right now — try again in a moment." Marked with `TODO(design)` comment.
- **Local mutation testing deferred** — Carthage/Build/iOS has 0-byte framework stubs (pre-existing across all worktrees per memory `feedback_worktree_palace_setup`). CI on push runs full test suite with proper Carthage bootstrap.
- **Phase 7 MBDC borrow-path siblings audit** (DownloadStartDispatcher / DownloadAuthRetryHandler / BookButtonMapper) remains OUT OF SCOPE per memory `phase7_borrow_path_regressions_2026_05_14`. Track as separate ticket.

## Architectural wins

- **Pure-policy extraction in audiobook bucket:** `AudiobookPositionPolicy.swift` extracts 4 pure policies (`BeginningPositionPolicy`, `AudiobookPositionPolicy` validator, `ChapterChangeDetector`, `ChapterTOCNormalizer`) + `AudiobookPositionLogging` protocol. Tightens mutation surface on critical-path audiobook logic without forcing tests to construct PalaceAudiobookToolkit types.
- **Internal `BorrowAuthErrorDecision` enum:** 3-case decision return type for `handleBorrowAuthErrorIfNeeded` keeps the suppress-vs-show signal threaded through callers without expanding public API.
- **No new singletons.** `NotificationService` retry subscribes to existing `accountsManager` publisher via constructor injection.

## Caveats addressed by integrator
- 3 lint violations introduced by implementer-added tests, fixed via `6bf40268f`
- 4 banned-pattern tests (constant-equals-literal + reflexive identity) in `NotificationServiceTokenTests` flagged by both reviewers, deleted via `30ce5b241`

## Integration commits
```
30ce5b241 [swarm_f3b9b087] integrator: address reviewer warnings — drop banned-pattern tests
7f801d2d9 [swarm_f3b9b087] manifest: record ForgeOS changeset_id + initiative_id
6bf40268f [swarm_f3b9b087] integrator: clean 3 lint violations introduced by swarm tests
46a4fc3e3 [swarm_f3b9b087] merge notifications-opds bucket into orchestrator
ab9206bfc [swarm_f3b9b087] merge mybooks-borrow bucket into orchestrator
e35974071 [swarm_f3b9b087] merge audiobook-position bucket into orchestrator
dcdf15da8 [swarm_f3b9b087] merge reader2-readstate bucket into orchestrator
```
