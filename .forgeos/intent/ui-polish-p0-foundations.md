# Intent — UI polish P0 shared motion foundations (PP-4745, PR2)

## Summary

Polish-only, no-redesign change that establishes shared motion foundations for
the Palace UI. Fixes the dead shimmer, introduces `PalaceMotion` / `PalaceRadius`
constants, a shared pressable button style, a preference-gated haptic modifier,
and a reactive (environment-driven) reduce-motion animation seam. Adopts these in
the code they touch — no mass migration.

Deployment target is iOS 17, so iOS-17 APIs (`.smooth`/`.snappy`, `.sensoryFeedback`,
`@Environment(\.accessibilityReduceMotion)`) are used without `@available` gating.

## Claims

- Fixes `ShimmerEffect` so a visual property (the highlight band offset) reads the
  animated phase and sweeps across the masked content — it no longer renders as a
  static grey wash.
- Adopts the shared shimmer in the four hand-rolled skeletons (`BookRowSkeletonView`,
  `CatalogLaneSkeletonView`, the private `LaneSkeletonView` in `CatalogLaneRowView`,
  `AccountDetailSkeletonView`), replacing each opacity-pulse with `.shimmerEffect()`
  while keeping the existing layout.
- Adds `PalaceMotion` (`standard`/`emphasized`/`gentle`/`shimmer`) and `PalaceRadius`
  (`card = 12`, `control = 8`) constant namespaces, wired into BOTH targets.
- Adds `PalacePressableButtonStyle` (scale 0.96 + subtle opacity on press, reduce-motion
  aware) wired into both targets, applied to the lane cover cards and shelf cells.
- Adds a `.palaceHaptic(_:trigger:)` SwiftUI modifier that wraps `.sensoryFeedback`
  and consults `AccessibilityService`'s `hapticFeedbackEnabled` preference + reduce-motion.
- Makes the reduce-motion animation-application path a reactive `ViewModifier` reading
  `@Environment(\.accessibilityReduceMotion)` so mid-session toggles are honored; the
  existing `accessibleAnimation(_:value:)` API is preserved.
- Adds a cover fade-in in `BookImageView` and activates the previously-dead cell
  transitions in `NormalBookCell`, both routed through the reduce-motion-aware seam.

## Anti-claims

- Does NOT change download / borrow / return / auth / DRM logic.
- Does NOT touch `NormalBookCell` download machinery (only the display-layer animation
  wiring on the cell root).
- No redesigns — every skeleton keeps its exact layout; only the pulse mechanism changes.
- No mass duration migration — the ~31 magic-duration sites are left untouched; constants
  are only adopted in the code these items already touch.
- Does NOT add new `@Published` state, reducers, or state-machine cases.

## Files in scope

Production (new):
- `Palace/Utilities/SwiftUI/PalaceMotion.swift`
- `Palace/Utilities/SwiftUI/PalacePressableButtonStyle.swift`
- `Palace/Utilities/SwiftUI/PalaceHaptic.swift`

Production (modified):
- `Palace/Utilities/SwiftUI/AccessibleAnimation.swift`
- `Palace/Utilities/SwiftUI/LoadingOverlayModifier.swift`
- `Palace/MyBooks/MyBooks/BookListSkeletonView.swift`
- `Palace/CatalogUI/Views/CatalogLaneSkeletonView.swift`
- `Palace/CatalogUI/Views/CatalogLaneRowView.swift`
- `Palace/Settings/Components/AccountDetailSkeletonView.swift`
- `Palace/Book/UI/BookDetail/BookImageView.swift`
- `Palace/MyBooks/MyBooks/BookCell/NormalBookCell.swift`
- `Palace/MyBooks/MyBooks/BookListView.swift`

Tests (new):
- `PalaceTests/Utilities/PalaceMotionTests.swift` (reduce-motion resolver + shimmer sweep + radius tokens)
- `PalaceTests/Utilities/PalacePressableButtonStyleTests.swift`
- `PalaceTests/Utilities/PalaceHapticTests.swift`
