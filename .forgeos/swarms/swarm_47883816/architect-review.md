# Architect Review — swarm_47883816 (test pollution sweep)

**Reviewer:** independent architect (post-triage verification pass)
**Date:** 2026-06-04
**Verdict:** **APPROVED_WITH_NOTES** — dispatch A/B/C/D/F in parallel, E sequential.

---

## Verified findings

### Site counts (verified against live grep)

| WP | Contract claim | Independent verification | Delta |
|----|----------------|--------------------------|-------|
| A — `AppContainer.production()` | 636 in 91 files | **636 in 91 files** | exact |
| B — bare `AccountsManager(` | 17 / 10 files | **17 sites, 9 distinct constructor files** ¹ | within tolerance |
| C — `TPPUserAccount.sharedAccount(` | 37 lines / 8 files | **37 lines, 8 files** | exact |
| D — `UserDefaults.standard` (tests) | 71 lines / 13 files | **71 lines, 11 distinct files** ² | minor |
| D — `UserDefaults.standard` (prod) | 89 sites | **89 sites** | exact |
| F — Task/DispatchQueue.async | 170 | **154 lines (`Task {` + `DispatchQueue.{global,main}.async`)** ³ | within tolerance |

¹ B's manifest lists 10 files, grep finds 9 distinct constructor files + 1 comment-ref file (AppContainerResetTests, already whitelisted) + 1 grep false positive on the test method name `testWithAccount_inheritsParentAccountsManager()`. Real migration count = 17 in 9 files. Manifest can be corrected from 10→9 or left (the off-limits clauses still hold).

² D's 13-file claim in plan includes `AccountsManagerTests.swift` (manifested under D) which has 0 `UserDefaults.standard` lines but does have AppContainer.production sites — so 11 files with actual UserDefaults.standard + 2 files D owns end-to-end for the AppContainer cleanup. Reconciles.

³ Different regex variants (escape forms) yielded 154 / 170 / 174 depending on whether `DispatchQueue.global.async` parens were greedy and whether `Task {` matched task-init followed by space. F's contract uses `≈` so all within tolerance.

A's top-14 file selection verified by re-counting: TPPBookRegistryIntegrationTests=46, MyBooksViewModelTests=39, BookDetailMetadataHydrationTests=30, AppContainerTests=28, TPPNetworkExecutorTests=23, ViewModelComputedPropertyTests=22, BookDetailViewModelTests=22, HoldsViewModelTests=17, BookCellModelStateTests=17, BookCellModelCacheTests=16, CarPlayTests=13, AppContainerAuthCoordinatorWiringTests=12, SignInModalLifecycleTests=9, NetworkQueueTests=9. Sum = **303** (matches "~303 / 636 ≈ 48%").

### File-collision check

Strict YAML parse across all six work packages' `files_scope:` blocks: **0 duplicate PalaceTests/ entries**. Cross-WP handoffs documented in plan.md table 41–71 and reflected in off-limits clauses. No collision.

### Off-limits completeness (A's coverage closure)

