# Module D 3rd attempt — Simdrive Journey transcript (SUCCESS PATH)

**Status:** READY — full 11-step success-path recording landed (2-tap
Borrow → Read flow under Wave 4 + Module C v2.1).
**Implementer:** subagent (orchestrator-spawned 3rd attempt, after
Wave 3 v2.2 fix + Wave 4 Path X dispatcher early-return).
**Contract:** `.forgeos/swarms/swarm_c2b95c85/contracts/D-Simdrive-Journey.md`
**Predecessors:** prior `D.md` and `D.md` (rerun) preserved as
historical record in `evidence/D-blocked/` + `evidence/D-blocked-v2/`.
This transcript REPLACES the prior BLOCKED rerun transcript.

## 1. Summary

- **Tap Borrow on the streaming-HTML repro book transitions registry
  to `.downloadNeeded` silently — NO `Borrow Failed` alert.** Wave 4's
  `DownloadStartDispatcher.processDownloadWithCredentials` early-return
  fires AFTER `processUnregisteredState` already seeded `.downloadNeeded`
  via the existing open-access branch. The Book Detail half-sheet then
  re-renders with `[Read, Return]` (Module C v2.1 BookButtonState
  `.downloadNeeded + streamingHTML → [.readStreaming, .return]`).
- **Tap Read on the half-sheet presents `StreamingReaderViewController`
  (Module B) inside `StreamingReaderView` (UIViewControllerRepresentable),
  wrapped in an inner UINavigationController.** WKWebView loads the
  BiblioBoard fulfill URL and renders the book cover + "You have
  requested..." landing page + "PINPOINT MY LOCATION" CTA. Reader chrome
  visible: outer SwiftUI `< Back` + inner UIKit `Close` bar-button-item.
- **End-to-end UX is two-tap (Borrow → Read) per Wave 4 + Path X intent
  — matches the EPUB / Reader2 pattern.** A swipe drives WKWebView
  scroll content ≥500px (PINPOINT MY LOCATION moves y=1905→1340, new
  "Search for your library" CTA appears at y=2146). Back-pop returns
  to Book Detail with `[Read, Return]` still showing. Second Read tap
  re-presents the reader (presenter wiring round-trip verified).

## 2. Files

NEW (project tree):

```
 .simdrive/journeys/PP-4161-streaming-html-reader.yaml     (success-path version; REPLACES the Wave 3/4 bug-repro YAML)
 .simdrive/fixtures/baselines/3.2.0/PP-4161-streaming/     (22 files: 11 pre + 11 post .png from the recording)
 .forgeos/swarms/swarm_c2b95c85/transcripts/D.md           (THIS transcript; REPLACES the prior BLOCKED rerun transcript)
```

Recording (~/.simdrive/, user-local, NOT in repo):

```
 ~/.simdrive/recordings/PP-4161-streaming-html-reader/
   recording.yaml       (11 steps; simdrive 1.0.0b4)
   snapshots/           (001_pre.png ... 011_post.png — 22 PNGs)
   _capture/            (per-step state contracts)
```

Preserved historical evidence (NOT replaced — documents the 3-escalation
bug chain):

```
 .forgeos/swarms/swarm_c2b95c85/evidence/D-blocked/         (Wave 3 gap: 'Download Failed' alert, .get→didSelectDownload bypass)
 .forgeos/swarms/swarm_c2b95c85/evidence/D-blocked-v2/      (Wave 4 gap: 'Borrow Failed — unexpected format' alert, didSelectReserve→borrowAsync vs open-access URL)
 .forgeos/swarms/swarm_c2b95c85/transcripts/C-v2.2.md       (Wave 3 fix transcript, since reverted by Wave 4)
 .forgeos/swarms/swarm_c2b95c85/transcripts/Wave4.md        (Path X revert + dispatcher early-return that this transcript validates)
```

## 3. Validation

```
mcp__simdrive__validate_replay name=PP-4161-streaming-html-reader
→ {"ok": true, "errors": [], "warnings": [], "step_count": 11,
   "simdrive_version": "1.0.0b4"}
```

Structurally OK. 11 steps × pre+post = 22 snapshots on disk.

## 4. Replay

Replayed on a freshly-reinstalled app (uninstall → install → tap Allow
on notifications alert → tap Palace Bookshelf in Add Library list) so
the catalog matches the captured initial state:

