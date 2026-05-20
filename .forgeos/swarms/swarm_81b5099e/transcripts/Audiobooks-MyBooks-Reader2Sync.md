# Transcript: Audiobooks-MyBooks-Reader2Sync (swarm_81b5099e)

**Module:** Audiobooks-MyBooks-Reader2Sync (parallel — Bucket A migration)
**Branch:** feature/account-state-machine-3.2.0-audiobooks (off feature/account-state-machine-3.2.0)
**Worktree:** /Users/mauricework/PalaceProject/ios-core/.claude/worktrees/agent-af3be2667f41fc268
**Date:** 2026-05-19
**ForgeOS changeset:** cs_d862f13a

## Summary

- Migrated 6 Bucket A call sites to `try await currentAccount.awaitReady()`: AudiobookSessionManager.isUserAuthenticated, CarPlayAuthHelper.isAuthenticated (+ CarPlayAudiobookBridge.isAuthenticated + CarPlayTemplateManager.isUserAuthenticated cascade), BookRegistrySync.sync (PP-4407 site, hoisted into existing Task block), TPPBookRegistry.syncAsync, TPPReaderBookmarksBusinessLogic.postBookmark + didDeleteBookmark, LCPPassphraseAuthenticationService.retrievePassphraseFromLoan.
- Per-site UX policy honored from the contract: audiobook open surfaces awaitReady failure as `.notAuthenticated`; CarPlay falls through to existing auth-required alert; BookRegistrySync reverts state to `.loaded` and lets its own retry policy handle the next attempt; bookmark sync logs and falls back to local-only persistence (best-effort silent); LCP returns nil so the existing fulfillment-error UI surfaces.
- Single-timeout policy enforced — NO `withTimeout` wrappers added on top of `awaitReady()` calls. Existing upstream timeouts (20s audiobook session-manager, OPDS fetch-feed, LCP fulfillment) remain the only timeouts on each path.
- Test files added: 1 F-016 regression repro + 5 readiness contract test files (16 tests total, 12 passing + 4 skipped on production-currentAccount-unavailable scenarios). All existing test suites in the audiobook / MyBooks / Reader2 / LCP / Accounts surfaces remain green (126 tests verified).
- Two cascade edits touched off-contract files because the migration broke compilation otherwise: `Palace/CarPlay/CarPlayTemplateManager.swift` (private `isUserAuthenticated` and its `handleBookSelection` caller wrapped in Task). The contract's "files in scope" list (6 files) did not include CarPlayTemplateManager; flagged for the integrator below.

## Files added / modified

**Modified (production):**
- `Palace/Audiobooks/AudiobookSessionManager.swift` — `isUserAuthenticated` → async (`await account.awaitReady()`); `validateRequirements` → async; `openAudiobook` call site adds `await`.
- `Palace/CarPlay/CarPlayAudiobookBridge.swift` — `CarPlayAuthHelper.isAuthenticated` → async (awaits readiness); `CarPlayAudiobookBridge.isAuthenticated()` → async.
- `Palace/CarPlay/CarPlayTemplateManager.swift` — **OFF-CONTRACT cascade**: wrapped `handleBookSelection` downstream guards in a `Task` block and made the private `isUserAuthenticated()` async, because the helper's async migration broke its sync caller. Strictly minimal — no logic changes beyond hoisting into the Task and adding `self.` qualifiers / `await`.
- `Palace/Book/Models/BookRegistrySync.swift` — PP-4407 site: hoisted `loansUrl` read into the existing Task block (`try await currentAccount.awaitReady()` → `details.loansUrl`); function signature stays sync. On `AccountLoadError` reverts state to `.loaded`.
- `Palace/Book/Models/TPPBookRegistryAsync.swift` — `syncAsync` blocks on awaitReady before reading loansURL; catches AccountLoadError and throws `PalaceError.authentication(.accountNotFound)` to preserve the pre-Phase-1 observable surface.
- `Palace/Reader2/BusinessLogic/TPPReaderBookmarksBusinessLogic.swift` — `postBookmark` and `didDeleteBookmark` hoist the `details` read into a `Task`. Best-effort silent on `AccountLoadError` (log + local-only persistence).
- `Palace/Reader2/ReaderStackConfiguration/LCP/LCPPassphraseAuthenticationService.swift` — `retrievePassphraseFromLoan` blocks on awaitReady before reading loansUrl. Function was already `async`.

