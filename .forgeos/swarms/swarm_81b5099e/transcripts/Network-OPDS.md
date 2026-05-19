# Network-OPDS implementer transcript — swarm_81b5099e

## Summary

- Migrated 2 Bucket-A OPDS loans-feed call sites to the Account state
  machine's `awaitReady()` readiness gate, closing the F-016 → audiobook
  race class on the OPDS layer. Production reads of `loansUrl` can no
  longer fire before `loadCatalogs` has populated `details`.
- `OPDSFeedService.fetchLoans` parameter widened from concrete
  `AccountsManager` to the existing `TPPCurrentLibraryAccountProvider`
  protocol; default arg unchanged. This is a pure widening — production
  call sites keep working, and the function is now unit-testable with
  the existing `TPPLibraryAccountMock` fixture.
- `UnifiedOPDSService.fetchLoans` gained an `accountsManager:
  TPPCurrentLibraryAccountProvider = AppContainer.production().accountsManager`
  parameter (in place of the previous direct
  `AppContainer.production().accountsManager.currentAccount?` read).
- 5 new tests added (3 + 2), all pass. Wider OPDS2 + Accounts regression
  pass: 239/239 across 18 test classes.
- Branch: `feature/account-state-machine-3.2.0-opds`. Worktree:
  `/Users/mauricework/PalaceProject/ios-core/.claude/worktrees/agent-ab2102cd02c80367c`.
  Pushed to origin under the same name.

## Files modified

| Path | Change | Net LOC |
|---|---|---|
| `Palace/OPDS2/OPDSFeedService.swift` | `fetchLoans` migrated to `awaitReady()`; param type widened to `TPPCurrentLibraryAccountProvider`. | +25 / −3 |
| `Palace/OPDS2/Service/UnifiedOPDSService.swift` | `fetchLoans` migrated to `awaitReady()`; added `accountsManager` parameter with `AppContainer.production().accountsManager` default. | +28 / −3 |

Total production: +53 / −6.

## Tests added

| File | Tests | Status |
|---|---|---|
| `PalaceTests/OPDS2/OPDSFeedServiceStateMachineTests.swift` (new) | `testFetchLoansFeed_blocksUntilLoaded_thenFetches`, `testFetchLoansFeed_failedDetailsLoad_throws`, `testFetchLoansFeed_failedDetailsLoad_throwsAccountLoadError_notPalaceError` | 3/3 PASS |
| `PalaceTests/OPDS2/UnifiedOPDSServiceStateMachineTests.swift` (new) | `testFetchLoansFeed_blocksUntilLoaded_thenFetches`, `testFetchLoansFeed_failedDetailsLoad_throws` | 2/2 PASS |

Pbxproj entries added via `ruby scripts/pbxproj_add_swift.rb --targets
PalaceTests --group PalaceTests/OPDS2` (idempotent helper, 2 files
added, 0 skipped, 0 failed).

The state-machine tests pin:
1. The blocking semantics — fetchLoans suspends on `awaitReady()` while
   the account is in `.detailsLoading` and only proceeds after the
   transition to `.detailsLoaded`. The UnifiedOPDSService version
   additionally proves "exactly one HTTP request fires after the gate
   releases" via `HTTPStubURLProtocol`-instrumented request counting.
2. The failure-propagation semantics — when state is `.detailsFailed`,
   fetchLoans throws the underlying `AccountLoadError` with the original
   error description preserved, and (for the UnifiedOPDSService case)
   no HTTP request fires.

Both tests use `AccountStateStore.shared` for transitions (the
production store; `Account.awaitReady()` is hard-wired to `.shared` per
the frozen API) with `AccountStateStore.shared._resetAllForTesting()`
in `tearDown` for inter-test isolation. This mirrors
`AccountStateMachineTests.swift`'s established pattern.

## Build + test command outputs

### Setup (one-time for the worktree)

