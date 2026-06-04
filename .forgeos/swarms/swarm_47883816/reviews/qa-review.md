# QA Test Review — cs_d92d06e8 (swarm_47883816 test pollution sweep)

**Reviewer:** SoD qa_test
**Verdict:** APPROVED (with non-blocking warnings)
**Date:** 2026-06-04

## Summary

This is a test-infrastructure changeset (5 new test files + ~300 test-body migrations + 9 new MetaTest lint files + narrow plumbing-only production DI in TPPSettings + RemoteFeatureFlags). 71/0 PASS across 9 new test classes. All 5 DoD scripts exit 0. The point of the swarm is structural test-isolation purity, and the new factories + lints are themselves isolated and self-tested.

## Findings

### APPROVE: Coverage adequacy of factories + lints
Each new `*Tests.swift` file constructs its SUT ≥1 time (verified via DoD #1 grep across all transcripts). Factory tests exercise the 4 behavioural contracts (distinct-per-call, production-cache-untouched, defer-flag-fires, override wiring). Lint tests scan the real PalaceTests/ tree AND feed synthetic violators through the same predicates. Symmetric coverage.

### APPROVE: Synthetic violators are real
Spot-checked synthetic violators in TPPUserAccountIsolationLintTests.swift:165, TearDownRequiredLintTests.swift:297-319, AppContainerIsolationLintTests.swift:34-37. Each synthesizes a string that contains the banned substring AND lacks the compliance marker AND extends XCTestCase directly. The detector predicate (substring + comment-skip + XCTestCase-subclass regex) is then run on the synthetic input — if any predicate ever no-ops, the lint silently passes everything. The self-tests close this hole.

### APPROVE: Edge cases (keychain isolation, suite isolation)
- TPPUserAccountTestFactory uses `test-uuid-<UUID>` prefix vs production `urn:uuid:065c0c11-…` — structural collision impossibility, verified per C-transcript.
- testUserDefaults() per-CALL isolation (not per-test) — modeled "fresh install vs post-write" idiom in single test body. `testTestUserDefaults_writesDoNotLeakToStandard` verifies belt-and-braces.
- Resetter uses `removePersistentDomain(forName:)` (wipes entire suite, not just known keys) — handles "test wrote key we don't know about" pollution vector.

### APPROVE: Test isolation invariant — factories are themselves pure
- TestAppContainerFactory pins `deferInitialLoadCatalogsForTesting = true` BEFORE constructing AccountsManager — prevents the very background-task pollution the swarm exists to close. Verified by `testMakeTestAppContainer_doesNotSpawnLoadCatalogsTask`.
- TPPUserAccountTestFactory.Tracker uses NSLock around minted array; lock released BEFORE closure execution (lock-acquisition ordering correct for resetter <10ms SLA).
- testUserDefaults helper has NO `?? .standard` fallback (verified by grep) — the whole isolation guarantee.

### APPROVE: Banned patterns absent
No `XCTAssertNotNil(MyClass())`, no enum rawValue tautologies, no `XCTAssertTrue(x is Y)` in new test bodies. `check-test-name-vs-body.py` on 30 modified test files returns 0 fake-wiring. Lint files reference banned substrings only inside string literals + comments (self-referential — correctly exempted).

### WARNING: Mutation kill-rate is vacuously 100% on production DI
Both TPPSettings + RemoteFeatureFlags DI changes report `0 changed-line mutation points` per `palace_mutate.py --diff-only`. The diff is pure plumbing (`UserDefaults.standard.X` → `defaults.X` substitutions; new `init(defaults: UserDefaults = .standard)`). Per CLAUDE.md neither file is on the critical-paths list (auth/borrow/return/DRM/audiobook/migrations/TPPNetworkResponder), so the ≥50% threshold is not strict. Behavioural coverage is provided by `DownloadOnlyOnWiFiTests.testSetting_persistsToUserDefaultsAcrossToggleCycle` (round-trip through the injected suite) and the 3 migrated override-key tests in RemoteFeatureFlagsTests. Acceptable for the risk profile but worth noting: a defect that broke the seam by accidentally reading `.standard` would not be caught by mutation; it's caught instead by the absence of `UserDefaults.standard` and `?? .standard` in the diff (verified). Treat the grep as the load-bearing assurance, not mutation.

### WARNING: Deferred-list debt is real
`A-deferred-files.txt` carries 56 files (under architect's 71 ceiling) but several are critical-path (BookReturnService*, AudiobookSessionManager*, TPPSignInOIDC, CredentialGuard, TokenRefreshAndRetryQueue). These files have ZERO structural protection — they can continue accumulating `AppContainer.production()` calls until the follow-up swarm drains them. Architect already flagged this and recommended a counter-cap in the lint (`XCTAssertLessThanOrEqual(deferredCount, baseline)`). Not in this changeset; flag for follow-up.

### WARNING: E-teardown-baseline.txt has 37 active polluters
The TearDownRequiredLint baseline exempts 37 XCTestCase-derived files that touch polluter state without tearDown. The list is SHRINK-ONLY (structurally enforced), but the 37 files themselves represent active state-leak risk. F-audit additionally identified 2 test-side fire-and-forget Tasks (DRMAdversarialTests, PersistentLoggerTests) + 3 production fire-and-forget clusters (DownloadAuthRetryHandler, BookReturnService, TPPUserAccount.signOut) reachable from tests. F's tickets are proposed but not filed. Flag for follow-up.

### PASS: Regression risk acceptably contained
- All 71 new tests pass in isolation (per A/B/C/D/E transcripts with xcresult paths).
- Sibling-package owned files exempted in the lint until parallel implementers committed — orchestrator's E should fold these into the whitelist/deferred list (architect's note #4).
- Production DI sites: 4 TPPSettings construction sites + 1 RemoteFeatureFlags.shared site all preserved (default-arg backward compat). Verified by D-transcript pre/post grep.

### PASS: Critical-path coverage NOT modified
SignInLogic/, Audiobooks/, MyBooks/Download*, MyBooks/Borrow*/Return*, Migrations/, TPPNetworkResponder/Executor — none touched by this swarm. The DI changes (Settings + FeatureFlags) are explicitly non-critical per CLAUDE.md.

## Verdict

**APPROVED.** The new test infrastructure is itself isolation-pure, the lints have working synthetic-violator self-tests, and the production DI is honestly plumbing. The two WARNING-level findings (deferred-list debt + teardown baseline + F's unfiled tickets) are real but explicitly architected as Option-b phased follow-up; surfacing them is structural, not silent. Critical paths untouched. Ship.

## Follow-up tickets (recommended, non-blocking)
1. Shrink A-deferred-files.txt — prioritize BookReturnService*, AudiobookSessionManager*, TPPSignInOIDCTests, CredentialGuardTests, TokenRefreshAndRetryQueueTests.
2. Migrate E-teardown-baseline.txt entries to PalaceWiringTestCase or add explicit tearDown.
3. File F's 5 proposed tickets (DRMAdversarialTests fluff, PersistentLoggerTests async tearDown, DownloadAuthRetryHandler Task retention, BookReturnService Task retention, TPPUserAccount.signOut Task retention).
4. Add `XCTAssertLessThanOrEqual(deferredCount, baseline)` invariant in AppContainerIsolationLintTests so deferred-list cannot grow.
