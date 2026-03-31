//
//  PositionSyncBanner.swift
//  Palace
//
//  Banner overlay for cross-format position sync offers.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI

/// A banner that appears when cross-format sync is available.
struct PositionSyncBanner: View {
    let fromPosition: ReadingPosition
    let toPosition: ReadingPosition
    let onAccept: () -> Void
    let onDismiss: () -> Void

    @State private var isVisible = true

    var body: some View {
        if isVisible {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: formatIcon(fromPosition.format))
                        .font(.title3)
                        .foregroundColor(.accentColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(bannerTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)

                        Text(bannerSubtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button("Go") {
                        withAnimation(.easeOut(duration: 0.2)) {
                            isVisible = false
                        }
                        onAccept()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            isVisible = false
                        }
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial)
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                .padding(.horizontal, 16)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(bannerTitle)
            .accessibilityHint("Double tap to jump to that position, or swipe to dismiss")
            .accessibilityAddTraits(.isButton)
        }
    }

    private var bannerTitle: String {
        switch fromPosition.format {
        case .epub:
            return "Continue from the ebook?"
        case .audiobook:
            return "Continue from the audiobook?"
        case .pdf:
            return "Continue from the PDF?"
        }
    }

    private var bannerSubtitle: String {
        "You were at \(fromPosition.displayDescription)"
    }

    private func formatIcon(_ format: ReadingFormat) -> String {
        switch format {
        case .epub: return "book.fill"
        case .audiobook: return "headphones"
        case .pdf: return "doc.fill"
        }
    }
}
