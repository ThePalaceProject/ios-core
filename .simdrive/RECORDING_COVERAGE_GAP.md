# Regression journey recording-coverage gap
> Generated inventory (no simdrive required). Work-list for the recording
> pass that runs once simdrive licensing is restored. Source of truth:
> `.simdrive/regression-areas.json` (manifest journeys) vs
> `~/.simdrive/recordings/<journey>/recording.yaml` (local recordings).
> Snapshot @ develop `e6307c8b2`, 2026-06-12. Step-parity verdicts added 2026-06-12.

## Headline
- **25** journeys referenced by the area manifest (was 24; +`audiobook-cold-load-first-open`, added 2026-06-17 with the PP-4542/#1094 fix to close the first-cold-open gap that let PP-4613 ship un-caught).
- **1** has a local recording (replayable today): `PP-4161-streaming-html-reader`.
- **24** are missing (require a fresh capture).
- **0 alias re-points possible** — all 3 alias-candidates were step-parity-checked and REJECTED (see below).

**Effective coverage: 1/25 (4%).** Recording is the single biggest lever on regression coverage.

## Per area-group
| Area group | Total | Present | Missing |
|---|---|---|---|
| `auth` | 5 | 0 | 5 |
| `circulation` | 3 | 0 | 3 |
| `reading` | 6 | 1 | 5 |
| `audiobook` | 5 | 0 | 5 |
| `catalog` | 4 | 0 | 4 |
| `ui-nav` | 2 | 0 | 2 |
| **TOTAL** | **25** | **1** | **24** |

## Step-parity verdicts (alias-candidates — all REJECTED)
The fuzzy name-match surfaced 3 manifest journeys whose flow a legacy
`b3-*` recording *might* have covered. Each was checked by comparing the
journey's `.simdrive/journeys/<id>.yaml` `steps:` against the recording's
step sequence (pure spec comparison, no simdrive). **None is a genuine
alias** — re-pointing any would leave load-bearing invariants unverified.
All 3 stay on the MISSING list.

| Journey | Checked recording | Verdict |
|---|---|---|
| `palace-bookshelf-anonymous` | `b3-smoke-bookshelf-catalog` | NOT-ALIAS: recording taps Palace Bookshelf then navigates Settings->About App; never asserts the anonymous Account-view no-sign-in invariants the journey exists for. |
| `catalog-browse-stateless` | `b3-smoke-bookshelf-catalog` | NOT-ALIAS: journey is 4 catalog scroll swipes; recording has zero swipes (3 taps: Bookshelf->Settings->About App). Different surface + action type. |
| `search-flow-stateful` | `b3-runtime-search-flow` | NOT-ALIAS: same search-input intent but recording omits the Cancel step + its "Cancel returns to unfiltered Catalog" invariant, and adds Catalog-tab + Continue steps. Partial overlap, not equivalent. |

## Missing — the capture work-list
Ordered by area-group priority (P0 auth/circulation first). Each needs a
fresh simdrive recording at `~/.simdrive/recordings/<journey>/recording.yaml`.
The 3 ex-alias-candidates (†) have a *close* b3-* recording that can seed/
speed the re-record even though it is not a drop-in.

### `auth` (5)
- [ ] `a1qa-basic-signin`
- [ ] `a1qa-sign-out`
- [ ] `danny-saml-signin-init`
- [ ] `icarus-oidc-signin`
- [ ] `library-picker-stateless`

### `circulation` (3)
- [ ] `palace-bookshelf-anonymous` †
- [ ] `book-return-from-mybooks`
- [ ] `read-return-from-mybooks-roundtrip`

### `reading` (5)
- [ ] `reader2-back-button`
- [ ] `reader2-bookmark-toggle`
- [ ] `reader2-page-forward`
- [ ] `reader2-settings-sheet`
- [ ] `reader2-toc-navigate`

### `audiobook` (5)
- [ ] `audiobook-cold-load-first-open`  ← NEW 2026-06-17 (PP-4542/PP-4613): first-cold-open of a fresh-borrow LCP audiobook must not dead-end on "Audiobook Unavailable". Spec authored; needs a capture staged DURING the .lcpa download.
- [ ] `audiobook-download-indicator-stateful`
- [ ] `audiobook-scrubber-drag`
- [ ] `audiobook-skip-forward`
- [ ] `audiobook-toc-seek`

### `catalog` (4)
- [ ] `catalog-browse-stateless` †
- [ ] `search-flow-stateful` †
- [ ] `feed-refresh-stateless`
- [ ] `book-detail-stateless`

### `ui-nav` (2)
- [ ] `tab-bar-tour`
- [ ] `settings-tour-stateless`

† a close-but-not-equivalent b3-* recording exists (see verdicts above) — use as a re-record reference, not a drop-in.

## Notes
- Every manifest journey already has its `.simdrive/journeys/<id>.yaml` spec
  (enforced by `scripts/tests/test_regression_area_chaos.py`); only the
  *recording* (the replayable HID trace) is missing.
- The many `chaos-*` recordings in `~/.simdrive/recordings/` are the chaos
  replay corpus (seeds for `run-chaos-pass.sh`), **not** journey recordings.
- Until a journey is recorded, `regression-area-worker.sh` SKIPS it (logged),
  so missing recordings silently shrink coverage rather than failing loudly.
