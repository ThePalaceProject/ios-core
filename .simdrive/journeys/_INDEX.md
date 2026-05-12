# simdrive Journey Index

Canonical user-flow recordings for Palace iOS regression testing. Replaces the legacy SpecterQA `.specterqa/journeys/` corpus (migrated 2026-04-30 to `.simdrive/_archive/journeys/`).

## Tier system (designed; gating currently downgraded — see "Known limitation" below)

| Tier | Meaning | Intended SSIM behavior | Current behavior |
|---|---|---|---|
| **stateless** (tier0) | No app data mutated. Start state == end state. | strict threshold (0.80–0.85), block on drift | smoke-only (block on error, warn on drift) |
| **stateful** (tier1) | Mutates state OR consumes non-deterministic content (OPDS search, Reader2 position). | loose threshold, warn on drift | unchanged — smoke-only |

The two-tier split was designed from the lesson of `reader2-page-forward.yaml`: that journey ran end-to-end on its first SSIM replay, but 8/9 steps "drifted" because Reader2 remembered the last-read page across sessions. Drift was a property of the app's state, not a bug. So we separated "is the layout regressed" (tier0, blocking) from "did the flow run cleanly" (tier1, smoke).

### How gating actually works (2026-04-30 update — corrects an earlier wrong claim)

We initially thought the iOS status-bar clock was killing SSIM. After landing simdrive 0.2.0a2's `MaskRect` feature and testing rigorously, we found **the clock isn't the problem at all** — Settings @ 11:02 vs Settings @ 12:07 scores **SSIM=1.000 with no mask**. Block-similarity is robust to digit-level changes when the rest of the screen is identical.

The actual drift source on Catalog-rooted journeys is **OPDS server-side content variability** — different cover thumbnails per session, lane reordering, etc. No mask can fix that, because the variability lives in the meaningful content.

**Resolution: two-mode gating.**

1. **Pure-deterministic screens (Settings, sign-in form, modal sheets):** SSIM-block at threshold ≥0.85. simdrive 0.2.0a2's `mask_regions` parameter is available for journeys that need it (e.g., Live Activities, banners). Confirmed: Settings replays at SSIM=1.000.
2. **OPDS-driven screens (Catalog, search results, recently borrowed, Reader2 stateful position):** SSIM is informational only. Use **structural checks** (`structural_checks:` field in the journey YAML) instead — assert that lane titles render, chrome is intact, and a minimum number of OCR marks are visible. Robust to thumbnail churn because we're checking *layout integrity*, not *pixel identity*.

Structural-check primitive lives at `scripts/simdrive-structural-check.py` and is invoked automatically by `scripts/simdrive-regress.sh` when a journey YAML declares `structural_checks:`. Schema:

```yaml
structural_checks:
  - after_step: 4
    required_text:   ["DPLA Publications", "More..."]   # OCR substring match (case-insensitive)
    required_chrome: ["a229e82e3f00", ...]              # exact stable_id match
    min_marks: 25                                        # proxy for "screen rendered"
```

Today's run (5 journeys): all 5 pass. 3 stateless journeys gated on structural checks; 2 stateful run as smoke checks.

## Journeys

