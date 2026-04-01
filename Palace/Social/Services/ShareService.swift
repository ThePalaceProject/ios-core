//
//  ShareService.swift
//  Palace
//
//  Created for Social Features — sharing implementation.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI
import UIKit

/// Generates shareable text, images, and deep links for books.
final class ShareService: ShareServiceProtocol {

    // MARK: - Text

    func shareText(for book: TPPBook) -> String {
        let authorPart: String
        if let authors = book.authors, !authors.isEmpty {
            authorPart = " by \(authors)"
        } else {
            authorPart = ""
        }
        return "I'm reading \"\(book.title)\"\(authorPart) on Palace!"
    }

    // MARK: - Deep Link

    func deepLink(for book: TPPBook) -> URL? {
        let encoded = book.identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? book.identifier
        return URL(string: "palace://book/\(encoded)")
    }

    // MARK: - Share Card Rendering

    func renderShareCard(_ card: ShareableBookCard) -> UIImage? {
        let cardView = ShareCardRenderView(card: card)
        let controller = UIHostingController(rootView: cardView)
        let size = CGSize(width: 600, height: 400)
        controller.view.bounds = CGRect(origin: .zero, size: size)
        controller.view.backgroundColor = .clear
        controller.view.layoutIfNeeded()

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            controller.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
    }

    // MARK: - Activity Items

    func shareItems(for book: TPPBook, cardImage: UIImage?) -> [Any] {
        var items: [Any] = [shareText(for: book)]
        if let image = cardImage {
            items.append(image)
        }
        if let link = deepLink(for: book) {
            items.append(link)
        }
        return items
    }
}

// MARK: - Private Rendering View

/// Internal SwiftUI view used only for image rendering. Not shown to users directly.
private struct ShareCardRenderView: View {
    let card: ShareableBookCard

    var body: some View {
        HStack(spacing: 20) {
            // Cover image
            if let cover = card.coverImage {
                Image(uiImage: cover)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 160, height: 240)
                    .cornerRadius(8)
                    .shadow(radius: 4)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 160, height: 240)
                    .overlay(
                        Image(systemName: "book.closed.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                    )
            }

            // Text content
            VStack(alignment: .leading, spacing: 8) {
                Text(card.title)
                    .font(.title2.bold())
                    .foregroundColor(.primary)
                    .lineLimit(3)

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

                if !card.quote.isEmpty {
                    Text("\"\(card.quote)\"")
                        .font(.caption)
                        .italic()
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                }

                Spacer()

                Text(ShareableBookCard.brandingText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 16)
        }
        .padding(20)
        .frame(width: 600, height: 400)
        .background(Color(.systemBackground))
    }
}
