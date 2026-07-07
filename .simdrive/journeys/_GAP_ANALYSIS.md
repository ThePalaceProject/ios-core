# simdrive Journey Gap Analysis

What's automated under simdrive vs what still requires manual testing or has no journey yet. Replaces the legacy `.specterqa/journeys/_GAP_ANALYSIS.md` (migrated 2026-04-30 to `.simdrive/_archive/journeys/_GAP_ANALYSIS.md`).

## Coverage status

| Feature area | Journey | Tier | Status |
|---|---|---|---|
| Tab-bar navigation | `tab-bar-tour` | stateless | ✅ Done |
| Catalog vertical scroll | `catalog-browse-stateless` | stateless | ✅ Done |
| Settings list rendering | `settings-tour-stateless` | stateless | ✅ Done |
| Catalog search (iOS-26 text-field regression) | `search-flow-stateful` | stateful | ✅ Done |
| Reader2 (Readium WKWebView) reachability | `reader2-page-forward` | stateful | ✅ Done |
| Book detail screen | — | — | ⏳ Next |
| Borrow → My Books → Return cycle | — | — | ⏳ Next |
| Sign-in: anonymous library (SQ-005 regression) | — | — | ⏳ Next |
| Sign-in: basic (barcode/PIN) | — | — | ⏳ Next |
| Sign-in: SAML | — | — | ⏳ Manual only (out-of-process IdP) |
| Sign-in: OAuth/Clever | — | — | ⏳ Manual only (out-of-process IdP) |
| Holds: reservations empty state | (observed 2026-07-06, recording pending) | stateless | 🟡 Partial — empty-reservations screen renders; see gap-work note below |
| Holds: place reservation (populated) | — | — | ⏳ Next (needs a seeded hold — recipe in gap-work note) |
| Library switcher (account list, add, switch) | — | — | ⏳ Next |
| Reader2 TOC navigation | — | — | ⏳ Next |
| Reader2 bookmark + restore | — | — | ⏳ Next |
| Reader2 font/theme switch | — | — | ⏳ Next |
| Audiobook playback | — | — | ⏸️ Cannot automate (audio output not verifiable in OCR) |
| PDF reader (Reader3 / PDFKit) | `reader3-pdf-borrow-and-open` | stateful | ✅ Done (2026-07-06 — anonymous borrow → open → page-forward → chrome) |
| Push notification handling | — | — | ⏸️ Cannot automate (real APNs required) |
| CarPlay | — | — | ⏸️ Cannot automate (no sim) |
| DRM fulfillment (Adobe / LCP) | — | — | ⏸️ Manual only (license servers) |
| Background download | — | — | ⏸️ Manual only (lifecycle dependent) |

## Gap-work note (2026-07-06) — post-PalaceUITests-removal

PR #1188 removed the never-wired `PalaceUITests/` XCUITest bundle. This pass
began closing the three coverage gaps that bundle *aspired* to (it never ran):

