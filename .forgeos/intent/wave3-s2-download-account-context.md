# Intent — Wave 3 S2: Downloads-owned account-context seams

**Slug:** wave3-s2-download-account-context
**Branch:** feat/wave3-s2-download-account-context
**Base:** chore/forward-port-main-to-develop @ 2a5c4cbd7 (stacked on #1348; S1 #1345 already landed)
**Critical path:** YES — auth / credentials / download-file scoping.

## Claims (what this diff does)

1. Declares three **Downloads-owned** protocols + two package-local mirror enums in a new
   app-target file `Palace/MyBooks/DownloadAccountContext.swift`, inverting the
   Downloads→Accounts coupling **without** widening the registry's `AccountScopeProviding`
   (PalaceBookRegistry stays untouched — Wave 3 §2 decision):
   - `DownloadAccountScopeProviding: Sendable` — `currentAccountID`, `currentAccountAuthSurfaceHosts`
   - `DownloadCredentialsProviding: Sendable` — `currentUserAccount()`, `userAccount(forAccount:)`
   - `DownloadUserAccount: AnyObject, Sendable` — the credential/auth surface Downloads reads
   - `DownloadReauthStrategy` (mirrors `AccountDetails.Authentication.ReauthStrategy`)
   - `DownloadAuthState` (mirrors `TPPAccountAuthState`)
2. `extension TPPUserAccount: DownloadUserAccount` (new file) with **exhaustive-switch** enum
   adapters — a new upstream `ReauthStrategy`/`TPPAccountAuthState` case becomes a COMPILE error
   here, not silent drift (§5 risk 3).
3. `AccountsManagerDownloadContextAdapter` (new, `Palace/Accounts/Library/`) conforming to the two
   providing protocols over the concrete `AccountsManager`. App-target composition; never leaks
   `Account`/`AccountsManager`/`TPPUserAccount` as named types across the protocol boundary.
4. AppContainer vends the adapter via a computed `downloadAccountContext` seam (stateless wrapper
   over `self.accountsManager`; no new stored property, no init churn).
5. Proves the seam by retyping the **smallest** consumer — `BookFileManager` — off the concrete
   `AccountsManager` onto `any DownloadAccountScopeProviding`. Behavior byte-identical
   (`currentAccountID` maps to `accountsManager.currentAccountId`, the exact defaults-backed read
   BookFileManager used).

## Anti-claims (what this diff deliberately does NOT do)

- Does NOT widen or touch `AccountScopeProviding` / PalaceBookRegistry.
- Does NOT retype `MyBooksDownloadCenter` (~15 read sites), BorrowOperation, the B7 closures, or
  any other Downloads consumer — **DEFERRED to a follow-up PR** (interim adoption is incremental,
  §2). Only `BookFileManager` is retyped here.
- Does NOT move any type into a SwiftPM package (that is 3a/3b).
- Does NOT change any runtime behavior — the retype and adapters are pure indirection.

## Files in scope

- NEW `Palace/MyBooks/DownloadAccountContext.swift`
- NEW `Palace/Accounts/User/TPPUserAccount+DownloadUserAccount.swift`
- NEW `Palace/Accounts/Library/AccountsManagerDownloadContextAdapter.swift`
- NEW `PalaceTests/MyBooks/DownloadAccountContextAdapterTests.swift`
- EDIT `Palace/AppInfrastructure/AppContainer.swift` (computed `downloadAccountContext`)
- EDIT `Palace/MyBooks/BookFileManager.swift` (dep retype)
- EDIT call sites passing `accountsManager:` to `BookFileManager(...)` — 3 prod + test sites
  (wrap concrete `AccountsManager` in the adapter, or drop the redundant production default arg).

## Signature deviations from the brief (verified against reality)

- `DownloadUserAccount.authState` renamed to **`downloadAuthState`** — `TPPUserAccount` already
  declares `var authState: TPPAccountAuthState`; a same-named `DownloadAuthState` property is an
  invalid redeclaration. The mirror member is therefore `downloadAuthState`.
- Adapter `currentAccountID` maps to `accountsManager.currentAccountId` (defaults-backed), NOT
  `currentAccount?.uuid` — that is the exact read `BookFileManager` funnelled through; the two
  diverge during a switch and only `currentAccountId` preserves behavior.
