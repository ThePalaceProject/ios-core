# Regression journey recording-coverage gap
> Generated inventory (no simdrive required). Work-list for the recording
> pass. Source of truth:
> `.simdrive/regression-areas.json` (manifest journeys) vs
> `~/.simdrive/recordings/<journey>/recording.yaml` (local recordings).
> Snapshot @ `chore/regression-stance-3.3.0`, 2026-07-08. Recompute after any capture pass.

## Headline
- **25** journeys referenced by the area manifest (`regression-areas.json` `area_groups`).
- **22** have a local recording (replayable today).
- **3** are missing (require a fresh capture): the two audiobook-staging journeys and the streaming-HTML reader journey — see the work-list below.

**Effective coverage: 22/25 (88%).** The corpus is now near-complete; only a short, named tail remains. Recording is still the single biggest lever on the last of the regression coverage.

> Recording is done for all 5 auth journeys, all 3 circulation journeys, 5 of 6 reading journeys, 3 of 5 audiobook journeys, all 4 catalog journeys, and both ui-nav journeys. The earlier "1/25 (4%)" snapshot (develop `e6307c8b2`, 2026-06-12) predated the capture pass that recorded the corpus; it is superseded by this stamp.

## Per area-group
| Area group | Total | Present | Missing |
|---|---|---|---|
| `auth` | 5 | 5 | 0 |
| `circulation` | 3 | 3 | 0 |
| `reading` | 6 | 5 | 1 |
| `audiobook` | 5 | 3 | 2 |
| `catalog` | 4 | 4 | 0 |
| `ui-nav` | 2 | 2 | 0 |
| **TOTAL** | **25** | **22** | **3** |

## Recorded — the replayable corpus (22)
Each has a `~/.simdrive/recordings/<journey>/recording.yaml` present today.

| Area group | Recorded journeys |
|---|---|
| `auth` | `a1qa-basic-signin`, `a1qa-sign-out`, `danny-saml-signin-init`, `icarus-oidc-signin`, `library-picker-stateless` |
| `circulation` | `palace-bookshelf-anonymous`, `book-return-from-mybooks`, `read-return-from-mybooks-roundtrip` |
| `reading` | `reader2-back-button`, `reader2-bookmark-toggle`, `reader2-page-forward`, `reader2-settings-sheet`, `reader2-toc-navigate` |
| `audiobook` | `audiobook-scrubber-drag`, `audiobook-skip-forward`, `audiobook-toc-seek` |
| `catalog` | `catalog-browse-stateless`, `search-flow-stateful`, `feed-refresh-stateless`, `book-detail-stateless` |
| `ui-nav` | `tab-bar-tour`, `settings-tour-stateless` |

> The three journeys previously flagged as "alias-candidates REJECTED" —
> `palace-bookshelf-anonymous`, `catalog-browse-stateless`, `search-flow-stateful` —
> now each have their own freshly-captured recording, so the fuzzy `b3-*`
> re-point question is moot. They appear in the RECORDED table above.

## Missing — the capture work-list (3)
Ordered by area-group priority. Each needs a fresh simdrive recording at
`~/.simdrive/recordings/<journey>/recording.yaml`.

### `reading` (1)
- [ ] `PP-4161-streaming-html-reader` — streaming-HTML reader (open DRM, substitutable). Journey spec present; recording not yet captured.

### `audiobook` (2)
- [ ] `audiobook-cold-load-first-open`  (PP-4542/PP-4613): first-cold-open of a fresh-borrow LCP audiobook must not dead-end on "Audiobook Unavailable". Spec authored; staging recipe is CORRECT (`reborrow_audiobook_streaming` — return + re-borrow a large LCP audiobook, "Dungeon Crawler Carl", and open it mid-download; supersedes the retired `forge_streaming_state`, whose delete-a-completed-`.lcpa` premise no longer reproduces the regression post-#1094). **Capture is BLOCKED on a per-sim network throttle**, NOT unblocked: on an un-throttled sim the ~715 MB `.lcpa` downloads in ~6–13s, too fast to reliably catch the open mid-download via UI-timed taps (+ a SpringBoard tap-race). Needs a download-window widener (host-level NLC or a per-sim shaper) before the recording can be captured.
- [ ] `audiobook-download-indicator-stateful`  (stays PHASE2 — asserts the live "Downloading… %" indicator; the `reborrow_audiobook_streaming` mid-download stage now produces a real active transfer, so it's a promotion candidate, but it hits the SAME throttle blocker as cold-load: the % window is too brief to catch reliably un-throttled).

## Journeys on disk but not yet in the area manifest
These `.simdrive/journeys/*.yaml` specs exist but are NOT in
`regression-areas.json` `area_groups`, so they are out of scope for the
22/25 headline above (the area-worker replays only manifest journeys). Listed
here so the tail is visible:

| Journey | Recording present? | Note |
|---|---|---|
| `app-rating-sentiment-gate` | Yes (`app-rating-sentiment-gate-positive`) | Epic PP-4086; declarative-flow companion. |
| `holds-reservations-empty` | Yes | Holds/reservations empty-state. |
| `reader3-pdf-open-and-page` | Yes | PDF reader open + page. |
| `PP-4529-print-page-navigation-voiceover` | **No** | VoiceOver print-page nav (PP-4529); recording not yet captured. |
| `ws4-ipad-on-mac-exit-adobe-drm` | **No** | iPad-on-Mac Adobe-DRM exit crash regression (manual tier); recording not yet captured. |

To fold any of these into the headline coverage, add its id to the right
group in `regression-areas.json` `area_groups` and re-run this inventory.

## Notes
- Every manifest journey already has its `.simdrive/journeys/<id>.yaml` spec
  (enforced by `scripts/tests/test_regression_area_chaos.py`); for the 3
  missing above, only the *recording* (the replayable HID trace) is absent.
- The many `chaos-*` recordings in `~/.simdrive/recordings/` (plus
  `rapid-tap-ask-me-later`, `trigger-spam-stacking`, `*.stale`, `*__diag`) are
  the chaos replay corpus / diagnostics, **not** journey recordings, and are
  excluded from the counts here.
- Until a journey is recorded, `regression-area-worker.sh` SKIPS it (logged),
  so missing recordings silently shrink coverage rather than failing loudly.
