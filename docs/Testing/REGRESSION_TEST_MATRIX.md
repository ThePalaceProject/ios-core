# Regression Test Matrix

Standing test area checklist for release-gate regression testing. Derived from the PP-4020 regression sprint (76 findings across 40+ areas). Use this matrix for every regression pass.

## How to Use

1. Copy this file into your regression workspace
2. Mark each area as you test it
3. Log findings to `findings.csv` with the Area and Test ID columns matching this matrix
4. P0 areas are mandatory every release. P1 every release. P2 sampled based on change scope.

## Priority Tiers

- **P0** — Critical path. Auth, borrow, download, DRM. Failure here blocks release.
- **P1** — Core experience. Reading, playback, sync, catalog. Test every release.
- **P2** — Polish and edge cases. Sample based on what changed.

---

## Test Fixtures

Authentication and distributor combinations are *matrix axes*, not single points. Use these libraries to exercise each combination. Credentials live in your local agent credentials dir (e.g. `~/.simdrive/credentials/` or the legacy `~/.simdrive/credentials/`) and are never committed.

### Auth-type → test library

| Auth type (Account.AuthType) | OPDS URL | Test library | Credentials env |
|------------------------------|----------|--------------|-----------------|
| `basic` (barcode + PIN) | `http://opds-spec.org/auth/basic` | A1QA Test Library | `a1qa-test.env` |
| `token` (basic-token) | `http://thepalaceproject.org/authtype/basic-token` | Lyrasis Reads | `lyrasis-reads.env` |
| `oauthIntermediary` (Clever) | `http://librarysimplified.org/authtype/OAuth-with-intermediary` | NYPL (Clever IdP) | manual login |
| `saml` (SAML 2.0) | `http://librarysimplified.org/authtype/SAML-2.0` | BiblioCommons / academic libraries | manual IdP |
| `oidc` (OpenID Connect) | `http://palaceproject.io/authtype/OpenIDConnect` | Palace OIDC test library | manual IdP |
| `anonymous` | `http://librarysimplified.org/rel/auth/anonymous` | Palace Bookshelf | — (no creds) |
| `coppa` (age gate) | `http://librarysimplified.org/terms/authentication/gate/coppa` | Open eBooks / Simplified collection | — |

**Note:** A regression pass that tests only `basic` is insufficient. Every release must cover at minimum: `basic`, `token`, `saml`, `oidc`, `anonymous` (5 of 7). `oauthIntermediary` and `coppa` are P1 sample-based unless the sprint touched those code paths.

### Distributor → test title / library

| Distributor | DRM | Formats | Test title | Notes |
|-------------|-----|---------|------------|-------|
| Palace Bookshelf (DPLA) | None | EPUB | Any DPLA title | Anonymous auth, DRM-free |
| Palace Marketplace (De Marque) | LCP | EPUB, audiobook | *Cyber Risk* (EPUB), *Animal Farm* (audiobook) | Primary LCP test distributor |
| Overdrive | Overdrive / OD | EPUB, audiobook | *Catching Fire* (audiobook on A1QA) | OD-specific fulfillment path; F-081 bug here |
| Findaway / AudioEngine | None (DRM-free audio) | audiobook | Any Findaway-keyed title | Separate playback engine |
| Adobe DRM distributors | Adobe RMSDK | EPUB | Any Adobe-fulfilled title | Requires Adobe activation |
| ODL / Unlimited Listens | Mixed | audiobook | "Unlimited Listens ODL Feed" (A1QA) | Hybrid LCP/OD |
| Open-access | None | EPUB, PDF | Any DRM-free title | Baseline — no fulfillment step |

**Note:** The `distributor` field on `TPPBook` is a free-form string. The only hard-coded branch is `OverdriveDistributorKey == "Overdrive"` (Overdrive audiobook fulfillment). All other distributors follow the generic path but differ in CM auth-doc metadata, DRM flow, and playback engine.

### Environmental gotchas (don't waste a session on these)