```
# Worktree had empty submodule dirs from `git worktree add`; bootstrap them:
git submodule update --init --recursive

# Worktree was missing 3 gitignored files that the build requires:
#   - Palace/AppInfrastructure/APIKeys.swift           (used .example template — safe stub)
#   - PalaceConfig/ReaderClientCert.sig                (copied from main — required for Palace.app launch under DRM target)
#   - PalaceConfig/GoogleService-Info.plist            (synthetic stub with valid plist shape — Firebase initialises but no real keys)
# adobe-rmsdk symlink (not a submodule):
ln -s /Users/mauricework/PalaceProject/ios-core/adobe-rmsdk adobe-rmsdk
```

These setup steps are documented as worktree friction in
`feedback_worktree_palace_setup.md` already.

### Build

```
SIM=DF4A2A27-9888-429D-A749-2E157A049A37
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination "id=$SIM" \
  -derivedDataPath /tmp/palace-opds-swarm \
  build-for-testing
# → ** TEST BUILD SUCCEEDED **
```

### Tests — migration coverage

```
SIM=DF4A2A27-9888-429D-A749-2E157A049A37
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination "id=$SIM" \
  -derivedDataPath /tmp/palace-opds-swarm \
  -only-testing:PalaceTests/OPDSFeedServiceStateMachineTests \
  -only-testing:PalaceTests/UnifiedOPDSServiceStateMachineTests \
  test
# → Test Suite 'OPDSFeedServiceStateMachineTests' passed — 3 tests
# → Test Suite 'UnifiedOPDSServiceStateMachineTests' passed — 2 tests
# → ** TEST SUCCEEDED **
```

### Tests — wider OPDS2 + Accounts regression (no-regression check)

```
xcodebuild ... \
  -only-testing:PalaceTests/OPDSFeedServiceTests \
  -only-testing:PalaceTests/OPDSFeedServiceStateMachineTests \
  -only-testing:PalaceTests/UnifiedOPDSServiceStateMachineTests \
  -only-testing:PalaceTests/OPDS2FeedTests \
  -only-testing:PalaceTests/OPDS2FeedParsingTests \
  -only-testing:PalaceTests/OPDS2AuthenticationDocumentTests \
  -only-testing:PalaceTests/OPDS2IntegrationTests \
  -only-testing:PalaceTests/OPDS2CatalogWiringTests \
  -only-testing:PalaceTests/OPDSFeedCacheTests \
  -only-testing:PalaceTests/OPDSFeedMigrationTests \
  -only-testing:PalaceTests/OPDS2BookBridgeTests \
  -only-testing:PalaceTests/OPDS2LinkAndPublicationTests \
  -only-testing:PalaceTests/OPDS2PublicationExtendedTests \
  -only-testing:PalaceTests/TPPContentTypeTests \
  -only-testing:PalaceTests/TPPOPDSGroupTests \
  -only-testing:PalaceTests/AccountStateMachineTests \
  -only-testing:PalaceTests/AccountsManagerStateMachineWiringTests \
  -only-testing:PalaceTests/AccountModelTests \
  -only-testing:PalaceTests/AccountDetailsTests \
  test
# → Executed 239 tests, with 0 failures (0 unexpected) in 6.6s
# → ** TEST SUCCEEDED **
```

## Mutation results

Cache key (file SHA + test selection):
`.forgeos/mutation-cache/UnifiedOPDSService.bf97d4d34c604c52.json`.

| File | Mutation points discovered | Killed | Survived | Kill rate |
|---|---|---|---|---|
| `Palace/OPDS2/OPDSFeedService.swift` | **0** | — | — | n/a |
| `Palace/OPDS2/Service/UnifiedOPDSService.swift` | 1 | 0 | 1 | 0% |

Both files have ≤1 mutation point on the **palace_mutate.py operator
set** (comparison flip, boolean flip, return flip). The migration itself
adds `guard let`, `try await`, and `throw` constructs — none of which
the script's operators target. The one mutation point on
UnifiedOPDSService.swift is at line 214 (`statusCode == 304` → `!= 304`)
in `performOPDS2Fetch` — the conditional-caching branch, **untouched by
this migration** and not covered by any existing test in the OPDS2
suite (no test in `PalaceTests/OPDS2/` stubs a 304 Not Modified
response).

