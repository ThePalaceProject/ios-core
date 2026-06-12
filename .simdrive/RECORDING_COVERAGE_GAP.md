# Regression journey recording-coverage gap
> Generated inventory (no simdrive required). Work-list for the recording
> pass that runs once simdrive licensing is restored. Source of truth:
> `.simdrive/regression-areas.json` (manifest journeys) vs
> `~/.simdrive/recordings/<journey>/recording.yaml` (local recordings).
> Snapshot @ develop `e2546ffb2`, 2026-06-12.

## Headline
- **24** journeys referenced by the area manifest.
- **1** have a local recording (replayable today).
- **3** are alias-candidates — a differently-named recording *may* cover them (needs step-parity verification before re-pointing).
- **20** are missing entirely (require a fresh capture).

**Effective coverage: 1/24 (4%).** Recording is the single biggest lever on regression coverage.

## Per area-group
| Area group | Total | Present | Alias-candidate | Missing |
|---|---|---|---|---|
| `auth` | 5 | 0 | 0 | 5 |
| `circulation` | 3 | 0 | 1 | 2 |
| `reading` | 6 | 1 | 0 | 5 |
| `audiobook` | 4 | 0 | 0 | 4 |
| `catalog` | 4 | 0 | 2 | 2 |
| `ui-nav` | 2 | 0 | 0 | 2 |
| **TOTAL** | **24** | **1** | **3** | **20** |

## Alias-candidates (verify step parity, then re-point or re-record)
These manifest journeys have **no** recording under their own id, but a
legacy `b3-*` recording exists whose name suggests it covers the same flow.
Do NOT assume equivalence — open the recording, confirm it drives the same
steps the journey YAML expects, then either rename/re-point it or re-record.

| Area | Journey | Possible existing recording |
|---|---|---|
| `circulation` | `palace-bookshelf-anonymous` | `b3-smoke-bookshelf-catalog` |
| `catalog` | `catalog-browse-stateless` | `b3-smoke-bookshelf-catalog` |
| `catalog` | `search-flow-stateful` | `b3-runtime-search-flow` |

## Missing — the capture work-list
Ordered by area-group priority (P0 auth/circulation first). Each needs a
fresh simdrive recording at `~/.simdrive/recordings/<journey>/recording.yaml`.

### `auth` (5)
- [ ] `a1qa-basic-signin`
- [ ] `a1qa-sign-out`
- [ ] `danny-saml-signin-init`
- [ ] `icarus-oidc-signin`
- [ ] `library-picker-stateless`

### `circulation` (2)
- [ ] `book-return-from-mybooks`
- [ ] `read-return-from-mybooks-roundtrip`

### `reading` (5)
- [ ] `reader2-back-button`
- [ ] `reader2-bookmark-toggle`
- [ ] `reader2-page-forward`
- [ ] `reader2-settings-sheet`
- [ ] `reader2-toc-navigate`

### `audiobook` (4)
- [ ] `audiobook-download-indicator-stateful`
- [ ] `audiobook-scrubber-drag`
- [ ] `audiobook-skip-forward`
- [ ] `audiobook-toc-seek`

### `catalog` (2)
- [ ] `feed-refresh-stateless`
- [ ] `book-detail-stateless`

### `ui-nav` (2)
- [ ] `tab-bar-tour`
- [ ] `settings-tour-stateless`

## Notes
- Every manifest journey already has its `.simdrive/journeys/<id>.yaml` spec
  (enforced by `scripts/tests/test_regression_area_chaos.py`); only the
  *recording* (the replayable HID trace) is missing.
- The many `chaos-*` recordings in `~/.simdrive/recordings/` are the chaos
  replay corpus (seeds for `run-chaos-pass.sh`), **not** journey recordings —
  they do not satisfy any manifest journey.
- Until a journey is recorded, `regression-area-worker.sh` SKIPS it (logged),
  so missing recordings silently shrink coverage rather than failing loudly —
  this inventory is the loud version.