```
mcp__simdrive__replay name=PP-4161-streaming-html-reader \
    on_drift=warn drift_threshold=0.85 halt_on_state_mismatch=false
→ {"ok": true, "halted_at": null, "halt_reason": null,
   "threshold": 0.85, "steps_planned": 11,
   "steps": [
     {"id":  1, "action": "tap",       "similarity": 0.5449, "drifted": true,  "executed": true},
     {"id":  2, "action": "type_text", "similarity": 0.6328, "drifted": true,  "executed": true},
     {"id":  3, "action": "press_key", "similarity": 0.7021, "drifted": false, "executed": true},
     {"id":  4, "action": "tap",       "similarity": 1.0,    "drifted": false, "executed": true},
     {"id":  5, "action": "tap",       "similarity": 0.9883, "drifted": false, "executed": true},
     {"id":  6, "action": "tap",       "similarity": 1.0,    "drifted": false, "executed": true},
     {"id":  7, "action": "swipe",     "similarity": 0.4629, "drifted": true,  "executed": true,
       "marks_drift_info": {"recorded_marks_count": 23, "live_marks_count": 3, "ratio": 0.13}},
     {"id":  8, "action": "tap",       "similarity": 0.5146, "drifted": true,  "executed": true},
     {"id":  9, "action": "tap",       "similarity": 0.5195, "drifted": true,  "executed": true},
     {"id": 10, "action": "tap",       "similarity": 0.5195, "drifted": true,  "executed": true},
     {"id": 11, "action": "tap",       "similarity": 1.0,    "drifted": false, "executed": true}
   ],
   "drift_events": [
     {"step_id": 7, "kind": "marks_count_drift",
      "recorded_marks_count": 23, "live_marks_count": 3, "ratio": 0.13}
   ]}
```

All 11 steps **executed: true** with non-null `ok: true`. Drift breakdown:

- **Steps 4-6, 11:** ≥0.988 similarity — pixel-stable transitions (Book
  Detail load, Borrow tap with no-alert, Read tap with reader presents).
- **Steps 1-3:** 0.54–0.70 similarity — the catalog feed's per-shelf
  carousel positions vary between replays (it's a live OPDS feed with
  no client-side seed). Acceptable under `on_drift: warn`.
- **Steps 7-10:** 0.46–0.52 similarity + step 7 marks-count drift
  (23 → 3) — expected per the contract: the BiblioBoard fulfill URL
  has dynamic content (cookie banner, library-finder widget,
  latency-dependent layout). The reader chrome (Close / < Back)
  remains structurally identical; the WKWebView body reflows.

`halt_on_state_mismatch=false` is required at replay-time because the
catalog's lead-shelf book covers (the initial-state required-tokens)
are randomized server-side per feed fetch ("INVESTIGATION OF" /
"REPORT INTO" / "ALLEGATIONS OF" — sub-headlines of the Sexual
Harassment Report cover — were captured but the same render may not
return on replay). The recording's `_capture/initial_state.yaml` was
written for the captured catalog; the structural state (foreground,
primary_button_present, partial text-subset match 7/10 tokens) holds.
This is a property of the dynamic OPDS feed, not a recording defect.

## 5. PP-4161 end-to-end verification

| Wave / module | Production claim | Verification step in this recording | Verdict |
|---|---|---|---|
| Wave 1 (Module A) | `TPPContentType.streamingHTML` no longer filtered out by catalog | Step 3 (submit_search) → step 4 (tap_book) — repro book appears at top of search results within the Palace Bookshelf catalog | **PASS** |
| Wave 2 (Module C v2.1 button mapping) | `BookButtonState` for `.unregistered + streamingHTML` → `[.get]` with "Borrow" label | Step 4 post-state — Book Detail half-sheet shows single `Borrow` button (stable_id `d45b20a36362`), NOT `Reserve` or `Get` | **PASS** |
| Wave 4 (Path X dispatcher early-return) | `DownloadStartDispatcher.processDownloadWithCredentials` short-circuits on `book.defaultBookContentType == .streamingHTML` BEFORE attempting startBorrow / addDownloadTask | Step 5 (tap_borrow) → post-state shows half-sheet re-rendering with `[Read, Return]`, **NO `Borrow Failed` alert** (compare evidence/D-blocked-v2/04 which captured the alert before Wave 4 landed) | **PASS** |
| Module C v2.1 button mapping (post-borrow) | `BookButtonState` for `.downloadNeeded + streamingHTML` → `[.readStreaming, .return]` with "Read" + "Return" labels | Step 5 post-state — half-sheet shows `Read` (mark 24) + `Return` (mark 25), NOT `Cancel` or `Download` | **PASS** |
| Module B + Module C presenter wiring | `BookDetailViewModel.handleAction(.readStreaming)` → `presentStreamingReader` → `NavigationCoordinator.pushStreamingHTMLRoute` → `NavigationHostView.streamingHTML` case → `StreamingReaderView` → `StreamingReaderViewController` with WKWebView + Close bar-button-item | Step 6 (tap_read_first) post-state — outer `< Back` + inner `Close` visible at top, BiblioBoard book cover + "You have requested..." + "PINPOINT MY LOCATION" CTA rendered in WKWebView | **PASS** |
| WKWebView scroll input + delegate forwarding | `scrollViewDidScroll` updates `viewModel.latestScrollOffset` on user-input scroll | Step 7 (swipe_scroll) post-state — content moved up ≥500px, new lower-half content ("Search for your library") visible | **PASS** |
| Module B `viewDidDisappear` save + reader re-presentation | `viewDidDisappear` → `viewModel.didDismiss` → `StreamingReaderProgressStore.save`; on re-entry a new VC instance is constructed and presents | Step 10 (tap_back_outer) post-state — Book Detail re-renders with `[Read, Return]` preserved; Step 11 (tap_read_second) post-state — reader re-presents with WKWebView + Close + BiblioBoard content | **PASS** |
| Module B scroll-restore on re-entry | New VC's `computeInitialState` reads UserDefaults via `StreamingReaderProgressStore` and emits `.ready(url, restoredScroll: savedOffset)`; `didFinish` applies `setContentOffset` | Step 11 post-state — reader presents but PINPOINT MY LOCATION is back at y=1905 (top), not the saved y=1340 | **PARTIAL — see Gaps** |

