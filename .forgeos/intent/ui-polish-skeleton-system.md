# Intent — Unified Skeleton Loading System (PP-4752)

## Summary
Build a single, premium, scheme-adaptive skeleton loading system
(`Palace/Utilities/SwiftUI/Skeleton.swift`) and adopt it across the app,
replacing the flat gray horizontal shimmer and the bare `ProgressView()`
spinners that appear where the loading surface has a known content shape.
Polish-only; no redesign of the underlying screens.

## Claims
- Adds a `Skeleton` design-token namespace: scheme-adaptive base fill + highlight,
  one shimmer duration, a diagonal sweep angle; radii from `PalaceRadius`.
- Adds a premium `.shimmering(active:)` ViewModifier: adaptive base (light AND
  dark), a soft wide highlight that sweeps diagonally in a continuous loop;
  Reduce Motion shows a calm static base (no sweep).
- Extracts the sweep math into pure static seams on `Skeleton`
  (`sweepTranslationX`, `SkeletonText.lineWidth`) so they are unit-testable.
- Adds shape primitives `SkeletonBox`, `SkeletonText`, `SkeletonCover`,
  `SkeletonCircle`, all adaptive + radius-tokenized.
- Adds a `.skeleton(_:placeholder:)` container modifier that cross-fades
  (`accessibleAnimation(PalaceMotion.gentle)`) between skeleton and content.
- Rebuilds the 4 existing skeletons on the new primitives.
- Replaces bare-spinner loading states that have a known content shape with
  content-shaped skeletons (catalog, my-books, holds, book detail, search, PDF).
- Re-implements the old `shimmerEffect()` / `ShimmerView` / `loadingOverlay`
  as thin wrappers over the new system so remaining call sites keep working.
- Adds unit tests for the pure seams.

## Anti-claims
- Does NOT redesign any screen layout or change navigation/behavior.
- Does NOT convert genuinely-indeterminate/short spinners (inline button
  spinners, web/EULA page loads, determinate progress bars).
- Does NOT touch critical-path auth/borrow/return/DRM logic.

## Files in scope
- Palace/Utilities/SwiftUI/Skeleton.swift (new)
- Palace/Utilities/SwiftUI/LoadingOverlayModifier.swift (wrappers)
- Palace/MyBooks/MyBooks/BookListSkeletonView.swift
- Palace/CatalogUI/Views/CatalogLaneSkeletonView.swift
- Palace/CatalogUI/Views/CatalogLaneRowView.swift
- Palace/Settings/Components/AccountDetailSkeletonView.swift
- High-traffic loading call sites (catalog, my-books, holds, book detail, PDF, search)
- PalaceTests/.../SkeletonTests.swift (new)
