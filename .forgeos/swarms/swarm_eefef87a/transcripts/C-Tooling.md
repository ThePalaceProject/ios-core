---
name: swarm_eefef87a-transcript-C-Tooling
type: ephemeral
status: active
created: 2026-05-26T15:00:00Z
last_refresh: 2026-05-27
freshness_window: 180d
owners: [accounts, mybooks]
description: Module C — Tooling transcript
---

# Module C — Tooling transcript

Status: complete

## Scope

Two edits to `scripts/verify-pr.sh` + one new ADR.

1. Expand `CRITICAL_MUTATION_PATHS_REGEX` (line 73) to cover every critical-path surface.
2. Add an audiobook cross-vendor smoke gate that runs `-only-testing:PalaceTests/AudiobookCrossVendorSmokeTests` when audiobook files change.
3. Write `docs/architecture/critical-path-mutation-coverage.md` documenting the regex methodology.

## Regex evolution

### Before (scripts/verify-pr.sh:73)

```
^Palace/(Audiobooks|SignInLogic|MyBooks/Download|Book/UI/BookDetail/BookButtonMapper)
```

Matched ~50 files. Missed the following critical surfaces:
- `MyBooksDownloadCenter.swift` + `+Async.swift` (the MBDC root — the regex `MyBooks/Download` requires `Download` to be the leading word after `MyBooks/`, so it matched `DownloadStart*` but not `MyBooksDownload*`)
- All borrow-lifecycle files (`BorrowOperation.swift`, `BorrowErrorPresenter.swift`, `BookSignInRedirectHandler.swift`)
- All DRM-fulfillment files (`AdobeDRMHandler.swift`, `LCPFulfillmentHandler.swift`, `RightsManagementDispatcher.swift`)
- Background + Overdrive download handlers
- `BorrowReducer.swift` (state machine for the BookDetailViewModel borrow/download/return lifecycle)
- Auth-critical accounts/network: `TPPUserAccount.swift`, `AccountsManager.swift`, `TPPNetworkExecutor.swift`
- `Packages/PalaceAuth/` SPM module

### After

```
^Palace/(Audiobooks/|SignInLogic/|MyBooks/(Download|Borrow|BookSignInRedirectHandler|AdobeDRMHandler|LCPFulfillmentHandler|RightsManagementDispatcher|MyBooksDownload|BackgroundDownloadHandler|OverdriveDownloadHandler)|Book/UI/BookDetail/(BookButtonMapper|BorrowReducer)|Accounts/User/TPPUserAccount|Accounts/Library/AccountsManager|Network/TPPNetworkExecutor|Packages/PalaceAuth/)
```

Matches **81** Swift files. Coverage delta: ~30 files moved from advisory to strict.

## Enumeration

### Methodology

1. List user-money / access-bearing surfaces from CLAUDE.md + memory pins.
2. `find Palace -name "*.swift" \( -path "*Borrow*" -o -path "*Download*" -o -path "*Auth*" -o -path "*DRM*" -o -path "*LCP*" -o -path "*Sign*" \)` → ~75 candidates.
3. Read each candidate's file header to confirm purpose. Reject value types, view files, Reader2 rendering-side DRM.
4. Cross-reference against `.forgeos/audits/phase7-synthesis-2026-05-26.md` + memory pin `phase7_borrow_path_regressions_2026_05_14.md`.
5. Construct regex; test against positive + negative + edge-case bucket.

### Files added to the regex (vs PR #1003 baseline)

Newly held to the 50% kill-rate floor by default:

**Borrow lifecycle (`Palace/MyBooks/Borrow*`):**
- `BorrowOperation.swift` — owns the complete borrow lifecycle (~487 LOC of former MBDC+Async extensions)
- `BorrowErrorPresenter.swift` — borrow error → user-facing alert mapping

**Borrow catalog routing (`Palace/Book/UI/BookDetail/`):**
- `BorrowReducer.swift` — pure state machine for BookDetailViewModel borrow/download/return lifecycle

**SAML redirect (`Palace/MyBooks/`):**
- `BookSignInRedirectHandler.swift` — SAML web-view + cookie-sync + post-auth retry mid-download

**MyBooksDownloadCenter facade (`Palace/MyBooks/MyBooksDownload*`):**
- `MyBooksDownloadCenter.swift`
- `MyBooksDownloadCenter+Async.swift`
- `MyBooksDownloadCenterProtocol.swift`
- `MyBooksDownloadErrorInfo.swift`
- `MyBooksDownloadInfo.swift`
- `MyBooksDownloadQueue.swift`