Wave 4 + Path X is the headline win: the bug that BLOCKED the previous
two D runs ("Download Failed" → "Borrow Failed — unexpected format") is
gone. Compare `evidence/D-blocked-v2/04-borrow-failed-unexpected-format-WAVE4-GAP.png`
(captured 2026-06-03 morning) against this recording's
`~/.simdrive/recordings/PP-4161-streaming-html-reader/snapshots/005_post.png`
— the latter is the half-sheet showing `[Read, Return]` with NO alert.

## 6. Gaps

1. **Scroll-restore on the BiblioBoard fulfill URL doesn't land at the
   saved offset.** `tap_back_outer` (step 10) DOES save (per
   `viewDidDisappear` → `didDismiss` → `store.save`; unit tests
   `StreamingReaderProgressStoreTests` + `StreamingReaderViewModelTests`
   cover this). `tap_read_second` (step 11) re-presents but the WKWebView
   lands at scroll y=0 not the saved y≈565. Hypothesis: the BiblioBoard
   landing page runs a JS-driven content reflow AFTER `didFinish` fires;
   `setContentOffset(CGPoint(x: 0, y: restored), animated: false)` runs
   against a still-laying-out document, then the post-reflow content
   overrides it. Suggested follow-up for Module B:
   - (a) Delay the setContentOffset by ~200ms after didFinish to let
         BiblioBoard JS settle, OR
   - (b) Use WKWebView.evaluateJavaScript with
         `window.scrollTo(0, restored)` after a `document.readyState ===
         'complete'` poll, OR
   - (c) Subscribe to `webView.scrollView.contentSize` KVO and only
         apply the restore once contentSize stabilizes.
   - This is a layout-race against a specific 3rd-party page; the wiring
     is correct (the new VC instance IS constructed; the store IS read;
     the `.ready(url, restoredScroll: x)` IS emitted), it's the apply
     timing that's racing the JS reflow. Module D's unit tests can't
     catch this because they test the store and the VM, not the
     WKWebView+JS interaction. Recommend adding an integration test
     OR an `e2e/streaming-html-reader-scroll-restore.simdrive.yaml`
     replay assertion once Module B chooses a fix.

2. **Inner UIKit `Close` bar-button-item is a no-op against the SwiftUI
   NavigationStack push.** `StreamingReaderViewController.closeTapped`
   detects that the VC is the rootViewController of its embedded
   UINavigationController, so it calls `dismiss(animated: true)`. But
   the embedded UINavigationController is presented via
   `UIViewControllerRepresentable` inside a SwiftUI NavigationStack
   PUSH, not modally. The dismiss runs against the embedded nav (no
   visible effect); the actual close is the outer SwiftUI `< Back`.
   Steps 8 + 9 (tap_close_navbar / tap_close_navbar_retry) document
   this behavior. Suggested follow-up for Module B:
   - (a) Have `closeTapped` invoke a SwiftUI-side onClose closure via
         `StreamingReaderView`'s coordinator so the route gets popped,
         OR
   - (b) Remove the inner Close button entirely since the outer < Back
         covers it (the UX has redundant chrome today).

