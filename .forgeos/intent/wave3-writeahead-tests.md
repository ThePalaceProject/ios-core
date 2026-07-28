# Intent: Wave 3 write-ahead coupling tests (Accounts ↔ Downloads)

**Slug:** wave3-writeahead-tests
**Branch:** feat/wave3-writeahead-tests
**Critical-path:** YES (borrow / download / account-switch / auth)
**Change kind:** TESTS ONLY — no production `Palace/**` edits.

## Context

God-class decomposition Wave 3 (`docs/architecture/god-class-decomposition-plan.md`
§3a-2/§3a-3, §4 Wave 3, §5) splits the mutually-coupled hub pair
`AccountsManager` (→ PalaceAccounts) and the MyBooks download subsystem
(→ PalaceDownloads). These write-ahead characterization/contract tests pin the
CURRENT bidirectional coupling behavior at the seams Wave 3 will sever, so the
later extraction is provably behavior-neutral.

Existing coverage already pins large parts of the coupling (verified this
session): the Downloads→Accounts current-account **capture-once** seam
(`MyBooksDownloadCenterAccountIdThreadingTests`), per-library credential/registry
isolation across a switch (`AccountSwitchLifecycleTests`), and the
account-switch **publication order** of the `currentAccount` setter
(`PalaceTests/Decomp/AccountsManagerCurrentAccountSwitchContractTests`). This
work adds ONLY the genuinely-unpinned coupling seams.

## Claims (what the new tests assert)

1. **Accounts→Downloads static edge — borrow reauth circuit breaker.**
   `AccountsManager.cleanupActiveContentBeforeAccountSwitch` (line ~994) calls
   `MyBooksDownloadCenter.clearAllBorrowReauthState()` →
   `BorrowOperation.clearAllBorrowReauthState()`. The behavioral contract: a book
   whose per-book borrow-reauth circuit breaker has tripped (2nd auth-error
   borrow is suppressed to a generic error) gets a FRESH reauth attempt after
   `clearAllBorrowReauthState()` — i.e. account switch resets the breaker.
   Driven through the real `BorrowOperation.borrowAsync` with closure spy seams.

2. **Downloads→Accounts read edge — per-account download-file scoping.**
   `BookFileManager.fileUrl(for:)` resolves the on-disk path under
   `accountsManager.currentAccountId`; changing the current account changes the
   resolved directory (files follow the current library). The sideloaded-content
   isolation EXCEPTION: a `sideload-`-prefixed id resolves under the fixed
   `SideloadedBookRegistry.sideloadContentAccountID` regardless of the current
   account, so a library switch cannot orphan sideloaded files.

## Anti-claims (explicitly NOT in scope)

- NOT re-pinning capture-once / bearerAuthorized threading (already covered).
- NOT re-pinning the `currentAccount` setter publication order (already covered).
- NOT testing the non-injectable setter side-effects that reach static
  singletons (`ImageCache.shared`, `TPPBookCoverRegistry.shared`,
  `networkExecutor` via `AppContainer.production()`) — those are recorded as
  needed production seams in the coupling map, not worked around.
- NO production code changes. If a seam can't be tested without one, it is
  documented, not added.

## Files in scope (test target only)

- `PalaceTests/Contract/AccountSwitchBorrowReauthCouplingContractTests.swift` (new)
- `PalaceTests/MyBooks/BookFileManagerAccountScopingTests.swift` (new)
- `docs/architecture/wave3-coupling-map.md` (new; doc)
- `.forgeos/intent/wave3-writeahead-tests.md` (this file)
