<!-- audit-verified: file paths and line ranges in Section 1 verified by direct Read of Palace/Audiobooks/*.swift and Palace/CarPlay/*.swift on 2026-05-28. Test inventory in Section 6 verified by `find PalaceTests/Audiobook* PalaceTests/CarPlay -name '*.swift'` (37 files). Known-trap claims in Section 7 sourced from MEMORY.md entries explicitly listed in Section 9. Items I could not verify by reading code (regression history details, in-field crash signatures, sim-environment audio limitations) are attributed to their source memory or HelpSpot ticket and not asserted as live code state. -->

# Audiobook area — verification checklist

**Owner area:** `Palace/Audiobooks/`, `Palace/CarPlay/`, plus the audiobook-touching auth surface at `Palace/Audiobooks/AudiobookSessionManager.swift` (SAML re-auth boundary) and the submodule at `ios-audiobooktoolkit/` (PalaceAudiobookToolkit SPM consumer).

**Purpose:** the architect's first deliverable on ANY swarm or /rigorous-fix in this area is *update this file*. Audiobook is the highest-churn area in the project — the toolkit submodule has shipped 25+ revisions with several revert cycles (see `reference_audiobook_toolkit_risk_profile.md`). Cross-vendor regressions are the dominant failure mode and they're invisible without a checklist that names every vendor × scenario.

**Last refresh:** 2026-05-28 (initial baseline).
**Refreshing architect:** sign and date the next-refresh row at the bottom of this file.

---

## 1. Call-site map (decision points across audiobook orchestration)

| File | Lines | What it does | Notes |
|------|-------|-------------|-------|
| `Palace/Audiobooks/AudiobookSessionManager.swift` | 274-292 | `openAudiobook(_:startPlaying:)` — entry point. Validates preconditions, supersedes prior loads via `loadGeneration`, runs `AudiobookLoader.load`. | Dual-channel error surface (`errorPublisher.send` + `return .failure`) is INTENTIONAL — CarPlay subscribes to publisher, in-app return checks Result. See trap 6. |
| `Palace/Audiobooks/AudiobookSessionManager.swift` | 305-365 | Load-completion continuation with `loadGeneration` supersession guard + SAML re-auth branch. | `continuation.resume(returning:)` is single-shot. Generation guard at 313 drops superseded completions. |
| `Palace/Audiobooks/AudiobookSessionManager.swift` | 931-948 | `shouldTriggerSAMLReauthForLoadFailure` / `shouldTriggerSAMLReauthForPlaybackFailure` — boundary predicates routing audiobook failures through `TPPReauthenticator`. | Migrated through AuthCoordinator wrapper in PR #1018; predicates kept as-is. |
| `Palace/Audiobooks/AudiobookSessionManager.swift` | 1111-1149 | `.playbackFailed` PlayerEvent handler — mid-playback errors. Records Crashlytics non-fatal, then SAML re-auth boundary, then `errorPublisher`. | PP-3703 (HelpSpot 17727) lives here. Cold-load failure branch at 1160 dismisses player UI rather than offering retry. |
| `Palace/Audiobooks/AudiobookLoader.swift` | 70 | `load(_:completion:)` — callback-shaped public entry. | Callback shape is deliberate — the loader fans out across vendor adapters and merges results; an `async` rewrite is a contract change. |
| `Palace/Audiobooks/AudiobookLoader.swift` | 111-244 | `resolveSource` → `refreshTokenIfNeeded` → `build` → `finalizeBuild` pipeline. | Token refresh happens BEFORE manifest fetch; this is the path PP-4276 / PR #910 hardened. |
| `Palace/Audiobooks/AudiobookLoader.swift` | 386 | `makeProductionAdapters()` — assembles the vendor dispatch chain. | First-match-wins ordering. Adding a new vendor = new adapter + insert into this array. |
| `Palace/Audiobooks/Vendors/AudiobookVendorAdapter.swift` | 42, 50, 62 | `AudiobookVendorAdapter` protocol — `canHandle(_:) → resolveManifest(...)`. | Callback-shaped (NOT `async`) to match the loader's public surface. |
| `Palace/Audiobooks/Vendors/Adapters+Production.swift` | 27-89 | Production wiring: `OpenAccessAdapter`, `BearerTokenAdapter` (MIME-gated wrapper), `LCPAdapter`, `LocalFileAdapter`. | OpenAccessAdapter is the fallback in the chain — see PR #979 (swarm_5c8ddbd5 audiobook vendor extraction). |
| `Palace/Audiobooks/PlaybackBootstrapper.swift` | 147, 181, 203, 243-432 | `ensureInitialized` (phone) / `ensureInitializedForCarPlay`, `configureAudioSession`, `setupRemoteCommands`, MPRemoteCommandCenter handlers. | Independent of UI lifecycle — must run regardless of which surface (phone, CarPlay, lock screen) triggers playback. |
| `Palace/Audiobooks/NowPlayingCoordinator.swift` | 126, 172, 188, 208, 226 | `updateNowPlaying`, `setPlaybackState`, `updatePlaybackRate`, `updateArtwork`, `clearNowPlaying`. | "ONLY class that should update Now Playing info" (header comment) — guards against race conditions across phone/CarPlay/lock-screen. |
| `Palace/Audiobooks/LCP/LCPAudiobooks.swift` | (verify per refresh) | `canOpenBook`, `hasLCPAcquisition` (recursive predicate). | Recursive walker landed via PR #972 (PP-4407). See trap 4 — Marketplace LCP MIME nesting. |
| `Palace/CarPlay/CarPlayTemplateManager.swift` | 33, 99, 395-453, 542-560, 604 | CarPlay template lifecycle. State-mutating calls (`setRootTemplate`, `presentTemplate`, `pushTemplate`, `popTemplate`, `dismissTemplate`) — most pass explicit completion. | Lines 321, 448, 542, 560 still pass `completion: nil` — verify these paths are NOT state-mutating-from-failure-prone-state. CarPlayCrashRegressionTests enforces this with a static scan. |
| `Palace/CarPlay/CarPlayAudiobookBridge.swift` | (verify per refresh) | Forwards `AudiobookSessionManager.errorPublisher` AND result returns into CarPlay UI. | The bridge is where dual-channel errors get deduped in PR #968 (CarPlayTemplateManager's `isPresentingAlert` flag). |

---

## 2. Module ownership

| Module | Owner | Public surface (changes here are a contract break) |
|--------|-------|---------------------------------------------------------|
| `Palace/Audiobooks/` | Main target | `AudiobookSessionManager` (singleton-killed in PR #982), `AudiobookSessionManaging` protocol, `AudiobookSessionState` / `AudiobookSessionError` enums, `AudiobookLoader`, `AudiobookVendorAdapter` protocol, `PlaybackBootstrapper`, `NowPlayingCoordinator`, `AudiobookPositionPolicy`, `LCPAudiobooks` |
| `Palace/Audiobooks/Vendors/` | Main target | The 5 production adapters: `BearerTokenAdapter`, `LCPAdapter`, `LocalFileAdapter`, `OpenAccessAdapter`, plus the `Adapters+Production` wiring. Adding a vendor = new adapter + insert into `AudiobookLoader.makeProductionAdapters` chain. |
| `Palace/Audiobooks/Tracker/` | Main target | `AudiobookTimeTracker`, `AudiobookDataManager`, `AudiobookTimeEntry`, `DataManager`. Position-write was unified to PalaceReadingPosition SPM in PR #980. |
| `Palace/CarPlay/` | Main target | `CarPlaySceneDelegate`, `CarPlayTemplateManager`, `CarPlayAudiobookBridge`, `CarPlayTemplateBuilder`, `CarPlayImageProvider`. iOS 26 requires non-nil completion on every state-mutating call (PR #968). |
| `ios-audiobooktoolkit/` (submodule → SPM `PalaceAudiobookToolkit`) | Upstream | `Player` protocol (async/await as of PR #177), `DefaultAudiobookManager`, `OpenAccessPlayer`, `LCPStreamingPlayer`, `OpenAccessTrack`. Cross-repo — every submodule bump is a cross-vendor regression risk (see trap 1). |

---

## 3. Vendor × scenario dispatch matrix

Verify before changing playback orchestration. Cross-vendor smoke tests live in `PalaceTests/Audiobooks/CrossVendorSmokeTests.swift` (4 vendor entries — LCP, BearerToken, OpenAccess, LocalFile).

| Vendor | First-open (cold) | Resume from pause | Network-loss mid-playback | CarPlay connect mid-playback | Background → foreground | Lock-screen controls |
|---|---|---|---|---|---|---|
| **Findaway / AudioEngine** | Player loads decrypted local manifest. F-046 (skip direction) + F-047 (TOC visibility) regression-prone. | Position restored from PalaceReadingPosition. | Local decode survives; no network needed post-license. | NowPlayingCoordinator hands off to CarPlay; PR #982 killed the singleton so explicit deps required. | OK if AVAudioSession survives backgrounding. | MPRemoteCommandCenter handlers in PlaybackBootstrapper.swift:279-432. |
| **OverDrive (OD)** | Manifest format quirks (F-053). Token refresh BEFORE open is mandatory — see AudiobookLoader.swift:137. 2.x regressed 25K Crashlytics non-fatals pre-fix. | Same as Findaway. | `x-overdrive-scope` + `x-overdrive-patron-authorization` headers required on 302 retry. | Same as Findaway. | OK. | OK. |
| **LCP (Marketplace)** | **F-011 / PP-4436 first-open hang** — engine doesn't start, nav-away-and-back fixes it. Suspect: PalaceAudiobookToolkit coordinator init race with PR #990 overhaul. | **HelpSpot 17964 — Carol mid-book resume failure** — broadened by E3-LCP-Resume row in regression matrix. | LCPStreamingPlayer.playCallback 30s timeout; **continuation-misuse crash on library-swap stress** — fixed via once-guard at LCP source + OpenAccessPlayer bridge (2026-05-26). | Same. | OK. | OK. |
| **OpenAccess (DPLA / no-DRM)** | Single-leg manifest fetch (no bearer dance). Fallback in the dispatch chain. | Same as Findaway. | **BiblioBoard cross-host token scoping bug** — bearer scoped to `manifest.originHost`, OPDS-for-Distributors splits manifest + media across hosts → 403 silent → lock-screen timer walks past playable range. | Same. | OK. | OK. |
| **BearerToken (BiblioBoard, two-leg manifest)** | MIME-gated wrapper around BearerTokenAdapter — only claims books where the acquisition chain MIME-matches. | Same. | Same BiblioBoard cross-host issue (see OpenAccess row). | Same. | OK. | OK. |
| **LocalFile (downloaded / sideloaded)** | Local manifest read; covers re-open after download completes. | Position from PalaceReadingPosition. | N/A. | Same. | OK. | OK. |

Additional scenario rows (apply to all vendors):

- **Audio-session interruption** (incoming phone call, Siri, other-app audio): MUST resume gracefully — see trap 7.
- **Bluetooth disconnect/reconnect**: F-060 regression-prone.
- **CarPlay SIGABRT path**: dual-channel error from AudiobookSessionManager + `completion: nil` on CPInterfaceController state-mutating call → NSException at CPInterfaceController.m:481 on iOS 26 (PR #968). Tests in `PalaceTests/CarPlay/`.

**F-011 / PP-4436 is the dominant 3.2.0 regression.** Cite explicitly in every audiobook PR until closed. Suspect surface: PR #990 (swarm_efd1f0c3) touched AudiobookSessionManager + AudiobookLoader + NowPlayingCoordinator + PlaybackBootstrapper + AudiobookVendorAdapter against the new toolkit contract.

---

## 4. Acquisition-chain fixture catalog (subset — full version in MEMORY.md `reference_marketplace_lcp_mime_nesting.md`)

For any predicate that asks "is this book an X audiobook?" — the chain MUST be walked recursively:

| Distributor | `defaultAcquisition.type` | Nesting depth to real type | Canonical fixture |
|---|---|---|---|
| Palace Marketplace LCP audiobook | `application/opds-publication+json` | 2 levels (`opds-publication → LCP license → audiobook+lcp`) | `Animal Farm` on Palace Marketplace. Recursive predicate `LCPAudiobooks.hasLCPAcquisition` landed PR #972. |
| Overdrive audiobook | varies | varies | `Catching Fire` on A1QA |
| Findaway / AudioEngine | varies | direct | Any Findaway-keyed title |
| OPDS-for-Distributors (BiblioBoard) | direct media URL | manifest + media on DIFFERENT hosts | BiblioBoard catalog titles; see trap 3. |
| Open access (DPLA) | direct | none | Any open-access audiobook |

**Recipe:** if a predicate is added, audit the chain — `OPDS2` nests arbitrarily; nothing caps it at 2. PP-4407 shipped a fix for the 2-level case; PP-4454 (PR #1008) ported the recursive predicate fix forward. Tests: `PalaceTests/Audiobook/AudiobookLoaderOPDSShapeMatrixTests.swift`, `LCPAcquisitionPredicateTests.swift`, `AudiobookLoaderPredicateTests.swift`.

---

## 5. Telemetry / observable surface points

| Surface point | File | Event / signal | Notes |
|---------------|------|---------|-------|
| Open audiobook | `AudiobookSessionManager.openAudiobook` | `Log.info` "Opening audiobook: '...' (id: ...)" + state transition `.idle → .loading` on `playbackStatePublisher` | Generation guard at 313 prevents superseded completions. |
| Load failure (cold) | `AudiobookSessionManager:326-330` | `errorPublisher.send(sessionError)` + `state = .error` + recordPlaybackFailure Crashlytics non-fatal | Cold-load failures dismiss player UI; no retry offer. |
| Playback failure (mid-stream) | `AudiobookSessionManager:1111-1149` | `Self.recordPlaybackFailure(error:position:bookId:)` → Crashlytics non-fatal (includes underlying error code, HTTP status, track URL, book id) | Replaces silent fall-through for 403 from BiblioBoard. |
| SAML re-auth boundary | `AudiobookSessionManager:336, 1128` | `Log.info` "SAML credentials stale ..." / "Bearer token refresh failed (session expired)" | PP-3703, HelpSpot 17727. |
| Now-playing UI updates | `NowPlayingCoordinator.applyUpdate` / `performUpdate` | MPNowPlayingInfoCenter updates; `checkForDryStream` watchdog | "ONLY class that should update Now Playing" — race-condition prevention. |
| Player events (toolkit upstream) | `PalaceAudiobookToolkit.Player` protocol | `playbackStarted` / `playbackStopped` / `playbackFailed` events | Async/await surface as of PR #177; bridge wraps in continuation with once-guard (LCP fix). |

---

## 6. Test surface

**Test files** (37 total across `PalaceTests/Audiobook/`, `PalaceTests/Audiobooks/`, `PalaceTests/CarPlay/` per `find ... | wc -l` on 2026-05-28):

`PalaceTests/Audiobook/` (15 files): AudiobookLoaderTests, AudiobookLoaderDispatchTests, AudiobookLoaderOPDSShapeMatrixTests, AudiobookLoaderPredicateTests, AudiobookSessionManagerTests, AudiobookPositionPolicyTests, AudiobookBookmarkBusinessLogicPositionWriteTests, AudiobookDataManagerSyncTests, AudiobookDataManagerModelsTests, AudiobookTimeEntryTests, AudiobookTrackerExtendedTests, AudiobookReliabilityTests, AudiobookIssueFixTests, AudiobookTOCTests, LCPAcquisitionPredicateTests + `Vendors/` subdir.

`PalaceTests/Audiobooks/` (14 files): AudiobookOpenStateRaceTests, AudiobookSessionManagerShutdownTests, AudiobookSessionStateTests, AudiobookLoadFailureSAMLReauthTests, AudiobookLoaderFinalizeBuildTests, AudiobookEventsTests, AudiobookTimeTrackerEdgeTests, AudioEngineWrapperTests, CrossVendorSmokeTests (4 vendor smoke tests — LCP, BearerToken, OpenAccess, LocalFile), NowPlayingCoordinatorTests, NowPlayingCoordinatorBackgroundTests, PlaybackBootstrapperTests, SAMLPlusBiblioBoardExpirationTests, TPPReturnPromptHelperTests + `Mocks/`.

`PalaceTests/CarPlay/` (2 files): CarPlayTests, CarPlayAuthHelperReadinessTests. Note: `CarPlayCrashRegressionTests` referenced in memory needs verification — search confirmed memory predates current tree.

Other audiobook-touching test files: `PalaceTests/AudiobookmarkTests.swift`, `AudiobookBookmarkBusinessLogicTests.swift`, `AudiobookPlaybackTests.swift`, `AudiobookTrackerTests.swift`, `LCP/LCPAudiobooksTests.swift`, `Logging/AudiobookFileLoggerTests.swift`, `Contract/AudiobookPositionAdapterContractTests.swift`, `Accessibility/AudiobookAccessibilityTests.swift`.

**Tests that test BEHAVIOR (must-survive any refactor):**
- `CrossVendorSmokeTests` — one smoke per vendor backend. Required by the toolkit-risk profile. Run on every audiobook PR.
- `AudiobookOpenStateRaceTests` — `loadGeneration` supersession contract.
- `AudiobookLoadFailureSAMLReauthTests` + `SAMLPlusBiblioBoardExpirationTests` — PP-3703 / HelpSpot 17727 boundary.
- `AudiobookPositionPolicyTests` + `Contract/AudiobookPositionAdapterContractTests` — position-write invariants (PalaceReadingPosition SPM contract).
- `LCPAcquisitionPredicateTests` + `AudiobookLoaderPredicateTests` + `OPDSShapeMatrixTests` — recursive MIME predicate (PP-4407 / PP-4454).
- `NowPlayingCoordinatorBackgroundTests` — backgrounding races.

**Tests that test IMPLEMENTATION (rewritable when underlying changes):**
- Tests asserting on specific call orders inside `AudiobookSessionManager` private methods (the contract is the dual-channel error surface + state-publisher transitions, not the internal sequencing).

**Sim-environment caveat:** none of these tests validate actual audio decode — sim doesn't decode audiobook audio (`feedback_audiobook_sim_audio_limitation.md`). Position-state drivers (skip ±30s, TOC seek, scrubber drag) are the appropriate UI-level checks on sim. Real-device runs required for decoder validation, audio-session interruption, background playback, and playback-rate audibility.

---

## 7. Known traps / anti-patterns (lessons from prior work)

1. **PalaceAudiobookToolkit submodule churn — 25+ revisions with revert cycles** (`reference_audiobook_toolkit_risk_profile.md`). Findaway / OverDrive / LCP / open-access all share the same player infrastructure. Every audiobook PR — even single-vendor ones — must run `CrossVendorSmokeTests` and a manual smoke on the 4 backend types before merge. Specific historical regressions: 2.0.2→2.0.4 adaptive memory partial abandonment; 2.0.5→2.1.0 location race + concurrency crashes; 2.2.3→2.2.4 manifest fetch using wrong task type, skipping bearer dance — a contract violation that shipped to prod.
2. **LCP `play(at:)` continuation-misuse crash on library-swap stress** (2026-05-26 production crash, `lcp_player_continuation_misuse_2026_05_26.md`). `LCPStreamingPlayer.playCallback` 30s timeout DispatchWorkItem can fire before the underlying seek completes; both call the same completion handler. Once `OpenAccessPlayer.play(at:)` wraps in `withCheckedThrowingContinuation` (PR #177), the second resume traps. **Rule:** every `withCheckedContinuation` wrapping a multi-path callback needs a once-guard at the bridge (NSLock + `fired` flag, set under lock, fire outside lock). Fix the source AND guard the bridge. Audit every callback impl before wrapping in a continuation.
3. **BiblioBoard cross-host token scoping** (`reference_biblioboard_cross_host_token_scoping.md`). `OpenAccessTrack` scoped bearer to `manifest.originHost`. OPDS-for-Distributors puts manifest at `palaceproject.io` and chapter MP3s at the distributor CDN (`library.biblioboard.com`). Mismatch strips Authorization → 403 → `AVPlayerItem .failed` did NOT surface to `playbackStatePublisher` → lock-screen 2s timer walks past playable range with no error UI. **Rule:** auth scope must be "hosts CM authorizes me to talk to," not "the host this URL lives on." Applies to LCP license servers, OverDrive Marketplace, Findaway chunked downloads — every new vendor must answer the token-scoping question explicitly.
4. **Marketplace LCP MIME-nesting in acquisition chain** (`reference_marketplace_lcp_mime_nesting.md`, PP-4407 / PP-4454). `canOpenBook` checked only `defaultAcquisition.type`, missed LCP MIME 2 levels deep in `indirectAcquisitions`. 639MB `.lcpa` ZIP saved as `.epub` → "Failed to parse local file as JSON." **Rule:** acquisition-chain predicates must be recursive by default. OPDS2 nests arbitrarily; nothing caps depth at 2. Audit any predicate that touches `defaultAcquisition.type` — almost always a bug; should walk the full `indirectAcquisitions` tree.
5. **iOS sim doesn't decode audiobook audio** (`feedback_audiobook_sim_audio_limitation.md`). Tapping Play flips the UI icon AND tells the player it's playing, but the audio engine doesn't decode (no audio device, AVAudioSession unreliable on sim). Position indicator stays stuck. Drive position state via **skip ±30s / TOC seek / scrubber drag / bookmark navigation** — they exercise the same position-invariant code paths without the decoder. DRM activation, audio-session interruption, background playback, BT reconnect, and playback-rate audibility must be deferred to real device.
6. **CarPlay SIGABRT — dual-channel error + `completion: nil`** (PR #968, `carplay_crash_3_1_0_build_476.md`). Two compounding bugs: (a) `AudiobookSessionManager.openAudiobook` surfaces a single failure through `errorPublisher.send` AND `return .failure` (intentional — phone + CarPlay both need it), (b) every CarPlay state-mutating call (`presentTemplate`/`pushTemplate`/`popTemplate`/`popToRootTemplate`/`dismissTemplate`/`setRootTemplate`) used `completion: nil`. iOS 26 raises NSException at CPInterfaceController.m:481 when one of these calls fails with `completion: nil`. **Rule:** NEVER pass `completion: nil` to any CarPlay state-mutating call. Always provide `{ _, error in if let error = error { Log.warn(...) } }`. Dedup alerts via `interfaceController.presentedTemplate == nil` + local `isPresentingAlert` flag, reset in dismiss-via-OK AND `templateDidDisappear`. CarPlayCrashRegressionTests should enforce this with a globbed static scan (verify file exists in current tree).
7. **Audio-session interruption (phone call, Siri, other audio) must resume gracefully.** AVAudioSession.interruptionNotification fires on call-in/Siri/Music; the player MUST pause on `.began` and offer/auto-resume on `.ended` with `.shouldResume` option. Regression-prone because sim can't reproduce — real-device only.
8. **`completion: nil` legacy paths still exist in CarPlay code.** `CarPlayTemplateManager.swift` lines 321, 448, 542, 560 still pass `completion: nil`. Verify on every refresh that these are not state-mutating-from-failure-prone-state paths (e.g., line 321 is `popToRootTemplate` in a guard-protected branch; line 542 is `pushTemplate` for chapter UI). If iOS bumps tighten the CPInterfaceController contract further, these need completion handlers too.

---

## 8. Architect's pre-swarm checklist (verify before writing a new contract)

Before any new swarm or /rigorous-fix in this area, the architect should:

1. **Refresh sections 1-3** — confirm call-site map, module ownership, vendor × scenario matrix are still accurate. Add new vendors / scenarios; mark removed ones.
2. **Re-check toolkit submodule SHA** — `git submodule status ios-audiobooktoolkit`. If it moved since last refresh, the matrix in section 3 needs a cross-vendor re-validation. The toolkit is the most regression-prone dependency in the project.
3. **Re-run cross-vendor smoke test inventory** — `grep "func testSmoke_" PalaceTests/Audiobooks/CrossVendorSmokeTests.swift | wc -l` — should be ≥ 4 (LCP, BearerToken, OpenAccess, LocalFile). If a vendor was added without a smoke test, that's the first gap to close.
4. **Re-grep `completion: nil` in CarPlay** — `grep -rn "completion: nil" Palace/CarPlay/` — every match needs justification per trap 6 + 8.
5. **Re-check F-011 / PP-4436 status** — confirm first-open hang is still open or marked closed. If still open, every PR touching `AudiobookSessionManager` / `AudiobookLoader` / `PlaybackBootstrapper` / `NowPlayingCoordinator` must explicitly state whether it affects the suspected race window.
6. **Re-check critical-path tests pass against current develop BEFORE the swarm starts** — `CrossVendorSmokeTests`, `AudiobookOpenStateRaceTests`, `AudiobookLoadFailureSAMLReauthTests`, `LCPAcquisitionPredicateTests`. Post-swarm regressions become attributable.
7. **Update Section 9 (refresh history)** with date + your initials.

---

## 9. Refresh history

| Date | Refreshed by | Notes |
|------|-------------|-------|
| 2026-05-28 | swarm rigor-meta-improvement (initial baseline) | Initial baseline derived from MEMORY.md audiobook entries (`audiobook_first_open_hang_3_2_0`, `lcp_player_continuation_misuse_2026_05_26`, `carplay_crash_3_1_0_build_476`, `reference_audiobook_toolkit_risk_profile`, `reference_biblioboard_cross_host_token_scoping`, `feedback_audiobook_sim_audio_limitation`, `reference_marketplace_lcp_mime_nesting`) + regression matrix E3-* / B6 / X2 rows + `git log --oneline origin/develop -- Palace/Audiobooks/`. UNKNOWN items called out for follow-up: existence of `PalaceTests/CarPlay/CarPlayCrashRegressionTests`, current state of F-011 / PP-4436, exact line ranges in `LCPAudiobooks.swift` + `CarPlayAudiobookBridge.swift`. |

---

**This file is owned by the audiobook area.** If you change anything in the modules listed in Section 2, update the relevant section here before you commit. The Definition of Done (CLAUDE.md) treats out-of-date area checklists as scope debt. Audiobook regressions in this codebase are cross-vendor by default — when one player path breaks, the others are also at risk. The whole point of this checklist is that it's faster to refresh than to re-derive from a cold start.
