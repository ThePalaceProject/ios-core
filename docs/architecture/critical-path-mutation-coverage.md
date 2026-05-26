# Critical-path mutation coverage — regex methodology

<!-- audit-verified -->

**Status:** active maintenance contract for `scripts/verify-pr.sh`.
**Owner:** anyone modifying critical-path code; re-run the audit per the maintenance section below.
**Related:** [`mutation-cache/`](../../.forgeos/mutation-cache/) (cache keying), `scripts/palace_mutate.py` (engine), `scripts/resolve-tests-for.py` (test-class resolution).

## Context

`scripts/verify-pr.sh` gates mutation-testing strictness on a regex of "critical-path" file prefixes (variable `CRITICAL_MUTATION_PATHS_REGEX`, scripts/verify-pr.sh:73-ish). Files matching the regex must clear the 50% mutant kill-rate floor or the PR is blocked; files outside the regex are advisory (warned but not blocked). `--enforce-mutations` promotes every changed file to strict; `--no-enforce-mutations` demotes everything to advisory.

The regex existed before this ADR but was constructed ad-hoc:

```
^Palace/(Audiobooks|SignInLogic|MyBooks/Download|Book/UI/BookDetail/BookButtonMapper)
```

The Phase 7 synthesis audit (`.forgeos/audits/phase7-synthesis-2026-05-26.md`) surfaced the problem: `BookButtonMapper.swift` was added as the most recent regex entry (PR #1003, finding #1) only after a sibling audit caught that it was off the strict path despite being a documented F-011-shape risk surface. The audit closes with "every state-machine wiring site needs the strict gate, but there's no enumeration of what 'every site' means." This ADR is that enumeration.

The regex sets the **lower bound** on PR rigor for user-money / access-bearing code paths: sign-in, borrow, download, DRM fulfillment, audiobook playback. Tightening it slows critical PRs on purpose. Loosening it silently regresses the posture audit — which is exactly the failure mode that landed F-011 in PR #990 ("audiobook first-open hang") and the BookButtonMapper gap. The ADR is the maintenance contract so future authors don't trim files from the regex without seeing what they're giving up.

## Enumeration methodology

Reproducible walk used to assemble the inclusion list. Anyone re-running the audit (per "Maintenance" below) should follow the same five steps:

1. **List the user-money / access-bearing surfaces** from the project memory rules + CLAUDE.md:
   - Sign-in (auth, OAuth/SAML/basic/OIDC, reauth, sign-out)
   - Borrow (lifecycle, error presentation, SAML web-view redirect)
   - Download (queue, start, completion, throttle, cancel, error recovery, background/foreground, retry, announcement, alert)
   - DRM (Adobe, LCP, rights dispatch — fulfillment side, NOT rendering side)
   - Audiobook playback (session manager, vendor adapters, tracker)
   - Catalog routing into the above (BookButtonMapper, BorrowReducer)
   - Auth-critical network plumbing (TPPNetworkExecutor account resolution, AccountsManager state machine, TPPUserAccount credential store)
   - PalaceAuth SPM package (extracted auth reducer/seams)
2. **Walk the file system** with a broad `find`:

   ```
   find Palace -name "*.swift" \( \
     -path "*Borrow*" -o -path "*Download*" -o \
     -path "*Auth*" -o -path "*DRM*" -o \
     -path "*LCP*" -o -path "*Sign*" \
   \) | sort
   ```

   This produced ~75 candidate files across `Audiobooks/`, `MyBooks/`, `SignInLogic/`, `Book/UI/BookDetail/`, `Accounts/`, `Network/`, `Reader2/`, and `Packages/PalaceAuth/`.
3. **Read each candidate's file header / class comment** to confirm purpose. Reject:
   - Pure value types and enum definitions (e.g. `TPPMyBooksDownloadInfo.swift` — `@objc enum TPPMyBooksDownloadRightsManagement: Int` only) — no mutable behavior to mutate.
   - View-layer files that only render state set elsewhere (e.g. `TPPBookDetailDownloadFailedView.swift`) — covered by snapshot tests, not mutation.
   - Reader2 rendering-side DRM (`Palace/Reader2/ReaderStackConfiguration/AdobeDRM/*`, `Palace/Reader2/ReaderStackConfiguration/LCP/*`) — exempted, see "Exempted files" below.
4. **Cross-reference against the audit corpus** in `.forgeos/audits/phase7-*.md` and the memory pin `phase7_borrow_path_regressions_2026_05_14.md`. Every file those audits called out as F-011 / F-014 / F-017 risk surface must be in the regex.
5. **Construct a regex** that matches every retained file. Test it against both the retained list (positive cases) and an explicit non-critical sampler (negative cases). The verification commands and output live in the "Verification" section below.

## Critical-path files

Complete table. **Strict mutation kill-rate floor (50%) applies to every entry.** PRs touching these files fail `verify-pr.sh` if the changed lines have <50% kill rate, unless `--no-enforce-mutations` is passed.

| Surface | Regex group | Files |
|---|---|---|
| **Sign-in** | `Palace/SignInLogic/` (all .swift) | `TPPSignInBusinessLogic.swift` + extensions (BookmarkSyncing, CardCreation, DRM, ForceReset, OAuth, OIDC, SAML, SignOut, UI), `TPPSignInBusinessLogicUIDelegate.swift`, `TPPReauthenticator.swift`, `SignInModalView.swift`, `SignInWebSheet.swift`, `SignInWebSheetPresenter.swift`, `SignInWebSheetViewModel.swift`, `SignInWebViewCoordinator.swift`, `LegacySAMLAuthAdapter.swift` |
| **Sign-in — extracted SPM** | `Palace/Packages/PalaceAuth/` | `Package.swift`, `Sources/PalaceAuth/AuthReducer.swift`, `AuthSeams.swift`, `Effect.swift`, `TokenRequest.swift`, `TPPSAMLHelper.swift`, `TPPUserAccountFrontEndValidation.swift`, `URLResponse+TPPAuthentication.swift` |
| **Borrow (lifecycle)** | `Palace/MyBooks/Borrow*` | `BorrowOperation.swift`, `BorrowErrorPresenter.swift` |
| **Borrow (catalog routing)** | `Palace/Book/UI/BookDetail/{BookButtonMapper,BorrowReducer}` | `BookButtonMapper.swift` (already added in PR #1003 — preserved), `BorrowReducer.swift` (NEW — pure state machine for the borrow/download/return lifecycle in BookDetailViewModel) |
| **Borrow (SAML web-view redirect)** | `Palace/MyBooks/BookSignInRedirectHandler` | `BookSignInRedirectHandler.swift` — owns SAML web-view + cookie-sync + post-auth retry mid-download |
| **Download** | `Palace/MyBooks/Download*` | `DownloadStartCoordinator.swift`, `DownloadStartDispatcher.swift`, `DownloadAuthRetryHandler.swift`, `DownloadCompletionParser.swift`, `DownloadQueueOrchestrator.swift`, `DownloadStateManager.swift`, `DownloadTaskLifecycleService.swift`, `DownloadThrottlingService.swift`, `DownloadAlertPresenter.swift`, `DownloadCancellationHandler.swift`, `DownloadProgressPublisher.swift`, `DownloadErrorRecovery.swift`, `DownloadAnnouncementService.swift` |
| **Download — MyBooksDownloadCenter facade** | `Palace/MyBooks/MyBooksDownload*` | `MyBooksDownloadCenter.swift`, `MyBooksDownloadCenter+Async.swift`, `MyBooksDownloadCenterProtocol.swift`, `MyBooksDownloadErrorInfo.swift`, `MyBooksDownloadInfo.swift`, `MyBooksDownloadQueue.swift` |
| **Download — background / Overdrive** | `Palace/MyBooks/{BackgroundDownloadHandler,OverdriveDownloadHandler}` | `BackgroundDownloadHandler.swift` (URLSession background delegate, file ops), `OverdriveDownloadHandler.swift` (302-redirect fulfillment dance for OD audiobooks) |
| **DRM fulfillment** | `Palace/MyBooks/{AdobeDRMHandler,LCPFulfillmentHandler,RightsManagementDispatcher}` | `AdobeDRMHandler.swift` (NYPLADEPTDelegate bridge — Adobe fulfilment, file move, rights persistence), `LCPFulfillmentHandler.swift` (LCP license-fulfilment + streaming-license-copy), `RightsManagementDispatcher.swift` (per-rights-management dispatch after `DownloadCompletionParser` extracts rights) |
| **Audiobook playback (all)** | `Palace/Audiobooks/` (all .swift) | `AudiobookLoader.swift`, `AudiobookPositionPolicy.swift`, `AudiobookSessionManager.swift`, `AudiobookSessionManaging.swift`, `AudioBookVendors+Extensions.swift`, `AudioBookVendorsHelper.swift`, `NowPlayingCoordinator.swift`, `PlaybackBootstrapper.swift`, `TPPReturnPromptHelper.swift`, `DPLA/{DPLAAudiobooks,JWKResponse}.swift`, `LCP/LCPAudiobooks.swift`, `Tracker/{AudiobookDataManager,AudiobookTimeEntry,AudiobookTimeTracker,DataManager}.swift`, `Vendors/{Adapters+Production,AudiobookVendorAdapter,BearerTokenAdapter,LCPAdapter,LocalFileAdapter,OpenAccessAdapter}.swift` |
| **Auth-critical accounts** | `Palace/Accounts/User/TPPUserAccount`, `Palace/Accounts/Library/AccountsManager` | `TPPUserAccount.swift` (the credential / bearer-token store — every borrow / download eventually reads this), `AccountsManager.swift` (the account-detail state machine — `feedback_round_trip_wiring_tests.md` covers it, but the production code needs mutation gating too) |
| **Auth-critical network** | `Palace/Network/TPPNetworkExecutor` | `TPPNetworkExecutor.swift` — the `bearerAuthorized(...)` class method + accountId resolution path the swarm Module A is hardening. Auth-token leakage / wrong-account dispatch lives here. |
| **Payment** | N/A | Palace is a library app — no payment surface. Listed for completeness so a future contributor knows the omission is intentional, not an oversight. |

## Exempted files

Files that touch a critical surface but are explicitly **not** in the regex:

### Reader2 (Readium 3.x WKWebView — XCTest-invisible)

- `Palace/Reader2/ReaderStackConfiguration/AdobeDRM/{AdobeCertificate,AdobeContentProtectionService,AdobeDRMAlerts,AdobeDRMContentProtection,AdobeDRMError,AdobeDRMLibraryService,AdobeRightsParser}.swift` and `.mm/.h` peers
- `Palace/Reader2/ReaderStackConfiguration/LCP/{LCPLibraryService,LCPPassphraseAuthenticationService,LicensesService,TPPLCPClient,TPPLCPLicense}.swift`
- `Palace/Reader2/ReaderStackConfiguration/DRMLibraryService.swift`
- All other `Palace/Reader2/**` rendering / nav / bookmark / position files

**Reasoning.** Reader2 runs inside Readium 3.x's WKWebView. Per CLAUDE.md "E2E / UI sim driving — simdrive": the WKWebView is invisible to the XCTest accessibility tree. Mutation-testing classes inside Reader2 against XCTest-resolved test selectors produces selectors that match zero classes — `palace_mutate.py` would dutifully report 0/0 kill rate for every mutation, which the verify-pr.sh aggregator silently rubber-stamps as "no mutations generated for changed files" (line ~417: `record "mutation" "pass" "No mutations generated for changed files"`).

**Alternative coverage.** Module D of swarm `swarm_eefef87a` (this same swarm) lands contract-snapshot tests at `PalaceTests/Contract/Reader2BookmarkContractTests.swift` and `PalaceTests/Contract/Reader2PositionResumeContractTests.swift`. The contract-snapshot framework (`PalaceTests/Contract/{CallLog,ContractSnapshot}.swift`) records the ordered sequence of dependency calls during a Reader2 scenario, stores the result as a JSON baseline, and asserts the snapshot on every subsequent run. Refactors that change the call contract — including silent breakage of bookmark sync or position resume — drift the snapshot and fail loudly.

This is the same pattern CLAUDE.md's "Contract-snapshot tests" section documents for `Borrow`, `BookReturn`, `DownloadStart`, `BorrowReducer`. It catches the same class of bug (silently re-ordered or dropped side-effect calls) that mutation-testing catches, via a different mechanism — and works against WKWebView-bound code where XCTest doesn't.

### `Palace/MyBooks/TPPMyBooksDownloadInfo.swift`

Pure `@objc enum` for rights-management values. No mutable behavior, no branches, no comparisons — mutation testing has nothing to flip. Excluded by the regex (the prefix `Palace/MyBooks/Download` doesn't match `Palace/MyBooks/TPPMyBooksDownloadInfo` because the regex requires `Download` to be the leading word after `MyBooks/`).

### `Palace/Book/UI/TPPBookDetailDownloadFailedView.swift`

SwiftUI view that displays an error message. Covered by snapshot tests for the rendered output; mutation testing on view-layout files produces low-signal mutants (most flips are on padding values or stringification). Excluded for the same reason — only the BookButtonMapper / BorrowReducer state-router files in `BookDetail/` get strict gating.

### `Palace/Holds/HoldsReducer.swift`

Reservations / holds is a parallel state machine, but not on the user-money path (a hold doesn't fulfil DRM or transfer files until it's promoted into a borrow). Excluded for now. **If holds ever becomes a fulfilment trigger** — e.g. an "auto-borrow on hold-ready" feature — re-run the audit and add `Palace/Holds/HoldsReducer` to the regex.

### `Palace/Network/TPPNetworkQueue.swift`

The offline retry queue. Important, but its retry surface is covered by `TPPNetworkExecutor` (which is in the regex) — the queue itself is a persistent log of failed requests, not a decision-maker. Excluded to keep the regex from sweeping in adjacent low-leverage files.

### `Palace/Accounts/Library/Account.swift`

Pure value type representing an account record. The state machine lives in `AccountsManager.swift` (in the regex); `Account.swift` is data plus simple accessors. Excluded for the same reason as `TPPMyBooksDownloadInfo.swift` (no behavior to mutate).

## Verification

The regex was tested against three buckets: previously-uncovered files (now match), already-covered files (still match), and non-critical files (must NOT match), plus an edge-case sampler for `Borrow`/`Download` name-substring confusion. Captured `2026-05-26` from the swarm `swarm_eefef87a-C` worktree.

**Command (positive — newly-included files):**

```bash
REGEX='^Palace/(Audiobooks/|SignInLogic/|MyBooks/(Download|Borrow|BookSignInRedirectHandler|AdobeDRMHandler|LCPFulfillmentHandler|RightsManagementDispatcher|MyBooksDownload|BackgroundDownloadHandler|OverdriveDownloadHandler)|Book/UI/BookDetail/(BookButtonMapper|BorrowReducer)|Accounts/User/TPPUserAccount|Accounts/Library/AccountsManager|Network/TPPNetworkExecutor|Packages/PalaceAuth/)'

for f in \
  "Palace/MyBooks/MyBooksDownloadCenter.swift" \
  "Palace/MyBooks/MyBooksDownloadCenter+Async.swift" \
  "Palace/MyBooks/BorrowOperation.swift" \
  "Palace/MyBooks/BorrowErrorPresenter.swift" \
  "Palace/MyBooks/BookSignInRedirectHandler.swift" \
  "Palace/MyBooks/AdobeDRMHandler.swift" \
  "Palace/MyBooks/LCPFulfillmentHandler.swift" \
  "Palace/MyBooks/RightsManagementDispatcher.swift" \
  "Palace/MyBooks/BackgroundDownloadHandler.swift" \
  "Palace/MyBooks/OverdriveDownloadHandler.swift" \
  "Palace/Book/UI/BookDetail/BorrowReducer.swift" \
  "Palace/Accounts/User/TPPUserAccount.swift" \
  "Palace/Accounts/Library/AccountsManager.swift" \
  "Palace/Network/TPPNetworkExecutor.swift" \
  "Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthReducer.swift"; do
  echo "$f" | grep -qE "$REGEX" && echo "  [OK]   $f" || echo "  [FAIL] $f"
done
```

**Output:**

```
  [OK]   Palace/MyBooks/MyBooksDownloadCenter.swift
  [OK]   Palace/MyBooks/MyBooksDownloadCenter+Async.swift
  [OK]   Palace/MyBooks/BorrowOperation.swift
  [OK]   Palace/MyBooks/BorrowErrorPresenter.swift
  [OK]   Palace/MyBooks/BookSignInRedirectHandler.swift
  [OK]   Palace/MyBooks/AdobeDRMHandler.swift
  [OK]   Palace/MyBooks/LCPFulfillmentHandler.swift
  [OK]   Palace/MyBooks/RightsManagementDispatcher.swift
  [OK]   Palace/MyBooks/BackgroundDownloadHandler.swift
  [OK]   Palace/MyBooks/OverdriveDownloadHandler.swift
  [OK]   Palace/Book/UI/BookDetail/BorrowReducer.swift
  [OK]   Palace/Accounts/User/TPPUserAccount.swift
  [OK]   Palace/Accounts/Library/AccountsManager.swift
  [OK]   Palace/Network/TPPNetworkExecutor.swift
  [OK]   Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthReducer.swift
```

**Command (positive — already-covered files, must still match):**

```bash
for f in \
  "Palace/Audiobooks/AudiobookSessionManager.swift" \
  "Palace/Audiobooks/Vendors/LCPAdapter.swift" \
  "Palace/SignInLogic/TPPSignInBusinessLogic.swift" \
  "Palace/SignInLogic/TPPSignInBusinessLogic+OIDC.swift" \
  "Palace/MyBooks/DownloadStartDispatcher.swift" \
  "Palace/MyBooks/DownloadAuthRetryHandler.swift" \
  "Palace/Book/UI/BookDetail/BookButtonMapper.swift"; do
  echo "$f" | grep -qE "$REGEX" && echo "  [OK]   $f" || echo "  [FAIL] $f"
done
```

**Output:**

```
  [OK]   Palace/Audiobooks/AudiobookSessionManager.swift
  [OK]   Palace/Audiobooks/Vendors/LCPAdapter.swift
  [OK]   Palace/SignInLogic/TPPSignInBusinessLogic.swift
  [OK]   Palace/SignInLogic/TPPSignInBusinessLogic+OIDC.swift
  [OK]   Palace/MyBooks/DownloadStartDispatcher.swift
  [OK]   Palace/MyBooks/DownloadAuthRetryHandler.swift
  [OK]   Palace/Book/UI/BookDetail/BookButtonMapper.swift
```

**Command (negative — non-critical files, must NOT match):**

```bash
for f in \
  "Palace/Catalog/CatalogViewModel.swift" \
  "Palace/CatalogUI/CatalogView.swift" \
  "Palace/Reader2/ReaderViewController.swift" \
  "Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeDRMContentProtection.swift" \
  "Palace/Reader2/ReaderStackConfiguration/LCP/LCPLibraryService.swift" \
  "Palace/Reader3/PDFViewerController.swift" \
  "Palace/Holds/HoldsReducer.swift" \
  "Palace/Utilities/StringExtensions.swift" \
  "Palace/AppInfrastructure/AppContainer.swift" \
  "Palace/Book/Models/TPPBookAuthor.swift" \
  "Palace/Book/UI/TPPBookDetailDownloadFailedView.swift" \
  "Palace/MyBooks/TPPMyBooksDownloadInfo.swift" \
  "Palace/Network/TPPNetworkQueue.swift" \
  "Palace/Accounts/Library/Account.swift" \
  "Palace/Migrations/MigrationCoordinator.swift"; do
  echo "$f" | grep -qE "$REGEX" && echo "  [FAIL] $f matched" || echo "  [OK]   $f"
done
```

**Output:**

```
  [OK]   Palace/Catalog/CatalogViewModel.swift
  [OK]   Palace/CatalogUI/CatalogView.swift
  [OK]   Palace/Reader2/ReaderViewController.swift
  [OK]   Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeDRMContentProtection.swift
  [OK]   Palace/Reader2/ReaderStackConfiguration/LCP/LCPLibraryService.swift
  [OK]   Palace/Reader3/PDFViewerController.swift
  [OK]   Palace/Holds/HoldsReducer.swift
  [OK]   Palace/Utilities/StringExtensions.swift
  [OK]   Palace/AppInfrastructure/AppContainer.swift
  [OK]   Palace/Book/Models/TPPBookAuthor.swift
  [OK]   Palace/Book/UI/TPPBookDetailDownloadFailedView.swift
  [OK]   Palace/MyBooks/TPPMyBooksDownloadInfo.swift
  [OK]   Palace/Network/TPPNetworkQueue.swift
  [OK]   Palace/Accounts/Library/Account.swift
  [OK]   Palace/Migrations/MigrationCoordinator.swift
```

**Total matched files in tree:**

```bash
find Palace -name '*.swift' | grep -E "$REGEX" | wc -l
# 81
```

81 Swift files held to the strict 50% kill-rate floor by default. Compare to the previous regex (`^Palace/(Audiobooks|SignInLogic|MyBooks/Download|Book/UI/BookDetail/BookButtonMapper)`), which matched ~50 files — the audit raised coverage by ~30 files in the borrow / DRM / accounts / network surfaces that were previously advisory-only.

## Maintenance

Re-run the audit when **any** of the following lands on `develop`:

1. **A file in the listed surfaces is renamed or moved.** The regex is path-based — a rename in `Palace/MyBooks/Borrow*` outside the prefix patterns (e.g. `Palace/MyBooks/BorrowFlow.swift` → `Palace/MyBooks/Flow/BorrowFlow.swift`) silently drops the file from the strict path. PRs that move critical-path files must update this ADR and the regex in the same commit.
2. **A new state machine, retry handler, or borrow/download/DRM router is added.** Examples that would trigger a re-audit:
   - A new vendor adapter under `Palace/Audiobooks/Vendors/` (already covered by the broad `Audiobooks/` prefix — but the ADR table should be updated so the file is enumerated).
   - A new file in `Palace/MyBooks/` that owns post-download fulfilment (similar shape to `RightsManagementDispatcher.swift`).
   - A new auth adapter or post-auth bridge outside `Palace/SignInLogic/` or `Palace/Packages/PalaceAuth/`.
3. **A new top-level extraction** — e.g. a follow-up SPM extraction in the spirit of `Packages/PalaceAuth`, or a `Packages/PalaceMyBooks` if the MBDC overhaul lands as its own module. The regex must be updated to include the new package path.
4. **The Reader2 testability story changes.** If a future Readium / XCTest combination becomes mutation-testable (or `simdrive` gains an automated mutation-killing replay corpus that subsumes contract snapshots), revisit the Reader2 exemption.
5. **A regression of the F-011 / F-014 / F-017 shape ships.** A live bug in a file that *should* have been on the strict path but wasn't is a load-bearing signal — re-run the enumeration in step 2 of "Methodology" and recompute the regex.

**Re-audit checklist:**

- [ ] Walk `find Palace -name "*.swift"` against the broad query in "Methodology" step 2.
- [ ] Diff the new file list against the "Critical-path files" table.
- [ ] For each added / removed / renamed file, justify inclusion or exclusion against the rules in "Methodology" step 3.
- [ ] Update the regex in `scripts/verify-pr.sh` (variable `CRITICAL_MUTATION_PATHS_REGEX`).
- [ ] Re-run the verification commands in "Verification" and paste the actual output into this ADR.
- [ ] Commit `scripts/verify-pr.sh` + this ADR together. **Never** ship the regex change without the ADR update — the regex change without ADR context is exactly the failure mode this document exists to prevent.

## See also

- `.forgeos/audits/phase7-synthesis-2026-05-26.md` — the audit that surfaced finding #1 (`BookButtonMapper` off the strict path) and motivated this ADR.
- `feedback_round_trip_wiring_tests.md` (project memory) — the state-machine wiring test pattern that complements the mutation gate on the audit-listed files.
- CLAUDE.md "Mutation testing" — engine + cache mechanics; this ADR is the **what** gate it applies to.
- CLAUDE.md "Contract-snapshot tests" — the alternative coverage strategy used for Reader2 and other XCTest-invisible surfaces.
