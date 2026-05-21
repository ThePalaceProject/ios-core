# Contract: Reader2-ReadState

**Bucket items:** P0 #1, #2, #3 (read-position correctness — EPUB/PDF reader)
**Priority:** P0 (read-position correctness — patron-visible regression risk)
**LOC estimate:** ~250–350 LOC (production + tests)

## Scope summary

Fix three read-position correctness defects in the Reader2 stack:

1. **`TPPLastReadPositionPoster.shouldStore` filter is too permissive** — `progression > 0` accepts any non-zero (including `0.0...ε`) progression, and the `cssSelector` escape-hatch posts even when progression is genuinely zero. Patrons report position jumping to chapter start on resume. We need a tighter predicate that (a) requires meaningful progression OR a CFI-anchored cssSelector, and (b) ignores the locator if the WKWebView hasn't actually rendered (i.e. `totalProgression == nil`).
2. **`TPPReadiumBookmark.init(dictionary:)` overwrites `progressWithinChapter` twice** — line 122 sets it from `readingOrderItemOffsetMilliseconds`, then line 125–127 unconditionally overwrites it from `chapterProgressKey`. Bookmarks restored from disk lose audio-style offsets when both keys are present (mixed-format dictionaries from older app versions).
3. **`TPPBaseReaderViewController` line 219–222 launches an unguarded `Task { await navigator.go(initialLocation) }`** — fires before WKWebView's first paint completes, racing the navigator's own initialization. Symptom: occasional "open EPUB, lands at chapter 1" instead of the saved location.

## Files in scope

- `Palace/Reader2/BusinessLogic/TPPLastReadPositionPoster.swift` (modify `shouldStore`)
- `Palace/Reader2/Bookmarks/TPPReadiumBookmark.swift` (fix ordering in `init(dictionary:)`, ~line 121–127)
- `Palace/Reader2/UI/TPPBaseReaderViewController.swift` (gate the initial `navigator.go(...)` Task — wait for navigator-ready signal or use a one-shot flag)
- `PalaceTests/Reader2/TPPLastReadPositionPosterTests.swift` (extend)
- `PalaceTests/Reader2/TPPReadiumBookmarkTests.swift` (extend)
- `PalaceTests/Reader2/TPPBaseReaderViewControllerInitialLocationTests.swift` (NEW — needs `pbxproj_add_swift.rb`)

## Files OFF-LIMITS

- `Palace/Reader2/Bookmarks/AudiobookBookmarkBusinessLogic.swift` — owned by **Audiobook-Position** bucket (item 4).
- `Palace/Audiobooks/AudiobookSessionManager.swift` — owned by **Audiobook-Position** bucket.
- Anything under `Palace/MyBooks/` — owned by **MyBooks-Borrow** / **Downloads-TaskMap** buckets.

## Public type / protocol / signature changes

- **None expected.** All three fixes are private-implementation changes; `shouldStore` is `private`, dictionary init is internal, `Task { navigator.go(...) }` is contained in `viewDidLoad`.
- If you must introduce a navigator-ready async signal, it should be a private `@MainActor` Bool flag + `CheckedContinuation`. Do NOT add new public methods to `TPPBaseReaderViewController`. If you find you need to expand the public surface, STOP and re-scope with integrator.

## DI seam updates

- `TPPLastReadPositionPoster` already takes `bookRegistryProvider` and `publication` via init — no new dependencies required.
- `TPPReadiumBookmark` is a value-ish NSObject; no DI seam.
- `TPPBaseReaderViewController` — if you need to inject a "ready" signal for testability, prefer a closure-default-parameter pattern (the codebase's standard — see `feedback_test_patterns_phase7`). Do NOT add a singleton.

## Test contracts (mutation-killing required where annotated)

### `TPPLastReadPositionPosterTests` (extend; **MUTATION KILLER required** — read position is critical-path-adjacent)

Add tests:
- `testShouldStore_progressionExactlyZero_doesNotStore` — locator with `totalProgression == 0.0`, no cssSelector → should NOT post.
- `testShouldStore_progressionNil_doesNotStore` — `totalProgression == nil` (locator without rendered page metrics) → should NOT post. **This is the bug that lets pre-render junk get persisted.**
- `testShouldStore_meaningfulProgression_stores` — `totalProgression == 0.45` → SHOULD post (regression guard).
- `testShouldStore_cssSelectorWithZeroProgression_behaviorSpecified` — pin the chosen behavior (whichever direction the implementer takes — accept-with-selector OR reject-zero-with-selector — but document and test it).
- Use a `MockBookRegistryProvider` spy that records `setLocation` calls, asserting count and identifier — NEVER hit `TPPBookRegistry.shared`.

Mutation surface: at minimum the implementer must run
```
python3 scripts/palace_mutate.py --file Palace/Reader2/BusinessLogic/TPPLastReadPositionPoster.swift --tests PalaceTests/Reader2/TPPLastReadPositionPosterTests --diff-only
```
and demonstrate ≥50% kill on the diff-only surface.

### `TPPReadiumBookmarkTests` (extend)

Add tests:
- `testInit_dictionary_withBothOffsetAndChapterProgress_prefersExplicitChapterProgress` — verify the new ordering (the implementer should document WHY chapter wins over readingOrderItemOffset and write the test to that contract).
- `testInit_dictionary_withOnlyReadingOrderItemOffset_preservesValue` — regression guard for the audio-style-offset case.
- `testInit_dictionary_withOnlyChapterProgress_preservesValue` — regression guard for the EPUB case.

### `TPPBaseReaderViewControllerInitialLocationTests` (NEW file)

This is hard to unit-test because `TPPBaseReaderViewController` is a UIViewController coupled to Readium's `Navigator`. **Two acceptable patterns:**

1. **Behavior-shape test:** instantiate a stub `Navigator` (protocol or test double) that records `go(to:)` invocations with a `CallLog`. Drive `loadViewIfNeeded()`, then assert `go(to:)` is NOT invoked synchronously, and IS invoked after a simulated ready signal. Use `XCTestExpectation` + the navigator stub's `goCalled` publisher — NEVER `sleep()`.
2. **Contract snapshot:** add `BaseReaderViewControllerContractTests` under `PalaceTests/Contract/` recording the call order `navigatorInit → readySignal → go(to: initialLocation)`. Pattern matches existing `BorrowOperationContractTests`.

The implementer picks one; whichever they pick, the test MUST kill the mutant where the ready-wait is removed and `Task { navigator.go(...) }` fires inline.

## Acceptance criteria

- `scripts/verify-pr.sh --quick` passes (build + tests + lint + a11y).
- All new/modified tests pass on a clean iPhone 16 Pro simulator (UDID `DF4A2A27-9888-429D-A749-2E157A049A37` per memory; harness auto-allocates).
- Mutation kill rate ≥50% on diff-scoped runs for `TPPLastReadPositionPoster.swift` and `TPPReadiumBookmark.swift`.
- No `.shared` reads in new test code. No force unwraps. No `XCTestExpectation` with hardcoded `sleep`.
- New Swift files added to BOTH `Palace` and `Palace-noDRM` targets via `ruby scripts/pbxproj_add_swift.rb`.
- Commit message contains `**Scope:**` + `**Not done:**` stanzas (hook will reject otherwise; ≥50 LOC bucket).
- No new user-facing copy (no localized strings added) — see memory `feedback_no_new_copy_without_design`.
- DO NOT commit. DO NOT push. Stage changes for the integrator.
