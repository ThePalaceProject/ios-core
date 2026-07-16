# Fix-contract — First-open book-action button flicker (BUG B)

**Branch:** `fix/audiobook-first-open-flicker` (PR 2 of the folded A/B effort; own PR per product-owner direction 2026-07-16)
**Area:** `Book` + `MyBooks` (book-action button state). See `docs/architecture/areas/mybooks/verification-checklist.md`.
**Symptom:** on first open (worst right after borrowing an audiobook), action buttons toggle/flip label (Cancel ↔ Download ↔ Listen) and the screen flashes a state then reverts. Observed live in the BUG-A repro: borrow → immediately "Listen" with no visible Download step, i.e. the early-ready promotion drives a visible label bounce.

## Root cause (confirmed against current source)

Three compounding sources of state churn land inside one ~50 ms window on first open:

1. **Throttle replays leading + trailing.** `stableButtonState` is built by `Publishers.CombineLatest4(...).removeDuplicates().throttle(50ms, scheduler: RunLoop.main, latest: true)` in both `BookCellModel.swift:366-374` and `BookDetailViewModel.swift:419-427`. `throttle(latest:true)` emits the leading value immediately AND the trailing value at window close. During the first-open burst (`unregistered → downloadNeeded → downloading → downloadSuccessful`), multiple non-duplicate button-sets enter one window, so the button lands on an intermediate label then snaps to the final one — animated by `BookButtonsView` (`.accessibleAnimation(value: filteredButtonTypes)`) so the flip is visible.
2. **Optimistic vs. authoritative race.** `startDownloadAfterAuth` sets `bookState = .downloading` (→ Cancel) at `BookDetailViewModel.swift:820` before the registry reports `.downloadNeeded` (→ Download/Read); the registry then reports `.downloading`. Net Cancel → Download → Cancel flip-flop in the borrow→download handoff.
3. **LCP early `.downloadSuccessful` promotion.** A freshly-borrowed LCP audiobook flips to `.downloadSuccessful` (→ Listen) the instant the license lands (`Palace/MyBooks/LCPFulfillmentHandler.swift` progress/complete callbacks), while content keeps downloading — so Listen can appear, then a later `.downloading`-flavored read reverts it.

## Proposed fix direction (MUST be validated by architect — state-timing fixes are high-risk)

- **Collapse transient intermediate button-sets** so a value that is immediately superseded within the settling window never renders. Candidate: replace the leading+trailing `throttle` with a scheme that emits only the *settled* value for a rapid burst but stays immediate when there is no burst (e.g. emit leading, then suppress a trailing that differs only via a known transient, OR a short debounce guarded so the very first idle emission is not delayed). Exact mechanism is the architect's call — the acceptance test is behavioral, not mechanism-specific.
- **Do not let the optimistic `.downloading` (`:820`) render a button-set that the authoritative stream will immediately contradict.** Options: gate the optimistic write behind the processing-spinner (which already masks the button set) rather than a full state flip, or reconcile so `.downloadNeeded` arriving right after the optimistic `.downloading` does not bounce the label.
- Keep the LCP early-ready semantics (Listen becoming available is correct product behavior) — smooth the *transition*, don't remove the promotion.

## Scope (in)
- `Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift` — `setupStableButtonState` (`:365-375`).
- `Palace/Book/UI/BookDetail/BookDetailViewModel.swift` — `setupStableButtonState` (`:416-428`) + the optimistic write in `startDownloadAfterAuth` (`:839` — architect W1 corrected the cite from `:820`).
- **(architect F1) Injectable scheduler seam.** Both pipelines hardcode `scheduler: RunLoop.main` (`BookCellModel.swift:373`, `BookDetailViewModel.swift:426`) with no injection point, so the burst-coalescing test can't be authored deterministically. Add an injected `scheduler` (default `RunLoop.main`, tests pass a virtual/immediate scheduler) to both — required for Test 1 + criterion #1.
- **(architect F2) LCP Listen↔Cancel revert home — a monotonicity clamp.** Source #3 (the LCP early `.downloadSuccessful` → Listen, then a later `.downloading`-flavored read reverts to Cancel) lands SECONDS apart, OUTSIDE the 50ms throttle window, so the throttle fix alone cannot absorb it. Pin a monotonicity guard on the audiobook button state: once a book has surfaced `.downloadSuccessful`/Listen in a session, a transient re-read of a "still-downloading" state must NOT revert the label — mirror the `max(...)` progress-monotonicity pattern already used in `BorrowReducer.swift:181`. Home it in-cluster (the `computeButtonState`/`stableButtonState` layer in `BookCellModel`/`BookDetailViewModel`), NOT in `LCPFulfillmentHandler` (out of scope). Add a 4th test driving the Listen→(seconds later).downloading revert and asserting Listen holds.

## Scope (out)
- `BookButtonMapper` / `BookButtonState` derivation logic — the mapping is correct; the problem is *timing*, not the map. Do NOT change which buttons a given state yields.
- The latent duplicate `BookButtonState.init?` (`:146`) — no live caller; leave unless it becomes load-bearing (note only).
- Animations in `BookButtonsView` — the flicker is upstream state churn; do not paper over it by removing the animation (that would just hide, not fix).
- BUG A (audiobook open hang) — PR 1, separate branch.