- **Cryptonomicon** on A1QA is in a stuck license-pool state — never use for regression.
- **Overdrive on Lyrasis Reads** fails with "Not a valid HPLD card" — EXPECTED per Lyrasis ops.
- Cover images from `storage.googleapis.com/rua-uplo/` return 404 — publisher deleted files.

---

## P0 — Critical Path (test every release)

### Authentication

Every auth row below must be run against **each** auth type listed in the "Auth types" column, one run per type. A row with "All 7" means 7 separate runs.

| ID | Area | Description | Auth Types | Automation | Notes |
|----|------|-------------|------------|------------|-------|
| A1 | Sign in (settings) | Sign in via Settings > Libraries > Account | All 7 (basic, token, oauth, saml, oidc, anonymous, coppa) | Partial (simdrive: basic, token) | Check nav title (F-001), form fields rendered correctly per auth type, error messages. Anonymous / COPPA should show no login form. |
| A2 | Sign in (just-in-time) | Sign-in prompt triggered by borrow/download | basic, token, oauth, saml, oidc | Manual (simdrive for basic) | Verify prompt appears, completes, resumes the original action without losing context. Anonymous libraries must **not** trigger JIT (SQ-005 regression). |
| A3 | Sign out (basic/token/anonymous) | Sign out and verify credential cleanup | basic, token, anonymous | Partial (simdrive) | No credential bleed in keychain. No stale UI. No hang (F-080 regression). |
| A3-SAML | Sign out (SAML SLO) | SAML Single Logout via CM | saml | Manual | Verify `/logout` endpoint called with correct params. PP-3452 refactored this. |
| A3-OIDC | Sign out (OIDC end_session) | OIDC RP-initiated logout | oidc | Manual | Verify `end_session_endpoint` called with `post_logout_redirect_uri`. Check for NSURLError -1002 on callback redirect (expected). |
| A3-OAuth | Sign out (OAuth intermediary) | Clever-style sign-out | oauth | Manual | Verify token cleared from keychain. Re-sign-in should work. |
| A4 | Sign-in errors | Wrong credentials, network loss, expired token | All 7 | Manual | F-067: network loss must **not** surface as "invalid credentials." Expired token must trigger silent refresh where applicable. |
| A5 | Multi-account switching | Switch between 3+ libraries with different auth | Mix of all | Manual | Verify no 401 cascade, no spurious login prompts, no stale modals (SQ-007). |
| A6 | Credential isolation | Verify credentials don't bleed across accounts | All 7 | Manual + unit (`TPPCredentialIsolationE2ETests`) | PP-4020 found 6-year-old TOCTOU race (F-034). Per-account `TPPUserAccount` instances must be isolated. |
| A7 | Reauth on 401 | Server returns 401 during in-flight request | basic, token, oauth, saml, oidc | Manual | Correct auth flow re-invoked (not always basic). No stacked modals (F-034 thread-safety). |
| A8 | Expired session recovery | Token expired, app foregrounded | token, oauth, oidc | Manual | Silent refresh via `TokenRefreshInterceptor` or user prompted once. No 401 loop. |

### Circulation

Borrow and fulfillment paths branch by distributor. Every circulation row below must be run across the distributor axis — one run per distributor listed, using the title/library mapping in the fixture table.

