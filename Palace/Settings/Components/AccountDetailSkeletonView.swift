//
//  AccountDetailSkeletonView.swift
//  Palace
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
    }

    private var headerSkeleton: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.gray.opacity(0.25))
                .frame(width: 50, height: 50)
                .shimmerEffect()

            Rectangle()
                .fill(Color.gray.opacity(0.25))
                .frame(width: 150, height: 20)
                .shimmerEffect()

            Spacer()
        }
        .padding(.vertical, 8)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    private var fieldSkeleton: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.25))
            .frame(height: 44)
            .shimmerEffect()
    }
}