## Verification criteria
- A test drives the first-open registry burst (`unregistered → downloadNeeded → downloading → downloadSuccessful` emitted within one throttle window on the test scheduler) and asserts `stableButtonState` emits only the START and the SETTLED value — no intermediate `.downloadInProgress`/`.downloadNeeded` flip in between. Use a controllable scheduler (not RunLoop.main wall-clock).
- Mutation kill ≥ 80% diff-only on the changed `setupStableButtonState` and the optimistic-write reconcile.
- Existing button-state tests stay green (`BookCellModel*`, `BookDetailViewModel*`, `BorrowReducer*`).
- `scripts/verify-pr.sh --quick` PASS.

## Tests required (TDD)
1. **Burst-coalescing test** (the core guard): feed the 4-state first-open burst on the INJECTED virtual scheduler; assert `stableButtonState` emits only START and SETTLED — no intermediate label. Needs the F1 scheduler seam.
2. **No-burst responsiveness test:** a single state change still updates `stableButtonState` promptly on the virtual scheduler (guards against over-debouncing lagging legitimate fast transitions — the key over-correction risk).
3. **Optimistic-reconcile test:** simulate `startDownloadAfterAuth` optimistic `.downloading` (`:839`) immediately followed by registry `.downloadNeeded`; assert the button does not bounce Cancel→Download→Cancel.
4. **(architect F2) LCP monotonicity test:** drive Listen (`.downloadSuccessful`) then, seconds later (a separate scheduler tick, OUTSIDE any throttle window), a `.downloading` re-read; assert the label HOLDS on Listen (the monotonicity clamp), not reverting to Cancel. This is the contract's headline symptom and the throttle fix cannot cover it.

## Implementation SoD review round 1 (2026-07-16) — narrowed after qa + blast findings

The round-1 impl was a broad rank-based monotonicity clamp (held ANY backward move). qa + blast_radius (both request-changes) found it too broad:
- **blast:** `DiskBudgetManager` LRU eviction sets `.downloadSuccessful → .downloadNeeded` DIRECTLY (`DiskBudgetManager.swift:168`); the broad clamp stranded a stale Listen on evicted content. And no transient flicker source even produces `success → needed`, so clamping it gave zero benefit. (Also found: SAML login-cancel sets `.downloading → .downloadNeeded`, `MyBooksDownloadCenter.swift:1254` — another real backward move.)
- **qa:** the reset lived in the same branch that unconditionally passed through, so the reset line was untested (no test drove a post-reset progress re-read).
- **blast:** the clamp made `computeButtonState` side-effecting → perturbed `validateStateConsistency`.

**RESOLVED — narrowed to a provably-safe latch** (`clampListenAgainstTransientDownloading`): hold Listen ONLY against a transient `.downloadSuccessful → .downloading` re-read (the LCP early-ready artifact — *never* a real transition, since re-download always routes through `.downloadNeeded`). EVERY other state (incl. the real `success → needed` eviction and `downloading → needed` cancel) drops the latch and passes through. Moved into the pipeline (`setupStableButtonState` map) so `computeButtonState`/init/validate stay pure. Tests now prove: eviction shows Download (not stranded Listen), return/fail → re-download drops the latch (post-reset progress read), `.downloading → .downloadNeeded` not clamped. 10 tests, both models.

**Scope narrowed accordingly:** #3 (LCP Listen↔Cancel) is fixed; **#2 (optimistic `.downloading`↔`.downloadNeeded`)** joins **#1 (throttle forward-flip)** in Not-done — both are timing artifacts a state-only latch cannot separate from a real cancel (they need the deferred coalescing/scheduler mechanism).

## Clamp-reset hygiene (architect round-2 F2 follow-up) — REQUIRED

The Listen monotonicity clamp has the SAME stuck-state failure mode documented for the stuck-Cancel bug (`BookCellModel.swift:385-391`): if it never resets, a returned/failed book stays stuck on Listen. So the clamp MUST reset (clear the "has surfaced Listen" latch) on: **return / cancel / delete / `.unregistered`** AND on a **terminal download error** (`.downloadFailed`). Add a yield-on-failure assertion in the tests (drive Listen → return → assert the label yields, not stuck). The clamp + its reset + Test 4 must exist in BOTH `BookCellModel` and `BookDetailViewModel` (acceptance requires both the My Books cell and the half-sheet).

**W1 (line cite):** anchor the optimistic write on the SYMBOL `startDownloadAfterAuth` (`bookState = .downloading`, first line of that method) — it's `:820` on plain develop, `:839` only on the BUG-A-stacked tree. Don't rely on the absolute line.

## Interaction with BUG A (architect W2)
BUG A touches `BookDetailViewModel.swift:690-708` (the `.read/.listen` handleAction case) + a new `audiobookSession` init seam; BUG B touches `:416-428` (setupStableButtonState) + `:839` (optimistic write). Disjoint → merge-clean. Stack BUG B on BUG A's branch (or rebase after A lands) and re-run `AudiobookOpenStateRaceTests` + the BUG A suite to confirm no regression.

## Acceptance
- First-open button shows at most one transition (initial → settled), no visible revert, on both the BookDetail half-sheet and the My Books cell.
- Normal (non-first-open) transitions remain immediate.
- All verification criteria pass; regression tests green; mutation ≥ 80% diff-only.
- Re-verify in sim against the BUG-A repro flow (borrow audiobook, watch the button settle cleanly).
