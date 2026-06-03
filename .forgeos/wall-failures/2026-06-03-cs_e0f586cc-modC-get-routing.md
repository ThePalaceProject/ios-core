---
date: 2026-06-03
pr: "#TBD"
source: near-miss
reviewer_ids: []
changeset_id: cs_e0f586cc
wall: contract
walls: [contract, orchestrator]
severity: high
wall_status: proposed
applied_in: ""
contributing_docs: []
name: wall-failure-2026-06-03-cs_e0f586cc-modC-get-routing
type: evolving
status: active
created: 2026-06-03
last_refresh: 2026-06-03
freshness_window: 365d
owners: [general]
escalations: 2
description: PP-4161 Module C contract missed how open-access streaming-HTML books transition .unregistered → .downloadNeeded. Caught in two layered escalations by Module D simdrive dogfood — v2.2 (.get bypasses BorrowOperation guard via didSelectDownload→startDownload) then Wave 4 (borrowAsync itself fails on open-access — no rel=borrow link). Final fix: Wave 4 Path X — DownloadStartDispatcher.processDownloadWithCredentials streaming-HTML early-return reusing the existing open-access branch.
---

# Module C contract missed open-access streaming-HTML borrow path (2 escalations)

**Escalation 1 (Wave 3, v2.2 hotfix):** `.get` button on Book Detail routes through `didSelectDownload → MyBooksDownloadCenter.startDownload`, NOT through `borrowAsync`. The v2.1 `BorrowOperation.swift:454` guard (`!borrowedBook.isStreamingHTML`) is correct but unreachable from `.get`. Symptom: "Download Failed" alert; book stuck in `.downloadFailed → [Cancel, Retry]`.

**Escalation 2 (Wave 4, after v2.2 rerouted .get via didSelectReserve → borrowAsync):** `borrowAsync` itself fails for open-access content because it issues an OPDS GET against `defaultAcquisition.hrefURL`, which for open-access IS the streaming asset URL (no `rel="borrow"` link exists in the OPDS entry). Server returns streaming HTML; OPDS parser fails; "Borrow Failed" alert; book never reaches `.downloadNeeded`.

**Resolution (Wave 4 Path X):** revert v2.2; route streaming-HTML `.get` through existing `didSelectDownload → downloadCenter.startDownload` chain; add an early-return in `DownloadStartDispatcher.processDownloadWithCredentials` AFTER the existing open-access branch in `processUnregisteredState` (line 145-163) transitions the registry to `.downloadNeeded`. No asset download attempt. User taps Read on a second tap (2-tap UX matching EPUB).

## Finding (verbatim from Module D dogfood)

> Tapping the "Borrow" button on the streaming-HTML book detail screen surfaces a "Download Failed" alert and routes the book into a download-failed state showing `[Cancel, Retry]` in the half-sheet — NOT `[Read, Return]` as v2.1 Option (c) was supposed to deliver. The book never reaches a state from which `Read` can be tapped; the new `StreamingReaderView` is never presented.
>
> Root cause: `Palace/Book/UI/BookDetail/BookDetailViewModel.swift:634-637` routes `.get` (the "Borrow" button) to `didSelectDownload → downloadCenter.startDownload`, bypassing `borrowAsync(attemptDownload: false)`. The `BorrowOperation:454` guard (`!borrowedBook.isStreamingHTML`) is correct but unreachable from this path.

(Full transcript: `.forgeos/swarms/swarm_c2b95c85/transcripts/D.md`. Evidence screenshots: `.forgeos/swarms/swarm_c2b95c85/evidence/D-blocked/01..04-*.png`.)

## What actually happened

Module C's Phase 1a round-2 v2.1 reasoning chain was:

1. Module C scope = "make `BookButtonState.downloadNeeded` for streamingHTML books return `[.readStreaming, .return]` (Option (c) — purely presentation)."
2. Module C scope = "add `BorrowOperation:453` one-line guard `!isStreamingHTML` so the auto-download chain doesn't fire for streaming-HTML books after borrow."
3. Implicit assumption: **the path from `.unregistered` → `.downloadNeeded` for streaming-HTML books goes through `BorrowOperation.borrowAsync`** — so the guard at line 453 protects the state transition.

The implicit assumption was wrong. The "Borrow" button on Book Detail (mapped from `BookButtonType.get` when the book is `.unregistered`) does NOT go through `borrowAsync`. It goes through `didSelectDownload(for: book)` → `downloadCenter.startDownload(for: book)`, which:

- For an EPUB/PDF/audiobook: eventually calls `borrowAsync(attemptDownload: true)` internally as part of the download fulfillment path, then proceeds to download the asset.
- For a streaming-HTML book: tries to fulfill the open-access link with MIME `text/html;profile=streaming-media`, which `MyBooksDownloadCenter` rejects (no fulfillment handler for that MIME). The download fails immediately, never touching `borrowAsync`, never invoking the BorrowOperation guard. Book lands in `.downloadFailed → [.cancel, .retry]`. User can never reach the streaming reader.

