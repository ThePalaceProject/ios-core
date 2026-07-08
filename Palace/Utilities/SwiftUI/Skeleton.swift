//
//  Skeleton.swift
//  Palace
//
//  Unified skeleton loading system (PP-4752).
//
//  A single source of truth for content-shaped loading placeholders. Every
//  skeleton in the app is built from the primitives here, so the base color,
//  the shimmer cadence + direction, and the corner radii are identical
//  everywhere by construction — they all flow from the `Skeleton` tokens.
//
//  Design goals ("great", not "compiles"):
//    * Scheme-adaptive — reads correct in BOTH light and dark.
//    * A soft, wide highlight that sweeps DIAGONALLY in a continuous, smooth
//      loop (not a hard horizontal band).
//    * Reduce Motion → NO sweep; a calm static base.
//    * The sweep math is a pure static seam so it is unit-testable without a
//      SwiftUI host.
//
//  Deployment target is iOS 17.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI

// MARK: - Design tokens

/// Namespace for the skeleton design tokens + pure geometry seams. The visual
/// system (base fill, highlight, cadence, angle) lives here so every primitive
/// and every call site resolves to the same look.
enum Skeleton {

  // MARK: Colors (scheme-adaptive)

  /// The resting placeholder fill. Light mode uses a soft near-white gray;
  /// dark mode a low-luminance gray that sits just above the background.
  static func baseColor(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color(white: 0.22) : Color(white: 0.90)
  }

  /// The traveling highlight color. In light mode a near-white sheen; in dark
  /// mode a lifted gray (pure white would blow out on a dark base).
  static func highlightColor(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color(white: 0.40) : Color(white: 1.0)
  }

  /// Peak opacity of the highlight at the band's center. Kept below 1 so the
  /// sweep reads as a soft sheen rather than a hard flash.
  static func highlightPeakOpacity(_ scheme: ColorScheme) -> Double {
    scheme == .dark ? 0.55 : 0.75
  }

  // MARK: Cadence + geometry

  /// One shimmer cycle duration. A single value everywhere → one cadence.
  static let duration: Double = 1.3

  /// The diagonal tilt of the sweep, measured from vertical. A gentle lean so
  /// the highlight crosses as a diagonal band, not a horizontal wipe.
  static let angle: Angle = .degrees(18)

  /// The highlight band width as a fraction of the content width. Wide + soft.
  static let highlightWidthFraction: CGFloat = 0.7

  /// Minimum band width (points) so tiny elements still get a visible sheen.
  static let minBandWidth: CGFloat = 80


  // MARK: Pure seams (unit-testable)

  /// The width (points) of the highlight band for a content of `contentWidth`.
  /// Wide and soft, but never narrower than `minBandWidth`.
  static func bandWidth(contentWidth: CGFloat) -> CGFloat {
    max(contentWidth * highlightWidthFraction, minBandWidth)
  }

  /// Horizontal translation (points) of the diagonal highlight band for a
  /// normalized `phase` in `[-1, 1]`.
  ///
  /// The band must travel from fully off the leading edge to fully off the
  /// trailing edge. Because the band is tilted by `angle`, the effective
  /// horizontal span it must cross is the content width plus the horizontal
  /// shadow of the content height across the tilt (`height * tan(angle)`),
  /// plus the band's own width. Centered geometry ⇒ the travel is symmetric:
  ///
  ///   phase = -1 → band fully off the leading edge   (negative offset)
  ///   phase =  0 → band centered on the content      (zero)
  ///   phase = +1 → band fully off the trailing edge  (positive offset)
  ///
  /// This is the visual property whose absence made the old shimmer render as
  /// a static wash: a moving `phase` here produces a visible traveling sweep.
  static func sweepTranslationX(phase: CGFloat,
                                width: CGFloat,
                                height: CGFloat,
                                angle: Angle,
                                bandWidth: CGFloat) -> CGFloat {
    let tilt = abs(CGFloat(tan(angle.radians)))
    let extendedWidth = width + height * tilt
    let travel = extendedWidth + bandWidth
    return phase * (travel / 2)
  }

  /// The normalized sweep phase in `[-1, 1)` for a given wall-clock `time`.
  ///
  /// A pure function of time so ALL skeletons share one OS-driven clock (a
  /// `TimelineView(.animation)`) instead of each owning a `repeatForever`
  /// timer — the single most important perf decision when a full catalog shows
  /// ~30 skeletons at once. `time` ramps the phase linearly from `-1` to `+1`
  /// over `duration`, then wraps back to `-1`. The wrap is invisible because
  /// the band is fully off-screen at both ends (see `sweepTranslationX`).
  static func phase(at time: TimeInterval, duration: Double) -> CGFloat {
    guard duration > 0 else { return -1 }
    let fraction = (time.truncatingRemainder(dividingBy: duration) + duration)
      .truncatingRemainder(dividingBy: duration) / duration   // 0 ..< 1
    return CGFloat(fraction * 2 - 1)                           // -1 ..< 1
  }