| Journey | Tier | Steps | What it verifies |
|---|---|---|---|
| [tab-bar-tour](tab-bar-tour.yaml) | stateless | 4 | Tab routing, screen transitions, return-to-catalog |
| [catalog-browse-stateless](catalog-browse-stateless.yaml) | stateless | 4 | Vertical scroll smoothness, lane rendering, scroll-back returns to top |
| [settings-tour-stateless](settings-tour-stateless.yaml) | stateless | 4 | Settings sections render, no toggle drift, return to catalog |
| [search-flow-stateful](search-flow-stateful.yaml) | stateful | 3 | UITextField focus on iOS 26 (the regression simdrive was built for); auto-capitalize; auto-submit |
| [reader2-page-forward](reader2-page-forward.yaml) | stateful | 9 | Readium WKWebView reachability — OCR sees page content and chrome (back, TT). The use case with no XCTest equivalent. |
| [audiobook-download-indicator-stateful](audiobook-download-indicator-stateful.yaml) | stateful | 3 | PP-4156 regression — download indicator visible (text + percentage) while an LCP audiobook is mid-download. Catches both visibility-rule and color-contrast bugs. |
| [a1qa-basic-signin](a1qa-basic-signin.yaml) | stateful | 3 | Basic-auth (barcode + PIN) form rendering, type+tap drive, state-contract gates pre-state signed-out. First basic-auth recording in the corpus. |
| [a1qa-sign-out](a1qa-sign-out.yaml) | stateful | 2 | Sign-out confirmation dialog (PR #900, PP-4229) + credential clearing. Halts cleanly at step 0 if pre-state is signed-out (intentional state-contract behavior). |
| [danny-saml-signin-init](danny-saml-signin-init.yaml) | stateful | 1 | SAML handoff to SwiftUI Safari sheet (PR #907). Smoke: tap launches the Safari sheet loading state; SSIM may drift past handoff (warn-only). |
| [icarus-oidc-signin](icarus-oidc-signin.yaml) | stateful | 11 | OIDC SFAuthenticationSession + Google→Microsoft federation. IdP rejects creds by design — recording smoke is the handoff structure, not the auth result. |
| [palace-bookshelf-anonymous](palace-bookshelf-anonymous.yaml) | stateful | 1 | Anonymous library Account view — negative invariants (no Sign in / Sign out buttons, "Account information not required" copy). Cleanest replay in the auth corpus. |

## How replays work

simdrive recordings live in `~/.simdrive/recordings/<journey-name>/recording.yaml` (one dir per journey, with pre/post screenshots per step). Project-tracked journey YAMLs (here in `.simdrive/journeys/`) are the *intent + expected invariants* layer that pairs with each recording.

To run all journeys:

```bash
scripts/simdrive-regress.sh                   # all journeys, exit 1 on stateless drift
scripts/simdrive-regress.sh --tier stateless  # only blocking journeys
scripts/simdrive-regress.sh --tier stateful   # only smoke journeys
scripts/simdrive-regress.sh --report /tmp/sd.json
```

To run a single journey:

```bash
python3 -c "
from simdrive import session, recorder
s = session.start(udid='<UDID>', app_bundle_id='org.thepalaceproject.palace')
print(recorder.replay(name='tab-bar-tour', session=s, on_drift='halt', drift_threshold=0.85))
session.end(session_id=s.session_id)
"
```

To gate a PR on the stateless tier:

```bash
scripts/verify-pr.sh --simdrive    # opt-in flag in verify-pr.sh
```

## Recording new journeys

1. Boot the sim with the right state (booted, signed in to the right test library if applicable).
2. Start a session: `mcp__simdrive__session_start({udid: ..., app_bundle_id: ...})`
3. `mcp__simdrive__record_start({session_id: ..., name: "<journey-id>"})`
4. Drive the flow (taps / swipes / type_text). Prefer `stable_id` over `mark` for replay durability.
5. `mcp__simdrive__record_stop({session_id: ...})` — writes `recording.yaml`.
6. Write the paired `.simdrive/journeys/<journey-id>.yaml` with intent + invariants + tier.
7. Add a row to this `_INDEX.md`.
8. Test with: `scripts/simdrive-regress.sh --only <journey-id>`.

## Tier 0 (stateless) checklist

A journey qualifies as stateless if:

- [ ] No write actions: no Borrow, Return, Sign In, Sign Out, toggle changes, bookmark, or any other state mutation.
- [ ] Round-trip: the last step returns the app to the same UI state as the first step (or close enough that SSIM ≥ threshold).
- [ ] No reliance on server-side non-determinism (search results, recent-activity feeds, time-based content).
- [ ] No reliance on cached app state that changes between launches (Reader2 last-page, recently-borrowed list).

If any of these fail, the journey is tier 1 (stateful).

## Related

- [`_GAP_ANALYSIS.md`](_GAP_ANALYSIS.md) — what's covered, what's missing, what's manual-only
- [Project CLAUDE.md "E2E / UI sim driving — simdrive"](../../CLAUDE.md) — tool rules
- [`docs/Testing/TESTING_POSTURE.md`](../../docs/Testing/TESTING_POSTURE.md) — overall testing posture
- Memory: `feedback_simdrive_replaces_specterqa.md`, `simdrive_v0_2_0a1_dogfood.md`