The bug is structurally inevitable given the Wave 2 contract: the contract specified the post-borrow state mapping but didn't specify HOW a streaming-HTML book reaches `.downloadNeeded` from `.unregistered`. The architect post-review (round 1 + round 2) verified the existing switches but didn't verify the call-graph from the user-visible `.get` action through to the registry state change.

## Walls that should have caught it (and why they didn't)

- **contract**: The architect's contract C v2.1 specified the post-borrow display behavior (BookButtonState .downloadNeeded → [.readStreaming, .return]) and the guard at BorrowOperation:453, but did NOT include a "verify the path from `.unregistered` → `.downloadNeeded` for streamingHTML actually traverses borrowAsync" verification step. The architect post-review (Phase 1a round 1 + round 2) verified scope counts and switch-site coverage but didn't trace the user-action → state-transition call graph. Advisory F caught the BorrowOperation guard need but assumed the path existed — didn't verify it.
- **orchestrator**: The orchestrator's Phase 4.5 skeptic pass (DoD #7 multi-step wiring coverage) ran on unit tests, not on user-action → state-transition integration tests. A unit test like `testBookDetailViewModel_handleAction_readStreaming_callsDidSelectReadStreaming` passes for `.readStreaming` but is silent on `.get → .downloadNeeded → .readStreaming becoming the displayed action`. The Module C transcript paste of "118/118 pass + mutation kill rate" was valid but didn't include a Borrow→Read happy-path integration test.
- **TDD/mutation**: Did not catch because there was no test that exercised the full Borrow → display-Read → tap-Read path. The added Wave 2 tests (`testBookButtonState_buttonTypes_streamingHTMLDownloadNeeded_yieldsReadStreamingAndReturn`) pinned the *display rule* in isolation — they assumed the precondition (book is in `.downloadNeeded`) without verifying the path that *gets the book there* exists.

## Proposed permanent fix

Three layers — each makes the failure mode more structurally impossible:

### 1. Contract template — add "call-graph completeness" to architect post-review checklist

In `.claude/skills/swarm/SKILL.md` Phase 1a architect-reviewer prompt, add a new check:

> **N. Call-graph completeness for new content-type behavior.** For any swarm that introduces a new value to an enum that drives user-visible buttons (`BookButtonType`, `BookButtonState`, `TPPBookContentType`, similar enums) AND specifies new behavior gated by that value (e.g. "for `.streamingHTML` books, the button is `.readStreaming`"), verify the FULL call graph from `userAction → buttonMapping → action handler → service call → registry state change → buttonMapping (re-evaluation)` is traced AND that every transition in that graph has either (a) an existing handler that does the right thing for the new value or (b) is in scope to be patched. Grep evidence required for each link in the chain.

This forces the architect to expand contract scope to cover the FULL path, not just the destination state.

### 2. Orchestrator skeptic-pass — borrow→display invariant for new content types

In `.claude/skills/swarm/SKILL.md` Phase 4.5, add a new check that runs on swarms touching `TPPBookContentType`:

```bash
# For any swarm that adds a new TPPBookContentType case, verify the test set
# includes at least one integration-style test that drives a full borrow → display
# cycle from .unregistered for that new case. Grep for "handleAction(for: .get)"
# AND the new content-type literal in the same test method.
```

### 3. CLAUDE.md "State-machine wiring tests" — extend the existing rule

CLAUDE.md already requires "consumer-side smoke test" for readiness gates. Extend the rule to cover **user-action → registry-state cycles for new content types**:

> **For every new `TPPBookContentType` case, add an integration-style test that drives `BookDetailViewModel.handleAction(for: .get)` (or the cell-side equivalent) and asserts the book reaches the expected `BookButtonState` for that content type via the production seam — not via `bookRegistry.setState(...)` direct shortcuts. Direct shortcut writes prove the storage works; they don't prove the user-action → display wiring works.**

The new test added in v2.2 (`testBookDetailViewModel_handleAction_getForStreamingHTMLBook_routesViaBorrowAsyncNotDownload`) is the canonical example of this pattern.

## Application log

- 2026-06-03 — fix-in-flight via Module C v2.2 hotfix; wall-failure entry committed alongside the fix
- TBD — update `INDEX.md` + `derived-improvements.md`
- TBD — apply layer-1 (SKILL.md Phase 1a) + layer-2 (SKILL.md Phase 4.5) + layer-3 (CLAUDE.md state-machine rule) updates after PR ships

## Related entries

- `.forgeos/wall-failures/2026-05-28-cs847892e8-arch1.md` — "fake wiring test" (Audiobook): test claimed to exercise wiring through a class but the mock book failed before the class ever loaded. Same root cause class: tests pinning a destination state without verifying the path that reaches it.
- `.forgeos/wall-failures/2026-05-28-cs9a267b63-arch1.md` — TPPReauthenticator: same shape (test name embeds production class noun the body doesn't reference).

The pattern across these three: **tests pin a property without proving the production path that produces that property is reachable from the user action that should trigger it.** The proposed fixes here extend the runnable greps to cover this class of bug.
