---
name: pp4896-remove-vestigial-book-to-remove
created: 2026-08-19
author: Maurice Carrier
branch: fix/pp-4896-remove-vestigial-book-to-remove
priority: PP-4896 / Normal (critical-path file: download center)
---

# Intent: delete the vestigial `bookIdentifierOfBookToRemove` scratch state from MyBooksDownloadCenter

## Context

PP-4896 was raised by independent architect review during Wave 3 S2b (PR #1358).
`MyBooksDownloadCenter.bookIdentifierOfBookToRemove` is declared once and
assigned `nil` at three sites but read NOWHERE in the tree, so the guard
`if accountScope.currentAccountID == account { bookIdentifierOfBookToRemove = nil }`
in `reset(account:)` has zero observable effect — the `==`/`!=` mutant is
unkillable by construction.

The ticket asked to resolve one of two possibilities via git history. History
settles it as case 1 (genuinely vestigial):

- Introduced 2014-08-04 (`709bf4c5b`) as scratch state for a `UIAlertViewDelegate`
  confirm-delete callback. `UIAlertView`'s delegate carries no payload, so the
  book identifier had to be stashed on the instance between "show alert" and
  "user tapped Delete".
- The reader (`alertView:didDismissWithButtonIndex:`) AND the writer
  (`removeCompletedDownloadForBookIdentifier:`) were BOTH deleted together on
  2020-02-12 in `b34820563` ("Fix / silence Xcode 11.3.1 warnings"), which
  dropped the deprecated `UIAlertViewDelegate` conformance.
- At that commit's parent, `removeCompletedDownloadForBookIdentifier:` had NO
  callers anywhere in the tree (only its `.h` declaration and `.m` definition),
  so the flow was already dead before it was removed. Nothing was lost.

No feature is missing today. Remove-from-device is live via the `.remove`
button, which routes through `didSelectReturn()` → `BookReturnService` →
`deleteLocalContent(for:account:)`, passing the identifier as an ARGUMENT rather
than stashing it in instance scratch state. `BookCellModel` documents the
product decision explicitly: "Local delete and in-progress indicator: no
confirmation needed" — only `.return` (giving the book back) is confirmed.

## Claims

- Deletes the `private var bookIdentifierOfBookToRemove: String?` declaration and
  all three `= nil` assignments (in `reset(_ libraryID:)`, `reset(account:)`, and
  `reset()`).
- Deletes the now-empty account-match guard in `reset(account:)`, leaving the
  method as its single meaningful statement `contentResetService.reset(account: account)`.
  Account scoping for the reset is unchanged — it lives in the service, which
  already receives `account`.
- Deletes the class doc-comment bullet describing the field as main-thread-only
  mutable state, since the field no longer exists.
- Deletes `testResetAccount_consultsInjectedScopeSeamOnBothGuardBranches` from
  `MyBooksDownloadCenterAccountScopeSeamTests`. That test pins ONLY the guard
  being deleted; with the guard gone `reset(account:)` performs no account-scope
  read, so the test asserts nothing. Its "HONEST LIMITATION" note is removed with it.
- Replaces that test 1:1 (per the CLAUDE.md fluff-replacement rule) with
  `testPersistStartedTaskRecord_*` covering the OTHER live `accountScope` read in
  the class — `persistStartedTaskRecord` stamping the durable record's `account`
  from the seam. This read was previously unpinned at the MBDC level, so seam
  coverage in this class goes UP, not down.

## Anti-claims

- Does NOT change any user-visible behavior. This is write-only dead state; no
  branch that anyone can observe is altered.
- Does NOT rewire or reintroduce a confirm-delete alert. The product's current
  no-confirmation-for-local-delete behavior is deliberate and stays as is.
- Does NOT change `reset(_ libraryID:)`, `reset()`, or `reset(account:)` account
  semantics — `contentResetService` still receives exactly the same account
  argument in each.
- Does NOT touch the `accountScope` seam itself, its adapter, or the other seam
  read at `persistStartedTaskRecord` / `fileUrl`.
- Does NOT remove the two existing `fileUrl` seam tests.

## Files in scope

- `Palace/MyBooks/MyBooksDownloadCenter.swift`
- `PalaceTests/MyBooks/MyBooksDownloadCenterAccountScopeSeamTests.swift`