- **PDF reader → DONE.** `reader3-pdf-borrow-and-open` recorded live: added the
  anonymous **Palace Bookshelf** library, borrowed a free DPLA publication
  ("January 6th on the Record", a ~5470-page PDF), opened it in Reader3, turned
  a page (Cover → Acknowledgments via OCR'd page indicator), and surfaced the
  reader chrome. Credential-free and portable.

- **Holds → PARTIAL.** The **empty-reservations** screen was observed rendering
  ("When you reserve a book from the catalog, it will show up here…"). The
  **populated** holds flow (queue position / ready-to-borrow / cancel) needs a
  seeded reservation, which is not reachable anonymously. Recipe to record it:
  1. `harness creds get palace-ios.lib.<lib>` — a test library with limited-copy
     titles (e.g. `minotaur`, `main-street-city`, `a1qa`). Enable beta libraries
     if the lib is hidden: `defaults write org.thepalaceproject.palace NYPLUseBetaLibrariesKey -bool true`.
  2. Settings → + ADD LIBRARY → add the lib → sign in (barcode + PIN from vault).
  3. Find a title with **no available copies** (shows "Reserve"/"Place Hold"),
     place the hold, then Holds tab shows the queue position → record.

- **Accessibility audits → documented decision.** Element-level
  `performAccessibilityAudit` is the one XCUITest-unique capability simdrive's
  OCR doesn't replicate. Coverage options + recommendation are in
  [`docs/Testing/accessibility-audit-coverage.md`](../../docs/Testing/accessibility-audit-coverage.md).
  Standing floor: verify-pr static label gate + simdrive contrast `visual_checks`
  + the `PP-4529` VoiceOver journey; a wired audit-only XCUITest target is an
  explicit owner decision, not a silent reduction.

Environment note: a fresh sim shows **HTTP 914** on the Catalog until a library
is added — that is "no library configured," **not** an offline sim. The registry
and Palace Bookshelf feed both load fine.

## Coverage thinking

**Tier-0 (stateless) journeys have a hard limit.** Anything that mutates app state or consumes non-deterministic content can't be SSIM-gated. The current stateless count (3) is roughly the right size for a critical-path layout sentinel — adding more risks fragility without more signal.

**Tier-1 (stateful) journeys grow with the app.** Every user-facing flow that XCTest can't reach (Reader2, OAuth, SAML sheets, push handling) belongs here as a smoke test. Many can also be promoted to "expected drift baseline" once we capture multiple golden replays per OS version.

### How OPDS-driven screens are gated (corrected understanding 2026-04-30)

We initially blamed the iOS status-bar clock for SSIM drift. **That was wrong.** Same-Settings screens taken 65 minutes apart score SSIM=1.000 without any masking. The block-similarity metric tolerates digit-level changes.

The actual drift source is **OPDS server-side content variability** — different book covers per session, lane reordering, etc. No mask can fix that, because the variability is in the meaningful content. Trying to SSIM-gate a Catalog-rooted journey means trying to assert "the OPDS server returned identical book lists across two sessions," which isn't a useful regression check.

The right gate for OPDS-driven screens is **structural checks**: assert that lane titles render, chrome is present, and a minimum number of OCR marks are visible. simdrive's `observe()` returns marks with text + bbox + stable_id — we check those instead of pixels.

This is implemented as `scripts/simdrive-structural-check.py` and is auto-invoked by `simdrive-regress.sh` for any journey that declares `structural_checks:` in its YAML. **All 3 stateless journeys today pass with structural gating.** SSIM is downgraded to informational on those.

**Status of `mask_regions`:** simdrive 0.2.0a2 ships the feature (great). We have `ssim_masks: [{x:0,y:0,w:1206,h:140}]` in our recording YAMLs as a precaution against future drift sources (Live Activities, app banners, etc.), but they're not load-bearing for any current journey.

## Categorization

### Cannot automate (manual only)

1. **Audio output** — playback fidelity, sleep timer at zero, lock-screen controls during playback. No way to OCR audio.
2. **DRM fulfillment** — Adobe RMSDK and LCP need real license servers; sim-only flows hit auth walls.
3. **Background lifecycle** — system interruptions (phone calls, Siri, low battery). The sim doesn't faithfully reproduce these.
4. **Push notification delivery** — APNs requires real device + server certs.
5. **CarPlay** — no CarPlay simulator that lets simdrive's HID injection through.

### Can automate but not yet done — priority order

1. **`book-detail-stateless`** — tap a book, verify title/author/cover/Borrow button, tap back. Fast win, single screen, mostly static.
2. **`anonymous-library-no-modal`** — confirm SQ-005 regression doesn't reproduce (anonymous-auth library shouldn't trigger sign-in modal on Download).
3. **`borrow-return-cycle`** — tap a free DPLA book, Borrow, verify in My Books, Return. State-mutating but reversible. Tier 1.
4. **`reader2-toc-navigation`** — open Reader2, surface TOC, jump to chapter, verify position. Tier 1 (book state persists).
5. **`reader2-bookmark`** — bookmark a page, exit, reopen, verify bookmark restored. Tier 1.
6. **`library-switcher`** — open library list, tap Add Library, see picker, cancel. Stateless if cancel is the last step.
7. **`sign-in-basic`** — barcode/PIN flow against A1QA Test Library. Tier 1 (real network, real keychain). Requires fixture credentials.

### Re-verify the earlier dogfood blockers

Two issues from `~/Desktop/SIMDRIVE_DOGFOOD_2026_04_29.md` (against simdrive 0.1.0a1) were not yet retested against 0.2.0a1 in the original conditions:

1. **Back-button-on-detail-page exit handler** on candidate `regression/PP-4164-3.0.1`. Today's session (iOS 18.4 sim, develop branch) showed clean — but the candidate build is what tripped it.
2. **SpringBoard Allow alert PIDChange race** (~1/4 first-launch sessions). Need 6+ cold launches to sample.

Both are scheduled for a weekly SessionStart reminder (see `~/.local/share/harness/reminders/palace-ios-pp4164-last`).

## Journey design rules

- **One screen, one journey** is preferred over megajourneys. Smaller is more diagnosable.
- **Always end on a known state** (start state for stateless, or an explicit reset action). Recordings that drift indefinitely accumulate state-debt.
- **Use stable_id for taps where possible.** Pixel coords are a fallback; they break the moment a layout shifts by 1px.
- **Loosen SSIM threshold for OPDS-backed screens** (catalog content can change server-side). Tighten for fully static screens (settings, sign-in form).
- **Document `state_reset` requirements** in the YAML when the journey requires preconditions that aren't enforced by the simulator alone.
