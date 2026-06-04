---
name: PP-917-account-switch-inline
created: 2026-06-03
author: claude-opus-4-7
---

## Summary

PP-917: bring the Figma "account switch" design forward into the modern 3.x
Settings screen. Today, Settings → MY LIBRARIES is a single navigation row
that pushes a standalone `TPPSettingsAccountsTableViewController` listing the
configured libraries. The new design inlines the library list directly under
the Settings section header with a trailing "+ ADD LIBRARY" button — matching
the older 1.0.x UX shape but using the current 3.x components (AccountDetailView
on tap, `AccountsManager` switching semantics, FCM token cleanup on delete).
The standalone `TPPSettingsAccountsTableViewController` becomes dead code and
is deleted.

## Claims

- adds inline `librariesSection` rendering one row per configured library in `Palace/Settings/NewSettings/TPPSettingsView.swift`
- adds `LibrariesSectionViewModel` in `Palace/Settings/NewSettings/LibrariesSectionViewModel.swift` to own sorted accounts, current-account uuid, stale-uuid filter, secondary-library deletion (with FCM token cleanup), and refresh-on-`TPPCurrentAccountDidChange`
- adds a `+ ADD LIBRARY` button in the libraries section header (trailing) that presents the existing `TPPAccountList` sheet
- adds per-row checkmark on the active library, library logo, name, and subtitle
- adds swipe-to-delete on non-active libraries with `NotificationService.shared.deleteToken(for:)` cleanup
- removes the standalone `TPPSettingsAccountsTableViewController` push-navigation row from Settings
- deletes `Palace/Settings/TPPSettingsAccountsList.swift` (only consumer was `TPPSettingsView`)
- removes pbxproj entries (`Palace` + `Palace-noDRM` Sources phases) for `TPPSettingsAccountsList.swift`
- adds pbxproj entries for `LibrariesSectionViewModel.swift` (Palace + Palace-noDRM Sources phases)
- adds pbxproj test entry for `PalaceTests/Settings/LibrariesSectionViewModelTests.swift`
- adds unit test coverage for `LibrariesSectionViewModel` (sorted-order, stale-uuid filter, delete-removes-FCM, refresh-on-notification)

## Anti-claims

- does NOT change `AccountsManager.currentAccount` setter semantics or the `TPPCurrentAccountDidChange` notification chain
- does NOT change `AccountDetailView` / `AccountDetailViewModel` — tapping a library row still pushes the existing detail screen
- does NOT change `TPPAccountList` (the library picker presented for "+ ADD LIBRARY")
- does NOT change how a library actually becomes active — that still flows through `MyBooksViewModel.loadAccount(_:)` (existing behavior, unchanged)
- does NOT touch auth, borrow, return, download, DRM, audiobook, or migration code
- does NOT change `TPPSettings.settingsAccountsList` / `settingsAccountIdsList` UserDefaults persistence
- does NOT introduce a new "switch to ..." confirmation alert — the legacy 1.0.x action sheet is intentionally NOT reintroduced; tap behavior matches the current 3.x model (push detail; switch via the picker)
- does NOT change iPad layout to a new master-detail shape — the existing `sideBarEnabled` gate is preserved but its `detailView` becomes redundant; left as-is rather than reworking iPad regressively

## Files in scope

- Palace/Settings/NewSettings/TPPSettingsView.swift
- Palace/Settings/NewSettings/LibrariesSectionViewModel.swift (NEW)
- Palace/Settings/TPPSettingsAccountsList.swift (DELETED)
- Palace.xcodeproj/project.pbxproj
- PalaceTests/Settings/LibrariesSectionViewModelTests.swift (NEW)
