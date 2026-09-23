//
//  LoadingOverlayModifier.swift
//  Palace
//
//  Backwards-compatible wrappers over the unified skeleton system
//  (`Skeleton.swift`, PP-4752). These types predate the system; they now
//  delegate to it so every skeleton in the app shares one base color, one
//  shimmer cadence + diagonal direction, and one set of radii by construction.
//
//  Prefer the new API in new code:
//    * `SkeletonBox` / `SkeletonText` / `SkeletonCover` / `SkeletonCircle`
//    * `.shimmering(active:)`
//    * `.skeleton(_:placeholder:)`
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI

/// Cross-fades content with a single full-bleed skeleton block while loading.
/// Thin wrapper over `.skeleton(_:placeholder:)`.
struct LoadingOverlayModifier: ViewModifier {
  var isLoading: Bool

  func body(content: Content) -> some View {
    content.skeleton(isLoading) {
      SkeletonBox(cornerRadius: PalaceRadius.control)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

extension View {
  func loadingOverlay(isLoading: Bool) -> some View {
    self.modifier(LoadingOverlayModifier(isLoading: isLoading))
  }
}

/// Legacy shimmer entry point. Now delegates to the unified `.shimmering`
/// sweep so callers that apply `.shimmerEffect()` to their own filled shape
/// get the premium diagonal, reduce-motion-aware sweep.
struct ShimmerEffect: ViewModifier {
  func body(content: Content) -> some View {
    content.shimmering(active: true)
  }
}

extension View {
  func shimmerEffect() -> some View {
    self.shimmering(active: true)
  }
}

/// Legacy single-block placeholder. Now a thin wrapper over `SkeletonBox` so it
/// picks up the adaptive base fill + shared shimmer.
struct ShimmerView: View {
  var width: CGFloat
  var height: CGFloat
  var cornerRadius: CGFloat = 0

  var body: some View {
    SkeletonBox(width: width, height: height, cornerRadius: cornerRadius)
      .transition(.opacity)
  }
}
