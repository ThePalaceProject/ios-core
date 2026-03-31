//
//  ShareCardView.swift
//  Palace
//
//  Created for Social Features — renders a shareable book card.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI

/// Renders a beautiful shareable card with book cover, metadata, and branding.
struct ShareCardView: View {
    let card: ShareableBookCard
    @State private var quoteText: String
    let onGenerate: (String) -> Void

    init(card: ShareableBookCard, onGenerate: @escaping (String) -> Void) {
        self.card = card
        self._quoteText = State(initialValue: card.quote)
        self.onGenerate = onGenerate
    }

    var body: some View {
        VStack(spacing: 16) {
            // Card preview
            cardPreview
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(.systemBackground))
                        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
                )
                .padding(.horizontal)

            // Quote input
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a quote or note (optional)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Type a favorite quote...", text: $quoteText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Quote or note")
            }
            .padding(.horizontal)

            // Share button
            Button {
                onGenerate(quoteText)
            } label: {
                Label("Share Card", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal)
            .accessibilityLabel("Share Card")
        }
        .padding(.vertical)
    }

    private var cardPreview: some View {
        HStack(spacing: 16) {
            // Cover
            if let cover = card.coverImage {
                Image(uiImage: cover)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 100, height: 150)
                    .cornerRadius(8)
                    .shadow(radius: 2)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 100, height: 150)
                    .overlay(
                        Image(systemName: "book.closed.fill")
                            .font(.title)
                            .foregroundColor(.gray)
                    )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(card.title)
                    .font(.headline)
                    .lineLimit(2)

                Text(card.author)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if let rating = card.rating {
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { star in
                            Image(systemName: star <= rating ? "star.fill" : "star")
                                .foregroundColor(.orange)
                                .font(.caption)
                        }
                    }
                }

                if !quoteText.isEmpty {
                    Text("\"\(quoteText)\"")
                        .font(.caption)
                        .italic()
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Text(ShareableBookCard.brandingText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(height: 180)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Share card for \(card.title) by \(card.author)"
        )
    }
}
