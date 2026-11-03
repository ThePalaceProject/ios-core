//
//  AudiobookPlayerLoadingSkeleton.swift
//  Palace
//
//  The shimmer lockup the audiobook player shows while it loads.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import SwiftUI

/// Mirrors the portrait full-player layout (grabber, title, scrubber, cover,
/// transport, bottom chips) on an opaque background, so a fresh open reads as the
/// player materializing. VoiceOver reads it as one element saying it is loading.
struct AudiobookPlayerLoadingSkeleton: View {
    let bottomInset: CGFloat

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 0) {
                SkeletonBox(width: 40, height: 5, cornerRadius: 2.5)
                    .padding(.top, 12)

                Spacer(minLength: 20)

                VStack(spacing: 10) {
                    SkeletonBox(width: 220, height: 20, cornerRadius: 4)
                    SkeletonBox(width: 150, height: 14, cornerRadius: 4)
                }

                VStack(spacing: 10) {
                    SkeletonBox(height: 4, cornerRadius: 2)
                    HStack {
                        SkeletonBox(width: 40, height: 12, cornerRadius: 3)
                        Spacer()
                        SkeletonBox(width: 40, height: 12, cornerRadius: 3)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 22)

                Spacer(minLength: 24)

                SkeletonBox(width: 240, height: 240, cornerRadius: 12)

                Spacer(minLength: 24)

                HStack(spacing: 26) {
                    SkeletonCircle(size: 40)
                    SkeletonCircle(size: 52)
                    SkeletonCircle(size: 72)
                    SkeletonCircle(size: 52)
                    SkeletonCircle(size: 40)
                }

                HStack(spacing: 40) {
                    SkeletonBox(width: 60, height: 30, cornerRadius: 15)
                    SkeletonBox(width: 44, height: 30, cornerRadius: 15)
                    SkeletonBox(width: 60, height: 30, cornerRadius: 15)
                }
                .padding(.top, 26)
                .padding(.bottom, bottomInset + 24)
            }
            .padding(.horizontal, 24)
        }
        .accessibilityElement()
        .accessibilityLabel(Strings.Generic.audiobookLoading)
    }
}