  /// Whether the sweep should animate. The sweep is suppressed — a calm static
  /// base shows instead — when the skeleton is inactive, or whenever continuous
  /// animation is globally disallowed (Reduce Motion OR Low Power Mode). Routes
  /// through `PalaceMotion.shouldAnimateContinuously` so the shimmer and the
  /// cover-load pulse share ONE gate.
  static func shouldAnimateSweep(active: Bool, reduceMotion: Bool, lowPower: Bool) -> Bool {
    active && PalaceMotion.shouldAnimateContinuously(reduceMotion: reduceMotion, lowPower: lowPower)
  }
}

// MARK: - Shimmer engine (shared clock, gated once)

/// The moving highlight band. Driven by a single OS-driven `TimelineView(.animation)`
/// clock; the phase is a pure function of wall-clock time
/// (`Skeleton.phase(at:duration:)`). There is NO per-view `repeatForever` timer,
/// so a full catalog (~30 skeletons) shares one clock instead of 30 always-on
/// loops. `TimelineView` pauses off-screen and stops when the view is removed
/// once content loads. Per-frame work is one 3-stop `LinearGradient` offset —
/// no blur, no `.plusLighter`, no offscreen render pass.
private struct SkeletonSweepBand: View {
  let scheme: ColorScheme

  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width
      let h = geo.size.height
      let band = Skeleton.bandWidth(contentWidth: w)
      let peak = Skeleton.highlightPeakOpacity(scheme)
      let highlight = Skeleton.highlightColor(scheme)

      TimelineView(.animation) { timeline in
        let phase = Skeleton.phase(
          at: timeline.date.timeIntervalSinceReferenceDate,
          duration: Skeleton.duration
        )
        Rectangle()
          .fill(
            LinearGradient(
              gradient: Gradient(colors: [
                highlight.opacity(0),
                highlight.opacity(peak),
                highlight.opacity(0)
              ]),
              startPoint: .leading,
              endPoint: .trailing
            )
          )
          // Tall enough that the tilted band fully covers the content corners.
          .frame(width: band, height: hypot(w, h) * 1.6)
          .rotationEffect(Skeleton.angle)
          .offset(
            x: Skeleton.sweepTranslationX(
              phase: phase, width: w, height: h,
              angle: Skeleton.angle, bandWidth: band
            )
          )
          .frame(width: w, height: h, alignment: .center)
      }
    }
    .allowsHitTesting(false)
  }
}

/// Owns the ONE gate + power-state observation for the sweep. Renders the moving
/// band only when a continuous animation is allowed (active, and not Reduce
/// Motion / Low Power Mode); otherwise renders nothing so the calm static base
/// shows and no clock is created.
private struct SkeletonSweepOverlay: View {
  var active: Bool

  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

  private var animate: Bool {
    Skeleton.shouldAnimateSweep(active: active, reduceMotion: reduceMotion, lowPower: lowPower)
  }

  var body: some View {
    band
      .onReceive(
        NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)
      ) { _ in
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
      }
  }

  @ViewBuilder private var band: some View {
    if animate {
      SkeletonSweepBand(scheme: scheme)
    } else {
      // Calm static base: no band, no clock created.
      Color.clear
    }
  }
}

/// Generic shimmer for arbitrary content (legacy `shimmerEffect()` callers).
/// Uses `.mask(content)` because the content shape is not statically known.
/// The shape primitives below use the cheaper `.clipShape` path instead.
struct ShimmerModifier: ViewModifier {
  var active: Bool = true

  func body(content: Content) -> some View {
    content.overlay {
      SkeletonSweepOverlay(active: active)
        .mask(content)
    }
  }
}

extension View {
  /// Overlays the premium diagonal shimmer sweep on a base-filled shape.
  /// Reduce Motion / Low Power Mode show a calm static base (no sweep).
  func shimmering(active: Bool = true) -> some View {
    modifier(ShimmerModifier(active: active))
  }

  /// Shape-aware shimmer for the primitives: fills `shape` with the adaptive
  /// base, overlays the sweep, and CLIPS to `shape` (cheap) rather than masking
  /// (which forces a per-frame offscreen content re-render).
  fileprivate func skeletonSurface<S: Shape>(_ shape: S, base: Color, active: Bool) -> some View {
    shape
      .fill(base)
      .overlay { SkeletonSweepOverlay(active: active) }
      .clipShape(shape)
  }
}

// MARK: - Shape primitives

/// A single rounded placeholder block. The atom of the system: adaptive base
/// fill + the shared shimmer + a radius token.
struct SkeletonBox: View {
  var width: CGFloat?
  var height: CGFloat?
  var cornerRadius: CGFloat = PalaceRadius.control
  var active: Bool = true

  @Environment(\.colorScheme) private var scheme

