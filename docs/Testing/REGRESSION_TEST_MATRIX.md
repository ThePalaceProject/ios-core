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

### Upgrade path (in-place)

The highest-consequence failure class is **user data loss on upgrade** — a schema/persistence change that silently zeroes a patron's shelf, credentials, or reading positions when they update the app over an existing install. A clean install tests nothing here; the whole point is upgrading *in place* over real prior-version state. Run each row across **at least `basic` + one SSO type** (`saml` or `oidc`) so credential-format migration is exercised, not just registry migration.

| ID | Area | Description | Auth Types | Automation | Notes |
|----|------|-------------|------------|------------|-------|
| UP1 | In-place upgrade — state preservation | **On the last shipped release build (3.2.0, TestFlight or App Store):** sign in (pick an auth type), borrow ≥1 book, download it, open it and set a reading position; for an audiobook set a playback position. This populates registry state + keychain credentials + downloaded files on disk. **Then upgrade IN PLACE to the 3.3.0 candidate** — do NOT delete the app (in-place upgrade is the whole point; a clean install tests nothing). **Verify post-upgrade:** loans still present, downloaded books still openable offline, reading/playback positions preserved, still signed in (credentials survived), no duplicate/lost entries, no crash-loop, no data wipe. | basic + one SSO (saml or oidc), min 2 runs | Manual | **3.3.0 blind spot — zero prior coverage.** Carries PR #1212 (registry "Bulletproof Ownership": quarantine + `.bak` backup + `schemaVersion` bump) and PR #1199 (Swift 6 language-mode flip). Registry lives at `<Application Support>/<accountID>/registry/registry.json` (see `BookRegistrySync.registryUrl`). Backup scheme: durable last-good sidecar `registry.json.bak` (`RegistryFileRecovery.writeBackup`, write-temp→fsync→atomic-rename); corrupt files copied aside to `registry.json.corrupt-<unix-timestamp>` and NEVER deleted; INV-1 refuses to persist an empty registry while a non-empty `.bak` exists. **A 3.2.0-written unversioned file must load as v1, migrate to `schemaVersion: 1` on next save, and never be quarantined or zeroed.** Watch the console for `INV-1: refusing to persist an EMPTY registry` (a fired guard means the load path saw the shelf as empty — investigate before shipping). |
| UP1-Result | *(expected result for UP1)* | All prior state preserved end-to-end: loans, downloaded files, EPUB/audiobook positions, and sign-in survive the upgrade with no data loss. App launches cleanly (no crash-loop, no forced re-sign-in, no empty-shelf flash that then repopulates). `registry.json` gains `schemaVersion: 1` on first post-upgrade save; any `.corrupt-*` quarantine file present ⇒ FAIL (real corruption, not the migration path). | basic + one SSO | Manual | If ANY prior-version state is lost, classify `blocker` (data loss) per the Severity Guide and block the release. |

---

### Platform-risk (3.3.0 structural changes)

3.3.0 is not a feature release with a few fixes — it carries four *whole-app* changes that no
single feature row can catch, because their failure mode is a crash, a hang, or a silently
wrong persisted value rather than a wrong pixel. Each row below is a **soak across the P0
flows**, not a screen check. Run them last, after the feature rows have established that the
flows work at all.

