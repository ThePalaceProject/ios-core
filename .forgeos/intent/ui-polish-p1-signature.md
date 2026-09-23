# Intent — UI Polish P1 Signature Moments (PP-4746)

PR3 of the UI-polish series. Presentation-only "signature moment" polish on top
of PR1 (iOS 17 bump) + PR2 (shared motion primitives: `PalaceMotion`,
`PalaceRadius`, `.palacePressable`, `.palaceHaptic`, `accessibleAnimation`).

## Claims

1. **Reader chrome toggle choreography** — `TPPBaseReaderViewController.toggleNavigationBar()`
   fades `bookTitleLabel` AND `positionLabel` (UIView alpha) in lockstep with the
   0.25s nav-bar slide instead of flipping `isHidden` instantly. Adds a pure,
   testable `overlayLabelsHidden(navigationBarHidden:voiceOverRunning:)` decision.
2. **Reader bookmark-add confirmation** — on a successful `addBookmark`, fire a
   pref-gated light haptic (`AccessibilityService.shared.triggerHaptic(.lightImpact)`)
   + a reduce-motion-gated bounce on the bookmark bar button (converted to a
   custom-view `UIButton` so the bounce is possible; same asset art, same
   target/action, same accessibility labels). Add-only; delete/passive relight
   unaffected.
3. **Reader theme/appearance cross-fade** — wrap `TPPReaderSettingsView` root in
   `accessibleAnimation(PalaceMotion.standard, value: settings.appearanceIndex)`
   and `TypographySettingsView` root in
   `accessibleAnimation(PalaceMotion.standard, value: viewModel.theme)`.
4. **Download-complete moment** — in `NormalBookCell`, when `model.stableButtonState`
   transitions to `.downloadSuccessful`, fire `.palaceHaptic(.success, trigger:)`
   + a one-shot scale pulse on the buttons row via `@State` +
   `accessibleAnimation(PalaceMotion.emphasized)`. Pure
   `shouldPulseReadButton(previous:current:)` seam. Display-only.
5. **Mini<->full player** — `AppTabHostView` full-player slide upgraded from
   `.easeInOut(0.3)` to `PalaceMotion.emphasized` (spring), same offset
   architecture. `AudiobookFullPlayerCoverContainer` dismiss `DragGesture` now
   tracks the finger via `.onChanged` (rubber-banded y-offset) and springs to
   dismiss/restore on `.onEnded`. Pure `rubberBandedDragOffset(translationHeight:)`
   + `shouldMinimize(translation:)` seams.
6. **Mini-player play/pause + entrance** — `.contentTransition(.symbolEffect(.replace))`
   + `accessibleAnimation(value: isPlaying)` on the glyph; container gets
   `.transition(.move(edge:.bottom).combined(with:.opacity))` + accessibleAnimation
   so it slides in/out.
7. **Sign-in button + inline error (PRESENTATION-ONLY)** — delete the
   `.id("signInButton-...")` / `.id("samlIDPList-...")` teardown hacks; animate
   `ActionButtonView` on `isLoading` via `accessibleAnimation`, hide the title
   (opacity 0, not 0.5) while loading, add `.palacePressable`. Add an inline error
   row under the PIN field rendered from the SAME existing `@Published`
   `alertMessage`/`showingAlert` (transition move(.top)+opacity under
   `PalaceMotion.emphasized`); existing `.alert` kept. Pure
   `titleOpacity(isLoading:)` + `shouldShowInlineFormError(showingAlert:message:)`
   seams.
8. **Library add/delete + current-library switch** — key the libraries `ForEach`
   list with `accessibleAnimation(value: accounts.map(\.uuid))`; add
   `.contentTransition(.symbolEffect(.replace))` + `.palaceHaptic(.success,
   trigger: currentAccountUUID)` on the active-library checkmark.

## Anti-claims (explicitly NOT changing)

- **NO authentication / credential / network / sign-in state-machine logic.** The
  sign-in screen changes (`AccountDetailView`, `ActionButtonView`) are animation,
  layout, and view-composition ONLY. No `@Published` semantics changed, no new
  view-model state, `signIn()` / `selectSAMLIDP()` / credential flow untouched.
- **NO download logic.** The download-complete moment reads `stableButtonState`
  only; `MyBooksDownloadCenter` / download machinery untouched.
- **NO audiobook playback / toolkit logic.** Full-player controls live in the
  submodule and are out of scope. Only the overlay slide animation + the
  container's dismiss-gesture presentation change here; `presenter.minimize()`
  behavior is preserved.
- No new user-facing copy without reusing existing strings catalog entries.
- No redesign of icons/layout; bookmark keeps its existing asset art.

## Files in scope

- `Palace/Reader2/UI/TPPBaseReaderViewController.swift`
- `Palace/Reader2/ReaderSettings/TPPReaderSettingsView.swift`
- `Palace/Reader2/Typography/TypographySettingsView.swift`
- `Palace/MyBooks/MyBooks/BookCell/NormalBookCell.swift`
- `Palace/AppInfrastructure/AppTabHostView.swift`
- `Palace/AppInfrastructure/AudiobookFullPlayerCoverContainer.swift`
- `Palace/AppInfrastructure/AudiobookMiniPlayerView.swift`
- `Palace/Settings/AccountDetailView.swift`
- `Palace/Settings/ActionButtonView.swift`
- `Palace/Settings/NewSettings/TPPSettingsView.swift`
- Tests: `PalaceTests/Reader2/ReaderChromeToggleFadeTests.swift`,
  `PalaceTests/Settings/SignInFormPresentationTests.swift`,
  `PalaceTests/MyBooks/DownloadCompleteMomentTests.swift`, and additions to
  `PalaceTests/AppInfrastructure/AudiobookFullPlayerCoverContainerTests.swift`.
