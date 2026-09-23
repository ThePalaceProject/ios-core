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

/// A single placeholder row that traces `LibraryRowView` (the real MY LIBRARIES
/// row) so a loaded row and its skeleton have identical height and column
/// positions (zero layout shift). Values are pulled 1:1 from `LibraryRowView`:
///   * Outer `HStack(spacing: 12)` — matches the real row.
///   * Leading selection glyph gutter: the real row reserves a 28pt-wide column
///     for the `circle` / `checkmark.circle.fill` symbol (`.frame(width: 28)`).
///   * Logo: `Image(uiImage:).scaledToFit().frame(width: 44, height: 44)` ⇒
///     44×44, SQUARE (r=0) to match the un-rounded real logo — a rounded
///     skeleton snaps to square when the logo loads.
///   * Text column: a `.body` name line (17pt) + a `.footnote` subtitle line
///     (13pt), `VStack(alignment: .leading, spacing: 2)` — mirrors the real
///     row's name + optional subtitle.
///   * `.padding(.vertical, 4)` — matches the real row.
struct SettingsLibraryRowSkeletonView: View {
    var body: some View {
        HStack(spacing: 12) {
            // Reserve the 28pt selection-glyph gutter so the logo starts at the
            // same x as the real row.
            Color.clear.frame(width: 28)

            // Square (r=0) to match the real library logo, which renders as a
            // plain `Image(uiImage:).scaledToFit()` with no corner rounding.
            SkeletonBox(width: 44, height: 44, cornerRadius: 0)

            VStack(alignment: .leading, spacing: 2) {
                SkeletonBox(width: 180, height: 17, cornerRadius: 4)
                SkeletonBox(width: 110, height: 13, cornerRadius: 4)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

/// The MY LIBRARIES section skeleton: the section header ("Libraries") plus a
/// few placeholder library rows. Rendered inside the settings `List` in place
/// of the real `librariesSection` while `LibrariesSectionViewModel.isLoading`.
///
/// `.accessibilityHidden(true)` follows the established skeleton convention
/// (Catalog / MyBooks / Account skeletons): the placeholder shapes are not
/// exposed to VoiceOver as real content; the surrounding "Settings" navigation
/// title conveys screen context.
struct SettingsLibrariesSkeletonView: View {
    typealias DisplayStrings = Strings.Settings

    var rows: Int = 3

    var body: some View {
        Section(header: Text(DisplayStrings.libraries)) {
            ForEach(0..<max(rows, 0), id: \.self) { _ in
                SettingsLibraryRowSkeletonView()
            }
        }
        .accessibilityHidden(true)
    }
}