| ID | Area | Description | Distributors | Automation | Notes |
|----|------|-------------|--------------|------------|-------|
| B1 | Borrow (generic) | Borrow a book from catalog | All 7 distributors | Partial (simdrive) | Check borrow sheet, button states, OPDS entry refresh. |
| B2 | Return | Return a borrowed book | All 7 distributors | Partial (simdrive) | Verify confirmation alert (PR #803), auto-dismiss, registry cleanup. F-012: revoke endpoint returns XML but client parses as JSON. |
| B3 | Place hold | Place a hold on unavailable title | All distributors that support holds | Manual | Check hold confirmation, Holds tab update. Anonymous libraries should not offer hold. |
| B4 | Cancel hold | Cancel an existing hold | All | Manual | Verify state sync in search/list view (F-065), Holds tab refresh. |
| B5 | Download (generic) | Download borrowed book for offline | Adobe, LCP, DRM-free, Overdrive EPUB | Manual | Check progress indication, completion, registry transition. |
| B6 | DRM fulfillment (LCP) | LCP license acquisition + CPM cleanup | Palace Marketplace (LCP) | Manual | PP-3704 fixed LCP session orphaning. Check license file present, playback works, silent re-download on orphan. |
| B6-Adobe | DRM fulfillment (Adobe) | Adobe RMSDK device activation + ACSM fulfillment | Adobe DRM libraries | Manual | Check device activation persists, fulfillment succeeds, DRM certificate loads without crash (see `AdobeCertificate` crash in Crashlytics). |
| B6-OD | DRM fulfillment (Overdrive) | Overdrive scope + patron-authorization headers | Overdrive (audiobook primary) | Manual | F-081: post-borrow OPDS entry still has `/borrow` URL; fix defers to `deferOverdriveFulfillment`. Headers `x-overdrive-scope` + `x-overdrive-patron-authorization` must arrive on 302. |
| B7 | Hold → loan conversion | Waited hold becomes available → user taps Borrow → loan placed → download | All distributors | Manual (requires waiting for hold to fire) | **C5 was "Unable to test" in PP-4020**. F-081 closed Overdrive path. **Adobe and LCP paths still need a waited-out run.** |
| B8 | Concurrent borrow | Rapid taps on Borrow button | All | simdrive (`concurrent-borrow.yaml`) | Verify no double-borrow, debounce works. |
| B9 | Borrow after sign-out | Anonymous flow: Borrow without any sign-in | anonymous | Manual | SQ-005 regression: must not show empty sign-in modal. |

---

## P1 — Core Experience (test every release)

### Reading

| ID | Area | Description | Variants | Automation | Notes |
|----|------|-------------|----------|------------|-------|
| E1 | EPUB reading — DRM-free | Page turn, search, bookmarks, visual settings | Palace Bookshelf title | Manual (Readium WKWebView invisible to XCTest) | Brightness slider (F-037), search order (F-039), nav bar toggle (F-036). |
| E1-LCP | EPUB reading — LCP DRM | Same as E1 but with LCP-protected EPUB | *Cyber Risk* on Palace Marketplace | Manual | Same checks + license-file presence, stale-loan DRM error (F-038). |
| E1-Adobe | EPUB reading — Adobe DRM | Same as E1 but with Adobe RMSDK | Any Adobe-fulfilled title | Manual | Same checks + Adobe activation must be live. Regression target: no `AdobeCertificate` crash. |
| E2 | PDF reading | Open, navigate, zoom, annotate | PDF on any library | Manual | |
| E2-Hang | PDF/EPUB open never completes | Open a borrowed title; assert reader renders content within 15s (no infinite spinner / blank screen). Cover **non-LCP-PDF** + **non-Marketplace EPUB** explicitly — PP-4454 only fixed Marketplace LCP-wrapped PDFs. | DRM-free PDF (Palace Bookshelf), DRM-free EPUB, Adobe EPUB | Manual | HelpSpot 17966 — Blake reports blank screen + infinite spinner on book open, survives reinstall + relogin. Verify the open-path is not silently failing for non-Marketplace titles after the PP-4454 recursive-predicate change. |
| E3-FA | Audiobook — Findaway / AudioEngine | Play, skip 30s, scrub, TOC, bookmarks | Any Findaway title | Manual | Check skip direction (F-046), TOC visibility (F-047), playback position persists. |
| E3-OD | Audiobook — Overdrive | Same as E3-FA but Overdrive distributor | *Catching Fire* on A1QA | Manual | Manifest format (F-053), token refresh before open. 2.x regressed open-failures (Crashlytics 25K non-fatals pre-fix). |
| E3-LCP | Audiobook — LCP | Same as E3-FA but LCP distributor | *Animal Farm* on Palace Marketplace | Manual | F-057 (instant checkout + streaming), F-058 (all player bugs fixed). LCP session re-download on orphan (PP-3704). |
| E3-LCP-Resume | LCP audiobook mid-book resume | Play through several chapters of a Marketplace LCP audiobook (10+ min in), pause, kill app, relaunch, reopen the title. Assert: position restored to pause point, Play resumes audio (engine starts, not just UI mount), no need to nav-away-and-back to unstick. Repeat across **first open** AND **subsequent open from a deep position**. | Multiple Marketplace LCP audiobooks (e.g. *Animal Farm* + one ≥6hr title) | Manual | HelpSpot 17964 — Carol on 3.0.3 reports one Marketplace audiobook played 14 chapters then refused to resume; multiple titles intermittently won't load. Broadens the known F-011 / PP-4436 "first-open hang" reproducer to also cover **resume from saved position after long playback**. If F-011 repros only on first open, this case is a new sibling — file as F-011 sibling. |
| E3-LCP-Gate | LCP first-open must not deadlock the readiness gate | Cold-launch app (kill from app switcher), tap an LCP/Marketplace audiobook, tap Listen. Assert: within ~3s of tapping Listen, audio actually starts playing (not "Loading..." spinner stuck for 10+ seconds, no "A Problem Has Occurred / Please try again later" alert). Repeat 3× in a row on different LCP titles. Watch the device console for `First-open readiness gate timed out` — if it appears even once on LCP, that's a regression. | Marketplace LCP audiobooks (e.g. *Trust*, *Animal Farm*, any Audible-Studios-via-Marketplace title) | Manual (idevicesyslog `-p Palace` while testing) | **FINDING-B (2026-06-01).** PR #1020 (#1020 close-out wave 1) added `PlaybackReadinessGate` that waits for `Player.isLoaded == true` before issuing `play(at:)`. But `LCPStreamingPlayer.isLoaded` only flips to true when `AVPlayer.timeControlStatus == .playing` — which requires `play()` to have been called. Pre-play gate deadlocks on LCP. Fix is `AudiobookSessionManager.startPlaybackAndSyncPosition` bypassing the gate when `loaded.decryptor != nil` (LCP path) and letting LCPStreamingPlayer's own 30s internal load timeout cover the hang-detection role. **Regression signal:** any time the readiness gate's `play(at:)`-gating logic, the `decryptor != nil` check, or `LCPStreamingPlayer.isLoaded` semantics are touched, run this test. |
| E3-Reborrow-Position | Return + re-borrow must reset playback position to 0:00 | Borrow any audiobook. Play to a recognizable position (e.g. Chapter 3, ~2 min in). Pause. Return the book from My Books. Re-borrow the same book. Tap Listen. Assert: playback starts at 00:00 / Chapter 1, NOT at the pre-return position. Repeat on at least one BiblioBoard-bearer-token title AND one Marketplace LCP title. | Any audiobook (e.g. *Memory and Dream* on a BiblioBoard library, *Trust* on Marketplace) | Manual (idevicesyslog `-p Palace`, watch for `Starting playback with local position: ... timestamp=<non-zero>` on the re-borrow open — that's the bug) | **FINDING-D (2026-06-01) / HelpSpot 17988 "Iron Flame missing first hour" cluster.** `AudiobookSessionManager.openAudiobook` calls `stopPlayback(dismissPhoneUI: !isSameBook)` to tear down a prior session. The teardown's `manager.saveLocation(currentLocation)` writes the stale prior-loan position into the freshly-borrowed registry record (since the book identifier is unchanged across the return/reborrow boundary). Fix: pass `persistFinalPosition: !isSameBook` so the same-book teardown skips the final-position write. **Regression signal:** any change to `stopPlayback`, `openAudiobook`'s pre-load teardown, `BorrowOperation.swift:418` (`let location = bookRegistry.location(forIdentifier:)`), or `BookmarkManager.setLocation` semantics. |
| E3-OA | Audiobook — open-access | Same as E3-FA but DRM-free | Any open-access audiobook | Manual | Baseline no-DRM path. Covered by L4 in PP-4020. |
| E4 | Audiobook background | Background playback, Bluetooth, lock screen, phone call, other-audio interruption | All distributors | Manual | Resume on BT reconnect (F-060), lock-screen controls (B1), phone-call interrupt (B2). |
| E5 | Offline reading/listening | Read/listen without network | All distributors + DRM types | Manual | Verify downloaded content accessible, license doesn't re-validate if cached. |
| E6-Adobe | Cross-device sync — Adobe | Device ID populated via RMSDK activation | Adobe libraries | `scripts/test-sync.sh` | Device ID UUID from `TPPUserAccount.deviceID`. |
| E6-NonAdobe | Cross-device sync — non-Adobe | Device ID fallback for LCP / Findaway / open-access | LCP, Findaway, open-access, anonymous | `scripts/test-sync.sh` | F-079: device ID must come from `FirebaseManager.shared.deviceID` (PR #833 fix), not empty string. 23 of 255 annotations were broken before fix. |
| E7 | EPUB position sync | Position syncs across 2 devices same account | All EPUB DRM types | `scripts/test-sync.sh` | `LocatorAudioBookTime` / EPUB locator format. |
| E8 | Audiobook position sync | Position syncs across 2 devices same account | All audiobook distributors | `scripts/test-sync.sh` | F-058 verified cross-device works on LCP. |

### Catalog

| ID | Area | Description | Automation | Notes |
|----|------|-------------|------------|-------|
| C1 | Catalog browsing | Browse lanes, scroll, facet switching | Partial (simdrive) | Check cover alignment (F-018), facet speed (F-041) |
| C2 | Catalog search | Live search, filter pills, results | Partial (simdrive) | Check auto-search (F-025), button styling (F-045) |
| C3 | My Books | Tab navigation, sort, state after borrow/return | Partial (simdrive) | Check auto-refresh on appear (F-035) |
| C4 | Holds tab | Holds display, cancel from list vs detail | Manual | Check state sync after cancel (F-065) |

---

## P2 — Polish & Edge Cases (sample based on changes)

### UI & Accessibility

| ID | Area | Description | Automation | Notes |
|----|------|-------------|------------|-------|
| U1 | UI completeness | Side-by-side screen comparison (15+ screens) | `browserstack-screenshot-walker.py` | Catalog, My Books, Settings, Detail, Search |
| U2 | Dark mode | All screens render correctly in dark mode | Manual | |
| U3 | Accessibility | VoiceOver, touch targets, screen names | `ios_accessibility_audit` | Check nav titles (F-001), label completeness |
| U4 | Error states | Network loss, expired tokens, malformed OPDS | Manual | Check error classification (F-067) |

### Downloads & Network

| ID | Area | Description | Automation | Notes |
|----|------|-------------|------------|-------|
| D1 | Multiple downloads | Queue 3+ downloads simultaneously | Manual | Check progress indication (F-042) |
| D2 | Cancel download | Cancel in-progress download | Manual | |
| D3 | Background download | Download completes when app backgrounded | Manual | Check auto-resume on foreground (F-059) |
| D4 | Network loss recovery | Buttons responsive after connectivity returns | Manual | Check stale buttons (F-063) |

### Notifications

| ID | Area | Description | Automation | Notes |
|----|------|-------------|------------|-------|
| N1 | Push delivery | Hold-available, loan-expiry notifications | `test-push-notifications.py` | Check event_type field (F-071) |
| N2 | Push tap routing | Notification tap navigates correctly | Manual | Check router not nil (F-072) |
| N3 | Deep-link nav | Notification opens correct tab/view | Manual | |
| N4 | Hold-ready notification ↔ holds-list coherence | Place a hold that will fire; when "hold ready" push arrives, open the app from the notification. Assert: Holds tab shows the title in **Ready** state (not still queued, not missing). Then sign out + reinstall + sign back in — assert holds list survives the round-trip (PP-4258/4259 end-of-feed reconciliation must catch them). | All distributors with hold support; multi-hold account preferred | Manual | HelpSpot 17960 — Derryl (iPhone 13 iOS 26.4.2) got "ready" push but app holds list disagreed, then reinstall briefly wiped all holds. HelpSpot 17971 — Heather sees "queue position 1 for months" never advancing, survives reinstall. Verify PP-4258/4259 registry snapshot covers the **notification-triggered state path**, not just the catalog refresh path. |

### Performance

| ID | Area | Description | Automation | Notes |
|----|------|-------------|------------|-------|
| P1 | Memory footprint | Instruments trace during stress test | Manual (Instruments) | Compare to baseline, check for leaks |
| P2 | Scroll performance | Catalog lane scrolling frame rate | Manual (Instruments) | |
| P3 | Launch time | Cold start to catalog visible | Manual | |

### Platform

| ID | Area | Description | Automation | Notes |
|----|------|-------------|------------|-------|
| X1 | iPad layout | All screens render correctly on iPad | Manual | |
| X2 | CarPlay | Audiobook browsing and playback via CarPlay | Manual | |
| X3 | Library onboarding | Add library, walkthrough, first sign-in | Partial (simdrive) | |
| X4 | Multi-library config | 3+ libraries, switching, isolation | Manual | |
| X5 | Book detail view | Cover, description, buttons, back nav | Partial (simdrive) | Check HTML tags (F-029), back button (F-043) |
| X6 | Settings completeness | All rows visible and functional | Partial (simdrive) | Content Licenses, Advanced, Wi-Fi toggle |

---

---

## Critical Auth × Distributor Combinations (P0 — must all pass every release)

A full cross-product would be 7 auth × 7 distributor = 49 runs. We don't need all 49 — real user journeys cluster into a small set of combinations. These are the ones where a regression would hit production users. **Every release must exercise all rows below end-to-end.**

| # | Auth type | Library | Distributor / DRM | Critical flows |
|---|-----------|---------|-------------------|----------------|
| 1 | anonymous | Palace Bookshelf | DRM-free EPUB | Borrow → Download → Read → Return |
| 2 | basic | A1QA | Overdrive audiobook | Place hold → **Borrow-from-hold** (F-081) → Play → Return |
| 3 | basic | A1QA | LCP EPUB | Borrow → Download → Read offline → Sync position across device |
| 4 | basic | A1QA | LCP audiobook | Borrow → Play (streaming) → Background playback → BT reconnect |
| 5 | token | Lyrasis Reads | Mixed distributors | Sign-in → Browse catalog → Borrow → Sign-out → Sign-in again (credential clear) |
| 6 | saml | SAML test library | Adobe DRM EPUB | Sign-in (IdP redirect) → Borrow → Adobe fulfillment → Read → **SAML SLO sign-out** |
| 7 | oidc | OIDC test library | LCP EPUB | Sign-in (IdP redirect) → Borrow → Read → **OIDC end_session sign-out** |
| 8 | oauth | NYPL (Clever) | Any | Sign-in via Clever → Borrow → Read → Sign-out |
| 9 | Multi-account | A1QA + Palace Marketplace + anonymous | Mixed | Add 3 libraries → Switch rapidly under active network load → Verify no credential bleed (F-034) |

**If a row above cannot be tested (e.g., Adobe activation not available on the test rig), mark it explicitly in the release report as a known gap with a waiver rationale.** Silent skipping is how "we tested everything" turns into "why didn't we catch X?"

---

## Classification Guide

When logging findings to the CSV, use these classifications:

| Classification | When to Use | Jira Type |
|----------------|-------------|-----------|
| `regression` | Worked in baseline, broken in candidate | Bug |
| `pre-existing` | Broken in both versions | Bug |
| `fixed` | Broken in baseline, fixed in candidate | N/A (document only) |
| `behavior-change` | Intentional change between versions | N/A (document only) |
| `new-feature` | Exists only in candidate | N/A (document only) |
| `superseded` | Initially logged but found to be incorrect | N/A (exclude from report) |

## Severity Guide

| Severity | Criteria | Jira Priority |
|----------|----------|---------------|
| `blocker` | Data loss, credential leak, unrecoverable state | Blocker |
| `major` | Core flow broken, workaround exists but painful | High |
| `minor` | Noticeable but low impact, cosmetic with UX effect | Normal |
| `cosmetic` | Visual-only, no functional impact | Low |

---

## Automation Gaps (roadmap, not blockers)

These are the items currently requiring manual runs that would most reduce per-release regression cost if automated. Ordered by cost-of-delay for a solo dev.

### simdrive journeys missing

| Journey to record | Covers | Why it matters |
|-------------------|--------|----------------|
| `sign-in-token.yaml` | A1 `token` auth on Lyrasis Reads | Token auth is used by an entire class of libraries; zero current coverage. |
| `sign-in-saml.yaml` + `sign-out-saml-slo.yaml` | A1/A3-SAML on a SAML test library | SAML flows are IdP-redirect-heavy; AX backend now handles the OAuth consent sheet (13.1.0) so this is newly feasible. |
| `sign-in-oidc.yaml` + `sign-out-oidc.yaml` | A1/A3-OIDC | OIDC was added in this refactor — should have journeys, currently zero. |
| `hold-to-loan-lcp.yaml` | B7 LCP path | C5 gap from PP-4020; Adobe/LCP not yet exercised end-to-end. |
| `hold-to-loan-adobe.yaml` | B7 Adobe path | Same. |
| `multi-library-credential-isolation.yaml` | A5 / A6 / #9 in critical matrix | F-034 was a 6-year-old bug; a journey that switches libraries under load is the durable defense. |
| `reauth-on-401-token.yaml` | A7 / A8 for token auth | Token refresh path is the most likely place for silent regressions. |

### Unit test coverage gaps

Auth area has good depth on SAML (3 test files), basic (`TPPBasicAuthTests`), credential isolation (`TPPCredentialIsolationE2ETests`), and reauthentication (`TPPReauthenticatorTests`). **OIDC has no dedicated unit test file** — only `SignInModalSAMLOIDCTests` which is UI-surface, not business logic. **OAuth intermediary (Clever) has no dedicated unit file either.**

| File to add | Covers |
|-------------|--------|
| `PalaceTests/SignInLogic/TPPSignInBusinessLogic+OIDCTests.swift` | `oidcLogIn`, `handleOIDCCallback`, `isOIDCLogoutCallbackRedirect`, token parsing, error-payload parsing |
| `PalaceTests/SignInLogic/TPPSignInBusinessLogic+OAuthTests.swift` | `oauthLogIn`, `handleRedirectURL`, universal-link payload parsing (ampersand / equals handling in base64 tokens) |
| `PalaceTests/SignInLogic/TPPSignInBusinessLogic+TokenTests.swift` | `getBearerToken`, expiry detection, refresh-on-foreground |
| `PalaceTests/MyBooks/OverdriveDeferredFulfillmentTests.swift` | **Done** in PR #843. 6/6 truth-table cases. |

### Scripted / tooling gaps

| Script / tool | Purpose |
|---------------|---------|
| `scripts/test-sync.sh --auth-type all` flag | Run sync tests against each auth type in one pass |
| Crashlytics snapshot delta tool | Snapshot top-20 crashes before RC, alert on any new entry in the top-20 after 24h on TestFlight |
| `scripts/run-auth-matrix.sh` | Orchestrate all 9 rows of the auth × distributor critical matrix through simdrive journeys + report pass/fail |

---

## Change log

- 2026-05-27 — Added E2-Hang, E3-LCP-Resume, N4 from HelpSpot triage for the 3.2.0 regression. Sources: 17964 (Marketplace audiobook mid-book resume failure), 17960 + 17971 (hold-ready notification ↔ holds-list desync), 17966 (generic reader open hang outside Marketplace LCP PDFs). Each row pins the originating ticket so the link survives.
- 2026-04-17 — Added test-fixture mapping, expanded auth types from 3 to 7, split B6 by distributor, added B7 (hold→loan), A3 by auth type, E1/E3/E6 split by DRM + distributor, added critical auth × distributor cross-product (9 rows), added Automation Gaps roadmap.
- 2026-04-16 — Initial matrix from PP-4020 sprint findings.