This is honest reporting under the spirit of the gate: the **migrated
lines are fully exercised by the new state-machine tests** (block /
release / failure-propagation), but the mutation tool's operator set
doesn't find structural mutations on `guard`/`await`/`throw`. OPDS2
isn't on the strict-mutation path list in `verify-pr.sh`
(strict applies to `Audiobooks/`, `SignInLogic/`,
`MyBooks/Download*`), so default mode treats this as a warning, not
a fail.

**Gap for the integrator**: if the swarm requires uniform ≥50% kill rate
across all changed files (`verify-pr.sh --enforce-mutations`), the
304-cache-hit path needs a separate test added to lift the kill rate.
That test is out of scope here (line 214 was not introduced by the
state-machine migration; it predates this swarm). Calling this out
explicitly so the integrator can choose to (a) accept the warning, or
(b) add the 304 coverage as a small follow-up before promotion.

## Build matrix

| Scheme | Status |
|---|---|
| Palace (DRM) | **PASS** — build, build-for-testing, tests all green. |
| Palace-noDRM | **PRE-EXISTING FAILURE** (not caused by this migration). Same Swift module-dependency errors reproduce on `origin/feature/account-state-machine-3.2.0` without my changes: `Unable to find module dependency: 'PalaceAudiobookToolkit'`, `Transifex`, `stduritemplate`. This is a build-environment issue affecting both worktree and main checkout. The migration code is DRM-agnostic by inspection (imports only `Foundation`, `PalaceLogging`, `PalaceCatalog` — no `#if FEATURE_DRM_CONNECTOR` branches added). **Integrator: this is environmental, not a contract-acceptance blocker, but worth flagging in case Phase 1's full LCP-matrix test was expected to surface separately.** |

## Gaps for the integrator

1. **UnifiedOPDSService AppContainer-shared antipattern** — Per the
   Network-OPDS contract, the `addAuthHeaders` method and the
   `fetchCatalogRoot` extension still read
   `AppContainer.production().accountsManager.currentUserAccount`
   directly. This was explicitly documented in the contract as out of
   scope for this migration ("DOCUMENT this technical debt in the PR
   description but do NOT refactor injection"). The PR description
   carries the same note. Follow-up: when `UnifiedOPDSService` is given
   a constructor-injected `accountsManager`, the only remaining
   migration there will be `fetchCatalogRoot` (which reads
   `catalogUrl`, not `loansUrl` — but for parity it should adopt
   `awaitReady()` too).
2. **Mutation kill rate** — file-level kill rate is 0% on both
   migrated files under the palace_mutate.py operator set. Migrated
   lines (`guard let` / `try await` / `throw`) have no operator-target
   surface; the one pre-existing mutation point on
   UnifiedOPDSService.swift:214 is on the 304-Not-Modified branch
   which the state-machine tests don't (and shouldn't, given the
   contract's narrow scope) cover. See "Mutation results" above for
   the integrator's policy choice.
3. **Palace-noDRM build** — pre-existing build failure on this
   environment. Confirmed it reproduces on `main` checkout independently
   of this migration. Not blocking, but should be tracked by whoever
   owns the LCP-matrix discipline (a separate Bucket A implementer in
   this swarm, plausibly).
4. **`fetchCatalogRoot` parity** — Not in scope for this contract
   (Network-OPDS targets the **loans-feed** Bucket A sites only).
   `fetchCatalogRoot` reads `catalogUrl` not `loansUrl`, but the race
   shape is identical. Logging this as a follow-up sibling site if
   anyone files a 3.2.x ticket for catalog-root state-machine adoption.

## ForgeOS changeset

`cs_d862f13a` (per the dispatcher's instructions; not promoted here,
left for the integrator to chain into the swarm's gate-promotion run).