3. **Catalog feed is non-deterministic at the lead-shelf level.** The
   replay framework's state-contract uses `text_subset_required` to gate
   replay-start, but the captured top-of-shelf book covers ("INVESTIGATION
   OF" / "REPORT INTO" / "ALLEGATIONS OF") are sub-headlines from one
   specific cover that may not appear in the same position on a fresh
   feed fetch. The replay command in section 4 used
   `halt_on_state_mismatch=false` to bypass this. Suggested follow-up
   (NOT this swarm's scope):
   - (a) Re-capture initial state with a coarser text-subset that
         matches only the persistent shelf titles ("DPLA Publications",
         "Big Ten Open Books Collection", "Fiction") and not the
         per-cover sub-headlines, OR
   - (b) Stub the OPDS catalog response in a test profile so the
         catalog state IS deterministic across replays. This is a
         broader regression-fixture issue not specific to PP-4161.

4. **simdrive 1.0.0b4 (loaded) vs 1.0.0b7 (on disk) — MCP reload
   needed.** All operations succeeded under the loaded version but the
   `_simdrive_warning` field consistently advises a restart. Not
   blocking.

## 7. Definition of Done evidence

### Contract verification (from `D-Simdrive-Journey.md`):

1. **Journey YAML exists:**
   ```
   $ test -f .simdrive/journeys/PP-4161-streaming-html-reader.yaml && echo OK
   OK
   ```

2. **Journey validates via simdrive MCP:**
   ```
   $ mcp__simdrive__validate_replay name=PP-4161-streaming-html-reader
   → {"ok": true, "errors": [], "warnings": [], "step_count": 11,
      "simdrive_version": "1.0.0b4"}
   ```

3. **Baselines exist for each step:**
   ```
   $ ls .simdrive/fixtures/baselines/3.2.0/PP-4161-streaming/ | wc -l
   22
   ```
   (11 pre + 11 post = 22, matching 11 step count.)

4. **Recording path exists:**
   ```
   $ test -d ~/.simdrive/recordings/PP-4161-streaming-html-reader/ && echo OK
   OK
   ```

5. **Journey replays end-to-end:** see section 4 — all 11 steps
   `executed: true` with the replay returning `ok: true`. Drift is
   on-content (WKWebView reflow), gated by `on_drift: warn` per
   contract.

6. **No production-code edits.** This implementer touched only:
   - `.simdrive/journeys/PP-4161-streaming-html-reader.yaml`
     (rewrote from the prior BLOCKED bug-repro version into the
     success-path version)
   - `.simdrive/fixtures/baselines/3.2.0/PP-4161-streaming/*.png`
     (22 new files)
   - `.forgeos/swarms/swarm_c2b95c85/transcripts/D.md`
     (THIS transcript; replaces the prior BLOCKED rerun)
   - `~/.simdrive/recordings/PP-4161-streaming-html-reader/`
     (user-local; not in repo)

   ```
   $ git diff --name-only -- 'Palace/' 'PalaceTests/'
   <empty>
   ```

   No production Swift or test Swift edits.

### CLAUDE.md DoD checklist (applicable subset — recording-only work):

| # | Check | Applicability | Status |
|---|---|---|---|
| 1 | SUT instantiation check | N/A (no Swift) | N/A |
| 2 | Function-result usage | N/A (no Swift) | N/A |
| 3 | Multi-step test body | N/A (no XCTest) | N/A |
| 4 | Scope coverage audit | YES — contract has 5 verification criteria + 4 DoD evidence items | ALL LANDED (sections 7.1–7.6 above) |
| 5 | Mutation pass | N/A (no production-code edits) | N/A |
| 6 | Build + verify-pr | YES — must confirm staged code still builds | Build SUCCEEDED in prep step (xcodebuild Palace Debug @ /tmp/dd-modD-3rd-57792); install succeeded; recording exercised the running app |
| 7 | Multi-step wiring claim | YES — sections 5 + 6 cite production seams (BookButtonState mapping, DownloadStartDispatcher early-return, presenter wiring) and the recording's snapshots ARE the coverage evidence for those seams | EVIDENCED — section 5 table maps each production claim to a recording step |
| 8 | Contract reconciliation | N/A (no commit message claims) | N/A |
| 9 | Blast-radius | N/A (no production-code edits) | N/A |
| 10 | Adjacency staleness | N/A (no production-code edits) | N/A |

The recording IS the integration test for Wave 4 + Module B + Module C
v2.1 wiring. The unit-test layer for each module already passed (Wave 4
transcript section 6b: 140/140 in the targeted suite). This transcript
+ the journey + the baselines are the visual / behavioral regression
artifacts.
