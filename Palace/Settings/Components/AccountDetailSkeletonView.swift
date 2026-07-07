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

    private var headerSkeleton: some View {
        HStack(spacing: 12) {
            SkeletonCircle(size: 50)

            VStack(alignment: .leading, spacing: 8) {
                SkeletonBox(width: 150, height: 20, cornerRadius: 4)
                SkeletonBox(width: 90, height: 12, cornerRadius: 4)
            }

            Spacer()
        }
        .padding(.vertical, 8)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    private var fieldSkeleton: some View {
        SkeletonBox(height: 44, cornerRadius: PalaceRadius.control)
            .frame(maxWidth: .infinity)
    }
}
