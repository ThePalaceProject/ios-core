---
name: pp5098-libraries-screen
created: 2026-09-08
author: Maurice Carrier
branch: feat/pp-5098-libraries-screen
priority: PP-5098 (Sprint 83, 3 pts) — Settings UI relocation; NOT critical-path (the account-switch chain is moved intact, not modified)
---

# Intent: move the library list and its management off the Settings tab onto a dedicated Libraries screen (PP-5098)

## Context

Settings lists the patron's libraries inline (PP-917), so a patron with five or
more libraries turns the tab into a long scroll that buries everything else.
Android is doing the same relocation under PP-1881, and the updated mockups put
libraries on a dedicated screen on both platforms.

`LibrariesSectionViewModel` is already a clean injectable seam behind the
`LibrariesSectionEnvironment` protocol — it owns `accounts`,
`currentAccountUUID`, `isSwitching`, `showAddLibrarySheet`, and `refresh()` /
`switchToAccount(_:completion:)` / `deleteSecondary(_:)` / `presentAddLibrary()`,
with the whole switching chain in `ProductionLibrariesSectionEnvironment`. A
dedicated screen can host that view model unmodified, which is what keeps the
ticket's out-of-scope guard ("no change to account-switching logic,
authentication, or catalog loading") genuinely true rather than aspirational.

Two things in the ticket did NOT survive contact with the code as written, and
both are resolved from the updated prototype rather than guessed:

1. The AC ("tapping a library's row opens that library's own settings")
   contradicts shipped behavior, where the ACTIVE row is a `NavigationLink` to
   `AccountDetailView` and an INACTIVE row is a `Button` opening the switch
   confirmation. The prototype resolves it in favour of the AC: the radio
   control switches, the row body opens library details on every row.
2. The iPad `sideBarEnabled` path wraps the list in a `NavigationView(.columns)`
   whose empty detail column is justified by a comment that says the list is
   inline. That justification dies with the list.

## Claims

- Adds a dedicated `LibrariesView`, pushed from a labeled Settings row, hosting
  the UNMODIFIED `LibrariesSectionViewModel`: list, current-library marker,
  switch, add-library sheet, swipe-to-delete, hydration skeleton, switching
  overlay and the post-switch Catalog tab jump all move there together.
- Removes the inline MY LIBRARIES section from `TPPSettingsView`; the Settings
  row is FIRST on the tab, so the remaining settings need no scrolling past a
  library list of any length.
- A library row gains a SECOND tap target. The leading radio control switches
  (confirmation dialog unchanged); the row body and disclosure chevron open that
  library's own settings — on active and inactive rows alike. Written as a
  `(state x tap)` table (`LibraryRowPresentation.outcome(of:)`) with all four
  cells asserted, because the row's behavior space doubled.
- Deletes the iPad two-column shape and the `UIDevice.current.orientation` reads
  that gated it. `AppTabHostView` already wraps this screen in
  `NavigationHostView` (a `NavigationStack`), so the landscape-only branch was
  nesting a deprecated `NavigationView` inside a navigation stack; portrait was
  already stacked. Settings → Libraries → Library Details becomes one push chain
  on every idiom.
- Moves the switch overlay onto the screen that starts the switch, via a named
  `SwitchingOverlayContainer`. Left at the navigation stack's root it would
  render BEHIND the pushed Libraries screen.
- New code takes an injected `AppContainer`, removing the
  `AppContainer.production()` reads the inline section made — including the one
  in `TPPSettingsView.init()`.
- Library names and descriptions reflow rather than truncate at large Dynamic
  Type sizes; the two tap targets are separate VoiceOver elements so selection
  is announced exactly once per library.

## Anti-claims

- Does NOT change the account-switch chain, authentication, or catalog loading.
  `ProductionLibrariesSectionEnvironment.switchToAccount` and
  `LibrariesSectionViewModel` are moved-in-place, not edited, and all 16 of
  `LibrariesSectionViewModelTests` pass untouched.
- Does NOT change what per-library settings contain, or rename
  `AccountDetailView`'s "Account" navigation title (the prototype says "Library
  Details"; that screen has other entry points, so the rename is flagged in the
  PR rather than made here).
- Does NOT surface the active library's name on the Settings row — the
  prototype's subtitle is static descriptive text, which answers the ticket's
  refinement question.
- Does NOT replace the deleted iPad columns with `horizontalSizeClass` or
  `NavigationSplitView` — that would build the split view this declines.
- Does NOT add in-app messaging about the moved flow, and does NOT touch the
  Android side (PP-1881).

## Verification plan

- Tests first: the `(state x tap)` table, the selection glyph, the swipe-delete
  guard, and the VoiceOver labels for both targets. NOT the overlay: rendering a
  SwiftUI view and reading its accessibility labels back works locally and
  returns nothing on CI, so that attempt was deleted rather than retried.
- Guards proven by reintroducing defects, each producing a NAMED failing
  assertion (a build failure is not a kill): dropping the negation in
  `isSelectionActionable`; inverting the selection glyph.
- `scripts/verify-pr.sh --quick` — full-scheme build + unit tests.
- On device, because unit tests cannot reach it: rotation with the columns gone,
  Stage Manager, the overlay covering the PUSHED screen (its Z-order is NOT
  test-pinnable here — no ViewInspector), the return-to-Settings stack state
  under PP-5051, iPad-on-Mac orientation `.unknown`, Dynamic Type reflow, and
  the two tap targets' hit testing inside one `List` row.

## Files in scope

- `Palace/Settings/NewSettings/LibrariesView.swift` (new — the screen + overlay container)
- `Palace/Settings/NewSettings/LibraryRowPresentation.swift` (new — the row tap table + labels)
- `Palace/Settings/NewSettings/TPPSettingsView.swift` (remove the inline section + iPad columns; add the entry row)
- `Palace/Settings/Components/SettingsSkeletonView.swift` (retrace the row geometry the skeleton mirrors)
- `Palace/Utilities/Localization/Strings.swift` (new strings)
- `Palace/Utilities/Testing/AccessibilityIdentifiers.swift` (new `libraries.*` ids)
- `PalaceTests/Settings/LibraryRowPresentationTests.swift` (new)
- `PalaceTests/Settings/LibrariesSectionViewModelTests.swift` (doc comments only)
