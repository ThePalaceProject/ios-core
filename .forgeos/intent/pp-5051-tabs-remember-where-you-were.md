---
name: pp-5051-tabs-remember-where-you-were
created: 2026-08-31
author: claude-opus-5
---

**ADR refs:** none queried — ForgeOS governance is OFF (`FORGEOS_ENABLED=0`). The
prose contract for this area is `Palace/AppInfrastructure/AppTabHostView.swift`
and `NavigationCoordinatorHub.swift`, both rewritten by PP-5022.

## Context

PP-5051: leaving a tab throws away where you were in it. Browse deep into a
catalog lane, check My Books, come back — you are at the lane list root. Every
other iOS app keeps per-tab position, and Palace also has no way to ask for the
top, because tapping the already-selected tab does nothing.

The reset was added in `1e8409aff` ("PR clean up and minor bug fixes") with no
rationale, and until PP-5022 it popped whichever stack a global pointer happened
to hold — sometimes the tab being left, sometimes the one being entered.

## Consequence this change must carry

Removing the reset breaks an assumption elsewhere:
`AppContainer.popToRootForAccountSwitch` pops only the SELECTED tab, which is
sufficient today ONLY because every other tab was already popped on leave. After
this change a library switch would leave the previous library's book details,
lanes, and search results sitting in the three tabs the patron is not looking at.
So the account-switch cleanup has to reach every registered stack.

Census of `popToRoot` production callers: exactly two —
`AppTabHostView.handleTabSelectionChange` (the reset being removed) and
`AppContainer.popToRootForAccountSwitch` (the one being widened).

That census was the wrong shape and review caught it. It enumerated callers of a
FUNCTION when the thing being removed was an INVARIANT — "a tab you are not on is
at its root" — whose readers do not call `popToRoot` at all. The five
`tabRouterHub.navigate(to:)` sites each mean "send the patron to that tab to see
a specific thing" and every one of them relied on that invariant; a ready-hold
notification would have landed on whatever book detail was left in the Holds tab.
They now go through `AppContainer.navigateToTabRoot(_:)`. When removing an
invariant, enumerate its READERS, not the callers of the function that maintained
it.

## Claims

- removes the outgoing-tab `popToRoot` from `AppTabHostView.handleTabSelectionChange`,
  so each tab keeps its own stack across a switch
- adds field `TabTapOutcome` — what a tab-bar tap means, so the two-cell table is
  a value rather than a condition inside a closure
- adds public function `applyTabTap(_:current:hub:selectTab:)` on `AppTabHostView`
  — routes a tab tap: re-tap of the active tab pops that tab to root, any other tab
  changes selection. Takes its inputs explicitly because the view's `@StateObject`
  router cannot be observed from a test
- adds public function `tabTapOutcome(tapped:current:)` on `AppTabHostView`
- migrates both TabView builders from `$router.selected` to a custom `tabSelection`
  binding, which is the only place a re-tap of the current tab is observable
- adds public function `shouldAnimateArrival(currentTab:destination:)` on `AppContainer`
- adds public function `navigateToTabRoot(_:)` on `AppContainer`, and migrates the
  five app-initiated `tabRouterHub.navigate(to:)` sites to it so being SENT to a tab
  lands on its root rather than on whatever the patron left there
- adds public function `allRegisteredCoordinators()` on `NavigationCoordinatorHub`
- adds public function `popAllToRootForAccountSwitch(hub:)` on `AppContainer` so the
  account switch reaches every tab, not just the visible one

## Anti-claims

- does NOT change which routes exist, how any destination renders, or the reader
- does NOT change the tab set, tab order, or tab chrome
- does NOT touch sign-in, borrow, return, download, or DRM fulfillment logic
- does NOT change `NavigationCoordinator`'s public surface
- does NOT change the other side effects of a tab switch (modal dismiss, registry
  sync for My Books/Holds, VoiceOver announcement)

## Files in scope

- Palace/AppInfrastructure/AppTabHostView.swift
- Palace/AppInfrastructure/NavigationCoordinatorHub.swift
- Palace/AppInfrastructure/AppContainer.swift
- PalaceTests/AppInfrastructure/AppTabSwitchPreservesStacksTests.swift (renamed from
  AppTabHostTabSwitchResetTests.swift — the old name states the contract this change
  inverts)
- PalaceTests/AppInfrastructure/AppTabStackMemoryTests.swift
- Palace/AppInfrastructure/NavigationCoordinator.swift (doc only — the `animated:`
  flag's rationale named the tab-switch reset)
- Palace/Notifications/NotificationService.swift
- Palace/CatalogUI/Views/CatalogView.swift
- Palace/MyBooks/MyBooks/MyBooksView.swift
- Palace/Settings/NewSettings/TPPSettingsView.swift
- docs/architecture/in-app-navigation-during-playback.md
- PalaceTests/MetaTests/AppTabSelectionBindingLintTests.swift
- docs/architecture/areas/holds/verification-checklist.md
- Palace.xcodeproj/project.pbxproj
