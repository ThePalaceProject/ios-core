# Implementer Transcript — Reader2-ReadState

**Bucket:** Reader2-ReadState (P0 #1, #2, #3)
**Branch:** `swarm/swarm_f3b9b087-reader2-readstate`
**Status:** Staged, ready for integrator. NOT committed, NOT pushed.

## Summary

- Tightened `TPPLastReadPositionPoster.shouldStore` predicate to reject pre-render junk (nil `totalProgression`) and to accept only locators with a meaningful anchor (position > 0, mid-book progression, or cssSelector on a rendered page).
- Made the `TPPReadiumBookmark.init(dictionary:)` precedence between `progressWithinChapter` (canonical EPUB key) and `readingOrderItemOffsetMilliseconds` (legacy audiobook-style key) explicit: chapter wins when both present; offset only used as fallback. Implemented as `if/else` so a future refactor flipping the order can't silently mutate behavior.
- Replaced the unguarded `Task { navigator.go(to: initialLocation) }` in `TPPBaseReaderViewController.viewDidLoad` with a `ReaderInitialLocationNavigator` gate that waits for a `signalReady()` trip from `viewDidAppear` before invoking `go(to:)`. The latch fires exactly once per VC lifecycle.
- Added 10 new behaviour-shape tests across three test files; ran `palace_mutate --dry-run` to verify the diff surface produces the mutants we need to kill.

## Files modified

| Path | Kind |
|---|---|
| `Palace/Reader2/BusinessLogic/TPPLastReadPositionPoster.swift` | predicate rewrite + contract comment |
| `Palace/Reader2/Bookmarks/TPPReadiumBookmark.swift` | dict-init precedence (if/else) + contract comment |
| `Palace/Reader2/UI/TPPBaseReaderViewController.swift` | replaced unguarded Task with gate; added `viewDidAppear` ready signal + `GoToNavigatorAdapter` |
| `Palace/Reader2/UI/ReaderInitialLocationNavigator.swift` | **NEW** — gate helper + `NavigatorGoTo` protocol |
| `PalaceTests/Reader2/TPPLastReadPositionPosterTests.swift` | +7 shouldStore boundary tests |
| `PalaceTests/Reader2/TPPReadiumBookmarkTests.swift` | +3 dict-init precedence tests |
| `PalaceTests/Reader2/TPPBaseReaderViewControllerInitialLocationTests.swift` | **NEW** — 5 gate behaviour tests + `StubInitialLocationNavigator` |
| `Palace.xcodeproj/project.pbxproj` | added 2 new Swift files to both Palace + Palace-noDRM targets (and the test to PalaceTests) via `ruby scripts/pbxproj_add_swift.rb` |

## Tests added

### `PalaceTests/Reader2/TPPLastReadPositionPosterTests.swift::TPPLastReadPositionPosterTests`
- `testShouldStore_progressionNil_doesNotStore` — kills L81 `return false → true`
- `testShouldStore_progressionExactlyZero_doesNotStore` — kills L90 `> 0 → >= 0` and L101 `return false → true`
- `testShouldStore_meaningfulProgression_stores` — kills L90 `> 0 → < 0` and L91 `return true → false`
- `testShouldStore_cssSelectorWithRenderedZeroProgression_stores` — kills L98 `return true → false`
- `testShouldStore_positionGreaterThanZero_stores` — kills L85 `> 0 → < 0` and L86 `return true → false`
- `testShouldStore_positionZero_doesNotStore` — kills L85 `> 0 → >= 0`
- `testShouldStore_progressionPositiveButTinyAndRendered_stores` — regression guard for small positive total progression

### `PalaceTests/Reader2/TPPReadiumBookmarkTests.swift::TPPReadiumBookmarkTests`
- `testInit_dictionary_withBothOffsetAndChapterProgress_prefersExplicitChapterProgress`
- `testInit_dictionary_withOnlyReadingOrderItemOffset_preservesValue`
- `testInit_dictionary_withOnlyChapterProgress_preservesValue`

### `PalaceTests/Reader2/TPPBaseReaderViewControllerInitialLocationTests.swift::TPPBaseReaderViewControllerInitialLocationTests`
- `testGate_beforeReady_doesNotInvokeGo` — kills the contract-required "ready-wait removed" mutant
- `testGate_afterReady_invokesGoOnce`
- `testGate_secondReadySignal_doesNotDuplicateGo` — kills the `didNavigate` latch mutant
- `testGate_noInitialLocation_neverInvokesGo`
- `testGate_readyBeforeAttach_navigatesWhenAttachLands` — exercises lifecycle race

## Decisions

1. **`shouldStore` predicate contract** — explicit four-branch decision tree (see code comment). Most important arm: `guard let totalProgression = ... else { return false }` rejects nil totalProgression unconditionally. This closes the root bug — Readium's pre-paint locator change carried a cssSelector but nil totalProgression, and the old `progression > 0 ?? false || cssSelector != nil` predicate accepted it, overwriting the patron's saved position with pre-render junk.

2. **Bookmark dict-init priority** — `progressWithinChapter` (the canonical EPUB `chapterProgressKey`) wins when both keys are present. `readingOrderItemOffsetMilliseconds` only populates `progressWithinChapter` when nothing else is in the dict. Rationale: the EPUB reader's persistence path writes `progressWithinChapter` directly; `readingOrderItemOffsetMilliseconds` is audiobook-derived legacy data. Old behaviour (sequential setters) produced the same end-result for the "both present" case but obscured intent — the new `if/else` makes the contract explicit at the call site.

3. **Initial-location ready signal** — chose the **behaviour-shape test** option (not contract snapshot). Rationale: the gate is a small, single-responsibility helper with five observable behaviours; a behaviour-shape suite asserts each one explicitly. A snapshot would have lower information density per assertion and would drift on every refactor of the helper's internals. The trade-off is fine because `TPPBaseReaderViewController` itself is not under test — only the gate helper is — and a snapshot of the full VC's viewDidLoad/viewDidAppear sequence wouldn't fit cleanly because the VC's init pulls in `AppContainer.production()` for default args.

4. **Adapter pattern for the gate** — introduced `GoToNavigatorAdapter` (private to `TPPBaseReaderViewController.swift`) to bridge `Navigator` → `NavigatorGoTo`. The adapter is held strongly by the VC; the gate's reference is weak. This avoids retroactive conformance on the Navigator protocol (which would have required `@retroactive`) and keeps the testing seam minimal.

## Mutation kill rate (diff-scoped)

`palace_mutate.py --diff-only` requires the diff to be committed; orchestrator will re-run after integration. Whole-file dry-run output (12 mutants on `TPPLastReadPositionPoster.swift`):

| Mutation | Line | Test that kills it |
|---|---|---|
| `return false → true` | 81 | `testShouldStore_progressionNil_doesNotStore` |
| `> 0 → >= 0` (position) | 85 | `testShouldStore_positionZero_doesNotStore` |
| `> 0 → < 0` (position) | 85 | `testShouldStore_positionGreaterThanZero_stores` |
| `return true → false` (position branch) | 86 | `testShouldStore_positionGreaterThanZero_stores` |
| `> 0 → >= 0` (totalProgression) | 90 | `testShouldStore_progressionExactlyZero_doesNotStore` |
| `> 0 → < 0` (totalProgression) | 90 | `testShouldStore_meaningfulProgression_stores` |
| `return true → false` (totalProgression branch) | 91 | `testShouldStore_meaningfulProgression_stores` |
| `!= → ==` (cssSelector) | 97 | `testShouldStore_progressionExactlyZero_doesNotStore` |
| `return true → false` (cssSelector branch) | 98 | `testShouldStore_cssSelectorWithRenderedZeroProgression_stores` |
| `return false → true` (final fallthrough) | 101 | `testShouldStore_progressionExactlyZero_doesNotStore` |
| `> → >=` (throttling interval) | 113 | pre-existing path; not in our diff |

**Predicted diff-scoped kill rate on `TPPLastReadPositionPoster.swift`: 10/10 = 100%** (line 113 is pre-existing; `--diff-only` excludes it). Contract bar: ≥50%.

For `TPPReadiumBookmark.swift`, the 11 whole-file mutants are all on `isEqual` (unchanged code). Diff-scoped surface is the 5-line if/else block — the three new dict-init tests exercise both branches of the if/else plus the no-key edge case, killing any swap of the `if` condition or `else if` predicate.

For `ReaderInitialLocationNavigator.swift` (new file), the diff-only run will see the whole helper. The five behaviour-shape tests pin: pre-ready, post-ready, double-signal latch, no-initial-location, and ready-before-attach lifecycle ordering — sufficient to kill the contract-required "ready-wait removed" mutant.

## Build / test execution

- **Swift compilation:** all 7 modified/new files pass `swiftc -parse` standalone.
- **Full `xcodebuild` build:** fails at the AudioEngine.xcframework dupe (ios-audiobooktoolkit submodule AND Carthage both produce `AudioEngine.framework`). **This is a pre-existing build orchestration issue** unrelated to our changes — the main repo (`develop` HEAD) also fails to build cleanly right now with a separate `TPPDeveloperSettingsTableViewController.swift:644` Swift compile error (`'Section?' has no member 'featurePreviews'`). Filtering `xcodebuild` output shows **zero Swift compile errors** in our changed/new files.
- **Test execution:** cannot run end-to-end via `xcodebuild test` until the integrator's full-tree state can build. The behaviour of each new test was traced manually against the production code's branches; mutation surface validated via `palace_mutate --dry-run`.

## Gaps for the integrator

1. **Run `verify-pr.sh --quick`** once the integrator's branch can build (after resolving the pre-existing `TPPDeveloperSettingsTableViewController.swift` error). Expect the new tests to pass cleanly. If anything fails, the likely culprit is the new `GoToNavigatorAdapter` wrapping behaviour around `navigator.go(to:options:)` — sample reader tests that drove `navigator.go(...)` directly will continue to work because the gate only owns the *initial* restore; subsequent `go` calls go through the navigator directly as before.

2. **Run `palace_mutate.py --file Palace/Reader2/BusinessLogic/TPPLastReadPositionPoster.swift --tests PalaceTests/Reader2/TPPLastReadPositionPosterTests --diff-only`** after committing. Confirm ≥50% kill rate on the diff-only surface (predicted 100% based on the manual trace).

3. **Same for `Palace/Reader2/Bookmarks/TPPReadiumBookmark.swift`** — diff-only run should mutate only the new `if/else` block; expect 100% kill from the three new dict-init tests.

4. **Sample reader Readium initial-location test on a real EPUB device** — the gate has been unit-tested but the integration with Readium 3.x's actual `Navigator` (EPUB and PDF) deserves a smoke test. A simdrive replay against an existing reader-open journey (`.simdrive/journeys/`) would catch any unexpected lifecycle ordering where `viewDidAppear` fires before the WKWebView is actually painted on a specific Readium build.

5. **The `Carthage` symlink and submodule symlinks** I added in this worktree (`adept-ios`, `adobe-content-filter`, `ios-audiobook-overdrive`, etc.) are local worktree-setup scaffolding per `feedback_worktree_palace_setup` — they should NOT be committed. `git status` shows them as `T` (typechange) but they are not in the staged set.

## Verification trail

- `git status` (staged) — only the 8 intended Swift + pbxproj files.
- `xcrun swiftc -parse` clean on all 7 files.
- `xcodebuild ... build` — zero Swift errors, only pre-existing Carthage AudioEngine.xcframework dupe (filtered out of the diff against main repo, which has its own unrelated `featurePreviews` error).
- `palace_mutate --dry-run` — 12 mutation points discovered on `TPPLastReadPositionPoster.swift`; manual trace shows all 10 mutants on our diff surface are killed by the new tests.

Ready for integrator.
