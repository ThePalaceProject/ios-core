//
//  AccountDetailSkeletonView.swift
//  Palace
//
//  Skeleton for the account-detail screen, built on the unified `Skeleton`
//  primitives (PP-4752): a header avatar + library name, then grouped field
//  rows — mirroring the real AccountDetailView layout.
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import SwiftUI

struct AccountDetailSkeletonView: View {
    var body: some View {
        List {
            headerSkeleton

            Section {
                ForEach(0..<3, id: \.self) { _ in
                    fieldSkeleton
                }
            }

            Section {
                fieldSkeleton
            }
        }
        .listStyle(GroupedListStyle())
        .accessibilityHidden(true)
    }

    // Traces `AccountDetailView.accountHeaderSection` 1:1:
    //   * `HStack(spacing: 12)` (Layout.logoSpacingList)
    //   * 50×50 logo (Layout.logoSizeList) — a rounded square, since the real
    //     logo is `Image.scaledToFit().frame(50×50)`, not a circular avatar.
    //   * ONE headline line (`Text(libraryName).palaceFont(.headline)`) — the
    //     real header has no subtitle, so there is no second line.
    //   * `.listRowInsets(top: 8, leading: 25, bottom: 8, trailing: 25)` =
    //     (verticalPaddingSmall, horizontalPadding) so the logo/text land at the
    //     real header's x/y, and `.listRowBackground(.clear)`.
    private var headerSkeleton: some View {
        HStack(spacing: 12) {
            SkeletonBox(width: 50, height: 50, cornerRadius: PalaceRadius.card)

            SkeletonBox(width: 150, height: 20, cornerRadius: 4)

            Spacer()
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 8, leading: 25, bottom: 8, trailing: 25))
    }

    private var fieldSkeleton: some View {
        SkeletonBox(height: 44, cornerRadius: PalaceRadius.control)
            .frame(maxWidth: .infinity)
    }
}