  init(width: CGFloat? = nil,
       height: CGFloat? = nil,
       cornerRadius: CGFloat = PalaceRadius.control,
       active: Bool = true) {
    self.width = width
    self.height = height
    self.cornerRadius = cornerRadius
    self.active = active
  }

  var body: some View {
    skeletonSurface(
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
      base: Skeleton.baseColor(scheme),
      active: active
    )
    .frame(width: width, height: height)
    .accessibilityHidden(true)
  }
}

/// A run of text lines, the last one shorter to mimic real prose. Widths flow
/// from the available width via a `GeometryReader`; the fraction math is the
/// pure `SkeletonText.lineWidth` seam.
struct SkeletonText: View {
  var lines: Int
  var lineHeight: CGFloat = 12
  var spacing: CGFloat = 8
  var lastLineFraction: CGFloat = 0.6
  var cornerRadius: CGFloat = 4
  var active: Bool = true

  init(lines: Int,
       lineHeight: CGFloat = 12,
       spacing: CGFloat = 8,
       lastLineFraction: CGFloat = 0.6,
       cornerRadius: CGFloat = 4,
       active: Bool = true) {
    self.lines = lines
    self.lineHeight = lineHeight
    self.spacing = spacing
    self.lastLineFraction = lastLineFraction
    self.cornerRadius = cornerRadius
    self.active = active
  }

  /// The width of the line at `index` given the total available `totalWidth`.
  /// Pure seam: the last line of a multi-line block is `lastLineFraction` wide.
  static func lineWidth(index: Int,
                        count: Int,
                        totalWidth: CGFloat,
                        lastLineFraction: CGFloat) -> CGFloat {
    guard count > 1, index == count - 1 else { return totalWidth }
    return totalWidth * lastLineFraction
  }

  private var totalHeight: CGFloat {
    guard lines > 0 else { return 0 }
    return CGFloat(lines) * lineHeight + CGFloat(lines - 1) * spacing
  }

  var body: some View {
    GeometryReader { geo in
      VStack(alignment: .leading, spacing: spacing) {
        ForEach(0..<max(lines, 0), id: \.self) { index in
          SkeletonBox(
            width: SkeletonText.lineWidth(
              index: index, count: lines,
              totalWidth: geo.size.width,
              lastLineFraction: lastLineFraction
            ),
            height: lineHeight,
            cornerRadius: cornerRadius,
            active: active
          )
        }
      }
    }
    .frame(height: totalHeight)
    .accessibilityHidden(true)
  }
}

/// A book-cover placeholder — cover aspect at the caller's size, SQUARE corners
/// to match the settled cover. `BookImageView` renders the real cover as a plain
/// `Image(...).aspectRatio(.fit)` with NO corner rounding, so a rounded skeleton
/// (previously `PalaceRadius.card` = 12pt) visibly snapped to square corners when
/// the cover faded in. Square here keeps the placeholder → cover transition
/// shape-stable. If book covers ever gain a corner radius, change BOTH sites.
struct SkeletonCover: View {
  var width: CGFloat = 100
  var height: CGFloat = 150
  var active: Bool = true

  /// Matches `BookImageView`'s cover, which is not corner-rounded. `0` = square.
  static let coverCornerRadius: CGFloat = 0

  init(width: CGFloat = 100, height: CGFloat = 150, active: Bool = true) {
    self.width = width
    self.height = height
    self.active = active
  }

  var body: some View {
    SkeletonBox(
      width: width, height: height,
      cornerRadius: Self.coverCornerRadius, active: active
    )
  }
}

/// A circular placeholder (avatars, logos, badges).
struct SkeletonCircle: View {
  var size: CGFloat
  var active: Bool = true

  @Environment(\.colorScheme) private var scheme

  init(size: CGFloat, active: Bool = true) {
    self.size = size
    self.active = active
  }

  var body: some View {
    skeletonSurface(Circle(), base: Skeleton.baseColor(scheme), active: active)
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

// MARK: - Container cross-fade

/// Cross-fades between a skeleton placeholder and the real content using the
/// shared gentle motion. When `isActive` the placeholder shows; otherwise the
/// content. The hand-off is animated (Reduce Motion drops the animation).
struct SkeletonContainerModifier<Placeholder: View>: ViewModifier {
  let isActive: Bool
  let placeholder: Placeholder

  func body(content: Content) -> some View {
    ZStack {
      if isActive {
        placeholder
          .transition(.opacity)
      } else {
        content
          .transition(.opacity)
      }
    }
    .accessibleAnimation(PalaceMotion.gentle, value: isActive)
  }
}

extension View {
  /// Cross-fades this content with a skeleton placeholder while `isActive`.
  ///
  /// ```swift
  /// realContent
  ///   .skeleton(model.isLoading) { MyContentSkeletonView() }
  /// ```
  func skeleton<Placeholder: View>(
    _ isActive: Bool,
    @ViewBuilder placeholder: () -> Placeholder
  ) -> some View {
    modifier(SkeletonContainerModifier(isActive: isActive, placeholder: placeholder()))
  }
}