All 91 files in `AppContainer.production()` grep accounted for:
- A scope (14 migration files) + A whitelist (5: PalaceTestSetup, PalaceTestSetupObservationTests, AccountTestSeeder, AdobeActivationTests, TestAppContainerFactory) = 19
- Handed to B (5 BookRegistry/* + 4 Integration/*) = 9
- Handed to C (AccountDetailViewModelTests, AccountSwitchCleanupTests, AuthFlowSecurityTests, BookRegistrySyncReadinessTests, ChaosFaultInjectionTests, CoverageGapTests3, ButtonStateTests, TPPCrossLibrarySignOutTests) = 8
- Handed to D (AccountsManagerTests, DownloadOnlyOnWiFiTests, others) = ~3
- A-deferred (long tail) = **55 files** (computed by `comm -23 all-A-files covered-set`)

Plan §"Verified site counts" claims "71 files" deferred — my independent computation shows **55 files** remain after subtracting A scope + whitelist + B/C/D handoffs. This is BETTER than the architect's 71 estimate (more A coverage than claimed via handoffs), not worse. The "71 / ~333 sites" framing in the plan is conservative. **Implementer A must produce the precise list in `A-deferred-files.txt` at lint-write time** — no contract change needed; the actual file is the authoritative source.

Some specific notable deferred files (high-value follow-up candidates):
- `PalaceTests/MyBooks/BookReturnService*Tests.swift` — critical path (BookReturn). Worth prioritizing in the follow-up swarm.
- `PalaceTests/Audiobooks/AudiobookSessionManager*Tests.swift` — critical path (audiobooks).
- `PalaceTests/Network/CredentialGuardTests.swift`, `PalaceTests/Network/TokenRefreshAndRetryQueueTests.swift` — auth-adjacent.
- `PalaceTests/SignInLogic/TPPSignInOIDCTests.swift` — critical path (sign-in).

**Recommend the follow-up swarm prioritize these critical-path files first**, not just by site-count.

### Production seam verification

- `Palace/Accounts/User/TPPUserAccount.swift` — exists; `init(libraryUUID:)` at line 84 (internal). ✅
- `Palace/Settings/TPPSettings.swift` — exists. ✅
- `Palace/FeatureFlags/RemoteFeatureFlags.swift` — exists. ✅
- `StorageKey.X.keyForLibrary(uuid:)` namespacing — multiple sites (`authorizationIdentifier`, `adobeToken`, `licensor`, `patron`, `adobeVendor`, `provider`, `userID`, `deviceID`, `credentials` all use `.keyForLibrary(uuid: libraryUUID)`). Library UUID is genuinely segregated in keychain key construction. C's "keychain-namespaced isolation" claim is **verifiable and correct**. ✅
- `AccountsManager.deferInitialLoadCatalogsForTesting` — exists in `Palace/Accounts/Library/AccountsManager.swift` (NOT `Palace/Accounts/AccountsManager.swift` as commonly referenced). Contract A line 64 cites the symbol but does not pin the file path, so this is fine. Implementer A should confirm the path before referencing in factory code. ✅

### TPPSettings/RemoteFeatureFlags DI blast radius

- `TPPSettings(` construction sites in production: **4** (`TPPConfiguration+SE.swift:21`, `AppContainer.swift:429`, `AccountsManager.swift:212`, `MyBooksDownloadCenter.swift:278` — last two already use defaulted args). `TPPSettings.shared` references: **0** — it's already DI'd structurally; D just needs to add a UserDefaults init arg. Adding `init(defaults: UserDefaults = .standard)` keeps all 4 sites green via the default. Safe.
- `RemoteFeatureFlags(` construction sites: **1 internal** (`static let shared = RemoteFeatureFlags()` at line 20). `RemoteFeatureFlags.shared` references: **26** — adding a defaulted UserDefaults init arg keeps all 26 callers green. Safe.

D's "minimum DI seam" is genuinely minimal. The "private let defaults: UserDefaults" instance property + defaulted init arg is **non-invasive** for production. STOP threshold (>5 caller changes) will not trigger.

### Verification-criteria grep validity

All inline greps tested for syntactic validity:
- A's grep with empty deferred list returns 636 matches as expected (will narrow once factory + migrations land + A-deferred-files.txt is populated). Syntax OK.
- C's grep parses cleanly; reproduces 37 lines (will narrow to documented whitelist after migration). Syntax OK.
- D's grep parses cleanly; reproduces 71 lines. Syntax OK.
- B's grep parses cleanly. Syntax OK.

No broken pipes, unescaped specials, or regex errors found in any of the 6 contracts' verification tables.

### Risk classification

D's `risk: standard` is correct per CLAUDE.md. `Palace/Settings/` and `Palace/FeatureFlags/` are NOT in the listed critical paths (auth, borrow, return, download, DRM, audiobook, migrations, TPPNetworkResponder/Executor). TPPSettings stores reader prefs, library default, sync flags — non-critical. RemoteFeatureFlags is read-only feature-flag retrieval. The DI seam is mechanical. **`standard` is correct.** ✅

---

## Issues found

### Non-blocking concerns (orchestrator should be aware)

**1. Lint coverage of the deferred 71 files is the load-bearing risk.** The plan and contract A correctly call this out (Option-b phasing), but the structural protection the lint provides applies only to the 19 migrated/whitelisted files. The deferred 71 files have **zero structural protection** — they can grow more `AppContainer.production()` calls until the follow-up swarm drains them. The lint will not block new pollution in those files because the deferred-list whitelist exempts them by name.

**Mitigation in contract:** Plan §"Acceptance criteria" cites the deferred list literally. **Recommend orchestrator add an outcome.md follow-up ticket scoped explicitly to "shrink A-deferred-files.txt to zero"** with a target date. Otherwise the deferred list becomes permanent debt — exactly the failure mode `derived-improvements.md` cluster patterns flag.

**Suggestion:** A could augment the lint to **count** the deferred list size and FAIL if it grows from baseline. Not blocking for this swarm — file as A's coordination note. (One-line addition: `XCTAssertLessThanOrEqual(deferredCount, expectedBaseline, "Deferred list MUST shrink, not grow")`.)

**2. C's plan-table line 50 (CoverageGapTests3) shows "2 sharedAccount (1 whitelisted identity check)" but C's whitelist lists "`PalaceTests/CoverageGapTests3.swift` line 203 area".** The contract correctly identifies that one site stays (the `XCTAssertTrue(account === TPPUserAccount.sharedAccount())` identity check) and one migrates. Implementer C must pin the line number at migration time — line numbers shift. **Recommend C uses a comment marker pattern** (`// LINT-WHITELIST: identity-check`) rather than line numbers in the lint file. Non-blocking.

**3. F's "audit only" stance is correct but vague on follow-up-ticket creation.** Contract F says "Recommended follow-up tickets (Jira / GitHub issue numbers)" but doesn't require F to actually create the tickets. If category-3 findings exist, F should **either** create the JIRA tickets **or** record proposed ticket bodies in the audit transcript so the orchestrator can file them. Otherwise the audit becomes a write-only artifact. Non-blocking but worth orchestrator awareness.

**4. E's sequential dispatch — concrete trigger spec.** Contract E says "E depends on A, B, C, D landing first" but the orchestrator dispatch logic needs a precise predicate. Suggest: **E dispatches when all of A/B/C/D have an integrated commit on the swarm branch AND each has populated its lint whitelist file.** Manifest sets `depends_on: [A, B, C, D]` correctly; the orchestrator must enforce. Non-blocking.

**5. F count is 174 not 170.** Within tolerance. F's contract verification criterion #2 uses `≈` so this passes. Non-blocking.

---

## Recommendation

**APPROVED_WITH_NOTES.** Dispatch A/B/C/D/F in parallel; gate E behind A/B/C/D integration.

The contracts are tight, the file-collision matrix is clean, all production seams are verified to exist with the claimed semantics, and the risk classification is correct. The phased Option (b) on A is the right call given the 16× delta from intent estimate, and the architect's transparent disclosure of the deferred 71 files prevents this from being silent partial-shipping.

**Action items for orchestrator before dispatch:**
1. Add a follow-up ticket creation note to `outcome.md`-to-be: "Follow-up swarm to drain A-deferred-files.txt to zero" with target SLA.
2. Confirm with implementer A that the lint will count + cap the deferred list size at baseline (one-line addition, non-blocking).
3. Remind implementer C to use comment-marker whitelist (not line numbers) in the lint file.
4. Reinforce to F: if category-3 findings exist, file the JIRA tickets OR record bodies in the audit transcript.

No contract changes required before dispatch.