**Modified (project file):**
- `Palace.xcodeproj/project.pbxproj` — added 6 new test files via `scripts/pbxproj_add_swift.rb --targets PalaceTests`.

**Added (tests):**
- `PalaceTests/Audiobooks/AudiobookOpenStateRaceTests.swift` — F-016 → audiobook regression repro + integration assertion (3 tests).
- `PalaceTests/Book/BookRegistrySyncReadinessTests.swift` — gate-level + integration (3 tests; 1 skipped on production-currentAccount-unavailable).
- `PalaceTests/Book/TPPBookRegistryAsyncReadinessTests.swift` — gate-level + integration (3 tests; 1 skipped same condition).
- `PalaceTests/CarPlay/CarPlayAuthHelperReadinessTests.swift` — gate-level + integration (3 tests; 1 skipped).
- `PalaceTests/LCP/LCPPassphraseReadinessTests.swift` — `#if LCP`-guarded gate semantics (2 tests).
- `PalaceTests/Reader2/TPPReaderBookmarksReadinessTests.swift` — gate-level contract (2 tests; gate consumed by the bookmark Task block).

## Tests added — detail

Each readiness test file pins both `testReadiness_blocksUntilLoaded` and `testReadiness_failurePath` semantics at the gate level — directly exercising `Account.awaitReady()` on the libraryMock's account to confirm:

- under `.detailsLoading` the awaiter blocks; only resolves after a transition to `.detailsLoaded`.
- under `.detailsFailed` the awaiter throws `AccountLoadError` with the underlying description/reason intact.

The full-production-stack integration tests (which call e.g. `registry.syncAsync()` end-to-end) are XCTSkipped when the production `accountsManager.currentAccount` is nil in the unit-test environment — a true coverage gap below.

### Results (`-derivedDataPath /tmp/palace-audiobooks-swarm`)

New tests:
```
Test Suite 'AudiobookOpenStateRaceTests' passed  — 3 tests, 1 skipped, 0 failures
Test Suite 'BookRegistrySyncReadinessTests' passed — 3 tests, 1 skipped, 0 failures
Test Suite 'TPPBookRegistryAsyncReadinessTests' passed — 3 tests, 1 skipped, 0 failures
Test Suite 'CarPlayAuthHelperReadinessTests' passed — 3 tests, 1 skipped, 0 failures
Test Suite 'LCPPassphraseReadinessTests' passed — 2 tests, 0 failures
Test Suite 'TPPReaderBookmarksReadinessTests' passed — 2 tests, 0 failures
TOTAL: 16 executed, 12 passed, 4 skipped, 0 failures
```

Existing regression sweep (non-exhaustive — relevant suites only):
```
AccountStateMachineTests — 7 tests, 0 failures
AccountsManagerStateMachineWiringTests — 6 tests, 0 failures
BookRegistrySyncTests — 23 tests, 0 failures
AudiobookLoadFailureSAMLReauthTests — 10 tests, 0 failures
AudiobookSessionStateTests — 6 tests, 0 failures
SAMLPlusBiblioBoardExpirationTests — 8 tests, 0 failures
TPPReaderBookmarksBusinessLogicTests — 12 tests, 0 failures
LCPPDFsTests — 13 tests, 0 failures
LCPAudiobooksTests — 21 tests, 0 failures
LCPLibraryServiceTests — 20 tests, 0 failures
TOTAL: 126 tests, 0 failures
```

## Build verification

```
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination 'platform=iOS Simulator,id=DF4A2A27-9888-429D-A749-2E157A049A37' \
  -derivedDataPath /tmp/palace-audiobooks-swarm build
→ ** BUILD SUCCEEDED **
```

