//
//  SettingsSkeletonView.swift
//  Palace
//
//  Skeleton for the Settings screen's MY LIBRARIES section (PP-4797), built on
//  the unified `Skeleton` primitives (PP-4752). Shown during the brief
//  launch-hydration window before the full account catalog materializes, so
//  the section renders placeholder library rows instead of a blank list that
//  pops in when hydration completes.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI

/// A single placeholder row that traces the real Libraries-screen row so a
/// loaded row and its skeleton have identical height and column positions (zero
/// layout shift). Values are pulled 1:1 from `LibrariesView.libraryRow`:
///   * Outer `HStack(spacing: 0)` holding the selection-control gutter and an
///     inner `HStack(spacing: 12)` for logo + text — the same nesting the real
///     row has, where `libraryRow` puts the control beside
///     `LibraryRowContentView` with no spacing between them.
///   * Leading selection-control gutter: 44pt. PP-5098 made the control a real
///     tap target, so the 22pt glyph sits in a `.frame(width: 44, height: 44)`
///     — it was a 28pt column while the glyph was decorative, and a skeleton
///     still reserving 28 (or adding the outer 12pt spacing on top of it) would
///     shift every logo sideways the moment it resolved.
///   * Logo: `Image(uiImage:).scaledToFit().frame(width: 44, height: 44)` ⇒
///     44×44, SQUARE (r=0) to match the un-rounded real logo — a rounded
///     skeleton snaps to square when the logo loads.
///   * Text column: a `.body` name line (17pt) + a `.footnote` subtitle line
///     (13pt), `VStack(alignment: .leading, spacing: 2)` — mirrors the real
///     row's name + optional subtitle.
///   * `.padding(.vertical, 4)` — matches the real row.
///
/// The real row's trailing disclosure chevron is drawn by the `NavigationLink`,
/// not by the row, so there is nothing here to trace for it.
struct SettingsLibraryRowSkeletonView: View {
    var body: some View {
        HStack(spacing: 0) {
            // Reserve the 44pt selection-control gutter so the logo starts at
            // the same x as the real row. No spacing after it — the real row
            // butts the control straight against the row body.
            Color.clear.frame(width: 44)

            HStack(spacing: 12) {
                // Square (r=0) to match the real library logo, which renders as
                // a plain `Image(uiImage:).scaledToFit()` with no rounding.
                SkeletonBox(width: 44, height: 44, cornerRadius: 0)

                VStack(alignment: .leading, spacing: 2) {
                    SkeletonBox(width: 180, height: 17, cornerRadius: 4)
                    SkeletonBox(width: 110, height: 13, cornerRadius: 4)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The MY LIBRARIES section skeleton: the section header plus a few
/// placeholder library rows. Rendered inside the Libraries screen's `List` in
/// place of the real `librariesSection` while
/// `LibrariesSectionViewModel.isLoading`. (PP-5098 moved the list itself off
/// the Settings tab; the skeleton travelled with it.)
///
/// `.accessibilityHidden(true)` follows the established skeleton convention
/// (Catalog / MyBooks / Account skeletons): the placeholder shapes are not
/// exposed to VoiceOver as real content; the surrounding "Settings" navigation
/// title conveys screen context.
struct SettingsLibrariesSkeletonView: View {
    typealias DisplayStrings = Strings.Settings

    var rows: Int = 3

    var body: some View {
        Section(header: Text(DisplayStrings.myLibraries)) {
            ForEach(0..<max(rows, 0), id: \.self) { _ in
                SettingsLibraryRowSkeletonView()
            }
        }
        .accessibilityHidden(true)
    }
}
