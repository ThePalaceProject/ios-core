# Intent: PR5 — modernization sweep + latent-bug fixes + dead-code removal (PP-4748)

## Claims
- **Part A (behavior-preserving modernization):** rename `.foregroundColor(` -> `.foregroundStyle(` (~48 files, modifier name only); `NavigationView` -> `NavigationStack` in simple sheets/pickers (CatalogFiltersSheetView, SignInModalView, FontPickerView, TypographySettingsView, AudiobookFullPlayerCoverContainer), drop `.navigationViewStyle(.stack)`; single-param `.onChange(of:)`/`.onChange(of:perform:)` -> two-param `{ _, new in }` and remove `Binding+onChange.swift` shim + its 2 call sites; `presentationMode` -> `@Environment(\.dismiss)`, `.navigationBarItems` -> `.toolbar`; remove always-true `if #available(iOS 17.0, *)` in SideLoadingView.
- **Part B (behavior-changing, with tests):** Bug7 TPPPDFReaderView `.sheet(isPresented: .constant(...))` -> real `Binding(get:set:)` resetting `readerMode` to `.reader` on dismiss (+ seam test); Bug8 NormalBookCell reset `downloadProgress = 0` on isDownloading false->true (+ seam test, no download/registry logic); Bug9 EPUBSearchView black header -> `.foregroundStyle(.primary)` + remove dead `if #available(iOS 15,*)`.
- **Part C (dead code, grep-confirmed zero call sites):** ContinueListeningRow/ContinueReadingRow; duplicate Settings/Components/ActionButtonView.swift (not in pbxproj); RefreshableView.swift + shadowing `refreshable(_:)`; stray dead modifiers in BookDetailView/AudiobookSampleToolbar; unused Platform banners PositionSyncBanner/OfflineQueueStatusView/OfflineQueueBadge; remove deleted compiled files from pbxproj (both targets).

## Deferred (scope-reduction, explicit)
- **Item 3 — deprecated `ActionSheet`/`Alert(...)` struct modernization** (MyBooksView, FacetView, HoldsView, CatalogView, HalfSheetview, NormalBookCell, BookDetailView, TPPPDFReaderView, ReadiumPDFReaderView; ~10 SwiftUI dialog sites): deferred to a focused follow-up. Rationale: these are user-facing dialog surfaces on borrow/holds/sort/position-sync paths that CLAUDE.md requires a chaos-qa sim pass for; the deprecated structs still compile and behave correctly on the iOS 17 floor, so this is a zero-user-impact deprecation cleanup best done with simulator verification rather than blind conversion under a strict behavior-preserving bar.

## Anti-claims
- No color/appearance changes in the sweep except the explicit dark-mode Bug9 fix.
- No behavior changes in Part A beyond modifier/container/API modernization.
- No submodule changes (PR6 owns audiobook player dark-theme + AudiobookSlider).
- No auth/sign-in, download-machinery, or book-registry logic changes — only display-value/color-modifier changes on those surfaces.
- No changes to the REAL Palace/Settings/ActionButtonView.swift.
- No change to TPPSettingsView NavigationView (deferred — needs NavigationSplitView).

## Critical-path files touched (mechanical color-only, for review routing)
- Palace/SignInLogic/SignInWebSheet.swift, Palace/SignInLogic/SignInModalView.swift
- Palace/AppInfrastructure/AudiobookMiniPlayerView.swift, Palace/AppInfrastructure/AudiobookFullPlayerCoverContainer.swift
- Palace/Settings/AccountDetailView.swift
- Palace/MyBooks/MyBooks/BookCell/NormalBookCell.swift (+ Bug8), BookButtonsView.swift