| ID | Area | Description | Variants | Automation | Notes |
|----|------|-------------|----------|------------|-------|
| PR1 | Swift 6 language-mode flip | Drive every P0 flow (sign in → borrow → download → open → read/play → return) while **perturbing concurrency**: background/foreground mid-download, rotate mid-open, lock the screen during playback, switch library while a feed is loading, tap Listen twice in rapid succession. Assert: no crash, no hang >5s, no UI frozen with the process alive. Capture `xcrun simctl spawn <UDID> log stream --predicate 'process == "Palace"'` for the whole run and grep it for `_dispatch_assert_queue_fail`, `EXC_BREAKPOINT`, `Main Thread Checker`, and `dispatch_sync called on queue already owned`. | Both targets (Palace, Palace-noDRM); at least one Adobe and one LCP title | Manual soak + `simctl` log capture; crash harvest via `scripts/regression_crash_harvest.py` | **31 `fix(swift6)` commits + PR #1199 flipped `SWIFT_VERSION` 5.0 → 6.0 for the whole app target.** Strict concurrency turns previously-silent main-actor violations into hard traps, so the regression signal is a *new crash class*, not a changed screen. Known live examples of the class: `boundedCompletion` delivering a caller closure off-queue (SIGTRAP), `AppContainer.production()` in a default argument re-entering its own lock at launch, off-main Now-Playing and account-change sinks. A clean pass here means the P0 flows survive perturbation, **not** that the app is free of the class. |
| PR2 | Readium 3.9.0 → 3.11.0 upgrade | Re-run **E1, E1-LCP, E1-Adobe, E2 in full** — this is a reader-engine swap, so page turn, TOC, search, visual settings, bookmark create/delete, and position round-trip all sit on changed code. Additionally: open a title, set a position deep in the book, kill the app, reopen, and assert the locator restores to the same place (locator serialization format is the thing most likely to drift across a toolkit bump). | DRM-free EPUB, LCP EPUB, Adobe EPUB, PDF | Manual (Readium renders in a WKWebView that XCTest cannot see) | PP-4848 (#1356). A toolkit bump can change locator encoding without changing any Palace source line, which makes it invisible to a diff-scoped review and to every unit test that round-trips through our own types. The cross-version check (position set on 3.2.0, restored on 3.3.0) is covered by **UP1** — do not skip it on the assumption that this row covers it. |
| PR3 | iOS 17 deployment floor | Install and cold-launch the candidate on the **lowest supported OS** and complete one full P0 loop (sign in → borrow → download → open → return). Assert no missing-symbol crash on launch and no API-availability fallback rendering an empty screen. | iOS 17 device or simulator (floor), plus the iOS 18 back-compat cell | Manual; `C-ios18` fleet cell is the nearest automated proxy | PR #1200 raised `IPHONEOS_DEPLOYMENT_TARGET` 16.0 → 17.0 across both targets and 7 SPM packages. Newer-OS-only API adopted since (iOS-18 `Tab` builder, iOS-26 tab minimize, `onScrollGeometryChange`) must degrade, not crash, on the floor. **Note:** `.simdrive/regression-areas.json` still calls `C-ios18` the "back-compat floor (iOS-16 substitute)" — that label predates this bump and is stale; the floor is iOS 17. |
| PR4 | Package extraction (decomp Waves 1–3) | Verify the extracted seams still hold the behavior they inherited: change a setting and confirm it survives relaunch (PalacePreferences); toggle a feature flag and confirm the gated UI follows (PalaceFeatureFlags); borrow/return and confirm My Books agrees with the catalog (PalaceBookRegistry as SSOT); switch libraries and confirm credentials and shelf do **not** bleed across accounts (PalaceAccounts / PalaceDownloads seams). | 2+ libraries with different auth types | Partial (unit + contract snapshots in `PalaceTests/Contract/`) | Waves 1a–3 extracted `PalacePreferences`, `PalaceFeatureFlags`, `PalaceBookModel`, `PalaceBookRegistry`, and the Accounts/Downloads seams into packages. Every wave claimed to be behavior-preserving and each was gated on a green suite — but a refactor that moves a singleton read behind a protocol changes *when* state is resolved, which the suite can miss. Credential isolation (A6) is the highest-consequence cell here; the 6-year-old F-034 bug lived in exactly this seam. |

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
| E9-Offline-Sync | Position/bookmark writes made while offline | Read or listen to a position **with the device in Airplane Mode**, then create a bookmark, then leave the app. Restore connectivity, foreground the app, and wait. Assert: the position and the bookmark reach the server (verify on a second device or by reinstalling and signing back in), and that **while offline the app never showed a sync-failure error** for a write that was merely queued. | All EPUB + audiobook DRM types; basic and one SSO auth | Partial (`scripts/test-sync.sh` covers the online path only) | **PP-4965 / PP-4987, merged as #1396 — the newest change in the release and untested by any journey.** The defect was that a queued-offline annotation write was classified as a *failure* and surfaced to the patron, and in some paths the position was then dropped rather than retried. The fix carries the HTTP response through to error classification, scopes the offline-queue drain credential per library, and purges legacy credentials before the drain. **Regression signals:** anything touching `TPPNetworkQueue`, annotation error classification, or the drain credential. Cross-check against the standing "app forgot where I was" complaint cluster — 25 of 83 App Store reviews Jan–Aug 2026. |
| E10-Position-Cadence | Position survives long untouched locked playback | Start an audiobook, note the position, **lock the screen and leave it playing untouched for ≥45 minutes**, then force-quit the app from the app switcher without unlocking or touching transport controls. Relaunch and reopen the title. Assert: the restored position reflects roughly where playback actually reached, not where it was when the screen locked. | Any audiobook; repeat on at least one LCP and one non-LCP title | Manual (long-running; run once per release, in parallel with other testing) | **Standing open defect, not a new regression — carry the known result forward rather than re-diagnosing it.** The autosave chain (`setupNowPlayingInfoTimer` → `Timer.publish(on: .main)` → `.positionUpdated` → `.throttle(5s, RunLoop.main)` → `saveLocation()`) sits entirely on the main runloop, which iOS coalesces and suspends during long screen-locked background playback. The NowPlaying-403 fix moved the *lock screen* onto the playback clock but deliberately did not re-publish `.positionUpdated`, so the autosave was left on the runloop. Four position fixes have shipped across 3.2.x/3.3.0 and the complaint volume is flat, because those fixes corrected *which* position is written and this defect is about *when*. If this row fails, file it against the existing cluster; do not open a duplicate. |
| E3-Skip | Audiobook — configurable skip interval | Change the skip interval in Settings, return to a playing audiobook, and confirm **both** the in-app player and the lock-screen/Now-Playing controls skip by the configured amount, in the correct direction. Verify the setting survives relaunch. | All distributors; test at least two distinct interval values | `audiobook-skip-forward` journey | PP-4712 (#1264, #1267). Skip direction was a real past finding (F-046) — assert direction explicitly, not just that the position moved. |
| E3-Sleep | Audiobook — sleep timer incl. 45 min | Set each sleep-timer option including the newly added **45 minutes**, confirm the countdown displays and decrements, and confirm playback actually stops at expiry (not merely that the UI says it will). Confirm "end of chapter" still works. | Any audiobook | `audiobook-sleep-timer-45` journey | PP-4903 (#1376). The 45-minute option is new in 3.3.0. |
| E3-Speed | Audiobook — 0.5×–3.0× playback rate | Step through the full rate range and confirm audio pitch/tempo actually changes at each step, the selected chip persists across player close/reopen and across app relaunch, and the **time-remaining readout is rate-aware** (at 2× the remaining time should roughly halve, not stay at the 1× value). | All distributors | Partial (unit: `AudiobookPlaybackTests`) | PP-4518 (#1124) widened the range; PP-4971 (#1384) made time-remaining rate-aware in both players. Test them together — the second is only observable while the first is exercised. |
| E3-Mini | Audiobook — mini-player and morphing full player | With an audiobook playing, confirm the persistent mini-player appears, its transport works, it can be dismissed and collapsed, and it morphs to the full player and back without visual tearing or a stuck intermediate state. Confirm the full-player **X fully closes** the session (playback stops and the player dismisses) rather than minimizing. | Any audiobook; light and dark appearance | Partial (unit: `AudiobookMorphingPlayerViewTests`) | PP-4798 (#1252), PP-4910 (#1373), #1217, #1230, #1288, #1290. The morphing player is gated behind `inAppPlaybackNav`, which **defaults to false** — confirm which state the candidate build ships with before testing, and test the shipped state first. |
| E3-Icons | Audiobook — revised player icon set | Compare the audiobook player against 3.2.0 side by side and confirm every control renders the intended new glyph at every Dynamic Type size, with no missing/placeholder glyph and no clipped icon. | iPhone + iPad, light and dark, largest Dynamic Type | Manual (visual) | PP-4911 (#1374). Icon assets are the classic silent-failure surface: a missing asset renders as blank space, which no functional test notices. |
| E3-Stream | Audiobook — LCP streaming-from-license (flag-gated) | **Confirm the flag is OFF in the candidate**, then verify LCP audiobooks still take the download-then-play path exactly as in 3.2.0. Only if the flag is deliberately enabled for a test build: verify playback starts without a full download and that E3-LCP-Gate still passes. | Marketplace LCP audiobooks | Manual | PP-4957 (#1: feature merged with the flag **false**). The shipped behavior for 3.3.0 is the flag-off path; the streaming path was accepted on simulator evidence and **still owes a device pass** before it is ever enabled. Treat flag-on as out of scope for this regression unless the release explicitly turns it on. |

### Catalog

| ID | Area | Description | Automation | Notes |
|----|------|-------------|------------|-------|
| C1 | Catalog browsing | Browse lanes, scroll, facet switching | Partial (simdrive) | Check cover alignment (F-018), facet speed (F-041) |
| C2 | Catalog search | Live search, filter pills, results | Partial (simdrive) | Check auto-search (F-025), button styling (F-045) |
| C3 | My Books | Tab navigation, sort, state after borrow/return | Partial (simdrive) | Check auto-refresh on appear (F-035) |
| C4 | Holds tab | Holds display, cancel from list vs detail | Manual | Check state sync after cancel (F-065) |
| C5 | Catalog offline state | Put the device in Airplane Mode and open the Catalog tab. Assert the offline state renders and **directs the patron to their downloaded books** (a usable route to My Books), rather than an empty lane, a spinner, or a bare error. Restore connectivity and confirm the catalog recovers without a relaunch. | Manual | PP-4578 (#1112). The recovery half matters as much as the empty state — a stuck offline view that survives reconnection is the regression. |
| C6 | Catalog top-left Palace branding | Confirm the top-left Palace icon is **static branding and not a tappable library switcher**. Tapping it must do nothing. Confirm the library switcher is still reachable by its intended route. | `catalog-browse-stateless` journey | PP-4821 (#1353). This removed an affordance patrons had learned; the check is that the old tap target is inert *and* that the replacement route exists. |
| C7 | Continue lane behavior | Open an ebook, return to the catalog, and confirm the Continue lane surfaces it. Then open an audiobook and confirm the lane updates to the newly-opened title. Confirm the lane collapses on scroll. Confirm the lane's audiobook continuation cards follow their own feature flag. | Manual | #1291 (a newly-opened ebook must update the lane over an audiobook), #1257 (scroll-collapse), PP-4910 (#1373 retired the catalog Continue section for audiobooks), #1294 (continuation cards split onto their own flag). Four changes landed on this one lane in this release — check the flag state before interpreting a "missing" lane as a bug. |

---

### Support & Feedback (new in 3.3.0)

Two patron-facing surfaces that did not exist in 3.2.0 and have **no matrix coverage at all**
until now. Both are reachable by ordinary patrons, and both can leak or misfire in ways the
unit suite cannot see — the triage bot handles free text typed by real people, and the rating
prompt is shown once and cannot be un-shown.

| ID | Area | Description | Automation | Notes |
|----|------|-------------|------------|-------|
| S1 | Support chat — reachable answer | From each entry point, ask a question that the FAQ corpus covers (e.g. how to add a library card, why a book will not download) and confirm a real answer comes back, that the topic chips route to an answer from **any** chip, and that a follow-up question does not repeat the preamble. | `triage-bot-category-chip-rapid-tap` journey | PP-4865 (#1390, #1382, #1379), PP-4847 (#1317), PP-4831. The recurring failure class here has been "the bot files a blank ticket instead of answering" — assert an answer appears, not merely that the screen changed. |
| S2 | Support chat — redaction of patron-typed secrets | Type text containing a password stated in prose ("my password is hunter2"), a payment-card number, a barcode/PIN pair, and a right-to-left override character. Confirm every one is redacted in the preview the patron is shown **and** in whatever is submitted. | `triage-bot-redaction-adversarial-input` journey; release-time leak check in the redaction corpus | PP-4817, PP-4842 (#1311, #1292). **This is the highest-severity row in the section: a miss here sends a patron's credentials to a support queue.** A prose-stated password was caught by chaos QA after the unit tests passed, so treat a green suite as insufficient evidence and drive the real UI. |
| S3 | Support chat — escalation and no dead ends | Ask something the corpus does not cover and confirm the bot escalates honestly (offers a real route to a human) rather than dead-ending, that the Send action is not stuck, that consent is requested before anything is sent, and that "Start over" clears the input. | Manual + the two chaos journeys | PP-4832 (#1308), PP-4843/4844/4845/4846 (#1313, #1318). |
| S4 | Help buttons — entry points | Confirm the Help button appears on **book detail** and **sign-in**, is correctly gated by its feature flag, and opens the support chat. Confirm it is **not** present on the audiobook full player (it was deliberately moved off). | Manual | PP-4812 (#1273); #1288 moved Help off the audiobook player. `HelpButton(entryPoint:)` has exactly two live call sites — `BookDetailView.swift:228` and `SignInModalView.swift:38`. A third appearance is a regression, not a bonus. |
| R1 | App rating — engagement gating | Confirm the rating prompt does **not** appear before the engagement thresholds are met. Exercise ordinary usage (browse, borrow, read) on a fresh install and confirm no prompt. | Partial (unit: engagement/eligibility tests) | PP-4087/PP-4088 (#1166). The failure mode that matters is a prompt that fires too early or on every launch — an over-eager rating prompt is an App Store review risk, and the patron only gets one. |
| R2 | App rating — sentiment gate and feedback path | Once eligible, confirm the sentiment gate appears, that a positive response routes to the StoreKit review request and a negative response routes to the feedback path (never to StoreKit), and that dismissing does not re-prompt on the next launch. | `app-rating-sentiment-gate` journey | PP-4089/PP-4090/PP-4091 (#1171). The negative-sentiment branch must never reach StoreKit — verify that direction explicitly. |

---

## P2 — Polish & Edge Cases (sample based on changes)

### UI & Accessibility

| ID | Area | Description | Automation | Notes |
|----|------|-------------|------------|-------|
| U1 | UI completeness | Side-by-side screen comparison (15+ screens) | `browserstack-screenshot-walker.py` | Catalog, My Books, Settings, Detail, Search |
| U2 | Dark mode | All screens render correctly in dark mode | Manual | |
| U3 | Accessibility | VoiceOver, touch targets, screen names | `ios_accessibility_audit` | Check nav titles (F-001), label completeness |
| U4 | Error states | Network loss, expired tokens, malformed OPDS | Manual | Check error classification (F-067) |
| U3-Footnote | VoiceOver — footnotes | In an EPUB with footnotes, use VoiceOver to reach a footnote reference, activate it, hear the note read, and return to the reading position via the backlink. | Manual (VoiceOver) | PP-4531 (#1106). `doc-noteref` / `doc-footnote` / `doc-backlink` roles. Unit-covered by `TPPReaderFootnoteAccessibilityTests`, but the DOM marking is only observable with VoiceOver actually running. |
| U3-PrintPage | VoiceOver — go to print page | Use "Go to Page" to navigate to a specific print page and confirm the reader lands on it and announces it. | `PP-4529-print-page-navigation-voiceover` journey | PP-4529 (#1096). |
| U3-WhereAmI | VoiceOver — "Where am I?" | Invoke the position announcement (custom rotor) mid-book and confirm it reports a sensible chapter/page position. | Manual (VoiceOver rotor) | PP-4527 (#1098, #1109). Rotor items are invisible to screenshots — this row cannot be automated by observation alone. |
| U3-BlockNav | VoiceOver — block-by-block navigation | Use the custom rotor to move block by block through a chapter and confirm focus advances one block at a time, in reading order, without skipping or looping. | Manual (VoiceOver rotor) | PP-4533 (#1107). |
| U3-SearchFocus | VoiceOver — focus retention on search | With VoiceOver on, type a search and submit; confirm focus **stays on the search field** and is not thrown to the top of the results. | Manual (VoiceOver) | PP-4641 (#1136). |
| U5 | Skeleton loading states | On a cold launch and on a library switch, confirm skeleton placeholders appear while content loads, match the shape of the real content (square covers/logos), animate on a shared clock (no visibly out-of-phase shimmer), respect Low Power Mode, and render correctly in dark mode. Confirm every skeleton is eventually **replaced** — a skeleton still on screen after load is a stuck state, not a loading state. | `PalaceForceSkeletons` launch argument forces the state; `settings-tour-stateless` journey touches Settings | PP-4797 (#1249, #1207, #1219). A stuck skeleton is the observable half of the Hidden Libraries deadlock (X8) — if you see one, capture the process state before assuming it is a render bug. |
| U6 | Chrome, tab bar, and motion | Confirm the tab bar and nav chrome are **monochrome** (no accent tints), the iOS-26 tab minimize behaves on scroll, tab switches do not flicker, catalog scrolling does not alias, and catalog taps produce haptics. Compare side by side with 3.2.0. | `tab-bar-tour` journey | PP-4743–PP-4748 (#1202, #1203, #1204, #1206, #1254, #1255, #1287). Palace chrome is monochrome by design — a tint appearing is a regression even if it looks deliberate. |

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
| X7 | Developer / Testing settings screen | Open Settings → Advanced → Testing and confirm the screen renders (it was migrated UIKit → SwiftUI), every row is reachable, the Advanced menu is always visible, and toggles persist across relaunch. Confirm simulated-error toggles are **off** in a candidate build. | `settings-tour-stateless` journey | PP-4788 (#1248), PP-4815 (#1271). A stale simulated-error toggle has previously been mistaken for a real defect in a QA report — check its state before filing anything that looks like an injected error. |
| X8 | Hidden Libraries toggle | Settings → Testing → **Enable Hidden Libraries**. Toggle it on. Assert the switch flips, the setting persists, and the app remains responsive. Then confirm hidden libraries appear in the picker with `availability=all` applied. | Manual | **DID NOT REPRODUCE on `ff3b1227c` (2026-08-20) — see `.regression-runs/rc-3.3.0-20260820/evidence/X8-hidden-libraries-result.txt`.** The toggle flipped, `NYPLUseBetaLibrariesKey` persisted `true`, and the UI stayed responsive (navigated to Catalog and rendered lanes immediately after). Tested on a FRESH install with ONE library and never signed in, one cell, one attempt — so this is *did not reproduce under these conditions*, not *fixed*; re-test with several libraries and a signed-in account. Note one recorded signal is not diagnostic: `Ss` + 0.0% CPU was also the state while idle and fully responsive, measured immediately before the toggle. Previously recorded as: Tapping this toggle freezes the app: process alive, 0.0% CPU, state `Ss` (sleeping), UI refuses all touch input for ~5 minutes, zero application log lines at any level. Two independent chaos agents reproduced it from different directions on different simulators during the 2026-08-10 develop sweep (off `b2f47552b`). It is a deadlock, not a dead control. Suspects already cleared: the `.TPPUseBetaDidChange` notification path and the publisher path — **do not re-investigate those**. This row exists so the regression *confirms current state* rather than rediscovering it; if it now passes, that is itself a finding worth recording. PP-4698 (#1147) is the `availability=all` half. |
| X9 | Side loading (test-only) | Confirm the side-load registry, manager, and catalog lane behave for a test build, and that the surface is **not reachable in a production configuration**. | Partial (unit) | PP-2677/2678/2679 (#1157). The regression that matters is exposure, not function — verify a release-configuration build does not surface it. |

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

- 2026-08-20 — **3.3.0 delta sweep: +26 rows.** The matrix had not been re-derived since 2026-07-08, while 280 commits, 115 PP tickets, 584 changed production files and 163 new production files landed on `develop`. Audit finding: the *unit* layer kept pace (712 test files changed in the same window) and the *journey* layer partly did, but the release-regression layer had zero rows for surfaces a patron can now reach. Added: **PR1–PR4** (P0 platform-risk — Swift 6 language-mode flip, Readium 3.9→3.11, iOS 17 floor, decomp Waves 1–3), **E9/E10** (offline-queued position writes; long-locked-playback autosave cadence), **E3-Skip/Sleep/Speed/Mini/Icons/Stream** (audiobook features added since 3.2.0), **C5–C7** (catalog offline state, static branding, Continue lane), **S1–S4 + R1–R2** (new Support & Feedback section — triage bot and app rating, neither of which existed in 3.2.0), **U3-Footnote/PrintPage/WhereAmI/BlockNav/SearchFocus** (Reader2 VoiceOver work), **U5/U6** (skeletons; chrome, tab bar and motion), **X7–X9** (Developer settings screen, Hidden Libraries, side loading). Two rows deliberately encode *known* state rather than asking a tester to rediscover it: **X8** (Hidden Libraries toggle deadlock, open since the 2026-08-10 sweep) and **E10** (main-runloop autosave cadence). Also corrected: the `C-ios18` cell is described in `.simdrive/regression-areas.json` as an "iOS-16 substitute" — the deployment floor is now iOS 17.0, so that label is stale (noted in PR3).

- 2026-07-08 — Added P0 in-place upgrade-path rows (UP1 / UP1-Result) for the 3.3.0 cycle. Motivation: 3.3.0 carries PR #1212 (registry "Bulletproof Ownership" — quarantine + `.bak` backup + `schemaVersion` bump) and PR #1199 (Swift 6 language-mode flip), and there was ZERO coverage of the in-place upgrade path — the highest-consequence failure class (user data loss). Row references the real persistence mechanism: `registry.json` + `registry.json.bak` + `.corrupt-<ts>` quarantine + INV-1 empty-save guard.
- 2026-05-27 — Added E2-Hang, E3-LCP-Resume, N4 from HelpSpot triage for the 3.2.0 regression. Sources: 17964 (Marketplace audiobook mid-book resume failure), 17960 + 17971 (hold-ready notification ↔ holds-list desync), 17966 (generic reader open hang outside Marketplace LCP PDFs). Each row pins the originating ticket so the link survives.
- 2026-04-17 — Added test-fixture mapping, expanded auth types from 3 to 7, split B6 by distributor, added B7 (hold→loan), A3 by auth type, E1/E3/E6 split by DRM + distributor, added critical auth × distributor cross-product (9 rows), added Automation Gaps roadmap.
- 2026-04-16 — Initial matrix from PP-4020 sprint findings.