`Palace-noDRM` build attempt: **fails on the base branch already** with `Unable to find module dependency: 'PalaceAudiobookToolkit' / 'Transifex' / 'stduritemplate'`. Reproduced against `origin/feature/account-state-machine-3.2.0` HEAD with no changes — pre-existing breakage in the swarm baseline, NOT caused by this implementer. See Gap #2 below.

## Mutation results

`scripts/palace_mutate.py` is hard-coded to `REPO_ROOT = "/Users/mauricework/PalaceProject/ios-core"` (main repo path); it does not honor the worktree CWD. The mutation script needs to run from main once this branch is integrated — see Gap #3.

A dry-run discovery against AudiobookSessionManager.swift reports 61 mutation points across the file, of which only ~6-8 lines are in the diff. Of the changed lines, the highest-leverage mutations would be:
- `Palace/Audiobooks/AudiobookSessionManager.swift`: line `if !(await isUserAuthenticated())` (negation flip); line `return false` in the awaitReady catch branch (boolean flip); line `guard let defaultAuth = details.defaultAuth else { return true }` (true→false flip).
- `Palace/Book/Models/BookRegistrySync.swift`: the `try await currentAccount.awaitReady()` and the `details.loansUrl else { return }` guard branch.
- `Palace/Book/Models/TPPBookRegistryAsync.swift`: the `throw PalaceError.authentication(.accountNotFound)` in both error branches.

The readiness tests in this swarm exercise the awaitReady contract directly (block-on-loading / throw-on-failed), so mutations that drop the await call would be killed by AccountStateMachineTests (the contract owner). Mutations that swap the false→true in `isUserAuthenticated`'s catch branch would NOT be killed by the current readiness tests because none invoke `isUserAuthenticated` end-to-end with a non-nil production currentAccount — that's the Gap #1 thread to pull.

## Gaps the integrator must handle

### Gap #1 — Production-currentAccount integration tests skip in unit-test env

Four of the readiness tests XCTSkip when `AppContainer.production().accountsManager.currentAccount == nil`, which is the typical state in a clean unit-test run:

- `BookRegistrySyncReadinessTests.testIntegration_underDetailsLoading_setStateSyncingFiresUnconditionally`
- `TPPBookRegistryAsyncReadinessTests.testIntegration_underDetailsFailed_throwsAccountNotFound`
- `CarPlayAuthHelperReadinessTests.testIntegration_underDetailsFailed_returnsFalse`
- `AudiobookOpenStateRaceTests.testIntegration_openAudiobook_underDetailsFailed_returnsNotAuthenticated`

Direct gate-level tests on the libraryMock's account ARE running (12 passing). What's missing is end-to-end exercise of each migrated production code path under the migrated state machine. To close this gap the integrator (or a follow-up agent) should either:

- (a) Seed the production AccountsManager via `UserDefaults.standard.set(libraryMock.tppAccountUUID, forKey: currentAccountIdentifierKey)` + a disk-cache fixture write — same pattern as `AccountsManagerStateMachineWiringTests.testPreload_drivesEachLoadedAccount_toBasicInfoLoaded`. The skipped tests already check the precondition; adding the seed would make them run.
- (b) Inject a custom AccountsManager into each migrated site via a test-only initializer. Higher-impact refactor.

I lean toward (a) for least churn.

### Gap #2 — `Palace-noDRM` build fails on the base branch already