**Background / Overdrive download (`Palace/MyBooks/`):**
- `BackgroundDownloadHandler.swift` — URLSession background delegate + file ops
- `OverdriveDownloadHandler.swift` — 302-redirect fulfillment dance for Overdrive audiobooks

**DRM fulfillment (`Palace/MyBooks/`):**
- `AdobeDRMHandler.swift` — NYPLADEPTDelegate bridge (Adobe fulfilment)
- `LCPFulfillmentHandler.swift` — LCP license-fulfilment + streaming-license-copy
- `RightsManagementDispatcher.swift` — per-rights-management dispatch step

**Auth-critical accounts:**
- `Palace/Accounts/User/TPPUserAccount.swift` — credential / bearer-token store
- `Palace/Accounts/Library/AccountsManager.swift` — account-detail state machine

**Auth-critical network:**
- `Palace/Network/TPPNetworkExecutor.swift` — `bearerAuthorized(...)` + accountId resolution (Module A's hardening target)

**PalaceAuth SPM module (`Palace/Packages/PalaceAuth/`):**
- `Package.swift`
- `Sources/PalaceAuth/AuthReducer.swift`
- `Sources/PalaceAuth/AuthSeams.swift`
- `Sources/PalaceAuth/Effect.swift`
- `Sources/PalaceAuth/TokenRequest.swift`
- `Sources/PalaceAuth/TPPSAMLHelper.swift`
- `Sources/PalaceAuth/TPPUserAccountFrontEndValidation.swift`
- `Sources/PalaceAuth/URLResponse+TPPAuthentication.swift`

### Already covered (preserved by the new regex)

- All `Palace/Audiobooks/**` (~25 files including AudiobookSessionManager, NowPlayingCoordinator, all four Vendors/* adapters, the Tracker subtree, DPLA/JWKResponse, LCP/LCPAudiobooks)
- All `Palace/SignInLogic/**` (~17 files including TPPSignInBusinessLogic + 8 extensions, SignInWebSheet, SignInModalView, TPPReauthenticator, LegacySAMLAuthAdapter)
- All `Palace/MyBooks/Download*` (~13 files — DownloadStartCoordinator, DownloadStartDispatcher, DownloadAuthRetryHandler, etc.)
- `Palace/Book/UI/BookDetail/BookButtonMapper.swift` (added in PR #1003)

### Explicitly exempted (documented in ADR)

- All `Palace/Reader2/**` — WKWebView-bound, XCTest-invisible. Covered by Module D's contract-snapshot tests at `PalaceTests/Contract/Reader2{Bookmark,PositionResume}ContractTests.swift`.
- `Palace/MyBooks/TPPMyBooksDownloadInfo.swift` — pure `@objc enum`, no behavior to mutate.
- `Palace/Book/UI/TPPBookDetailDownloadFailedView.swift` — SwiftUI view layer, covered by snapshot tests.
- `Palace/Holds/HoldsReducer.swift` — holds is parallel state machine, not on user-money path (until / unless auto-borrow-on-hold-ready ships).
- `Palace/Network/TPPNetworkQueue.swift` — offline retry log, decisions live in TPPNetworkExecutor (which is on the strict path).
- `Palace/Accounts/Library/Account.swift` — value type, decisions live in AccountsManager.

## ADR sections written

`docs/architecture/critical-path-mutation-coverage.md` includes all six contract-required sections:

1. **Context** — references `phase7-synthesis-2026-05-26.md` + the BookButtonMapper finding (PR #1003).
2. **Enumeration methodology** — reproducible 5-step walk.
3. **Critical-path files** — complete table with surface → regex group → enumerated files.
4. **Exempted files** — Reader2 exemption (with Module D's contract-snapshot strategy as the alternative coverage) + value-type / view-layer / out-of-scope exemptions.
5. **Verification** — three bash commands (positive newly-included, positive already-covered, negative non-critical) + actual captured output, plus total-file count (81).
6. **Maintenance** — when to re-run the audit (file rename, new state machine, new SPM extraction, Reader2 testability change, F-011-shape regression) + re-audit checklist.

Includes `<!-- audit-verified -->` attestation token.

## Audiobook smoke gate

Added after the mutation step (between step 5 and step 6 in verify-pr.sh — labelled `# 5b. Audiobook cross-vendor smoke`).

**Trigger:** `git diff --name-only $BASE...HEAD` matches `^Palace/Audiobooks/` or `^ios-audiobooktoolkit/`.

**Behavior:**
- No audiobook files changed → `record "audiobook_smoke" "pass" "Skipped (no audiobook files changed)"`. Doesn't slow non-audiobook PRs.
- Audiobook files changed → invoke `xcodebuild ... -only-testing:PalaceTests/AudiobookCrossVendorSmokeTests test`. Parses bundle rollup the same way the main unit-tests step does (`Test Suite 'All tests' (passed|failed)` + `Executed N tests` per bundle, failure count from `N failure(s)` token).
- Zero executed cases with audiobook files changed → fail loudly (misconfiguration guard — same shape as the mutation step's "Suspicious: ... 0 mutations" check). Catches the case where Module B's test class hasn't landed yet but the gate is referencing it by name.

**`record` schema preserved** — the new check is `audiobook_smoke`, status pass/fail, detail string. Added to the docs-only fast-path's record set as well so the JSON `checks` array stays consistent across both code paths.

**Mutation-only mode:** smoke gate records `pass — Skipped (--mutation-only)` to keep the JSON schema stable.

## Verification

### Regex tests

Captured 2026-05-26 from `swarm_eefef87a-module-C` branch.

**Positive — previously uncovered files (must now match):**

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

15/15 OK.

**Positive — already-covered files (must still match):**

```
  [OK]   Palace/Audiobooks/AudiobookSessionManager.swift
  [OK]   Palace/Audiobooks/Vendors/LCPAdapter.swift
  [OK]   Palace/SignInLogic/TPPSignInBusinessLogic.swift
  [OK]   Palace/SignInLogic/TPPSignInBusinessLogic+OIDC.swift
  [OK]   Palace/MyBooks/DownloadStartDispatcher.swift
  [OK]   Palace/MyBooks/DownloadAuthRetryHandler.swift
  [OK]   Palace/Book/UI/BookDetail/BookButtonMapper.swift
```

7/7 OK. PR #1003's BookButtonMapper inclusion preserved.

**Negative — non-critical files (must NOT match):**

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

15/15 correctly rejected. Reader2 DRM exemption confirmed; `TPPMyBooksDownloadInfo` substring-confusion ("Download" in the name but not a Download* file) correctly rejected; `HoldsReducer` parallel state machine correctly excluded.

### Smoke-gate detection logic

```
ALL_CHANGED="Palace/Audiobooks/Vendors/LCPAdapter.swift
Palace/Audiobooks/AudiobookSessionManager.swift"
AUDIOBOOK_CHANGED=$(echo "$ALL_CHANGED" | grep -E "^Palace/Audiobooks/|^ios-audiobooktoolkit/" || true)
# → Detected: both files

ALL_CHANGED="Palace/Catalog/CatalogViewModel.swift"
AUDIOBOOK_CHANGED=$(echo "$ALL_CHANGED" | grep -E "^Palace/Audiobooks/|^ios-audiobooktoolkit/" || true)
# → Empty → would skip
```

### Script syntax / functional

- `bash -n scripts/verify-pr.sh` → no syntax errors.
- `scripts/verify-pr.sh --quick` against current diff (six .md + manifest.yaml files from scaffold commit) → ran all 10 steps without crashing. Audiobook smoke step correctly reported "Skipped (no audiobook files changed)". The one [FAIL] in the run was `unit_tests — 0 tests, 0 failures` due to the scaffold-only diff returning an empty `*.swift` filter — a pre-existing wc-on-empty-string quirk in the script's `Changed files: $(echo "$CHANGED_SWIFT" | wc -l)` header (empty `echo` produces one blank line, so wc reports 1). Not caused by this PR's edits; surfaces only on diffs with zero Swift files, which is the docs-fast-path's exact use case. Out of scope.

## Files touched

- `scripts/verify-pr.sh` — regex update at line 73, audiobook smoke gate added after the mutation step, audiobook smoke record added to the docs-only fast-path's record set.
- `docs/architecture/critical-path-mutation-coverage.md` — new ADR (six sections + audit-verified attestation).

No edits to `Palace/` or `PalaceTests/` — Module B owns the audiobook smoke Swift file.

## Constraints honored

- No production code edits.
- No test edits.
- No edits to other ADRs in `docs/architecture/`.
- Existing `record` / pass-fail / JSON-schema patterns preserved.
- ADR includes actual captured bash output (not placeholders).
- ForgeOS changeset referenced in commit message: `cs_34366ad3`.

## Open items / escalations

None. The audiobook smoke gate references `AudiobookCrossVendorSmokeTests` by string name, which is Module B's contract — the gate is robust if Module B's file lands on develop before this Module C PR merges (the `xcodebuild ... -only-testing:` resolution is deferred to test-run time, not Swift import time).
