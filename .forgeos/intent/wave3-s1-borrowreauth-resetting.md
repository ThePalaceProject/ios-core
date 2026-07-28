# Intent: Wave 3 S1 — invert the account-switch → borrow-reauth reset (BorrowReauthResetting)

**Slug:** wave3-s1-borrowreauth-resetting
**Branch:** feat/wave3-s1-borrowreauth-resetting
**Critical-path:** YES (money-path: account-switch borrow-reauth circuit-breaker reset)
**Change kind:** small production seam + tests. TDD.

## Context

God-class decomposition Wave 3 (`docs/architecture/god-class-decomposition-plan.md`
§3a, and the S1 decision in the Wave 3 brief) severs the mutually-coupled hub pair
`AccountsManager` (→ PalaceAccounts) and the MyBooks download subsystem
(→ PalaceDownloads). This PR is seam **S1**: the ONE hard, un-inverted
Accounts→Downloads STATIC edge.

`AccountsManager.cleanupActiveContentBeforeAccountSwitch(from:to:)`
(AccountsManager.swift:995) calls the static
`MyBooksDownloadCenter.clearAllBorrowReauthState()` on every real library switch,
which wipes the process-global per-book borrow-reauth circuit breaker
(`BorrowOperation.reauthTracker`). If that clear is dropped, a user who switches
libraries after a failed borrow is silently stuck on the generic-error path with
no reauth prompt — a money-path regression. S1 makes the edge *injected* (an
`any BorrowReauthResetting` dependency) so the call is spy-testable and so the
type-level Accounts→MyBooks reference dies mechanically at the 3a package move.

## Claims (what this change does)

1. New protocol `BorrowReauthResetting: Sendable { func clearAllBorrowReauthState() }`
   declared in `Palace/Accounts/Library/BorrowReauthResetting.swift` (the consuming
   package's side; moves into PalaceAccounts at 3a).
2. New app-side adapter `DownloadCenterBorrowReauthResetter: BorrowReauthResetting`
   in `Palace/MyBooks/DownloadCenterBorrowReauthResetter.swift`, forwarding to
   `MyBooksDownloadCenter.clearAllBorrowReauthState()`.
3. `AccountsManager` gains `private let borrowReauthResetter: any BorrowReauthResetting`,
   an init param defaulting to a REAL `DownloadCenterBorrowReauthResetter()`
   (behavior-identical; avoids churning ~135 test constructions; a no-op default is
   FORBIDDEN because it would silently drop a money-path clear), and the :995 static
   call becomes `borrowReauthResetter.clearAllBorrowReauthState()`.
4. `AppContainer._buildCachedAppContainer()` passes the resetter EXPLICITLY at the
   `AccountsManager(...)` construction (:634), per the no-default-fires house rule.

## Anti-claims (explicitly NOT in scope)

- NOT changing WHAT the clear does (still a global `reauthTracker.clearAll()`),
  its call site, or its synchronous ordering before the async nav cleanup.
- NOT inverting any other Accounts↔Downloads seam (S2/S3, the `AccountScopeProviding`
  question, locator kills) — those are separate PRs.
- NOT moving any type into a package (that is 3a).
- NOT widening `AccountScopeProviding` or touching PalaceBookRegistry.

## Files in scope

- `Palace/Accounts/Library/BorrowReauthResetting.swift` (new, prod)
- `Palace/MyBooks/DownloadCenterBorrowReauthResetter.swift` (new, prod)
- `Palace/Accounts/Library/AccountsManager.swift` (edit: property + init param + :995 call)
- `Palace/AppInfrastructure/AppContainer.swift` (edit: explicit wire at :634)
- `PalaceTests/Accounts/BorrowReauthResettingTests.swift` (new, tests)
- `Palace.xcodeproj/project.pbxproj` (2 prod files → both targets, 1 test file)
- `.forgeos/intent/wave3-s1-borrowreauth-resetting.md` (this file)
