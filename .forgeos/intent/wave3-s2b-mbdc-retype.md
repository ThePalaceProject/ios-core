# Intent — Wave 3 S2b: retype MyBooksDownloadCenter's account-scope reads onto the S2 seam

**Slug:** wave3-s2b-mbdc-retype
**Branch:** feat/wave3-s2b-mbdc-retype
**Base:** develop (S2 / #1350 has landed on develop; this branch is based on develop, no longer stacked on an unmerged S2 branch)
**Critical path:** YES — Downloads / auth / credentials / per-account download-file scoping.

## Claims (what this diff does)

1. Adds a stored `accountScope: any DownloadAccountScopeProviding` to
   `MyBooksDownloadCenter`, injected via a new optional init param
   (`accountScope: (any DownloadAccountScopeProviding)? = nil`) that defaults —
   in the init body — to an `AccountsManagerDownloadContextAdapter` over the SAME
   resolved `accountsManager`, keeping scope + credential reads coherent (a
   default expression can't reference another param, so the nil-coalesce is in
   the body, mirroring `bookFileManager`/`diskBudgetManager`).
2. Retypes MBDC's **5 account-SCOPE read sites** off the concrete `accountsManager`
   onto that seam (behavior byte-identical — the adapter's `currentAccountID`
   returns exactly `accountsManager.currentAccountId`, its
   `currentAccountAuthSurfaceHosts` returns `currentAccount?.authSurfaceHosts ?? []`):
   - `currentAccountHostsProvider` closure in the `TokenRefreshInterceptor` wire-up
     (was `AppContainer.production().accountsManager.currentAccount?.authSurfaceHosts`) — **B6 locator kill**
   - `currentAccountHostsProvider` closure in the `DownloadAuthRetryHandler` wire-up (same) — **B6 locator kill**
   - `captureCurrentAccountId` closure (`DownloadStartCoordinator.currentAccountIdProvider`)
   - `reset(account:)` guard (`accountsManager.currentAccountId == account`)
   - `persistStartedTaskRecord` account stamp (`accountsManager.currentAccountId ?? ""`)
3. Points MBDC's default `BookFileManager` construction at the resolved
   `accountScope` (was constructing a fresh `AccountsManagerDownloadContextAdapter`
   inline) so a test-injected scope spy flows into BookFileManager too — one
   coherent account seam.
4. Adds `PalaceTests/MyBooks/MyBooksDownloadCenterAccountScopeSeamTests.swift`:
   a spy `DownloadAccountScopeProviding` proves MBDC resolves account scope
   through the injected seam (value flows to the on-disk file path; the
   `reset(account:)` guard consults the seam), not a hardcoded AccountsManager.

## Anti-claims (what this diff deliberately does NOT do)

- Does NOT change any runtime behavior — pure retype/indirection. The value read
  is identical (defaults-backed `currentAccountId`; empty-set-for-nil authSurfaceHosts
  is behavior-neutral because both consumers collapse nil and empty via a
  `!isEmpty` guard → identical legacy-fallback).
- Does NOT retype the **credential** path (`userAccount` / `userAccount(forCapturedId:)` /
  the B7 `() -> TPPUserAccount` closures / the sub-service `accountsManager:` passes).
  The concrete `accountsManager` stays for that cluster — see the seam-gap note below.
- Does NOT inject `DownloadCredentialsProviding` (no credential read crosses cleanly
  this PR — it would be dead code; deferred with the B7 cluster to 3b).
- Does NOT touch `AccountScopeProviding` / PalaceBookRegistry, and moves nothing into a package.

## Seam gap discovered (report to the wave)

The credential-vending path canNOT cross to `DownloadCredentialsProviding` this
PR: `MyBooksDownloadCenter.userAccount` (public, `TPPUserAccount`) is consumed at
`URLSessionTaskDelegate` challenge by `TPPBasicAuth(credentialsProvider:)`, whose
param is `NYPLBasicAuthCredentialsProvider` — a conformance `DownloadUserAccount`
does NOT declare. It is also fed to `BorrowOperation.attemptOIDCSilentReauth(userAccount: TPPUserAccount)`
and the deferred B7 `() -> TPPUserAccount` closures. So credentials retype at 3b
**together with** those closures, and 3b must also decide how the URLSession-challenge
`TPPBasicAuth` site obtains an `NYPLBasicAuthCredentialsProvider` (widen the seam,
or keep that one site app-side against the concrete type).

## Files in scope

- EDIT `Palace/MyBooks/MyBooksDownloadCenter.swift` (stored prop + init param + body resolve + 5 read sites + BookFileManager wire; verbose rationale kept to terse one-line pointers)
- NEW  `Palace/MyBooks/MyBooksDownloadCenter+AccountScope.swift` (documentation-only: the account-scope seam rationale, extracted out of the frozen hub per the god-class LOC-freeze contract)
- NEW  `PalaceTests/MyBooks/MyBooksDownloadCenterAccountScopeSeamTests.swift`

## Verification

- Both targets (Palace + Palace-noDRM) build clean, fresh derivedDataPath.
- MBDC existing suites green (behavior-neutral) + the new seam test.
- Locator ratchet DROPS (2 `AppContainer.production()` B6 reaches removed).
- STARVE-001 / TearDownRequiredLint / AppContainer+AccountsManager isolation lints green.
- forge-review: architect + qa_test SoD (fresh identities).