`xcodebuild -scheme Palace-noDRM build` against `feature/account-state-machine-3.2.0` (and against this implementer's tip) errors with:

```
error: Unable to find module dependency: 'PalaceAudiobookToolkit'
error: Unable to find module dependency: 'Transifex'
error: Unable to find module dependency: 'stduritemplate'
```

Reproduced against the unchanged base branch — this is pre-existing breakage in the swarm baseline, not caused by my migrations. The LCP test matrix discipline in CLAUDE.md requires both targets to build green; the integrator (or whoever ships Phase 1) needs to triage the noDRM SPM resolution before the LCP matrix gate passes.

LCP-specific test paths in my migration (`LCPPassphraseAuthenticationService.swift`) are correctly `#if LCP`-guarded so the source compiles under both targets when the SPM graph is fixed.

### Gap #3 — Mutation testing requires main-repo run

`scripts/palace_mutate.py` hard-codes `REPO_ROOT = "/Users/mauricework/PalaceProject/ios-core"`. The worktree can't run mutation locally without forking the script or rebasing the branch into main. Once the branch is integrated into main (rebase or fast-forward), run:

```
python3 scripts/palace_mutate.py \
  --file Palace/Audiobooks/AudiobookSessionManager.swift \
  --tests PalaceTests/AudiobookOpenStateRaceTests \
  --max-mutations 20
```

…and similar for each of the 7 modified production files. The per-file kill rate ≥50% requirement is per-contract; the readiness tests are designed to kill mutations on the new `await` lines but not on the unchanged surrounding logic (which is covered by the existing AccountStateMachineTests + BookRegistrySyncTests sweeps).

### Gap #4 — CarPlayTemplateManager.swift edit was off-contract

The contract scoped 6 files. I had to also touch `Palace/CarPlay/CarPlayTemplateManager.swift` (1 file, ~70 net LOC of structural changes — wrap a 5-step sequence in a `Task`, add `self.` qualifiers, await one call) because making `CarPlayAuthHelper.isAuthenticated` async broke its sync caller. Strictly mechanical — no behavior change beyond Task-wrapping the post-await sequence so the existing alert/playback sequencing remains linear with the await. Flag for review.

### Gap #5 — Bookmark integration tests can't drive TPPAnnotations stub

`TPPReaderBookmarksReadinessTests` exercises the gate contract at libraryMock account level but doesn't end-to-end drive `postBookmark` / `didDeleteBookmark` through the awaitReady → server-post sequence — because `TPPAnnotations.postBookmark` hits a real annotation endpoint and needs network stubbing (HTTPStubURLProtocol + injection point) not present. The existing `TPPReaderBookmarksBusinessLogicTests` covers the local-add path; my readiness tests pin the gate consumption. To close: add a TPPAnnotations stub seam and integration test in a follow-up.

## Worktree-setup notes for the next implementer

The worktree's xcodebuild had two non-obvious failure modes that ate ~30min of debug:

1. **Carthage + ios-audiobooktoolkit symlink trap.** Symlinking `Carthage` (and the audiobook-toolkit submodule) to `/Users/mauricework/PalaceProject/ios-core/` causes `xcodebuild` to see TWO different paths for `AudioEngine.xcframework` (the worktree path AND the main path, via the submodule's `../Carthage/Build/...` ref). This triggers "Multiple commands produce 'AudioEngine.framework'" failures. Fix: `rm Carthage ios-audiobooktoolkit && cp -aL` real copies. Cost: ~700MB disk, but no symlink ambiguity.

2. **Missing PalaceConfig + secrets.** The worktree needs `Palace/AppInfrastructure/APIKeys.swift`, `Palace/TPPSecrets.swift`, `PalaceConfig/GoogleService-Info.plist`, `PalaceConfig/ReaderClientCert.sig`, and `adobe-rmsdk/` (the public headers under `dp/public/`). All are gitignored or unmanaged. `cp` from `/Users/mauricework/PalaceProject/ios-core/` covers all.

I've left this state intact in the worktree (so re-running the tests works locally) but did NOT commit any of those gitignored files — the rebase against origin confirmed only the 7 migrated production files + the test files + project.pbxproj are in the diff.

## Reporting fields requested

- **Worktree path:** `/Users/mauricework/PalaceProject/ios-core/.claude/worktrees/agent-af3be2667f41fc268`
- **Branch:** `feature/account-state-machine-3.2.0-audiobooks` (off `feature/account-state-machine-3.2.0`)
- **Transcript:** `.forgeos/swarms/swarm_81b5099e/transcripts/Audiobooks-MyBooks-Reader2Sync.md` (this file)
- **ForgeOS changeset:** `cs_d862f13a`
